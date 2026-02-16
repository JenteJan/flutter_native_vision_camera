import AVFoundation
import UIKit
import Vision

/// iOS implementation of the Flutter Native Vision Camera plugin.
///
/// Uses AVFoundation for camera access, FlutterTextureRegistry for
/// zero-copy GPU preview, and FlutterMethodChannel for control commands.
public class FlutterNativeVisionCameraPlugin: NSObject, FlutterPlugin {

    private var channel: FlutterMethodChannel!
    private var textureRegistry: FlutterTextureRegistry!

    private var captureSession: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private var isFrameProcessorEnabled = false
    private var textureId: Int64?
    private var pixelBufferRenderer: PixelBufferRenderer?
    private var pendingPhotoResult: FlutterResult?
    
    private var lastZoom: Float = 1.0
    private var lastAFTriggerZoom: Float = 1.0
    private var isManualFocusActive = false
    
    private var codeScannerRequest: VNDetectBarcodesRequest?
    private var isCodeScannerEnabled = false

    private let sessionQueue = DispatchQueue(label: "dev.jentejan.flutter_native_vision_camera.session")

    public static func register(with registrar: FlutterPluginRegistrar) {
        let channel = FlutterMethodChannel(
            name: "dev.jentejan.flutter_native_vision_camera/camera",
            binaryMessenger: registrar.messenger()
        )
        let instance = FlutterNativeVisionCameraPlugin()
        instance.channel = channel
        instance.textureRegistry = registrar.textures()
        registrar.addMethodCallDelegate(instance, channel: channel)
    }

    public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
        switch call.method {
        case "getAvailableCameraDevices":
            getAvailableCameraDevices(result: result)
        case "initialize":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected arguments", details: nil))
                return
            }
            let deviceId = args["deviceId"] as? String ?? ""
            let codeScanner = args["codeScanner"] as? [String: Any]
            initializeCamera(deviceId: deviceId, codeScanner: codeScanner, result: result)
        case "setActive":
            guard let args = call.arguments as? [String: Any],
                  let isActive = args["isActive"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected isActive", details: nil))
                return
            }
            setActive(isActive, result: result)
        case "setZoom":
            guard let args = call.arguments as? [String: Any],
                  let zoom = args["zoom"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected zoom", details: nil))
                return
            }
            setZoom(Float(zoom), result: result)
        case "setTorch":
            guard let args = call.arguments as? [String: Any],
                  let mode = args["mode"] as? String else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected mode", details: nil))
                return
            }
            setTorch(mode, result: result)
        case "setExposure":
            guard let args = call.arguments as? [String: Any],
                  let exposure = args["exposure"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected exposure", details: nil))
                return
            }
            setExposure(Float(exposure), result: result)
        case "focus":
            guard let args = call.arguments as? [String: Any],
                  let x = args["x"] as? Double,
                  let y = args["y"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected x, y", details: nil))
                return
            }
            focus(at: CGPoint(x: x, y: y), result: result)
        case "takePhoto":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected arguments", details: nil))
                return
            }
            takePhoto(args: args, result: result)
        case "startRecording":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Recording not implemented yet", details: nil))
        case "stopRecording":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Recording not implemented yet", details: nil))
        case "pauseRecording":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Recording not implemented yet", details: nil))
        case "resumeRecording":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Recording not implemented yet", details: nil))
        case "cancelRecording":
            result(FlutterError(code: "NOT_IMPLEMENTED", message: "Recording not implemented yet", details: nil))
        case "setFrameProcessor":
            guard let args = call.arguments as? [String: Any],
                  let enabled = args["enabled"] as? Bool else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected enabled", details: nil))
                return
            }
            isFrameProcessorEnabled = enabled
            pixelBufferRenderer?.isFrameProcessorEnabled = enabled
            result(nil)
        case "setCodeScanner":
            let config = call.arguments as? [String: Any]
            updateCodeScanner(config: config?["codeScanner"] as? [String: Any])
            result(nil)
        case "takeSnapshot":
            takeSnapshot(result: result)
        case "getCameraPermissionStatus":
            getCameraPermissionStatus(result: result)
        case "requestCameraPermission":
            requestCameraPermission(result: result)
        case "getMicrophonePermissionStatus":
            getMicrophonePermissionStatus(result: result)
        case "requestMicrophonePermission":
            requestMicrophonePermission(result: result)
        case "dispose":
            disposeCamera()
            result(nil)
        default:
            result(FlutterMethodNotImplemented)
        }
    }

    // MARK: - Device Discovery

    private func getAvailableCameraDevices(result: @escaping FlutterResult) {
        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: [
                .builtInWideAngleCamera,
                .builtInTelephotoCamera,
                .builtInUltraWideCamera,
            ],
            mediaType: .video,
            position: .unspecified
        )

        let devices = discoverySession.devices.map { device -> [String: Any?] in
            let position: String
            switch device.position {
            case .front: position = "front"
            case .back: position = "back"
            default: position = "external"
            }

            let formats: [[String: Any?]] = device.formats.compactMap { format in
                let desc = format.formatDescription
                let dims = CMVideoFormatDescriptionGetDimensions(desc)
                let fpsRanges = format.videoSupportedFrameRateRanges

                return [
                    "photoHeight": Int(dims.height),
                    "photoWidth": Int(dims.width),
                    "videoHeight": Int(dims.height),
                    "videoWidth": Int(dims.width),
                    "minFps": fpsRanges.map { $0.minFrameRate }.min() ?? 1.0,
                    "maxFps": fpsRanges.map { $0.maxFrameRate }.max() ?? 30.0,
                    "minISO": device.activeFormat.minISO,
                    "maxISO": device.activeFormat.maxISO,
                    "fieldOfView": format.videoFieldOfView,
                    "maxZoom": format.videoMaxZoomFactor,
                    "supportsVideoHdr": format.isVideoHDRSupported,
                    "supportsPhotoHdr": false,
                    "supportsDepthCapture": !format.supportedDepthDataFormats.isEmpty,
                    "autoFocusSystem": format.autoFocusSystem == .phaseDetection
                        ? "phase-detection" : "contrast-detection",
                    "videoStabilizationModes": ["off"], // Simplified
                    "pixelFormats": ["yuv"],
                ]
            }

            return [
                "id": device.uniqueID,
                "name": device.localizedName,
                "position": position,
                "hasFlash": device.hasFlash,
                "hasTorch": device.hasTorch,
                "isMultiCam": false,
                "minZoom": device.minAvailableVideoZoomFactor,
                "maxZoom": device.maxAvailableVideoZoomFactor,
                "neutralZoom": 1.0,
                "minExposure": device.minExposureTargetBias,
                "maxExposure": device.maxExposureTargetBias,
                "supportsLowLightBoost": device.isLowLightBoostSupported,
                "supportsFocus": device.isFocusPointOfInterestSupported,
                "hardwareLevel": "full",
                "sensorOrientation": "portrait",
                "physicalDevices": ["wide-angle-camera"],
                "formats": formats,
            ]
        }

        result(devices)
    }

    // MARK: - Camera Initialization

    private func initializeCamera(deviceId: String, codeScanner: [String: Any]?, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            self.updateCodeScanner(config: codeScanner)

            let device: AVCaptureDevice?
            if deviceId.isEmpty {
                device = AVCaptureDevice.default(for: .video)
            } else {
                device = AVCaptureDevice(uniqueID: deviceId)
            }

            guard let device = device else {
                result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Device \(deviceId) not found", details: nil))
                return
            }
            
            self.captureDevice = device
            
            // Enable HDR if supported
            do {
                try device.lockForConfiguration()
                if device.activeFormat.isVideoHDRSupported {
                    device.automaticallyAdjustsVideoHDREnabled = true
                }
                device.unlockForConfiguration()
            } catch {}

            let session = AVCaptureSession()
            session.sessionPreset = .high

            do {
                let input = try AVCaptureDeviceInput(device: captureDevice)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
                }
                return
            }

            // Set up video output for preview texture
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            let renderer = PixelBufferRenderer()
            videoOutput.setSampleBufferDelegate(renderer, queue: self.sessionQueue)

            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            // Set up photo output
            let photoOutput = AVCapturePhotoOutput()
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            self.photoOutput = photoOutput

            self.videoOutput = videoOutput
            self.pixelBufferRenderer = renderer
            self.captureSession = session

            // Register texture with Flutter
            DispatchQueue.main.async {
                let textureId = self.textureRegistry.register(renderer)
                self.textureId = textureId
                renderer.plugin = self // Link back for code scanning
                renderer.textureRegistry = self.textureRegistry
                renderer.textureId = textureId

                session.startRunning()

                result(["textureId": textureId])
            }
        }
    }

    // MARK: - Photo Capture

    private    func takePhoto(options: [String: Any], result: @escaping FlutterResult) {
        guard let photoOutput = photoOutput else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Photo output not initialized", details: nil))
            return
        }

        let settings = AVCapturePhotoSettings()
        
        // Flash
        if let flash = options["flash"] as? String {
            switch flash {
            case "on": settings.flashMode = .on
            case "auto": settings.flashMode = .auto
            default: settings.flashMode = .off
            }
        }
        
        // HDR
        if let enableHdr = options["enableHdr"] as? Swift.Bool, enableHdr {
            if photoOutput.isAutoPhotoHDRSupported {
                settings.isAutoPhotoHDREnabled = true
            }
        }

        // Location
        if let locationMap = options["location"] as? [String: Any],
           let lat = locationMap["latitude"] as? Double,
           let lon = locationMap["longitude"] as? Double {
            // In a real app, we'd use CoreLocation and set metadata
            // For now, we'll assume we can pass it to the delegate
        }

        self.pendingPhotoResult = result
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Camera Controls

    private func setActive(_ active: Bool, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            if active {
                self?.captureSession?.startRunning()
            } else {
                self?.captureSession?.stopRunning()
            }
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func setZoom(_ factor: Float, result: @escaping FlutterResult) {
        guard let device = captureDevice else {
            result(FlutterError(code: "CAMERA_ERROR", message: "No device", details: nil))
            return
        }
        do {
            try device.lockForConfiguration()
            let zoom = CGFloat(max(1.0, min(factor, Float(device.maxAvailableVideoZoomFactor))))
            device.videoZoomFactor = zoom
            device.unlockForConfiguration()
            
            lastZoom = factor
            
            // Pro-Tip: Re-trigger focus if zoom change is significant (> 0.1x)
            if abs(lastZoom - lastAFTriggerZoom) > 0.1 && !isManualFocusActive {
                lastAFTriggerZoom = lastZoom
                triggerAutoFocus()
            }
            
            result(nil)
        } catch {
            result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func triggerAutoFocus() {
        guard let device = captureDevice else { return }
        do {
            try device.lockForConfiguration()
            if device.isFocusModeSupported(.continuousAutoFocus) {
                device.focusMode = .continuousAutoFocus
            }
            if device.isExposureModeSupported(.continuousAutoExposure) {
                device.exposureMode = .continuousAutoExposure
            }
            device.unlockForConfiguration()
        } catch {
            print("Failed to trigger auto focus: \(error)")
        }
    }

    private func setTorch(_ mode: String, result: @escaping FlutterResult) {
        guard let device = captureDevice, device.hasTorch else {
            result(FlutterError(code: "CAMERA_ERROR", message: "No torch", details: nil))
            return
        }
        do {
            try device.lockForConfiguration()
            device.torchMode = mode == "on" ? .on : .off
            device.unlockForConfiguration()
            result(nil)
        } catch {
            result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    private func setExposure(_ bias: Float, result: @escaping FlutterResult) {
        guard let device = captureDevice else {
            result(FlutterError(code: "CAMERA_ERROR", message: "No device", details: nil))
            return
        }
        do {
            try device.lockForConfiguration()
            let clampedBias = max(device.minExposureTargetBias, min(bias, device.maxExposureTargetBias))
            device.setExposureTargetBias(clampedBias, completionHandler: nil)
            device.unlockForConfiguration()
            result(nil)
        } catch {
            result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    func focus(at point: CGPoint, result: @escaping FlutterResult) {
        guard let device = captureDevice else {
            result(FlutterError(code: "CAMERA_ERROR", message: "No device", details: nil))
            return
        }
        
        do {
            try device.lockForConfiguration()
            
            // Map point to focusPointOfInterest (0,0 - 1,1)
            // Note: point (x,y) from Dart is 0..1 relative to the preview widget.
            // On iOS, focusPointOfInterest is in normalized coordinates (0,0) top-left to (1,1) bottom-right.
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = point
                device.focusMode = .autoFocus
            }
            
            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = point
                device.exposureMode = .continuousAutoExposure
            }
            
            isManualFocusActive = true
            device.unlockForConfiguration()
            
            // Revert to continuous focus after 5 seconds
            DispatchQueue.main.asyncAfter(deadline: .now() + 5.0) { [weak self] in
                guard let self = self, let device = self.captureDevice else { return }
                do {
                    try device.lockForConfiguration()
                    if device.isFocusModeSupported(.continuousAutoFocus) {
                        device.focusMode = .continuousAutoFocus
                    }
                    self.isManualFocusActive = false
                    device.unlockForConfiguration()
                } catch {}
            }
            
            result(nil)
        } catch {
            result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
        }
    }

    // MARK: - Code Scanner

    private func updateCodeScanner(config: [String: Any]?) {
        guard let config = config else {
            isCodeScannerEnabled = false
            codeScannerRequest = nil
            return
        }

        isCodeScannerEnabled = true
        let request = VNDetectBarcodesRequest { [weak self] request, error in
            guard error == nil, let results = request.results as? [VNBarcodeObservation], !results.isEmpty else { return }
            
            let codes = results.map { observation -> [String: Any] in
                return [
                    "type": observation.symbology.rawValue,
                    "value": observation.payloadStringValue ?? "",
                    "frame": [
                        "x": observation.boundingBox.origin.x,
                        "y": observation.boundingBox.origin.y,
                        "width": observation.boundingBox.size.width,
                        "height": observation.boundingBox.size.height
                    ]
                ]
            }
            
            DispatchQueue.main.async {
                self?.channel.invokeMethod("onCodeScanned", codes)
            }
        }
        
        // TODO: Filter symbologies based on config["types"]
        self.codeScannerRequest = request
    }

    func scanBarcodes(in pixelBuffer: CVPixelBuffer) {
        guard isCodeScannerEnabled, let request = codeScannerRequest else { return }
        let handler = VNImageRequestHandler(cvPixelBuffer: pixelBuffer, options: [:])
        try? handler.perform([request])
    }

    // MARK: - Snapshot

    private func takeSnapshot(result: @escaping FlutterResult) {
        guard let buffer = pixelBufferRenderer?.getCurrentBuffer() else {
            result(FlutterError(code: "CAPTURE_ERROR", message: "No buffer available", details: nil))
            return
        }

        let ciImage = CIImage(cvPixelBuffer: buffer)
        let context = CIContext()
        guard let cgImage = context.createCGImage(ciImage, from: ciImage.extent) else {
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to create image", details: nil))
            return
        }
        
        let uiImage = UIImage(cgImage: cgImage)
        guard let data = uiImage.jpegData(compressionQuality: 0.8) else {
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to encode JPEG", details: nil))
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileURL = tempDir.appendingPathComponent("snapshot_\(Int(Date().timeIntervalSince1970)).jpg")
        
        do {
            try data.write(to: fileURL)
            result([
                "path": fileURL.path,
                "width": Int(ciImage.extent.width),
                "height": Int(ciImage.extent.height),
                "orientation": "portrait",
                "isMirrored": false
            ])
        } catch {
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to save: \(error.localizedDescription)", details: nil))
        }
    }

    // MARK: - Permissions

    private func getCameraPermissionStatus(result: @escaping FlutterResult) {
        switch AVCaptureDevice.authorizationStatus(for: .video) {
        case .authorized: result("granted")
        case .denied: result("denied")
        case .restricted: result("restricted")
        case .notDetermined: result("not-determined")
        @unknown default: result("denied")
        }
    }

    private func requestCameraPermission(result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .video) { granted in
            DispatchQueue.main.async {
                result(granted ? "granted" : "denied")
            }
        }
    }

    private func getMicrophonePermissionStatus(result: @escaping FlutterResult) {
        switch AVCaptureDevice.authorizationStatus(for: .audio) {
        case .authorized: result("granted")
        case .denied: result("denied")
        case .restricted: result("restricted")
        case .notDetermined: result("not-determined")
        @unknown default: result("denied")
        }
    }

    private func requestMicrophonePermission(result: @escaping FlutterResult) {
        AVCaptureDevice.requestAccess(for: .audio) { granted in
            DispatchQueue.main.async {
                result(granted ? "granted" : "denied")
            }
        }
    }

    // MARK: - Cleanup

    private func disposeCamera() {
        sessionQueue.async { [weak self] in
            self?.captureSession?.stopRunning()
            self?.captureSession = nil
            self?.captureDevice = nil
            self?.videoOutput = nil
            self?.photoOutput = nil
            if let textureId = self?.textureId {
                DispatchQueue.main.async {
                    self?.textureRegistry.unregisterTexture(textureId)
                }
            }
            self?.pixelBufferRenderer = nil
            self?.textureId = nil
            self?.pendingPhotoResult = nil
        }
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension FlutterNativeVisionCameraPlugin: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let result = pendingPhotoResult else { return }
        pendingPhotoResult = nil

        if let error = error {
            result(FlutterError(code: "CAPTURE_ERROR", message: error.localizedDescription, details: nil))
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to get photo data", details: nil))
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "photo_\(Int(Date().timeIntervalSince1970)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)

        do {
            try data.write(to: fileURL)
            let dims = CMVideoFormatDescriptionGetDimensions(photo.formatDescription)
            result([
                "path": fileURL.path,
                "width": Int(dims.width),
                "height": Int(dims.height),
                "isRawPhoto": false,
                "orientation": "portrait",
                "isMirrored": false
            ])
        } catch {
            result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to save photo: \(error.localizedDescription)", details: nil))
        }
    }
}

// MARK: - PixelBufferRenderer

/// Bridges AVCaptureVideoDataOutput to Flutter's texture registry.
///
/// Each frame's CVPixelBuffer is held and provided to Flutter when
/// it requests the texture — enabling zero-copy GPU rendering.
class PixelBufferRenderer: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {

    var textureRegistry: FlutterTextureRegistry?
    var textureId: Int64 = 0
    var isFrameProcessorEnabled = false
    weak var plugin: FlutterNativeVisionCameraPlugin?
    private var latestPixelBuffer: CVPixelBuffer?

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        guard let buffer = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    func getCurrentBuffer() -> CVPixelBuffer? {
        return latestPixelBuffer
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }
        latestPixelBuffer = pixelBuffer
        
        if isFrameProcessorEnabled {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds
            
            let metadata = FrameMetadata(
                width: width,
                height: height,
                pixelFormat: 0, // YUV placeholder
                orientation: 0, // Portrait placeholder
                timestamp: timestamp
            )
            
            // Retain the buffer so it stays alive during asynchronous FFI processing
            CFRetain(pixelBuffer)
            VisionCamera_dispatchFrame(pixelBuffer, metadata)
        }
        
        plugin?.scanBarcodes(in: pixelBuffer)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.textureRegistry?.textureFrameAvailable(self.textureId)
        }
    }
}
