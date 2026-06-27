package dev.jentejan.flutter_native_vision_camera

import android.Manifest
import android.app.Activity
import android.content.Context
import android.content.pm.PackageManager
import android.graphics.*
import android.hardware.camera2.CameraCharacteristics
import android.os.Build
import android.os.Handler
import android.os.Looper
import android.util.Log
import android.util.Size
import android.view.OrientationEventListener
import android.view.Surface
import androidx.annotation.OptIn
import androidx.camera.camera2.interop.Camera2CameraInfo
import androidx.camera.camera2.interop.ExperimentalCamera2Interop
import androidx.camera.core.*
import androidx.camera.core.resolutionselector.ResolutionSelector
import androidx.camera.core.resolutionselector.ResolutionStrategy
import androidx.camera.lifecycle.ProcessCameraProvider
import androidx.camera.video.*
import androidx.camera.video.VideoCapture
import androidx.core.app.ActivityCompat
import androidx.core.content.ContextCompat
import androidx.lifecycle.Lifecycle
import androidx.lifecycle.LifecycleOwner
import androidx.lifecycle.LifecycleRegistry
import com.google.mlkit.vision.barcode.BarcodeScanner
import com.google.mlkit.vision.barcode.BarcodeScannerOptions
import com.google.mlkit.vision.barcode.BarcodeScanning
import com.google.mlkit.vision.barcode.common.Barcode
import com.google.mlkit.vision.common.InputImage
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.embedding.engine.plugins.activity.ActivityAware
import io.flutter.embedding.engine.plugins.activity.ActivityPluginBinding
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.plugin.common.MethodChannel.MethodCallHandler
import io.flutter.plugin.common.PluginRegistry
import io.flutter.view.TextureRegistry
import java.io.File
import java.util.concurrent.*
import java.util.concurrent.atomic.AtomicBoolean
import java.util.concurrent.atomic.AtomicInteger
import java.util.concurrent.atomic.AtomicLong

/**
 * Android implementation of the Flutter Native Vision Camera plugin.
 *
 * Migrated to CameraX API for improved stability and lifecycle management.
 * Uses Flutter TextureRegistry for zero-copy GPU preview.
 */
class FlutterNativeVisionCameraPlugin : FlutterPlugin, MethodCallHandler, ActivityAware, PluginRegistry.RequestPermissionsResultListener, LifecycleOwner {

    private lateinit var lifecycleRegistry: LifecycleRegistry
    override val lifecycle: Lifecycle get() = lifecycleRegistry

    // Native dispatcher. Passes every image plane (with its row/pixel stride and
    // byte size) so the Dart/C++ side can read true multi-plane YUV.
    private external fun nativeDispatchFrame(
        p0: java.nio.ByteBuffer, p1: java.nio.ByteBuffer?, p2: java.nio.ByteBuffer?,
        rs0: Int, rs1: Int, rs2: Int,
        ps0: Int, ps1: Int, ps2: Int,
        sz0: Int, sz1: Int, sz2: Int,
        numPlanes: Int,
        width: Int, height: Int, format: Int, orientation: Int, timestamp: Double, id: Long
    )

    private lateinit var channel: MethodChannel
    private lateinit var textureRegistry: TextureRegistry
    private lateinit var context: Context
    private var activity: Activity? = null
    private var binding: ActivityPluginBinding? = null
    private var pendingPermissionResult: MethodChannel.Result? = null
    private var pendingMicPermissionResult: MethodChannel.Result? = null

    // CameraX components
    private var cameraProvider: ProcessCameraProvider? = null
    private var camera: androidx.camera.core.Camera? = null
    private var preview: Preview? = null
    private var imageAnalysis: ImageAnalysis? = null
    private var imageCapture: ImageCapture? = null
    private var videoCapture: VideoCapture<Recorder>? = null
    private var activeRecording: Recording? = null
    private var cameraExecutor: ExecutorService = Executors.newSingleThreadExecutor()

    private var surfaceProducer: TextureRegistry.SurfaceProducer? = null
    
    @Volatile private var isFrameProcessorEnabled = false
    private var videoPath: String? = null
    private var lastZoom: Float = 1.0f 
    private var lastTorchMode: String = "off"
    private var lastExposure: Int = 0
    private var isFrontCamera: Boolean = false
    private var activeDeviceId: String? = null
    @Volatile private var isActive: Boolean = false
    
    private var barcodeScanner: BarcodeScanner? = null
    @Volatile private var isCodeScannerEnabled = false
    private var currentFormat: Map<String, Any>? = null
    private var mirrorCaptures: Boolean = false
    
    private var recordingStartTime: Long = 0
    private var pendingVideoResult: MethodChannel.Result? = null

    private val isProcessingCode = AtomicBoolean(false)
    private var lastScanTime: Long = 0
    private val scanThrottleMs: Long = 200 

    private var mainHandler: Handler = Handler(Looper.getMainLooper())
    
    private var orientationEventListener: OrientationEventListener? = null
    private var physicalOrientation: Int = Surface.ROTATION_0

    private class ManagedImageProxy(val image: ImageProxy) {
        val refCount = AtomicInteger(1)
    }

    companion object {
        private const val CHANNEL_NAME = "dev.jentejan.flutter_native_vision_camera/camera"
        private const val CAMERA_PERMISSION_REQUEST = 1001
        private const val MIC_PERMISSION_REQUEST = 1002

        private val frameIdCounter = AtomicLong(0)

        // Static frame management to allow easy C -> JNI release calls
        private val activeFrames = ConcurrentHashMap<Long, ManagedImageProxy>()

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

        @JvmStatic
        @androidx.annotation.Keep
        fun retainFrame(id: Long): Int {
            val managed = activeFrames[id] ?: return 0
            return managed.refCount.incrementAndGet()
        }

        fun clearFrames() {
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
        
        lifecycleRegistry = LifecycleRegistry(this)
        lifecycleRegistry.currentState = Lifecycle.State.CREATED
        
        val cameraProviderFuture = ProcessCameraProvider.getInstance(context)
        cameraProviderFuture.addListener({
            cameraProvider = cameraProviderFuture.get()
        }, ContextCompat.getMainExecutor(context))
        
        startOrientationListener()
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        stopOrientationListener()
        channel.setMethodCallHandler(null)
        releaseCamera(true)
        lifecycleRegistry.currentState = Lifecycle.State.DESTROYED
    }

    private fun startOrientationListener() {
        if (orientationEventListener != null) return
        orientationEventListener = object : OrientationEventListener(context) {
            override fun onOrientationChanged(orientation: Int) {
                if (orientation == ORIENTATION_UNKNOWN) return
                val newRotation = when {
                    orientation < 45 || orientation > 315 -> Surface.ROTATION_0
                    orientation in 45..134 -> Surface.ROTATION_270
                    orientation in 135..224 -> Surface.ROTATION_180
                    orientation in 225..314 -> Surface.ROTATION_90
                    else -> Surface.ROTATION_0
                }
                if (newRotation != physicalOrientation) {
                    physicalOrientation = newRotation
                    // Keep capture outputs correctly oriented from the physical
                    // sensor angle, even when the UI is orientation-locked.
                    imageCapture?.targetRotation = newRotation
                    videoCapture?.targetRotation = newRotation
                    imageAnalysis?.targetRotation = newRotation
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
                mirrorCaptures = call.argument<Boolean>("mirror") ?: true
                initializeCamera(deviceId, format, enablePhoto, enableVideo, codeScanner, result)
            }
            "setActive" -> {
                val active = call.argument<Boolean>("isActive") ?: call.argument<Boolean>("active") ?: false
                setActive(active, result)
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
                result.success(null)
            }
            "setCodeScanner" -> {
                val config = call.argument<Map<String, Any>>("codeScanner")
                updateCodeScanner(config)
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

    @OptIn(ExperimentalCamera2Interop::class)
    private fun getAvailableCameraDevices(result: MethodChannel.Result) {
        val provider = cameraProvider ?: run {
            result.error("CAMERA_ERROR", "CameraProvider not available", null)
            return
        }

        val devices = provider.availableCameraInfos.map { info ->
            val camera2Info = Camera2CameraInfo.from(info)
            deviceToMap(camera2Info)
        }
        result.success(devices)
    }

    @OptIn(ExperimentalCamera2Interop::class)
    private fun deviceToMap(info: Camera2CameraInfo): Map<String, Any?> {
        val id = info.cameraId
        val facing = info.getCameraCharacteristic(CameraCharacteristics.LENS_FACING)
        val position = when (facing) {
            CameraCharacteristics.LENS_FACING_FRONT -> "front"
            CameraCharacteristics.LENS_FACING_BACK -> "back"
            CameraCharacteristics.LENS_FACING_EXTERNAL -> "external"
            else -> "back"
        }

        val hasTorch = info.getCameraCharacteristic(CameraCharacteristics.FLASH_INFO_AVAILABLE) ?: false

        val minZoom = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            info.getCameraCharacteristic(CameraCharacteristics.CONTROL_ZOOM_RATIO_RANGE)?.lower?.toDouble() ?: 1.0
        } else 1.0
        val maxZoom = (info.getCameraCharacteristic(CameraCharacteristics.SCALER_AVAILABLE_MAX_DIGITAL_ZOOM) ?: 1.0f).toDouble()

        val exposureRange = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_COMPENSATION_RANGE)

        val hardwareLevel = when (info.getCameraCharacteristic(CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL)) {
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LEGACY -> "legacy"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_LIMITED -> "limited"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_FULL -> "full"
            CameraCharacteristics.INFO_SUPPORTED_HARDWARE_LEVEL_3 -> "level-3"
            else -> "legacy"
        }

        // Build format list from stream configuration map
        val configMap = info.getCameraCharacteristic(CameraCharacteristics.SCALER_STREAM_CONFIGURATION_MAP)
        val formats = mutableListOf<Map<String, Any?>>()

        // Calculate a rough Field of View
        val focalLengths = info.getCameraCharacteristic(CameraCharacteristics.LENS_INFO_AVAILABLE_FOCAL_LENGTHS)
        val sensorSize = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_PHYSICAL_SIZE)
        val fov = if (focalLengths != null && focalLengths.isNotEmpty() && sensorSize != null) {
            2.0 * Math.atan(sensorSize.width / (2.0 * focalLengths[0])) * 180.0 / Math.PI
        } else 60.0

        val stabilizationModes = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AVAILABLE_VIDEO_STABILIZATION_MODES)
        val mappedStabilization = mutableListOf<String>("off")
        stabilizationModes?.forEach { mode ->
            when (mode) {
                CameraCharacteristics.CONTROL_VIDEO_STABILIZATION_MODE_ON -> mappedStabilization.add("standard")
                // Cinematic etc can be mapped if needed
            }
        }

        if (configMap != null) {
            val previewSizes = configMap.getOutputSizes(SurfaceTexture::class.java)
            val photoSizes = configMap.getOutputSizes(ImageFormat.JPEG)?.toSet() ?: emptySet()
            val fpsRanges = info.getCameraCharacteristic(CameraCharacteristics.CONTROL_AE_AVAILABLE_TARGET_FPS_RANGES)

            previewSizes?.forEach { size ->
                val minFps = fpsRanges?.minByOrNull { it.lower }?.lower ?: 15
                val maxFps = fpsRanges?.maxByOrNull { it.upper }?.upper ?: 30

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
                    "minISO" to (info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.lower ?: 100),
                    "maxISO" to (info.getCameraCharacteristic(CameraCharacteristics.SENSOR_INFO_SENSITIVITY_RANGE)?.upper ?: 3200),
                    "maxZoom" to maxZoom,
                    "fieldOfView" to fov,
                    "supportsVideoHdr" to false,
                    "supportsPhotoHdr" to false,
                    "supportsDepthCapture" to false,
                    "autoFocusSystem" to "phase-detection",
                    "videoStabilizationModes" to mappedStabilization,
                    "pixelFormats" to listOf("yuv"),
                ))
            }
        }

        val sensorOrientationDegrees = info.getCameraCharacteristic(CameraCharacteristics.SENSOR_ORIENTATION) ?: 90
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
            "supportsFocus" to true,
            "supportsLowLightBoost" to false,
            "supportsRawCapture" to false,
            "hardwareLevel" to hardwareLevel,
            "sensorOrientation" to sensorOrientation,
            "physicalDevices" to listOf("wide-angle-camera"),
            "formats" to formats,
        )
    }

    // ─── Camera Initialization ─────────────────────────────────────────

    @OptIn(ExperimentalCamera2Interop::class)
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
        releaseCamera(false) 
        updateCodeScanner(codeScanner)
        lastZoom = 1.0f
        lastTorchMode = "off"
        lastExposure = 0
        currentFormat = format
        activeDeviceId = deviceId

        if (cameraProvider == null) {
            safeResult.error("CAMERA_ERROR", "CameraProvider not initialized", null)
            return
        }

        // 1. Selector and Rotation
        val selector = if (deviceId.isEmpty()) {
            isFrontCamera = false
            CameraSelector.DEFAULT_BACK_CAMERA
        } else {
            CameraSelector.Builder().addCameraFilter { cameras ->
                cameras.filter {
                    val info = Camera2CameraInfo.from(it)
                    if (info.cameraId == deviceId) {
                        isFrontCamera = it.lensFacing == CameraSelector.LENS_FACING_FRONT
                        true
                    } else false
                }
            }.build()
        }

        val rotation = if (Build.VERSION.SDK_INT >= Build.VERSION_CODES.R) {
            activity?.display?.rotation ?: Surface.ROTATION_0
        } else {
            @Suppress("DEPRECATION")
            activity?.windowManager?.defaultDisplay?.rotation ?: Surface.ROTATION_0
        }
        
        // 2. Surface Producer for Flutter Preview
        // SurfaceProducer is better for Impeller/Vulkan on devices like Pixel 8
        val producer = textureRegistry.createSurfaceProducer()
        surfaceProducer = producer

        // 3. Resolutions
        val videoWidth = format?.get("videoWidth") as? Int ?: 1920
        val videoHeight = format?.get("videoHeight") as? Int ?: 1080
        val targetSize = Size(videoWidth, videoHeight)
        
        val resolutionSelector = ResolutionSelector.Builder()
            .setResolutionStrategy(ResolutionStrategy(targetSize, ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
            .build()

        // 4. Preview UseCase
        val previewUseCase = Preview.Builder()
            .setResolutionSelector(resolutionSelector)
            .setTargetRotation(rotation)
            .build()
        
        previewUseCase.setSurfaceProvider(cameraExecutor) { request ->
            // CameraX is the authority on how much the preview buffer must be
            // rotated to display upright — it accounts for sensor orientation,
            // target rotation AND use-case negotiation (which can pre-rotate the
            // buffer). Report it to Dart so a single source of truth drives the
            // preview rotation. This also re-fires on device rotation.
            request.setTransformationInfoListener(cameraExecutor) { info ->
                val degrees = info.rotationDegrees
                // CameraX mirrors the front-camera preview itself; report that so
                // the Dart side doesn't double-mirror it.
                val mirrored = isFrontCamera
                mainHandler.post {
                    channel.invokeMethod(
                        "onPreviewConfigurationChanged",
                        mapOf("rotationDegrees" to degrees, "mirrored" to mirrored)
                    )
                }
            }

            val res = request.resolution
            Log.d("CameraPlugin", "CameraX requesting preview surface: ${res.width}x${res.height}")

            // Important: Set size before providing surface
            producer.setSize(res.width, res.height)
            val surface = producer.surface
            request.provideSurface(surface, cameraExecutor) {
                // Surface consumed
            }
        }
        preview = previewUseCase

        // 5. Image Analysis UseCase (Frame Processor)
        val analysisUseCase = ImageAnalysis.Builder()
            .setResolutionSelector(resolutionSelector)
            .setTargetRotation(rotation)
            .setBackpressureStrategy(ImageAnalysis.STRATEGY_KEEP_ONLY_LATEST)
            .setOutputImageFormat(ImageAnalysis.OUTPUT_IMAGE_FORMAT_YUV_420_888)
            .build()
        
        analysisUseCase.setAnalyzer(cameraExecutor) { image ->
            processFrame(image)
        }
        imageAnalysis = analysisUseCase

        // 6. Image Capture UseCase
        if (enablePhoto) {
            val photoWidth = format?.get("photoWidth") as? Int ?: 1920
            val photoHeight = format?.get("photoHeight") as? Int ?: 1080
            imageCapture = ImageCapture.Builder()
                .setResolutionSelector(ResolutionSelector.Builder()
                    .setResolutionStrategy(ResolutionStrategy(Size(photoWidth, photoHeight), ResolutionStrategy.FALLBACK_RULE_CLOSEST_HIGHER_THEN_LOWER))
                    .build())
                .setTargetRotation(rotation)
                .setCaptureMode(ImageCapture.CAPTURE_MODE_MINIMIZE_LATENCY)
                .build()
        }

        // 7. Video Capture UseCase
        if (enableVideo) {
            val recorder = Recorder.Builder()
                .setQualitySelector(QualitySelector.from(Quality.HIGHEST))
                .build()
            videoCapture = VideoCapture.Builder(recorder)
                .setTargetRotation(rotation)
                .build()
        }

        // 8. Bind to Lifecycle
        try {
            val useCases = mutableListOf<UseCase>(previewUseCase, analysisUseCase)
            imageCapture?.let { useCases.add(it) }
            videoCapture?.let { useCases.add(it) }

            camera = cameraProvider?.bindToLifecycle(
                this,
                selector,
                *useCases.toTypedArray()
            )
            
            lifecycleRegistry.currentState = Lifecycle.State.STARTED
            
            // Get actual preview resolution after binding
            val actualRes = previewUseCase.resolutionInfo?.resolution ?: targetSize
            
            safeResult.success(mapOf(
                "textureId" to producer.id(),
                "previewWidth" to actualRes.width,
                "previewHeight" to actualRes.height
            ))
        } catch (e: Exception) {
            safeResult.error("CAMERA_ERROR", "Failed to bind use cases: ${e.message}", null)
        }
    }

    private fun processFrame(image: ImageProxy) {
        if (!isActive || (!isFrameProcessorEnabled && !isCodeScannerEnabled)) {
            image.close()
            return
        }

        val id = frameIdCounter.incrementAndGet()
        val managed = ManagedImageProxy(image)
        activeFrames[id] = managed

        try {
            val now = System.currentTimeMillis()
            val scanning = isProcessingCode.get()
            val shouldScan = isCodeScannerEnabled && !scanning && (now - lastScanTime) > scanThrottleMs
            
            if (shouldScan) {
                val inputImage = InputImage.fromMediaImage(image.image!!, image.imageInfo.rotationDegrees)
                val scanner = barcodeScanner
                if (scanner != null && isActive) {
                    isProcessingCode.set(true)
                    lastScanTime = now
                    managed.refCount.incrementAndGet()
                    
                    val rotation = image.imageInfo.rotationDegrees
                    val isRotated = rotation == 90 || rotation == 270
                    val logicalWidth = if (isRotated) image.height else image.width
                    val logicalHeight = if (isRotated) image.width else image.height

                    scanner.process(inputImage)
                        .addOnSuccessListener { barcodes ->
                            if (isActive) {
                                val results = barcodes.map { barcode ->
                                    val box = barcode.boundingBox
                                    mapOf(
                                        "value" to barcode.rawValue,
                                        "type" to barcodeFormatToString(barcode.format),
                                        "frame" to if (box != null) mapOf(
                                            "x" to box.left.toDouble() / logicalWidth.toDouble(),
                                            "y" to box.top.toDouble() / logicalHeight.toDouble(),
                                            "width" to box.width().toDouble() / logicalWidth.toDouble(),
                                            "height" to box.height().toDouble() / logicalHeight.toDouble()
                                        ) else null,
                                        "corners" to barcode.cornerPoints?.map { mapOf("x" to it.x, "y" to it.y) }
                                    )
                                }
                                mainHandler.post {
                                    channel.invokeMethod("onCodeScanned", results)
                                }
                            }
                        }
                        .addOnFailureListener { e ->
                            if (isActive) Log.e("CameraPlugin", "MLKit Error: ${e.message}")
                        }
                        .addOnCompleteListener {
                            isProcessingCode.set(false)
                            releaseFrame(id)
                        }
                }
            }

            // Dispatch to Native/C++ (synchronous). Pass every plane with its
            // row/pixel stride and byte size so Dart can read true multi-plane YUV.
            managed.refCount.incrementAndGet()
            val planes = image.planes
            val b0 = planes[0].buffer
            val b1 = if (planes.size > 1) planes[1].buffer else null
            val b2 = if (planes.size > 2) planes[2].buffer else null
            nativeDispatchFrame(
                b0, b1, b2,
                planes[0].rowStride,
                if (planes.size > 1) planes[1].rowStride else 0,
                if (planes.size > 2) planes[2].rowStride else 0,
                planes[0].pixelStride,
                if (planes.size > 1) planes[1].pixelStride else 0,
                if (planes.size > 2) planes[2].pixelStride else 0,
                b0.remaining(),
                b1?.remaining() ?: 0,
                b2?.remaining() ?: 0,
                planes.size,
                image.width,
                image.height,
                0x23, // YUV_420_888
                image.imageInfo.rotationDegrees,
                image.imageInfo.timestamp.toDouble() / 1e9,
                id
            )
        } finally {
            releaseFrame(id)
        }
    }

    private fun setActive(active: Boolean, result: MethodChannel.Result) {
        isActive = active
        result.success(null)
    }

    // ─── Photo Capture ────────────────────────────────────────────────

    private fun takePhoto(options: Map<String, Any>, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        val capture = imageCapture ?: run {
            safeResult.error("CAMERA_ERROR", "ImageCapture not initialized", null)
            return
        }

        val path = options["path"] as? String
        val file = if (path != null) {
            File(path, "photo_${System.currentTimeMillis()}.jpg")
        } else {
            File(context.cacheDir, "photo_${System.currentTimeMillis()}.jpg")
        }

        val metadata = ImageCapture.Metadata().apply {
            // Mirror the saved image only when explicitly requested (selfie
            // mirror); otherwise save what the camera actually sees.
            isReversedHorizontal = mirrorCaptures && isFrontCamera
        }
        val outputOptions = ImageCapture.OutputFileOptions.Builder(file)
            .setMetadata(metadata)
            .build()

        capture.takePicture(outputOptions, cameraExecutor, object : ImageCapture.OnImageSavedCallback {
            override fun onImageSaved(outputFileResults: ImageCapture.OutputFileResults) {
                mainHandler.post {
                    safeResult.success(mapOf(
                        "path" to file.absolutePath,
                        "width" to (currentFormat?.get("photoWidth") ?: 1920),
                        "height" to (currentFormat?.get("photoHeight") ?: 1080),
                        "orientation" to rotationToOrientationString(physicalOrientation),
                        "isMirrored" to (mirrorCaptures && isFrontCamera)
                    ))
                }
            }

            override fun onError(exception: ImageCaptureException) {
                mainHandler.post {
                    safeResult.error("CAPTURE_ERROR", "Failed to capture photo: ${exception.message}", null)
                }
            }
        })
    }

    // ─── Video Recording ──────────────────────────────────────────────

    private fun startRecording(path: String?, flash: String, fileType: String, result: MethodChannel.Result) {
        val safeResult = SafeResult(result)
        val capture = videoCapture ?: run {
            safeResult.error("CAMERA_ERROR", "VideoCapture not initialized", null)
            return
        }

        val outputFilePath = path ?: File(context.cacheDir, "video_${System.currentTimeMillis()}.mp4").absolutePath
        videoPath = outputFilePath
        
        // Torch control via cameraControl
        camera?.cameraControl?.enableTorch(flash == "on")
        lastTorchMode = flash

        val file = File(outputFilePath)
        val outOptions = FileOutputOptions.Builder(file).build()

        // Only enable audio when RECORD_AUDIO has actually been granted —
        // calling withAudioEnabled() without the permission throws.
        val hasAudio = ContextCompat.checkSelfPermission(
            context, Manifest.permission.RECORD_AUDIO
        ) == PackageManager.PERMISSION_GRANTED

        try {
            var pending = capture.output.prepareRecording(context, outOptions)
            if (hasAudio) {
                pending = pending.withAudioEnabled()
            } else {
                Log.w("CameraPlugin", "RECORD_AUDIO not granted — recording video without audio")
            }

            activeRecording = pending.start(cameraExecutor) { event ->
                when (event) {
                    is VideoRecordEvent.Start -> {
                        recordingStartTime = System.currentTimeMillis()
                        mainHandler.post { safeResult.success(null) }
                    }
                    is VideoRecordEvent.Finalize -> {
                        if (event.hasError()) {
                            Log.e("CameraPlugin", "Video recording error: ${event.error}")
                            // Drop the dangling recording so a later stopRecording()
                            // doesn't hang, and surface the failure to whichever call
                            // is still pending plus the controller's error stream.
                            activeRecording = null
                            mainHandler.post {
                                safeResult.error("RECORDING_ERROR", "Recording failed (code ${event.error})", null)
                                pendingVideoResult?.error("RECORDING_ERROR", "Recording failed (code ${event.error})", null)
                                pendingVideoResult = null
                                channel.invokeMethod("onError", mapOf(
                                    "code" to "RECORDING_ERROR",
                                    "message" to "Recording failed (code ${event.error})"
                                ))
                            }
                            return@start
                        }
                        val duration = (event.recordingStats.recordedDurationNanos / 1e9)
                        val metadata = mapOf(
                            "path" to (videoPath ?: ""),
                            "duration" to duration,
                            "width" to (currentFormat?.get("videoWidth") ?: 1920),
                            "height" to (currentFormat?.get("videoHeight") ?: 1080)
                        )
                        mainHandler.post {
                            pendingVideoResult?.success(metadata)
                            pendingVideoResult = null
                        }
                    }
                }
            }
        } catch (e: Exception) {
            Log.e("CameraPlugin", "Failed to start recording: ${e.message}")
            safeResult.error("RECORDING_ERROR", "Failed to start recording: ${e.message}", null)
        }
    }

    private fun stopRecording(result: MethodChannel.Result) {
        pendingVideoResult = result
        activeRecording?.stop()
        activeRecording = null
    }

    private fun pauseRecording(result: MethodChannel.Result) {
        activeRecording?.pause()
        result.success(null)
    }

    private fun resumeRecording(result: MethodChannel.Result) {
        activeRecording?.resume()
        result.success(null)
    }

    private fun cancelRecording(result: MethodChannel.Result) {
        val path = videoPath
        activeRecording?.stop()
        activeRecording = null
        path?.let { File(it).delete() }
        result.success(null)
    }

    // ─── Controls ─────────────────────────────────────────────────────

    private fun setZoom(zoom: Double, result: MethodChannel.Result) {
        camera?.cameraControl?.setZoomRatio(zoom.toFloat())
        lastZoom = zoom.toFloat()
        result.success(null)
    }

    private fun setTorch(mode: String, result: MethodChannel.Result) {
        camera?.cameraControl?.enableTorch(mode == "on")
        lastTorchMode = mode
        result.success(null)
    }

    private fun setExposure(exposure: Double, result: MethodChannel.Result) {
        camera?.cameraControl?.setExposureCompensationIndex(exposure.toInt())
        lastExposure = exposure.toInt()
        result.success(null)
    }

    private fun focus(x: Double, y: Double, result: MethodChannel.Result) {
        // x,y arrive already normalized to 0..1 in sensor space (the widget maps
        // through BoxFit and front-mirror), so use a unit-sized factory.
        val factory = SurfaceOrientedMeteringPointFactory(1f, 1f)
        val point = factory.createPoint(x.toFloat().coerceIn(0f, 1f), y.toFloat().coerceIn(0f, 1f))
        val action = FocusMeteringAction.Builder(point, FocusMeteringAction.FLAG_AF or FocusMeteringAction.FLAG_AE)
            .setAutoCancelDuration(5, TimeUnit.SECONDS)
            .build()
        
        camera?.cameraControl?.startFocusAndMetering(action)
        result.success(null)
    }

    private fun setFocusDistance(distance: Double, result: MethodChannel.Result) {
        // CameraX does not provide direct "manual focal distance" API in diopters like Camera2 easily
        // Usually handled via Camera2Interop if needed.
        result.notImplemented()
    }

    private fun rotationToOrientationString(rotation: Int): String = when (rotation) {
        Surface.ROTATION_0 -> "portrait"
        Surface.ROTATION_90 -> "landscape-right"
        Surface.ROTATION_180 -> "portrait-upside-down"
        Surface.ROTATION_270 -> "landscape-left"
        else -> "portrait"
    }

    // ─── Code Scanner Utilities ────────────────────────────────────────

    private fun getMlKitRotation(): Int {
        return camera?.cameraInfo?.sensorRotationDegrees ?: 0
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
            isCodeScannerEnabled = false
            barcodeScanner?.close()
            barcodeScanner = null
            return
        }

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
        // In CameraX, we can't easily "steal" a frame from the pipeline without complex setup
        // Mark as not implemented as per request if complex.
        result.error("NOT_IMPLEMENTED", "takeSnapshot is not implemented in CameraX yet", null)
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
        if (requestCode == MIC_PERMISSION_REQUEST) {
            val pendingResult = pendingMicPermissionResult ?: return false
            if (grantResults.isNotEmpty() && grantResults[0] == PackageManager.PERMISSION_GRANTED) {
                pendingResult.success("granted")
            } else {
                pendingResult.success("denied")
            }
            pendingMicPermissionResult = null
            return true
        }
        return false
    }

    private fun getMicrophonePermissionStatus(result: MethodChannel.Result) {
        val status = ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO)
        result.success(if (status == PackageManager.PERMISSION_GRANTED) "granted" else "denied")
    }

    private fun requestMicrophonePermission(result: MethodChannel.Result) {
        if (ContextCompat.checkSelfPermission(context, Manifest.permission.RECORD_AUDIO) == PackageManager.PERMISSION_GRANTED) {
            result.success("granted")
            return
        }
        val act = activity ?: run {
            result.error("NO_ACTIVITY", "Activity not available", null)
            return
        }
        if (pendingMicPermissionResult != null) {
            result.error("PERMISSION_REQUEST_IN_PROGRESS", "A microphone permission request is already in progress", null)
            return
        }
        pendingMicPermissionResult = result
        ActivityCompat.requestPermissions(act, arrayOf(Manifest.permission.RECORD_AUDIO), MIC_PERMISSION_REQUEST)
    }

    // ─── Lifecycle & Cleanup ──────────────────────────────────────────

    private fun releaseCamera(stopThread: Boolean = true) {
        Log.d("CameraPlugin", "Releasing camera and resources")
        
        isActive = false
        isProcessingCode.set(false)

        activeRecording?.stop()
        activeRecording = null

        FlutterNativeVisionCameraPlugin.clearFrames()

        try {
            cameraProvider?.unbindAll()
        } catch (e: Exception) {
            Log.e("CameraPlugin", "Error unbinding CameraX: ${e.message}")
        }
        
        preview = null
        imageAnalysis = null
        imageCapture = null
        videoCapture = null
        camera = null
        
        surfaceProducer?.release()
        surfaceProducer = null
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
