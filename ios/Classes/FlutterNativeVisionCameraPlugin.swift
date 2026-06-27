import AVFoundation
import UIKit
import Vision

/// iOS implementation of the Flutter Native Vision Camera plugin.
///
/// Uses AVFoundation for camera access, FlutterTextureRegistry for
/// zero-copy GPU preview, and FlutterMethodChannel for control commands.
public class SwiftFlutterNativeVisionCameraPlugin: NSObject, FlutterPlugin {

    private var channel: FlutterMethodChannel!
    private var textureRegistry: FlutterTextureRegistry!

    private var captureSession: AVCaptureSession?
    private var captureDevice: AVCaptureDevice?
    private var videoOutput: AVCaptureVideoDataOutput?
    private var photoOutput: AVCapturePhotoOutput?
    private var audioOutput: AVCaptureAudioDataOutput?
    private var audioInput: AVCaptureDeviceInput?
    private var isFrameProcessorEnabled = false
    private var textureId: Int64?
    private var pixelBufferRenderer: PixelBufferRenderer?
    fileprivate var pendingPhotoResult: FlutterResult?


    // Recording state (AVAssetWriter reuses the live frame stream so frames keep
    // flowing to the preview/processor while recording).
    private var recorder: VideoRecorder?
    private var videoPath: String?
    private var enableVideo = false
    private var mirrorCaptures = false

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
        let instance = SwiftFlutterNativeVisionCameraPlugin()
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
            let enableVideo = args["enableVideo"] as? Bool ?? false
            self.mirrorCaptures = args["mirror"] as? Bool ?? true
            initializeCamera(deviceId: deviceId, enableVideo: enableVideo, codeScanner: codeScanner, result: result)
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
        case "setFocusDistance":
            guard let args = call.arguments as? [String: Any],
                  let distance = args["distance"] as? Double else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected distance", details: nil))
                return
            }
            setFocusDistance(Float(distance), result: result)
        case "takePhoto":
            guard let args = call.arguments as? [String: Any] else {
                result(FlutterError(code: "INVALID_ARGS", message: "Expected arguments", details: nil))
                return
            }
            takePhoto(options: args, result: result)
        case "startRecording":
            let args = call.arguments as? [String: Any] ?? [:]
            startRecording(options: args, result: result)
        case "stopRecording":
            stopRecording(result: result)
        case "cancelRecording":
            cancelRecording(result: result)
        case "pauseRecording", "resumeRecording":
            // AVAssetWriter does not expose a hardware pause; Android supports it.
            result(FlutterError(code: "NOT_SUPPORTED", message: "pause/resume recording is not supported on iOS", details: nil))
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
        var deviceTypes: [AVCaptureDevice.DeviceType] = [
            .builtInWideAngleCamera,
            .builtInTelephotoCamera,
            .builtInUltraWideCamera,
        ]

        if #available(iOS 13.0, *) {
            deviceTypes.append(.builtInDualCamera)
            deviceTypes.append(.builtInTripleCamera)
            deviceTypes.append(.builtInDualWideCamera)
        }

        // External cameras (USB-C / Continuity) are supported from iOS 17.
        if #available(iOS 17.0, *) {
            deviceTypes.append(.external)
        }

        let discoverySession = AVCaptureDevice.DiscoverySession(
            deviceTypes: deviceTypes,
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
                    "pixelFormats": ["rgb"],
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
                "minFocusDistance": 0.0,
                "hardwareLevel": "full",
                "sensorOrientation": "portrait",
                "physicalDevices": ["wide-angle-camera"],
                "formats": formats,
            ]
        }

        result(devices)
    }

    // MARK: - Camera Initialization

    private func initializeCamera(deviceId: String, enableVideo: Bool, codeScanner: [String: Any]?, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }

            // Tear down any prior session/texture so re-init and device switching
            // don't leak the previous camera.
            self.teardownSession()

            self.enableVideo = enableVideo
            self.updateCodeScanner(config: codeScanner)

            let device: AVCaptureDevice?
            if deviceId.isEmpty {
                device = AVCaptureDevice.default(for: .video)
            } else {
                device = AVCaptureDevice(uniqueID: deviceId)
            }

            guard let device = device else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "DEVICE_NOT_FOUND", message: "Device \(deviceId) not found", details: nil))
                }
                return
            }

            self.captureDevice = device

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
                let input = try AVCaptureDeviceInput(device: device)
                if session.canAddInput(input) {
                    session.addInput(input)
                }
            } catch {
                DispatchQueue.main.async {
                    result(FlutterError(code: "CAMERA_ERROR", message: error.localizedDescription, details: nil))
                }
                return
            }

            // Video output for preview texture + frame processing + recording source.
            let videoOutput = AVCaptureVideoDataOutput()
            videoOutput.videoSettings = [
                kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA
            ]
            videoOutput.alwaysDiscardsLateVideoFrames = true
            let renderer = PixelBufferRenderer()
            videoOutput.setSampleBufferDelegate(renderer, queue: self.sessionQueue)
            if session.canAddOutput(videoOutput) {
                session.addOutput(videoOutput)
            }

            // Photo output.
            let photoOutput = AVCapturePhotoOutput()
            if session.canAddOutput(photoOutput) {
                session.addOutput(photoOutput)
            }
            self.photoOutput = photoOutput

            // Audio input + output for recording (only when a mic is permitted).
            if enableVideo,
               AVCaptureDevice.authorizationStatus(for: .audio) == .authorized,
               let audioDevice = AVCaptureDevice.default(for: .audio),
               let audioIn = try? AVCaptureDeviceInput(device: audioDevice) {
                if session.canAddInput(audioIn) {
                    session.addInput(audioIn)
                    self.audioInput = audioIn
                    let audioOut = AVCaptureAudioDataOutput()
                    audioOut.setSampleBufferDelegate(self, queue: self.sessionQueue)
                    if session.canAddOutput(audioOut) {
                        session.addOutput(audioOut)
                        self.audioOutput = audioOut
                    }
                }
            }

            self.videoOutput = videoOutput
            self.pixelBufferRenderer = renderer
            self.captureSession = session

            let format = device.activeFormat
            let dims = CMVideoFormatDescriptionGetDimensions(format.formatDescription)

            DispatchQueue.main.async {
                let textureId = self.textureRegistry.register(renderer)
                self.textureId = textureId
                renderer.plugin = self
                renderer.textureRegistry = self.textureRegistry
                renderer.textureId = textureId
                self.setupRotationCoordinator(for: device)

                self.sessionQueue.async {
                    session.startRunning()
                    DispatchQueue.main.async {
                        result([
                            "textureId": textureId,
                            "previewWidth": Int(dims.width),
                            "previewHeight": Int(dims.height)
                        ])
                    }
                }
            }
        }
    }

    // MARK: - Photo Capture

    private func takePhoto(options: [String: Any], result: @escaping FlutterResult) {
        guard let photoOutput = photoOutput else {
            result(FlutterError(code: "NOT_INITIALIZED", message: "Photo output not initialized", details: nil))
            return
        }

        let settings = AVCapturePhotoSettings()

        if let flash = options["flash"] as? String {
            switch flash {
            case "on": settings.flashMode = .on
            case "auto": settings.flashMode = .auto
            default: settings.flashMode = .off
            }
        }

        if let enableHdr = options["enableHdr"] as? Swift.Bool, enableHdr {
            if #available(iOS 13.0, *) {
                settings.photoQualityPrioritization = .quality
            }
        }

        // Mirror the saved photo only when explicitly requested (selfie mirror);
        // otherwise capture what the camera actually sees.
        if let conn = photoOutput.connection(with: .video), conn.isVideoMirroringSupported {
            conn.automaticallyAdjustsVideoMirroring = false
            conn.isVideoMirrored = self.mirrorCaptures && (self.captureDevice?.position == .front)
        }

        self.pendingPhotoResult = result
        photoOutput.capturePhoto(with: settings, delegate: self)
    }

    // MARK: - Video Recording

    private func startRecording(options: [String: Any], result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            guard self.enableVideo else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NOT_INITIALIZED", message: "Camera was not initialized with enableVideo: true", details: nil))
                }
                return
            }
            guard self.recorder == nil else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "ALREADY_RECORDING", message: "A recording is already in progress", details: nil))
                }
                return
            }

            let path = (options["path"] as? String)
                ?? FileManager.default.temporaryDirectory
                    .appendingPathComponent("video_\(Int(Date().timeIntervalSince1970)).mp4").path
            self.videoPath = path

            // Torch during recording, matching Android.
            if let flash = options["flash"] as? String, flash == "on" {
                try? self.captureDevice?.lockForConfiguration()
                if self.captureDevice?.hasTorch == true { self.captureDevice?.torchMode = .on }
                self.captureDevice?.unlockForConfiguration()
            }

            // Use the live buffer dimensions when available, else the active format.
            var width = 1920
            var height = 1080
            if let buf = self.pixelBufferRenderer?.getCurrentBuffer() {
                width = CVPixelBufferGetWidth(buf)
                height = CVPixelBufferGetHeight(buf)
            } else if let dev = self.captureDevice {
                let dims = CMVideoFormatDescriptionGetDimensions(dev.activeFormat.formatDescription)
                width = Int(dims.width); height = Int(dims.height)
            }

            let mirror = self.mirrorCaptures && (self.captureDevice?.position == .front)
            let transform = Self.portraitTransform(mirror: mirror)

            do {
                self.recorder = try VideoRecorder(
                    url: URL(fileURLWithPath: path),
                    width: width,
                    height: height,
                    audio: self.audioOutput != nil,
                    transform: transform
                )
                DispatchQueue.main.async { result(nil) }
            } catch {
                self.recorder = nil
                DispatchQueue.main.async {
                    result(FlutterError(code: "RECORDING_ERROR", message: "Failed to start recording: \(error.localizedDescription)", details: nil))
                }
            }
        }
    }

    private func stopRecording(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self, let recorder = self.recorder else {
                DispatchQueue.main.async {
                    result(FlutterError(code: "NOT_RECORDING", message: "No recording in progress", details: nil))
                }
                return
            }
            let path = self.videoPath ?? recorder.url.path
            // The recording transform rotates 90°, so the played file is
            // portrait — report the oriented (display) dimensions.
            let width = recorder.height
            let height = recorder.width
            recorder.finish { [weak self] duration in
                // Mutate plugin state on the session queue (where the frame-append
                // path reads `recorder`), not on the asset-writer's queue.
                self?.sessionQueue.async {
                    self?.recorder = nil
                    self?.turnTorchOff()
                }
                DispatchQueue.main.async {
                    result([
                        "path": path,
                        "duration": duration,
                        "width": width,
                        "height": height
                    ])
                }
            }
        }
    }

    private func cancelRecording(result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let self = self else { return }
            let path = self.videoPath
            self.recorder?.cancel()
            self.recorder = nil
            self.turnTorchOff()
            if let path = path { try? FileManager.default.removeItem(atPath: path) }
            DispatchQueue.main.async { result(nil) }
        }
    }

    private func turnTorchOff() {
        guard let device = captureDevice, device.hasTorch else { return }
        try? device.lockForConfiguration()
        device.torchMode = .off
        device.unlockForConfiguration()
    }

    /// Display transform for a portrait-oriented recording from a landscape sensor buffer.
    private static func portraitTransform(mirror: Bool) -> CGAffineTransform {
        var t = CGAffineTransform(rotationAngle: .pi / 2)
        if mirror { t = t.scaledBy(x: 1, y: -1) }
        return t
    }

    // Called from the renderer (on sessionQueue) for every video sample buffer.
    fileprivate func appendRecordingVideo(_ sampleBuffer: CMSampleBuffer) {
        recorder?.appendVideo(sampleBuffer)
    }

    // MARK: - Camera Controls

    private func setActive(_ active: Bool, result: @escaping FlutterResult) {
        sessionQueue.async { [weak self] in
            guard let session = self?.captureSession else {
                DispatchQueue.main.async { result(nil) }
                return
            }
            if active {
                if !session.isRunning { session.startRunning() }
            } else {
                if session.isRunning { session.stopRunning() }
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
            let minZoom = Float(device.minAvailableVideoZoomFactor)
            let maxZoom = Float(device.maxAvailableVideoZoomFactor)
            let zoom = CGFloat(max(minZoom, min(factor, maxZoom)))
            device.videoZoomFactor = zoom
            device.unlockForConfiguration()

            lastZoom = factor

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

            // Dart sends a point normalized 0..1 in the preview's sensor space.
            let clamped = CGPoint(x: min(max(point.x, 0), 1), y: min(max(point.y, 0), 1))
            if device.isFocusPointOfInterestSupported {
                device.focusPointOfInterest = clamped
                device.focusMode = .autoFocus
            }

            if device.isExposurePointOfInterestSupported {
                device.exposurePointOfInterest = clamped
                device.exposureMode = .continuousAutoExposure
            }

            isManualFocusActive = true
            device.unlockForConfiguration()

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

    private func setFocusDistance(_ distance: Float, result: @escaping FlutterResult) {
        guard let device = captureDevice else {
            result(FlutterError(code: "CAMERA_ERROR", message: "No device", details: nil))
            return
        }
        guard device.isLockingFocusWithCustomLensPositionSupported else {
            result(FlutterError(code: "NOT_SUPPORTED", message: "Manual focus distance not supported on this device", details: nil))
            return
        }
        do {
            try device.lockForConfiguration()
            let lens = min(max(distance, 0.0), 1.0)
            isManualFocusActive = true
            device.setFocusModeLocked(lensPosition: lens, completionHandler: nil)
            device.unlockForConfiguration()
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
                // Vision's boundingBox is normalized with a bottom-left origin;
                // flip Y to a top-left origin to match Android.
                let box = observation.boundingBox
                return [
                    "type": Self.symbologyToString(observation.symbology),
                    "value": observation.payloadStringValue ?? "",
                    "frame": [
                        "x": box.origin.x,
                        "y": 1.0 - box.origin.y - box.size.height,
                        "width": box.size.width,
                        "height": box.size.height
                    ]
                ]
            }

            DispatchQueue.main.async {
                self?.channel.invokeMethod("onCodeScanned", arguments: codes)
            }
        }

        if let types = config["codeTypes"] as? [String], !types.isEmpty {
            request.symbologies = types.compactMap { Self.stringToSymbology($0) }
        }
        self.codeScannerRequest = request
    }

    func scanBarcodes(in pixelBuffer: CVPixelBuffer) {
        guard isCodeScannerEnabled, let request = codeScannerRequest else { return }
        // Tell Vision the buffer's orientation so the returned bounding boxes are
        // normalized in the UPRIGHT (displayed) frame — matching the rotated
        // preview and the Android coordinate convention. Without this, boxes are
        // normalized against the raw landscape buffer and appear stretched/
        // misplaced once the preview is rotated upright.
        let orientation: CGImagePropertyOrientation =
            (captureDevice?.position == .front) ? .leftMirrored : .right
        let handler = VNImageRequestHandler(
            cvPixelBuffer: pixelBuffer,
            orientation: orientation,
            options: [:]
        )
        try? handler.perform([request])
    }

    private static func symbologyToString(_ s: VNBarcodeSymbology) -> String {
        switch s {
        case .qr: return "qr"
        case .ean13: return "ean-13"
        case .ean8: return "ean-8"
        case .code128: return "code-128"
        case .code39: return "code-39"
        case .code93: return "code-93"
        case .dataMatrix: return "data-matrix"
        case .upce: return "upc-e"
        case .pdf417: return "pdf-417"
        case .aztec: return "aztec"
        case .itf14, .i2of5: return "itf"
        default: return "unknown"
        }
    }

    private static func stringToSymbology(_ s: String) -> VNBarcodeSymbology? {
        switch s {
        case "qr": return .qr
        case "ean-13": return .ean13
        case "ean-8": return .ean8
        case "code-128": return .code128
        case "code-39": return .code39
        case "code-93": return .code93
        case "data-matrix": return .dataMatrix
        case "upc-e": return .upce
        case "pdf-417": return .pdf417
        case "aztec": return .aztec
        case "itf": return .itf14
        default: return nil
        }
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

    // MARK: - Preview Rotation

    /// Reports the preview rotation to Dart (single source of truth, mirrors the
    /// Android `onPreviewConfigurationChanged` path).
    ///
    /// `AVCaptureVideoDataOutput` always delivers the buffer in the sensor's
    /// (landscape) orientation, so for a portrait UI a fixed 90° (back) / 270°
    /// (front) rotation displays it upright — deterministic and matching Android.
    /// We deliberately do NOT use `RotationCoordinator`'s horizon-level angle:
    /// that follows the device gyro, which is wrong for an orientation-locked UI.
    private func setupRotationCoordinator(for device: AVCaptureDevice) {
        // Both the back and front sensor buffers need a 90° rotation to display
        // upright in a portrait UI. The front camera's horizontal selfie-mirror
        // is applied separately by CameraPreview, so it does not change this.
        reportPreviewRotation(90)
    }

    private func reportPreviewRotation(_ angle: CGFloat) {
        let degrees = Int(angle.rounded())
        DispatchQueue.main.async {
            self.channel.invokeMethod(
                "onPreviewConfigurationChanged",
                // AVCaptureVideoDataOutput delivers an un-mirrored buffer, so the
                // Dart side applies the front-camera selfie mirror itself.
                arguments: ["rotationDegrees": degrees, "mirrored": false]
            )
        }
    }

    // MARK: - Cleanup

    /// Stops and releases the session, outputs, and texture. Runs on sessionQueue.
    private func teardownSession() {
        recorder?.cancel()
        recorder = nil
        captureSession?.stopRunning()
        captureSession = nil
        captureDevice = nil
        videoOutput = nil
        photoOutput = nil
        audioOutput = nil
        audioInput = nil
        if let textureId = self.textureId {
            DispatchQueue.main.async {
                self.textureRegistry.unregisterTexture(textureId)
            }
        }
        pixelBufferRenderer = nil
        textureId = nil
        // Fail any in-flight photo capture so the Dart future resolves instead
        // of hanging forever on dispose / device-switch.
        if let pending = pendingPhotoResult {
            DispatchQueue.main.async {
                pending(FlutterError(code: "CANCELLED", message: "Camera disposed during photo capture", details: nil))
            }
        }
        pendingPhotoResult = nil
    }

    private func disposeCamera() {
        sessionQueue.async { [weak self] in
            self?.teardownSession()
        }
    }
}

// MARK: - Audio sample delegate (recording)

extension SwiftFlutterNativeVisionCameraPlugin: AVCaptureAudioDataOutputSampleBufferDelegate {
    public func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        // Only the audio output is delegated to the plugin; the video output is
        // delegated to PixelBufferRenderer.
        recorder?.appendAudio(sampleBuffer)
    }
}

// MARK: - AVCapturePhotoCaptureDelegate

extension SwiftFlutterNativeVisionCameraPlugin: AVCapturePhotoCaptureDelegate {
    public func photoOutput(_ output: AVCapturePhotoOutput, didFinishProcessingPhoto photo: AVCapturePhoto, error: Error?) {
        guard let result = self.pendingPhotoResult else { return }
        self.pendingPhotoResult = nil

        if let error = error {
            DispatchQueue.main.async {
                result(FlutterError(code: "CAPTURE_ERROR", message: error.localizedDescription, details: nil))
            }
            return
        }

        guard let data = photo.fileDataRepresentation() else {
            DispatchQueue.main.async {
                result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to get photo data", details: nil))
            }
            return
        }

        let tempDir = FileManager.default.temporaryDirectory
        let fileName = "photo_\(Int(Date().timeIntervalSince1970)).jpg"
        let fileURL = tempDir.appendingPathComponent(fileName)
        let isMirrored = self.mirrorCaptures && (self.captureDevice?.position == .front)

        do {
            try data.write(to: fileURL)
            let dims = photo.resolvedSettings.photoDimensions
            DispatchQueue.main.async {
                result([
                    "path": fileURL.path,
                    "width": Int(dims.width),
                    "height": Int(dims.height),
                    "isRawPhoto": false,
                    "orientation": "portrait",
                    "isMirrored": isMirrored
                ])
            }
        } catch {
            DispatchQueue.main.async {
                result(FlutterError(code: "CAPTURE_ERROR", message: "Failed to save photo: \(error.localizedDescription)", details: nil))
            }
        }
    }
}

// MARK: - VideoRecorder (AVAssetWriter)

/// Records the live BGRA frame stream (and optional audio) to an .mp4 via
/// AVAssetWriter, so the preview/frame-processor stream keeps running.
final class VideoRecorder {
    let url: URL
    let width: Int
    let height: Int

    private let assetWriter: AVAssetWriter
    private let videoInput: AVAssetWriterInput
    private let audioInput: AVAssetWriterInput?
    private var started = false
    private var finished = false
    private var lastTimestamp: CMTime = .zero
    private var startTimestamp: CMTime = .zero

    init(url: URL, width: Int, height: Int, audio: Bool, transform: CGAffineTransform) throws {
        self.url = url
        self.width = width
        self.height = height

        try? FileManager.default.removeItem(at: url)
        assetWriter = try AVAssetWriter(outputURL: url, fileType: .mp4)

        let videoSettings: [String: Any] = [
            AVVideoCodecKey: AVVideoCodecType.h264,
            AVVideoWidthKey: width,
            AVVideoHeightKey: height
        ]
        videoInput = AVAssetWriterInput(mediaType: .video, outputSettings: videoSettings)
        videoInput.expectsMediaDataInRealTime = true
        videoInput.transform = transform
        if assetWriter.canAdd(videoInput) { assetWriter.add(videoInput) }

        if audio {
            let audioSettings: [String: Any] = [
                AVFormatIDKey: kAudioFormatMPEG4AAC,
                AVNumberOfChannelsKey: 1,
                AVSampleRateKey: 44100.0
            ]
            let input = AVAssetWriterInput(mediaType: .audio, outputSettings: audioSettings)
            input.expectsMediaDataInRealTime = true
            if assetWriter.canAdd(input) {
                assetWriter.add(input)
                audioInput = input
            } else {
                audioInput = nil
            }
        } else {
            audioInput = nil
        }
    }

    func appendVideo(_ sampleBuffer: CMSampleBuffer) {
        guard !finished, CMSampleBufferDataIsReady(sampleBuffer) else { return }
        let ts = CMSampleBufferGetPresentationTimeStamp(sampleBuffer)
        if !started {
            // If startWriting fails, leave `started` false so a later frame can
            // retry rather than appending into a non-writing writer.
            guard assetWriter.startWriting() else { return }
            started = true
            startTimestamp = ts
            assetWriter.startSession(atSourceTime: ts)
        }
        lastTimestamp = ts
        if assetWriter.status == .writing, videoInput.isReadyForMoreMediaData {
            videoInput.append(sampleBuffer)
        }
    }

    func appendAudio(_ sampleBuffer: CMSampleBuffer) {
        guard started, !finished, let audioInput = audioInput,
              CMSampleBufferDataIsReady(sampleBuffer) else { return }
        if assetWriter.status == .writing, audioInput.isReadyForMoreMediaData {
            audioInput.append(sampleBuffer)
        }
    }

    func finish(completion: @escaping (Double) -> Void) {
        guard started, !finished, assetWriter.status == .writing else {
            finished = true
            completion(0)
            return
        }
        finished = true
        let duration = CMTimeGetSeconds(CMTimeSubtract(lastTimestamp, startTimestamp))
        videoInput.markAsFinished()
        audioInput?.markAsFinished()
        assetWriter.finishWriting {
            completion(max(0, duration))
        }
    }

    func cancel() {
        guard !finished else { return }
        finished = true
        if assetWriter.status == .writing {
            assetWriter.cancelWriting()
        }
    }
}

// MARK: - PixelBufferRenderer

/// Bridges AVCaptureVideoDataOutput to Flutter's texture registry.
///
/// Each frame's CVPixelBuffer is retained and provided to Flutter when
/// it requests the texture — enabling zero-copy GPU rendering.
class PixelBufferRenderer: NSObject, FlutterTexture, AVCaptureVideoDataOutputSampleBufferDelegate {

    var textureRegistry: FlutterTextureRegistry?
    var textureId: Int64 = 0
    var isFrameProcessorEnabled = false
    weak var plugin: SwiftFlutterNativeVisionCameraPlugin?

    private var latestPixelBuffer: CVPixelBuffer?
    private let bufferLock = NSLock()

    func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        guard let buffer = latestPixelBuffer else { return nil }
        return Unmanaged.passRetained(buffer)
    }

    func getCurrentBuffer() -> CVPixelBuffer? {
        bufferLock.lock()
        defer { bufferLock.unlock() }
        return latestPixelBuffer
    }

    func captureOutput(
        _ output: AVCaptureOutput,
        didOutput sampleBuffer: CMSampleBuffer,
        from connection: AVCaptureConnection
    ) {
        guard let pixelBuffer = CMSampleBufferGetImageBuffer(sampleBuffer) else { return }

        // Retain the buffer we hand to the texture registry; release the prior one.
        bufferLock.lock()
        latestPixelBuffer = pixelBuffer
        bufferLock.unlock()

        // Feed the recorder (no-op when not recording). Runs on the session queue.
        plugin?.appendRecordingVideo(sampleBuffer)

        if isFrameProcessorEnabled {
            let width = Int32(CVPixelBufferGetWidth(pixelBuffer))
            let height = Int32(CVPixelBufferGetHeight(pixelBuffer))
            let timestamp = CMSampleBufferGetPresentationTimeStamp(sampleBuffer).seconds

            let metadata = FrameMetadata(
                width: width,
                height: height,
                pixelFormat: 1, // BGRA (maps to PixelFormat.rgb on the Dart side)
                orientation: 0,
                timestamp: timestamp
            )

            // Retain the buffer so it stays alive during asynchronous FFI processing.
            // VisionCamera_dispatchFrame locks it; Frame_decrementRefCount unlocks + releases.
            let handle = Unmanaged.passRetained(pixelBuffer).toOpaque()
            VisionCamera_dispatchFrame(handle, metadata)
        }

        plugin?.scanBarcodes(in: pixelBuffer)

        DispatchQueue.main.async { [weak self] in
            guard let self = self else { return }
            self.textureRegistry?.textureFrameAvailable(self.textureId)
        }
    }
}
