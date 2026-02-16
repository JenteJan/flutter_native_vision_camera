package dev.jentejan.flutter_native_vision_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.SurfaceTexture
import android.hardware.camera2.CameraCharacteristics
import android.hardware.camera2.CameraCaptureSession
import android.hardware.camera2.CameraDevice
import android.hardware.camera2.CameraManager
import android.hardware.camera2.CaptureRequest
import android.hardware.camera2.TotalCaptureResult
import android.hardware.camera2.params.OutputConfiguration
import android.hardware.camera2.params.SessionConfiguration
import android.media.Image
import android.media.ImageReader
import android.media.MediaRecorder
import android.media.ImageWriter
import android.util.Size
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.common.InputImage
import android.graphics.Bitmap
import android.graphics.BitmapFactory
import android.graphics.Matrix
import android.graphics.Rect
import android.hardware.camera2.params.MeteringRectangle
import android.os.Build
import android.os.Handler
import android.os.HandlerThread
import android.util.Log
import android.view.Surface
import android.view.OrientationEventListener
import java.io.File
import java.io.FileOutputStream
import java.nio.ByteBuffer
import java.text.SimpleDateFormat
import java.util.Date
import java.util.Locale
import java.util.concurrent.Executor
import java.util.concurrent.Executors
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.exifinterface.media.ExifInterface
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.util.concurrent.ConcurrentHashMap
import java.util.concurrent.atomic.AtomicInteger

/**
 * Android implementation of the Flutter Native Vision Camera plugin.
 *
 * Uses Camera2 API for camera access, Flutter TextureRegistry for
 * zero-copy GPU preview, and MethodChannel for control commands.
 */
class FlutterNativeVisionCameraPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener {

    // Native dispatcher
    private external fun nativeDispatchFrame(buffer: java.nio.ByteBuffer, width: Int, height: Int, format: Int, orientation: Int, timestamp: Double, id: Long, address: Long)
    private external fun nativeSetFrameProcessorCallback(callback: Long)

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var context: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null

    private var cameraManager: CameraManager? = null
    private var cameraDevice: CameraDevice? = null
    private var captureSession: CameraCaptureSession? = null
    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    private var previewSurface: Surface? = null
    private var photoReader: ImageReader? = null
    private var frameReader: ImageReader? = null
    @Volatile private var isFrameProcessorEnabled = false
    private var mediaRecorder: MediaRecorder? = null
    private var videoPath: String? = null
    private var lastZoom: Float = 1.0f // Track zoom level
    private var lastAFTriggerZoom: Float = 1.0f
    private var lastTorchMode: String = "off"
    private var lastExposure: Int = 0
    private var isFrontCamera: Boolean = false
    private var activeDeviceId: String? = null
    private var isManualFocusActive: Boolean = false
    @Volatile private var isActive: Boolean = false
    
    private var barcodeScanner: BarcodeScanner? = null
    @Volatile private var isCodeScannerEnabled = false
    private var currentFormat: Map<String, Any>? = null
    
    // Video Metadata Tracking
    private var videoWidth = 1920
    private var videoHeight = 1080
    private var recordingStartTime: Long = 0

    private var backgroundThread: HandlerThread? = null
    private var backgroundHandler: Handler? = null
    private val isProcessingCode = java.util.concurrent.atomic.AtomicBoolean(false)
    private var lastScanTime: Long = 0
    private val scanThrottleMs: Long = 200 // Max 5 scans per second

    private var mainHandler: Handler = Handler(android.os.Looper.getMainLooper())
    private var mainExecutor: Executor = Executor { command -> mainHandler.post(command) }
    
    private var orientationEventListener: OrientationEventListener? = null
    private var physicalOrientation: Int = Surface.ROTATION_0

    private class ManagedImage(val image: Image) {
        val refCount = AtomicInteger(1)
    }

    companion object {
        private const val CHANNEL_NAME = "dev.jentejan.flutter_native_vision_camera/camera"
        private const val CAMERA_PERMISSION_REQUEST = 1001

        private val frameIdCounter = java.util.concurrent.atomic.AtomicLong(0)

        // Static frame management to allow easy C -> JNI release calls
        private val activeFrames = ConcurrentHashMap<Long, ManagedImage>()

        @JvmStatic
        @androidx.annotation.Keep
        fun releaseFrame(id: Long): Int {
            val managed = activeFrames[id] ?: return 0
            val currentCount = managed.refCount.decrementAndGet()
            if (currentCount <= 0) {
                activeFrames.remove(id)
                try {
                    managed.image.close()
                } catch (e: Exception) {
                    Log.e("CameraPlugin", "Failed to close image $id: ${e.message}")
                }
                return 0
            }
            return currentCount
        }

        fun clearFrames() {
            Log.d("CameraPlugin", "Clearing all ${activeFrames.size} active frames")
            activeFrames.forEach { (id, managed) ->
                try {
                    managed.image.close()
                } catch (e: Exception) {}
            }
            activeFrames.clear()
        }

        init {
            System.loadLibrary("flutter_native_vision_camera")
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        channel = MethodChannel(binding.binaryMessenger, CHANNEL_NAME)
        channel.setMethodCallHandler(this)
        textureRegistry = binding.textureRegistry
        context = binding.applicationContext
        cameraManager = context.getSystemService(Context.CAMERA_SERVICE) as CameraManager
        startOrientationListener()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopOrientationListener()
        channel.setMethodCallHandler(null)
        releaseCamera(true)
    }

    private fun startOrientationListener() {
        if (orientationEventListener != null) return
        orientationEventListener = object : OrientationEventListener(context) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                physicalOrientation = when {
                    orientation < 45 || orientation > 315 -> Surface.ROTATION_0
                    orientation in 45..134 -> Surface.ROTATION_270
                    orientation in 135..224 -> Surface.ROTATION_180
                    orientation in 225..314 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
            }
        }
        orientationEventListener?.enable()
    }

    private fun stopOrientationListener() {
        orientationEventListener?.disable()
        orientationEventListener = null
    }

    override fun onAttachedToActivity(binding: ActivityPluginBinding) {
        activity = binding.activity
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivityForConfigChanges() {
        activity = null
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onReattachedToActivityForConfigChanges(binding: ActivityPluginBinding) {
        activity = binding.activity
        this.binding = binding
        binding.addRequestPermissionsResultListener(this)
    }

    override fun onDetachedFromActivity() {
        releaseCamera(false)
        activity = null
        binding?.removeRequestPermissionsResultListener(this)
        binding = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        when (call.method) {
            "getAvailableCameraDevices" -> getAvailableCameraDevices(result)
            "initialize" -> {
                val deviceId = call.argument<String>("deviceId") ?: ""
                val format = call.argument<Map<String, Any>>("format")
                val enablePhoto = call.argument<Boolean>("enablePhoto") ?: false
                val enableVideo = call.argument<Boolean>("enableVideo") ?: false
                val codeScanner = call.argument<Map<String, Any>>("codeScanner")
                initializeCamera(deviceId, format, enablePhoto, enableVideo, codeScanner, result)
            }
            "setActive" -> {
                val isActive = call.argument<Boolean>("isActive") ?: call.argument<Boolean>("active") ?: false
                setActive(isActive, result)
            }
            "setZoom" -> {
                val zoom = call.argument<Double>("zoom") ?: 1.0
                setZoom(zoom, result)
            }
            "setTorch" -> {
                val mode = call.argument<String>("mode") ?: "off"
                setTorch(mode, result)
            }
            "setExposure" -> {
                val exposure = call.argument<Double>("exposure") ?: 0.0
                setExposure(exposure, result)
            }
            "focus" -> {
                val x = call.argument<Double>("x") ?: 0.5
                val y = call.argument<Double>("y") ?: 0.5
                focus(x, y, result)
            }
            "takePhoto" -> {
                val options = call.arguments as? Map<String, Any> ?: emptyMap()
                takePhoto(options, result)
            }
            "startRecording" -> {
                val path = call.argument<String>("path")
                val flash = call.argument<String>("flash") ?: "off"
                val fileType = call.argument<String>("fileType") ?: "mp4"
                startRecording(path, flash, fileType, result)
            }
            "stopRecording" -> {
                stopRecording(result)
            }
            "pauseRecording" -> {
                pauseRecording(result)
            }
            "resumeRecording" -> {
                resumeRecording(result)
            }
            "cancelRecording" -> {
                cancelRecording(result)
            }
            "setFrameProcessor" -> {
                isFrameProcessorEnabled = call.argument<Boolean>("enabled") ?: false
                updateRepeatingRequest()
                result.success(null)
            }
            "setCodeScanner" -> {
                val config = call.argument<Map<String, Any>>("codeScanner")
                updateCodeScanner(config)
                updateRepeatingRequest()
                result.success(null)
            }
            "takeSnapshot" -> {
                takeSnapshot(result)
            }
            "getCameraPermissionStatus" -> getCameraPermissionStatus(result)
            "requestCameraPermission" -> requestCameraPermission(result)
            "getMicrophonePermissionStatus" -> getMicrophonePermissionStatus(result)
            "requestMicrophonePermission" -> requestMicrophonePermission(result)
            "setFocusDistance" -> {
                val distance = call.argument<Double>("distance") ?: 0.0
                setFocusDistance(distance, result)
            }
            "dispose" -> {
                releaseCamera(true)
                result.success(null)
            }
            else -> result.notImplemented()
        }
    }

    // ─── Device Discovery ──────────────────────────────────────────────

    private fun getAvailableCameraDevices(result: MethodChannel.Result) {
        val manager = cameraManager ?: run {
            result.error("CAMERA_ERROR", "CameraManager not available", null)
            return
        }

        val devices = manager.cameraIdList.map { id ->
            val chars = manager.getCameraCharacteristics(id)
            deviceToMap(id, chars)
        }
        result.success(devices)
    }

    private fun deviceToMap(id: String, chars: CameraCharacteristics): Map<String, Any?> {
        val facing = chars.get(CameraCharacteristics.LENS_FACING)
        val position = when (facing) {
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "back"
        }

        val sensorSize = chars.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)
        val hasTorch = chars.get(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

        val zoomRange = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            chars.get(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)
        } else null

        val minZoom = zoomRange?.lower?.toDouble() ?: 1.0
        val maxZoom = (chars.get(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1.0f).toDouble()

        val exposureRange = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)
        val exposureStep = chars.get(CameraCharacteristics.CONTROL_AE_COMPENSATION_STEP)

        val hardwareLevel = when (chars.get(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level-3"
            else -> "legacy"
        }

        // Build format list from stream configuration map
        val configMap = chars.get(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val formats = mutableListOf<Map<String, Any?>>()

        if (configMap != null) {
            val previewSizes = configMap.getOutputSizes(SurfaceTexture::class.java)
            val photoSizes = configMap.getOutputSizes(android.graphics.ImageFormat.JPEG)?.toSet() ?: emptySet()
            val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)

            previewSizes?.forEach { size ->
                val minFps = fpsRanges?.minByOrNull { it.lower }?.lower ?: 15
                val maxFps = fpsRanges?.maxByOrNull { it.upper }?.upper ?: 30

                // If this exact size is supported as a photo, use it. 
                // Otherwise, find the best matching aspect ratio.
                val photoSize = if (photoSizes.contains(size)) {
                    size
                } else {
                    val aspectRatio = size.width.toDouble() / size.height.toDouble()
                    photoSizes.filter { 
                        Math.abs((it.width.toDouble() / it.height.toDouble()) - aspectRatio) < 0.1 
                    }.maxByOrNull { it.width * it.height } ?: photoSizes.maxByOrNull { it.width * it.height } ?: size
                }

                formats.add(mapOf(
                    "photoHeight" to photoSize.height,
                    "photoWidth" to photoSize.width,
                    "videoHeight" to size.height,
                    "videoWidth" to size.width,
                    "minFps" to minFps,
                    "maxFps" to maxFps,
                    "minISO" to (chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.lower ?: 100),
                    "maxISO" to (chars.get(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.upper ?: 3200),
                    "fieldOfView" to 0.0, // TODO: calculate from focal length + sensor size
                    "maxZoom" to maxZoom,
                    "supportsVideoHdr" to false,
                    "supportsPhotoHdr" to false,
                    "supportsDepthCapture" to false,
                    "autoFocusSystem" to "contrast-detection",
                    "videoStabilizationModes" to listOf("off"),
                    "pixelFormats" to listOf("yuv"),
                ))
            }
        }

        val sensorOrientationDegrees = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        val sensorOrientation = when (sensorOrientationDegrees) {
            0 -> "portrait"
            90 -> "landscape-left"
            180 -> "portrait-upside-down"
            270 -> "landscape-right"
            else -> "portrait"
        }

        return mapOf(
            "id" to id,
            "name" to "Camera $id ($position)",
            "position" to position,
            "hasFlash" to hasTorch,
            "hasTorch" to hasTorch,
            "minFocusDistance" to 0.0,
            "isMultiCam" to false,
            "minZoom" to minZoom,
            "maxZoom" to maxZoom,
            "neutralZoom" to 1.0,
            "minExposure" to (exposureRange?.lower?.toDouble() ?: 0.0),
            "maxExposure" to (exposureRange?.upper?.toDouble() ?: 0.0),
            "supportsLowLightBoost" to false,
            "supportsRawCapture" to false,
            "supportsFocus" to true,
            "hardwareLevel" to hardwareLevel,
            "sensorOrientation" to sensorOrientation,
            "physicalDevices" to listOf("wide-angle-camera"),
            "formats" to formats,
        )
    }

    // ─── Camera Initialization ─────────────────────────────────────────

    @Suppress("MissingPermission")
    private fun initializeCamera(
        deviceId: String,
        format: Map<String, Any>?,
        enablePhoto: Boolean,
        enableVideo: Boolean,
        codeScanner: Map<String, Any>?,
        result: MethodChannel.Result
    ) {
        val safeResult = SafeResult(result)
        releaseCamera(false) // Close existing session/camera first, don't stop thread
        startBackgroundThread() // Only starts if not already running
        updateCodeScanner(codeScanner)
        lastZoom = 1.0f
        lastTorchMode = "off"
        lastExposure = 0
        currentFormat = format
        activeDeviceId = deviceId

        val manager = cameraManager ?: run {
            safeResult.error("CAMERA_ERROR", "CameraManager not available", null)
            return
        }

        val chars = manager.getCameraCharacteristics(deviceId)
        isFrontCamera = chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT

        // Create surface producer for preview.
        val producer = textureRegistry.createSurfaceProducer()
        surfaceProducer = producer

        manager.openCamera(deviceId, object : CameraDevice.StateCallback() {
            override fun onOpened(camera: CameraDevice) {
                cameraDevice = camera
                createPreviewSession(camera, producer, format, safeResult)
            }

            override fun onDisconnected(camera: CameraDevice) {
                camera.close()
                cameraDevice = null
                activity?.runOnUiThread {
                    channel.invokeMethod("onError", mapOf(
                        "code" to "device-disconnected",
                        "message" to "Camera device disconnected",
                    ))
                }
            }

            override fun onError(camera: CameraDevice, error: Int) {
                camera.close()
                cameraDevice = null
                safeResult.error("CAMERA_ERROR", "Failed to open camera: error $error", null)
            }
        }, mainHandler)
    }

    private fun createPreviewSession(
        camera: CameraDevice,
        producer: TextureRegistry.SurfaceProducer,
        format: Map<String, Any>?,
        result: MethodChannel.Result
    ) {
        val safeResult = if (result is SafeResult) result else SafeResult(result)
        val previewWidth = format?.get("videoWidth") as? Int ?: 1920
        val previewHeight = format?.get("videoHeight") as? Int ?: 1080
        val photoWidth = format?.get("photoWidth") as? Int ?: 1920
        val photoHeight = format?.get("photoHeight") as? Int ?: 1080

        Log.d("CameraPlugin", "Initializing camera with resolved format: Preview ${previewWidth}x${previewHeight}, Photo ${photoWidth}x${photoHeight}")
        
        val chars = cameraManager!!.getCameraCharacteristics(camera.id)
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
        Log.d("CameraPlugin", "Sensor Orientation: $sensorOrientation")
        
        producer.setSize(previewWidth, previewHeight)
        val surface = producer.surface
        previewSurface = surface

        // Setup Photo Reader
        photoReader = ImageReader.newInstance(photoWidth, photoHeight, android.graphics.ImageFormat.JPEG, 2)
        
        // Setup Frame Processor Reader (YUV_420_888 for zero-copy)
        // Set to 30 to prevent starvation on fast sensors or slow processors
        frameReader = ImageReader.newInstance(previewWidth, previewHeight, android.graphics.ImageFormat.YUV_420_888, 30)
        frameReader?.setOnImageAvailableListener({ reader ->
            val image = try {
                // Use acquireNextImage to ensure we handle every event and release properly
                reader.acquireNextImage()
            } catch (e: Exception) {
                null
            } ?: return@setOnImageAvailableListener

            if (!isActive || (!isFrameProcessorEnabled && !isCodeScannerEnabled)) {
                image.close()
                return@setOnImageAvailableListener
            }

            val id = frameIdCounter.incrementAndGet()
            if (id % 60 == 0L) {
                val activeCount = activeFrames.size
                Log.d("CameraPlugin", "Frame $id received (active=$activeCount, scanner=$isCodeScannerEnabled)")
                if (activeCount > 10) {
                    Log.w("CameraPlugin", "Warning: High active frame count ($activeCount). Possible leak?")
                }
            }

            val managed = ManagedImage(image)
            activeFrames[id] = managed

            try {
                // ... logic moved into try block ...
                var inputImage: InputImage? = null
                val now = System.currentTimeMillis()
                val scanning = isProcessingCode.get()
                val shouldScan = isCodeScannerEnabled && !scanning && (now - lastScanTime) > scanThrottleMs
                
                if (shouldScan) {
                    try {
                        val rotation = getMlKitRotation()
                        inputImage = InputImage.fromMediaImage(image, rotation)
                    } catch (e: Exception) {
                        Log.e("CameraPlugin", "MLKit: Failed to create InputImage: ${e.message}")
                    }
                }

                // 1. Dispatch to Native/C++ (Synchronous)
                managed.refCount.incrementAndGet()
                val yBuffer = image.planes[0].buffer
                nativeDispatchFrame(yBuffer, image.width, image.height, 0x23, sensorOrientation, image.timestamp.toDouble() / 1e9, id, 0L)
                
                // 2. MLKit Dispatch (Asynchronous, Throttled)
                if (shouldScan && inputImage != null) {
                    val scanner = barcodeScanner
                    if (scanner != null && isActive) {
                        try {
                            isProcessingCode.set(true)
                            lastScanTime = now
                            Log.d("CameraPlugin", "MLKit: Starting code scan for frame $id...")
                            
                            managed.refCount.incrementAndGet()
                            scanner.process(inputImage)
                                .addOnSuccessListener { barcodes ->
                                    if (isActive) {
                                        val rotation = getMlKitRotation()
                                        val isRotated = rotation == 90 || rotation == 270
                                        val logicalWidth = if (isRotated) image.height else image.width
                                        val logicalHeight = if (isRotated) image.width else image.height

                                        val resultList = barcodes.map { barcode ->
                                            val box = barcode.boundingBox
                                            mapOf(
                                                "type" to barcodeFormatToString(barcode.format),
                                                "value" to barcode.rawValue,
                                                "frame" to if (box != null) mapOf(
                                                    "x" to box.left.toDouble() / logicalWidth.toDouble(),
                                                    "y" to box.top.toDouble() / logicalHeight.toDouble(),
                                                    "width" to box.width().toDouble() / logicalWidth.toDouble(),
                                                    "height" to box.height().toDouble() / logicalHeight.toDouble()
                                                ) else null
                                            )
                                        }

                                        mainHandler.post {
                                            if (resultList.isNotEmpty()) {
                                                Log.d("CameraPlugin", "MLKit: Invoking onCodeScanned (MainThread) with ${resultList.size} codes")
                                            }
                                            channel.invokeMethod("onCodeScanned", resultList)
                                        }
                                    }
                                }
                                .addOnFailureListener { e ->
                                    if (isActive) Log.e("CameraPlugin", "MLKit: Processing Error for frame $id", e)
                                }
                                .addOnCompleteListener {
                                    isProcessingCode.set(false)
                                    FlutterNativeVisionCameraPlugin.releaseFrame(id)
                                }
                        } catch (e: Exception) {
                            Log.e("CameraPlugin", "MLKit: Scanner task exception for frame $id", e)
                            isProcessingCode.set(false)
                            FlutterNativeVisionCameraPlugin.releaseFrame(id)
                        }
                    }
                }
            } finally {
                // 3. Release the base reference for this acquisition loop
                FlutterNativeVisionCameraPlugin.releaseFrame(id)
            }
        }, backgroundHandler)

        val surfaces = mutableListOf(surface, photoReader!!.surface, frameReader!!.surface)

        val previewRequest = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
            addTarget(surface)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_VIDEO)
            
            // Maximize FPS
            val fpsRanges = chars.get(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)
            val maxFpsRange = fpsRanges?.maxByOrNull { it.upper }
            if (maxFpsRange != null) {
                set(CaptureRequest.CONTROL_AE_TARGET_FPS_RANGE, maxFpsRange)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
            }
        }

        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
            val outputConfigs = surfaces.map { OutputConfiguration(it) }
            val sessionConfig = SessionConfiguration(
                SessionConfiguration.SESSION_REGULAR,
                outputConfigs,
                mainExecutor,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        updateRepeatingRequest()
                            
                        // Prime the session with a single capture to kickstart the pipeline
                        try {
                            val primeBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
                            primeBuilder.addTarget(surface)
                            session.capture(primeBuilder.build(), null, backgroundHandler)
                        } catch (e: Exception) {
                            Log.e("CameraPlugin", "Priming failed: ${e.message}")
                        }

                        result.success(mapOf(
                            "textureId" to producer.id(),
                            "previewWidth" to previewWidth,
                            "previewHeight" to previewHeight
                        ))
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        result.error("CAMERA_ERROR", "Failed to configure capture session", null)
                    }
                }
            )
            camera.createCaptureSession(sessionConfig)
        } else {
            @Suppress("DEPRECATION")
            camera.createCaptureSession(
                surfaces,
                object : CameraCaptureSession.StateCallback() {
                    override fun onConfigured(session: CameraCaptureSession) {
                        captureSession = session
                        try {
                            session.capture(previewRequest.build(), null, backgroundHandler)
                            session.setRepeatingRequest(
                                previewRequest.build(),
                                null,
                                backgroundHandler,
                            )
                        } catch (e: Exception) {
                            Log.e("CameraPlugin", "Failed to start preview: ${e.message}")
                        }
                        result.success(mapOf(
                            "textureId" to producer.id(),
                            "previewWidth" to previewWidth,
                            "previewHeight" to previewHeight
                        ))
                    }

                    override fun onConfigureFailed(session: CameraCaptureSession) {
                        result.error("CAMERA_ERROR", "Failed to configure capture session", null)
                    }
                },
                backgroundHandler,
            )
        }
    }

    // ─── Photo Capture ────────────────────────────────────────────────

    private fun takePhoto(options: Map<String, Any>, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        val camera = cameraDevice ?: run {
            safeResult.error("CAMERA_ERROR", "Camera not initialized", null)
            return
        }
        val session = captureSession ?: run {
            safeResult.error("CAMERA_ERROR", "Capture session not ready", null)
            return
        }
        val reader = photoReader ?: run {
            safeResult.error("CAMERA_ERROR", "Photo reader not ready", null)
            return
        }

        val flash = options["flash"] as? String ?: "off"
        val enableHdr = options["enableHdr"] as? Boolean ?: false
        val path = options["path"] as? String
        val location = options["location"] as? Map<String, Any>

        val rotation = physicalOrientation

        val captureRequest = camera.createCaptureRequest(CameraDevice.TEMPLATE_STILL_CAPTURE).apply {
            addTarget(reader.surface)
            set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            set(CaptureRequest.FLASH_MODE, if (flash == "on") CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
            
            val manager = cameraManager!!
            val chars = manager.getCameraCharacteristics(camera.id)
            val orientation = getJpegOrientation(chars, rotation)
            set(CaptureRequest.JPEG_ORIENTATION, orientation)
            Log.i("CameraPlugin", "Photo JPEG Orientation: $orientation (physical: $rotation)")
            
            if (enableHdr) {
                set(CaptureRequest.CONTROL_SCENE_MODE, CaptureRequest.CONTROL_SCENE_MODE_HDR)
                set(CaptureRequest.CONTROL_MODE, CaptureRequest.CONTROL_MODE_USE_SCENE_MODE)
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
            }
        }

        reader.setOnImageAvailableListener({ reader ->
            val image = reader.acquireLatestImage() ?: return@setOnImageAvailableListener
            
            val buffer = image.planes[0].buffer
            val bytes = ByteArray(buffer.remaining())
            buffer.get(bytes)
            image.close()

            try {
                val file = if (path != null) {
                    File(path, "photo_${System.currentTimeMillis()}.jpg")
                } else {
                    File(context.cacheDir, "photo_${System.currentTimeMillis()}.jpg")
                }

                val manager = cameraManager!!
                val chars = manager.getCameraCharacteristics(camera.id)
                val isFrontCamera = chars.get(CameraCharacteristics.LENS_FACING) == CameraCharacteristics.LENS_FACING_FRONT

                val finalBitmap = if (isFrontCamera) {
                    val bitmap = BitmapFactory.decodeByteArray(bytes, 0, bytes.size)
                    if (bitmap != null) {
                        val matrix = Matrix()
                        val rotationDegrees = getJpegOrientation(chars, rotation)
                        matrix.postRotate(rotationDegrees.toFloat())
                        matrix.postScale(-1.0f, 1.0f)
                        
                        val processed = Bitmap.createBitmap(bitmap, 0, 0, bitmap.width, bitmap.height, matrix, true)
                        bitmap.recycle()
                        processed
                    } else null
                } else null

                if (finalBitmap != null) {
                    FileOutputStream(file).use { finalBitmap.compress(Bitmap.CompressFormat.JPEG, 95, it) }
                } else {
                    FileOutputStream(file).use { it.write(bytes) }
                }
                
                location?.let {
                    try {
                        val exif = ExifInterface(file.absolutePath)
                        val lat = it["latitude"] as? Double ?: 0.0
                        val lon = it["longitude"] as? Double ?: 0.0
                        exif.setLatLong(lat, lon)
                        if (it.containsKey("altitude")) {
                            exif.setAttribute(ExifInterface.TAG_GPS_ALTITUDE, it["altitude"].toString())
                        }
                        exif.saveAttributes()
                    } catch (e: Exception) {
                        Log.e("CameraPlugin", "EXIF Error: ${e.message}")
                    }
                }

                activity?.runOnUiThread {
                    val w = finalBitmap?.width ?: reader.width
                    val h = finalBitmap?.height ?: reader.height
                    finalBitmap?.recycle()
                    
                    // Clear the listener so we don't catch extra frames
                    reader.setOnImageAvailableListener(null, null)
                    
                    safeResult.success(mapOf(
                        "path" to file.absolutePath,
                        "width" to w,
                        "height" to h,
                        "isRawPhoto" to false,
                        "orientation" to if (h > w) "portrait" else "landscape-left",
                        "isMirrored" to isFrontCamera
                    ))
                }
            } catch (e: Exception) {
                activity?.runOnUiThread {
                    reader.setOnImageAvailableListener(null, null)
                    safeResult.error("CAPTURE_ERROR", "Failed to save photo: ${e.message}", null)
                }
            }
        }, backgroundHandler)

        try {
            session.capture(captureRequest.build(), null, backgroundHandler)
        } catch (e: Exception) {
            photoReader?.setOnImageAvailableListener(null, null)
            safeResult.error("CAPTURE_ERROR", "Failed to trigger capture: ${e.message}", null)
        }
    }

    // ─── Video Recording ──────────────────────────────────────────────

    private fun startRecording(path: String?, flash: String, fileType: String, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        val camera = cameraDevice ?: run {
            safeResult.error("CAMERA_ERROR", "Camera not initialized", null)
            return
        }
        
        videoWidth = currentFormat?.get("videoWidth") as? Int ?: 1920
        videoHeight = currentFormat?.get("videoHeight") as? Int ?: 1080
        val outputFilePath = path ?: File(context.cacheDir, "video_${System.currentTimeMillis()}.mp4").absolutePath
        videoPath = outputFilePath

        val rotation = physicalOrientation // Use real physical rotation instead of UI lock

        try {
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.S) {
                mediaRecorder = MediaRecorder(context)
            } else {
                @Suppress("DEPRECATION")
                mediaRecorder = MediaRecorder()
            }

            val manager = cameraManager!!
            val chars = manager.getCameraCharacteristics(camera.id)
            val orientationHint = getJpegOrientation(chars, rotation)
            Log.i("CameraPlugin", "Starting recording with orientationHint: $orientationHint (using physicalOrientation: $rotation)")

            mediaRecorder?.apply {
                setAudioSource(MediaRecorder.AudioSource.MIC)
                setVideoSource(MediaRecorder.VideoSource.SURFACE)
                setOutputFormat(MediaRecorder.OutputFormat.MPEG_4)
                setVideoEncoder(MediaRecorder.VideoEncoder.H264)
                setAudioEncoder(MediaRecorder.AudioEncoder.AAC)
                setVideoEncodingBitRate(10000000)
                setVideoFrameRate(30)
                setVideoSize(videoWidth, videoHeight)
                setOrientationHint(orientationHint)
                setOutputFile(outputFilePath)
                prepare()
            }

            val videoSurface = mediaRecorder!!.surface
            
            // Reconfigure session to include video surface
            val surfaces = mutableListOf(previewSurface!!, videoSurface)
            photoReader?.let { surfaces.add(it.surface) }
            frameReader?.let { surfaces.add(it.surface) }

            lastTorchMode = flash

            val stateCallback = object : CameraCaptureSession.StateCallback() {
                override fun onConfigured(session: CameraCaptureSession) {
                    captureSession = session
                    try {
                        updateRepeatingRequest()
                        mediaRecorder?.start()
                        recordingStartTime = System.currentTimeMillis()
                        safeResult.success(null)
                    } catch (e: Exception) {
                        safeResult.error("RECORD_ERROR", "Failed to start recording: ${e.message}", null)
                    }
                }

                override fun onConfigureFailed(session: CameraCaptureSession) {
                    safeResult.error("RECORD_ERROR", "Failed to configure video session", null)
                }
            }

            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.P) {
                val outputConfigs = surfaces.map { OutputConfiguration(it) }
                camera.createCaptureSession(SessionConfiguration(
                    SessionConfiguration.SESSION_REGULAR, 
                    outputConfigs, 
                    mainExecutor, 
                    stateCallback
                ))
            } else {
                @Suppress("DEPRECATION")
                camera.createCaptureSession(surfaces, stateCallback, backgroundHandler)
            }

        } catch (e: Exception) {
            safeResult.error("RECORD_ERROR", "Failed to prepare recorder: ${e.message}", null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        try {
            mediaRecorder?.apply {
                stop()
                reset()
                release()
            }
            mediaRecorder = null
            
            val duration = (System.currentTimeMillis() - recordingStartTime) / 1000.0
            val metadata = mapOf(
                "path" to (videoPath ?: ""),
                "duration" to duration,
                "width" to videoWidth,
                "height" to videoHeight
            )
            revertToPreview(safeResult, metadata)
        } catch (e: Exception) {
            safeResult.error("RECORD_ERROR", "Failed to stop recording: ${e.message}", null)
        }
    }

    private fun cancelRecording(result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        try {
            mediaRecorder?.apply {
                stop()
                reset()
                release()
            }
            mediaRecorder = null
            videoPath?.let { File(it).delete() }
            revertToPreview(safeResult, null)
        } catch (e: Exception) {
            safeResult.error("RECORD_ERROR", "Failed to cancel recording: ${e.message}", null)
        }
    }

    private fun revertToPreview(result: SafeResult, finalMetadata: Map<String, Any>?) {
        val camera = cameraDevice
        val producer = surfaceProducer
        if (camera != null && producer != null) {
            createPreviewSession(camera, producer, currentFormat, object : MethodChannel.Result {
                override fun success(res: Any?) {
                    result.success(finalMetadata)
                }
                override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
                    result.error(errorCode, errorMessage, errorDetails)
                }
                override fun notImplemented() {
                    result.notImplemented()
                }
            })
        } else {
            result.success(finalMetadata)
        }
    }

    private fun pauseRecording(result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                mediaRecorder?.pause()
                safeResult.success(null)
            } catch (e: Exception) {
                safeResult.error("RECORD_ERROR", "Failed to pause recording: ${e.message}", null)
            }
        } else {
            safeResult.error("UNSUPPORTED", "Pause recording requires Android 7.0+", null)
        }
    }

    private fun resumeRecording(result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.N) {
            try {
                mediaRecorder?.resume()
                safeResult.success(null)
            } catch (e: Exception) {
                safeResult.error("RECORD_ERROR", "Failed to resume recording: ${e.message}", null)
            }
        } else {
            safeResult.error("UNSUPPORTED", "Resume recording requires Android 7.0+", null)
        }
    }


    // ─── Code Scanner ─────────────────────────────────────────────────

    private fun getMlKitRotation(): Int {
        val deviceId = activeDeviceId ?: return 0
        val chars = cameraManager?.getCameraCharacteristics(deviceId) ?: return 0
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        
        // physicalOrientation is set by OrientationEventListener as Surface.ROTATION_0, 90, 180, 270
        val rotationDegrees = when (physicalOrientation) {
            Surface.ROTATION_0 -> 0
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }

        return if (isFrontCamera) {
            (sensorOrientation + rotationDegrees) % 360
        } else {
            (sensorOrientation - rotationDegrees + 360) % 360
        }
    }

    private fun barcodeFormatToString(format: Int): String {
        return when (format) {
            Barcode.FORMAT_CODE_128 -> "code-128"
            Barcode.FORMAT_CODE_39 -> "code-39"
            Barcode.FORMAT_CODE_93 -> "code-93"
            Barcode.FORMAT_CODABAR -> "codabar"
            Barcode.FORMAT_EAN_13 -> "ean-13"
            Barcode.FORMAT_EAN_8 -> "ean-8"
            Barcode.FORMAT_ITF -> "itf"
            Barcode.FORMAT_UPC_A -> "upc-a"
            Barcode.FORMAT_UPC_E -> "upc-e"
            Barcode.FORMAT_QR_CODE -> "qr"
            Barcode.FORMAT_PDF417 -> "pdf-417"
            Barcode.FORMAT_AZTEC -> "aztec"
            Barcode.FORMAT_DATA_MATRIX -> "data-matrix"
            else -> "unknown"
        }
    }

    private fun updateCodeScanner(config: Map<String, Any>?) {
        if (config == null) {
            Log.d("CameraPlugin", "Disabling code scanner")
            isCodeScannerEnabled = false
            barcodeScanner?.close()
            barcodeScanner = null
            return
        }

        Log.d("CameraPlugin", "Enabling code scanner with config: $config")
        isCodeScannerEnabled = true
        val types = config["codeTypes"] as? List<String>
        val builder = BarcodeScannerOptions.Builder()
        
        if (types != null && types.isNotEmpty()) {
            val formats = mutableListOf<Int>()
            for (type in types) {
                when (type) {
                    "qr" -> formats.add(Barcode.FORMAT_QR_CODE)
                    "ean-13" -> formats.add(Barcode.FORMAT_EAN_13)
                    "ean-8" -> formats.add(Barcode.FORMAT_EAN_8)
                    "code-128" -> formats.add(Barcode.FORMAT_CODE_128)
                    "code-39" -> formats.add(Barcode.FORMAT_CODE_39)
                    "code-93" -> formats.add(Barcode.FORMAT_CODE_93)
                    "data-matrix" -> formats.add(Barcode.FORMAT_DATA_MATRIX)
                    "upc-a" -> formats.add(Barcode.FORMAT_UPC_A)
                    "upc-e" -> formats.add(Barcode.FORMAT_UPC_E)
                    "pdf-417" -> formats.add(Barcode.FORMAT_PDF417)
                    "aztec" -> formats.add(Barcode.FORMAT_AZTEC)
                    "itf" -> formats.add(Barcode.FORMAT_ITF)
                    "codabar" -> formats.add(Barcode.FORMAT_CODABAR)
                }
            }
            if (formats.isNotEmpty()) {
                if (formats.size == 1) {
                    builder.setBarcodeFormats(formats[0])
                } else {
                    builder.setBarcodeFormats(formats[0], *formats.subList(1, formats.size).toIntArray())
                }
            } else {
                builder.setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
            }
        } else {
            builder.setBarcodeFormats(Barcode.FORMAT_ALL_FORMATS)
        }
        
        barcodeScanner?.close()
        barcodeScanner = BarcodeScanning.getClient(builder.build())
    }

    // ─── Snapshot ─────────────────────────────────────────────────────

    private fun takeSnapshot(result: MethodChannel.Result) {
        val reader = frameReader ?: run {
            result.error("CAMERA_ERROR", "Frame reader not ready", null)
            return
        }

        // For absolute simplicity in this stub, we take the last frame from frameReader
        // and save it as a JPEG. In a real app, you might want a higher res snapshot.
        val image = reader.acquireLatestImage() ?: run {
             result.error("CAPTURE_ERROR", "No frame available for snapshot", null)
             return
        }

        val buffer = image.planes[0].buffer
        val bytes = ByteArray(buffer.remaining())
        buffer.get(bytes)
        image.close()

        val file = File(context.cacheDir, "snapshot_${System.currentTimeMillis()}.jpg")
        try {
            FileOutputStream(file).use { it.write(bytes) }
            result.success(mapOf(
                "path" to file.absolutePath,
                "width" to 1280,
                "height" to 720,
                "orientation" to "portrait",
                "isMirrored" to false
            ))
        } catch (e: Exception) {
            result.error("CAPTURE_ERROR", "Failed to save snapshot: ${e.message}", null)
        }
    }

    // ─── Permissions ───────────────────────────────────────────────────

    private fun getCameraPermissionStatus(result: MethodChannel.Result) {
        val status = ContextCompat.checkSelfPermission(context, Manifest.permission.CAMERA)
        result.success(if (status == PackageManager.PERMISSION_GRANTED) "granted" else "denied")
    }

    private fun requestCameraPermission(result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        pendingPermissionResult = result
        ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.CAMERA), CAMERA_PERMISSION_REQUEST)
    }

    override fun onRequestPermissionsResult(requestCode: Int, permissions: Array<out String>, grantResults: IntArray): Boolean {
        if (requestCode == CAMERA_PERMISSION_REQUEST) {
            val pendingResult = pendingPermissionResult ?: return false
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                pendingResult.success("granted")
            } else {
                pendingResult.success("denied")
            }
            pendingPermissionResult = null
            return true
        }
        return false
    }

    private fun getMicrophonePermissionStatus(result: MethodChannel.Result) {
        val status = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
        result.success(if (status == PackageManager.PERMISSION_GRANTED) "granted" else "denied")
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        val act = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.RECORD_AUDIO), CAMERA_PERMISSION_REQUEST + 1)
        result.success("granted") // Simplified.
    }

    // ─── Lifecycle ─────────────────────────────────────────────────────

    private fun setActive(isActive: Boolean, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        this.isActive = isActive
        if (isActive) {
            updateRepeatingRequest()
        } else {
            captureSession?.stopRepeating()
        }
        safeResult.success(null)
    }

    private fun setZoom(zoom: Double, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        if (cameraDevice == null || captureSession == null) {
            safeResult.error("CAMERA_ERROR", "Camera not ready", null)
            return
        }
        lastZoom = zoom.toFloat()
        updateRepeatingRequest()

        // Debounce focus trigger during rapid zoom transitions
        backgroundHandler?.removeCallbacks(afTriggerRunnable)
        backgroundHandler?.postDelayed(afTriggerRunnable, 300)

        safeResult.success(null)
    }

    private val afTriggerRunnable = Runnable {
        if (Math.abs(lastZoom - lastAFTriggerZoom) > 0.1f && !isManualFocusActive) {
            lastAFTriggerZoom = lastZoom
            triggerAutoFocus()
        }
    }

    private fun triggerAutoFocus() {
        val camera = cameraDevice ?: return
        val session = captureSession ?: return
        val surface = previewSurface ?: return
        try {
            // 1. Cancel previous AF state machine
            val cancelBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            cancelBuilder.addTarget(surface)
            mediaRecorder?.surface?.let { cancelBuilder.addTarget(it) }
            
            cancelBuilder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_CANCEL)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                cancelBuilder.set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
            }
            session.capture(cancelBuilder.build(), null, backgroundHandler)

            // 2. Immediate trigger
            val triggerBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            triggerBuilder.addTarget(surface)
            mediaRecorder?.surface?.let { triggerBuilder.addTarget(it) }
            
            triggerBuilder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            triggerBuilder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                triggerBuilder.set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
            }
            session.capture(triggerBuilder.build(), null, backgroundHandler)
        } catch (e: Exception) {
            Log.e("CameraPlugin", "Auto focus trigger failed", e)
        }
    }

    private fun setTorch(mode: String, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        if (cameraDevice == null || captureSession == null) {
            safeResult.error("CAMERA_ERROR", "Camera not ready", null)
            return
        }
        lastTorchMode = mode
        updateRepeatingRequest()
        safeResult.success(null)
    }

    private fun setExposure(exposure: Double, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        if (cameraDevice == null || captureSession == null) {
            safeResult.error("CAMERA_ERROR", "Camera not ready", null)
            return
        }
        lastExposure = exposure.toInt()
        updateRepeatingRequest()
        safeResult.success(null)
    }



    private fun setFocusDistance(distance: Double, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        val session = captureSession ?: run {
            safeResult.error("CAMERA_ERROR", "Capture session not ready", null)
            return
        }
        
        // Map distance (0.0 - 1.0) to (Infinity - minFocusDistance)
        // Camera2 focus distance is in diopters (1/m). 0 is infinity.
        val manager = cameraManager!!
        val chars = manager.getCameraCharacteristics(cameraDevice!!.id)
        val minDistance = chars.get(CameraCharacteristics.LENS_INFO_MINIMUM_FOCUS_DISTANCE) ?: 0.0f
        
        val lensPosition = (distance * minDistance).toFloat()
        
        try {
            val request = cameraDevice!!.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW).apply {
                addTarget(previewSurface!!)
                set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_OFF)
                set(CaptureRequest.LENS_FOCUS_DISTANCE, lensPosition)
                if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                    set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
                }
            }
            session.setRepeatingRequest(request.build(), null, backgroundHandler)
            safeResult.success(null)
        } catch (e: Exception) {
            safeResult.error("CAMERA_ERROR", "Failed to set focus distance: ${e.message}", null)
        }
    }

    private fun focus(x: Double, y: Double, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        val camera = cameraDevice ?: return
        val session = captureSession ?: run {
            safeResult.error("CAMERA_ERROR", "Capture session not ready", null)
            return
        }
        try {
            val characteristics = cameraManager!!.getCameraCharacteristics(camera.id)
            val arraySize = characteristics.get(CameraCharacteristics.SENSOR_INFO_ACTIVE_ARRAY_SIZE)!!
            val sensorOrientation = characteristics.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
            
            // Precise coordinate mapping from 0..1 to sensor coordinates
            var sensorX = 0
            var sensorY = 0
            
            when (sensorOrientation) {
                90 -> {
                    sensorX = (y * arraySize.width()).toInt()
                    sensorY = ((1.0 - x) * arraySize.height()).toInt()
                }
                270 -> {
                    sensorX = ((1.0 - y) * arraySize.width()).toInt()
                    sensorY = (x * arraySize.height()).toInt()
                }
                180 -> {
                    sensorX = ((1.0 - x) * arraySize.width()).toInt()
                    sensorY = ((1.0 - y) * arraySize.height()).toInt()
                }
                else -> { // 0 or other
                    sensorX = (x * arraySize.width()).toInt()
                    sensorY = (y * arraySize.height()).toInt()
                }
            }
            
            val halfSize = 120 // Slightly larger area for better reliability
            val focusRect = Rect(
                Math.max(0, sensorX - halfSize),
                Math.max(0, sensorY - halfSize),
                Math.min(arraySize.width(), sensorX + halfSize),
                Math.min(arraySize.height(), sensorY + halfSize)
            )
            
            val metering = MeteringRectangle(focusRect, MeteringRectangle.METERING_WEIGHT_MAX)
            
            // 1. Cancel previous AF state machine
            val cancelBuilder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            cancelBuilder.addTarget(previewSurface!!)
            mediaRecorder?.surface?.let { cancelBuilder.addTarget(it) } // Crucial: avoid flickering in recording
            
            cancelBuilder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_CANCEL)
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                cancelBuilder.set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom) // Crucial: avoid flickering when zoomed
            }
            session.capture(cancelBuilder.build(), null, backgroundHandler)

            // 2. Trigger new focus request
            val builder = camera.createCaptureRequest(CameraDevice.TEMPLATE_PREVIEW)
            builder.addTarget(previewSurface!!)
            mediaRecorder?.surface?.let { builder.addTarget(it) }
            
            builder.set(CaptureRequest.CONTROL_AF_REGIONS, arrayOf(metering))
            builder.set(CaptureRequest.CONTROL_AE_REGIONS, arrayOf(metering))
            builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
            builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_START)
            builder.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER, CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_START)
            
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
            }
            builder.set(CaptureRequest.FLASH_MODE, if (lastTorchMode == "on") CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)

            isManualFocusActive = true
            session.capture(builder.build(), null, backgroundHandler)
            
            // Resume repeating with AF_MODE_AUTO to hold focus
            builder.set(CaptureRequest.CONTROL_AF_TRIGGER, CaptureRequest.CONTROL_AF_TRIGGER_IDLE)
            builder.set(CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER, CaptureRequest.CONTROL_AE_PRECAPTURE_TRIGGER_IDLE)
            session.setRepeatingRequest(builder.build(), null, backgroundHandler)
            
            // Revert to continuous AF after 5 seconds
            backgroundHandler?.postDelayed({
                isManualFocusActive = false
                updateRepeatingRequest()
            }, 5000)

            safeResult.success(null)
        } catch (e: Exception) {
            safeResult.error("CAMERA_ERROR", "Focus failed: ${e.message}", null)
        }
    }

    private fun getJpegOrientation(chars: CameraCharacteristics, deviceOrientation: Int): Int {
        val sensorOrientation = chars.get(CameraCharacteristics.SENSOR_ORIENTATION) ?: 0
        val lensFacing = chars.get(CameraCharacteristics.LENS_FACING)

        // Round device orientation to a multiple of 90
        val deviceOrientationDegrees = when (deviceOrientation) {
            Surface.ROTATION_0 -> 0
            Surface.ROTATION_90 -> 90
            Surface.ROTATION_180 -> 180
            Surface.ROTATION_270 -> 270
            else -> 0
        }

        val result = if (lensFacing == CameraCharacteristics.LENS_FACING_FRONT) {
            (sensorOrientation + deviceOrientationDegrees) % 360
        } else {
            (sensorOrientation - deviceOrientationDegrees + 360) % 360
        }
        
        Log.i("CameraPlugin", "getJpegOrientation: lensFacing=$lensFacing, sensor=$sensorOrientation, device=$deviceOrientationDegrees, result=$result")
        return result
    }

    private fun updateRepeatingRequest() {
        val camera = cameraDevice ?: return
        val session = captureSession ?: return
        val surface = previewSurface ?: return

        try {
            val template = if (mediaRecorder != null) CameraDevice.TEMPLATE_RECORD else CameraDevice.TEMPLATE_PREVIEW
            val builder = camera.createCaptureRequest(template)
            
            builder.addTarget(surface)
            
            mediaRecorder?.surface?.let {
                builder.addTarget(it)
            }
            
            if (isFrameProcessorEnabled || isCodeScannerEnabled) {
                frameReader?.surface?.let {
                    builder.addTarget(it)
                }
            }

            // Apply zoom
            if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
                builder.set(CaptureRequest.CONTROL_ZOOM_RATIO, lastZoom)
            }
            
            // Apply torch
            builder.set(CaptureRequest.FLASH_MODE, if (lastTorchMode == "on") CaptureRequest.FLASH_MODE_TORCH else CaptureRequest.FLASH_MODE_OFF)
            
            // Apply exposure
            builder.set(CaptureRequest.CONTROL_AE_EXPOSURE_COMPENSATION, lastExposure)
            
            // Apply continuous AF for smoothness, unless manual focus is active
            if (!isManualFocusActive) {
                // Use CONTINUOUS_PICTURE for more aggressive/faster focus in vision apps
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_CONTINUOUS_PICTURE)
            } else {
                builder.set(CaptureRequest.CONTROL_AF_MODE, CaptureRequest.CONTROL_AF_MODE_AUTO)
            }

            val request = builder.build()
            session.setRepeatingRequest(request, null, backgroundHandler)
        } catch (e: Exception) {
            Log.e("CameraPlugin", "Failed to update repeating request", e)
        }
    }

    private fun startBackgroundThread() {
        if (backgroundThread != null) return
        backgroundThread = HandlerThread("CameraBackground").also { it.start() }
        backgroundHandler = Handler(backgroundThread!!.looper)
    }

    private fun releaseCamera(stopThread: Boolean = true) {
        Log.d("CameraPlugin", "Releasing camera and resources (stopThread=$stopThread)")
        
        isActive = false
        isFrameProcessorEnabled = false
        isCodeScannerEnabled = false
        isProcessingCode.set(false)
        isManualFocusActive = false

        // Cancel any pending focus resets
        backgroundHandler?.removeCallbacksAndMessages(null)

        // Stop receiving new images
        try {
            frameReader?.setOnImageAvailableListener(null, null)
            photoReader?.setOnImageAvailableListener(null, null)
        } catch (e: Exception) { /* ignore */ }

        // Clear any pending frames
        FlutterNativeVisionCameraPlugin.clearFrames()

        try {
            captureSession?.abortCaptures()
            captureSession?.stopRepeating()
        } catch (e: Exception) { /* ignore */ }
        
        try {
            captureSession?.close()
        } catch (e: Exception) { /* ignore */ }
        captureSession = null
        
        try {
            cameraDevice?.close()
        } catch (e: Exception) { /* ignore */ }
        cameraDevice = null
        
        mediaRecorder?.apply {
            try {
                stop()
            } catch (e: Exception) { /* ignore if not recording */ }
            try {
                reset()
            } catch (e: Exception) { /* ignore */ }
            try {
                release()
            } catch (e: Exception) { /* ignore */ }
        }
        mediaRecorder = null

        try {
            previewSurface?.release()
        } catch (e: Exception) { /* ignore */ }
        previewSurface = null
        
        try {
            surfaceProducer?.release()
        } catch (e: Exception) { /* ignore */ }
        surfaceProducer = null
        
        try {
            photoReader?.close()
        } catch (e: Exception) { /* ignore */ }
        photoReader = null
        
        try {
            frameReader?.close()
        } catch (e: Exception) { /* ignore */ }
        frameReader = null

        if (stopThread) {
            try {
                backgroundThread?.quitSafely()
            } catch (e: Exception) { /* ignore */ }
            backgroundThread = null
            backgroundHandler = null
        }
    }

    /**
     * A wrapper around MethodChannel.Result that ensures a result is only submitted once.
     */
    private class SafeResult(private val result: MethodChannel.Result) : MethodChannel.Result {
        private var hasReplied = false

        override fun success(res: Any?) {
             if (hasReplied) return
             hasReplied = true
             result.success(res)
        }

        override fun error(errorCode: String, errorMessage: String?, errorDetails: Any?) {
            if (hasReplied) return
            hasReplied = true
            result.error(errorCode, errorMessage, errorDetails)
        }

        override fun notImplemented() {
            if (hasReplied) return
            hasReplied = true
            result.notImplemented()
        }
    }
}
