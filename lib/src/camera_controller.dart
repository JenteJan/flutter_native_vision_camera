import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../flutter_native_vision_camera.dart';

/// The method channel used for communication with native platform code.
const MethodChannel _channel = MethodChannel(
  'dev.jentejan.flutter_native_vision_camera/camera',
);

/// State of the [CameraController].
enum CameraState {
  /// The controller is created but not yet initialized.
  uninitialized,

  /// The camera is initialized and ready to start.
  initialized,

  /// The camera is actively streaming and processing frames.
  active,

  /// The camera is recording video.
  recording,

  /// The controller has been disposed.
  disposed,
}

/// A high-performance camera controller that manages hardware sessions.
///
/// Advantages over `camera` package:
/// * **Zero-Copy Preview**: Uses `TextureRegistry` for direct GPU rendering.
/// * **Physical Orientation**: Correctly handles hardware sensor orientation.
/// * **Integrated ML**: Built-in high-speed Barcode/QR scanning via MLKit.
/// * **FFI Frame Processing**: Synchronous background frame analysis.
/// * **Unified API**: Easy-to-use reactive state via [ValueNotifier].
class CameraController extends ValueNotifier<CameraState> {
  int? _textureId;
  bool _isInitialized = false;
  bool _isActive = false;
  bool _isRecording = false;

  CameraDevice? _device;
  FrameProcessorPipeline? _frameProcessorPipeline;
  int? _previewWidth;
  int? _previewHeight;
  int? _previewRotationDegrees;
  bool _previewMirrored = false;
  bool _mirror = true;

  // Configuration State
  double _zoom = 1.0;
  String _torch = 'off';

  final StreamController<CameraError> _onErrorController =
      StreamController<CameraError>.broadcast();
  final StreamController<List<Code>> _onCodeScannedController =
      StreamController<List<Code>>.broadcast();

  /// Gets the current zoom level.
  double get zoom => _zoom;

  /// Gets the current torch/flash mode.
  String get torch => _torch;

  /// Whether the camera is currently recording video.
  bool get isRecording => _isRecording;

  /// Whether the controller is initialized.
  bool get isInitialized => _isInitialized;

  /// Whether the camera is actively streaming.
  bool get isActive => _isActive;

  /// The texture ID for the camera preview.
  ///
  /// Use this with Flutter's `Texture(textureId: controller.textureId)` widget.
  int? get textureId => _textureId;

  /// The currently active camera device.
  CameraDevice? get device => _device;

  /// The width of the preview texture, in raw sensor space (un-rotated).
  int? get previewWidth => _previewWidth;

  /// The height of the preview texture, in raw sensor space (un-rotated).
  int? get previewHeight => _previewHeight;

  /// The clockwise quarter-turns needed to rotate the raw preview texture so
  /// it displays upright.
  ///
  /// **This is the single source of truth for preview rotation.** The value is
  /// reported by the native layer, which is the only place that knows how much
  /// the preview buffer was already rotated (the camera stack may pre-rotate it
  /// depending on the bound use-cases, device orientation and sensor mount).
  /// [CameraPreview] applies this for you; custom previews/overlays must use
  /// this value (or [displayPreviewSize]) instead of swapping/rotating
  /// dimensions themselves. Falls back to the device's
  /// [CameraDevice.sensorOrientation] before the native value arrives.
  int get previewRotation {
    final degrees =
        _previewRotationDegrees ?? _device?.sensorOrientation.degrees ?? 0;
    return (degrees ~/ 90) % 4;
  }

  /// The raw preview buffer size, in sensor space (before [previewRotation]).
  Size? get rawPreviewSize => (_previewWidth != null && _previewHeight != null)
      ? Size(_previewWidth!.toDouble(), _previewHeight!.toDouble())
      : null;

  /// The preview size in display (upright) space, accounting for
  /// [previewRotation]. Lay out overlays against this so they align with the
  /// rotated preview.
  Size? get displayPreviewSize {
    final raw = rawPreviewSize;
    if (raw == null) return null;
    return previewRotation.isOdd ? Size(raw.height, raw.width) : raw;
  }

  /// Whether the native preview texture is already horizontally mirrored
  /// relative to the true scene.
  ///
  /// Reported by the native layer because the camera stacks differ: Android's
  /// CameraX mirrors the front-camera preview itself, while iOS delivers an
  /// un-mirrored buffer. [CameraPreview] uses this so the front preview looks
  /// like a mirror on both platforms without double-mirroring.
  bool get previewMirrored => _previewMirrored;

  /// Whether the front camera is mirrored (the "selfie" look) for **both** the
  /// preview and the captured photo/video. Set via [initialize]'s `mirror`
  /// argument. Has no effect on back cameras.
  bool get mirror => _mirror;

  /// Fires when a runtime error occurs in the native layer.
  Stream<CameraError> get onError => _onErrorController.stream;

  /// Fires when the [CodeScanner] detects barcodes or QR codes.
  Stream<List<Code>> get onCodeScanned => _onCodeScannedController.stream;

  static CameraController? _activeHandler;

  /// Creates a [CameraController]. Initialize it using [initialize].
  CameraController() : super(CameraState.uninitialized);

  /// Initializes the camera with the specified [device].
  ///
  /// [format] controls resolution and FPS.
  /// [enablePhoto] and [enableVideo] prepare the underlying pipeline.
  /// [codeScanner] enables the high-speed barcode scanning features.
  Future<void> initialize(
    CameraDevice device, {
    CameraDeviceFormat? format,
    PixelFormat pixelFormat = PixelFormat.yuv,
    bool enablePhoto = false,
    bool enableVideo = false,
    CodeScannerConfiguration? codeScanner,
    bool mirror = true,
  }) async {
    if (value == CameraState.disposed) return;

    try {
      _device = device;
      _previewRotationDegrees = null;
      _previewMirrored = false;
      _mirror = mirror;

      _activeHandler = this;
      _channel.setMethodCallHandler(_handleMethodCall);

      debugPrint('CameraController: Initializing for device ${device.id}');

      final Map<String, dynamic>? result = await _channel
          .invokeMapMethod<String, dynamic>('initialize', {
            'deviceId': device.id,
            'format': format?.toMap(),
            'pixelFormat': pixelFormat.index,
            'enablePhoto': enablePhoto,
            'enableVideo': enableVideo,
            'codeScanner': codeScanner?.toMap(),
            'mirror': mirror,
          });

      if (result != null) {
        _textureId = result['textureId'] as int;
        _previewWidth = result['previewWidth'] as int;
        _previewHeight = result['previewHeight'] as int;
      }
      _isInitialized = true;

      value = CameraState.initialized;
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
      rethrow;
    }
  }

  /// Starts or stops the camera stream.
  Future<void> setActive(bool active) async {
    if (!_isInitialized || value == CameraState.disposed) return;
    try {
      await _channel.invokeMethod('setActive', {'isActive': active});
      _isActive = active;
      value = active ? CameraState.active : CameraState.initialized;
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
    }
  }

  /// Changes the zoom level (e.g. 1.0 for neutral, 2.0 for 2x).
  Future<void> setZoom(double zoom) async {
    if (!_isActive) return;
    try {
      await _channel.invokeMethod('setZoom', {'zoom': zoom});
      _zoom = zoom;
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
    }
  }

  /// Changes the torch mode ('on', 'off', 'auto').
  Future<void> setTorch(String mode) async {
    if (!_isActive) return;
    try {
      await _channel.invokeMethod('setTorch', {'mode': mode});
      _torch = mode;
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
    }
  }

  /// Changes the manual exposure compensation.
  Future<void> setExposure(double exposure) async {
    if (!_isActive) return;
    try {
      await _channel.invokeMethod('setExposure', {'exposure': exposure});
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
    }
  }

  /// Starts a video recording to the specified local [filePath].
  ///
  /// The video is encoded using hardware acceleration.
  Future<void> startRecording(String filePath) async {
    if (!_isActive || _isRecording) return;
    try {
      await _channel.invokeMethod('startRecording', {'path': filePath});
      _isRecording = true;
      value = CameraState.recording;
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
      rethrow;
    }
  }

  /// Stops the current video recording.
  Future<void> stopRecording() async {
    if (!_isRecording) return;
    try {
      await _channel.invokeMethod('stopRecording');
      _isRecording = false;
      value = CameraState.active;
      notifyListeners();
    } on PlatformException catch (e) {
      _onErrorController.add(
        CameraError(code: e.code, message: e.message ?? 'Unknown error'),
      );
      rethrow;
    }
  }

  /// Focuses the camera at the given [point] (0..1).
  Future<void> focus(Point point) async {
    if (!_isActive) return;
    await _channel.invokeMethod('focus', point.toMap());
  }

  /// Sets the lens focus distance (0.0 for infinity, 1.0 for closest).
  /// This enables "Rack Focus" effects.
  Future<void> setFocusDistance(double distance) async {
    if (!_isActive) return;
    await _channel.invokeMethod('setFocusDistance', {'distance': distance});
  }

  /// Sets the frame processor for this camera session.
  ///
  /// The [callback] will be executed on a background isolate for every frame.
  /// Set to `null` to disable frame processing.
  Future<void> setFrameProcessor(FrameProcessorCallback? callback) async {
    _frameProcessorPipeline?.stop();
    _frameProcessorPipeline = null;

    if (callback != null) {
      _frameProcessorPipeline = FrameProcessorPipeline(callback);
      await _frameProcessorPipeline!.start();
    }

    await _channel.invokeMethod('setFrameProcessor', {
      'enabled': callback != null,
    });
  }

  /// Updates the code scanner configuration.
  Future<void> setCodeScanner(CodeScannerConfiguration? configuration) async {
    await _channel.invokeMethod('setCodeScanner', {
      'codeScanner': configuration?.toMap(),
    });
  }

  /// Takes a high-resolution photo.
  Future<PhotoFile> takePhoto([TakePhotoOptions? options]) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'takePhoto',
      options?.toMap() ?? {},
    );
    return PhotoFile.fromMap(result!);
  }

  /// Takes a snapshot of the current preview.
  ///
  /// Snapshots are usually faster than high-resolution photos.
  Future<PhotoFile> takeSnapshot([TakeSnapshotOptions? options]) async {
    final result = await _channel.invokeMapMethod<String, dynamic>(
      'takeSnapshot',
      options?.toMap() ?? {},
    );
    return PhotoFile.fromMap(result!);
  }

  /// Disposes the controller and releases all hardware resources.
  @override
  void dispose() {
    if (value == CameraState.disposed) return;

    if (_activeHandler == this) {
      _channel.setMethodCallHandler(null);
      _activeHandler = null;
    }

    // Stop any active frame processing immediately
    _frameProcessorPipeline?.stop();
    _frameProcessorPipeline = null;

    // Notify native side to shut down camera hardware
    _channel.invokeMethod('dispose');
    _channel.setMethodCallHandler(null);

    _onCodeScannedController.close();
    _onErrorController.close();

    _isInitialized = false;
    _isActive = false;
    _isRecording = false;
    value = CameraState.disposed;
    super.dispose();
  }

  Future<void> _handleMethodCall(MethodCall call) async {
    if (kDebugMode) {
      print('CameraController: Received MethodCall: ${call.method}');
    }

    // Only handle callbacks for the active controller to avoid conflicts
    if (_activeHandler != this) {
      if (kDebugMode) {
        print('CameraController: Ignoring call for inactive instance');
      }
      return;
    }

    try {
      switch (call.method) {
        case 'onInitialized':
          _isInitialized = true;
          break;
        case 'onPreviewConfigurationChanged':
          final args = Map<String, dynamic>.from(call.arguments as Map);
          _previewRotationDegrees = (args['rotationDegrees'] as num).toInt();
          _previewMirrored = (args['mirrored'] as bool?) ?? false;
          notifyListeners();
          break;
        case 'onStarted':
          _isActive = true;
          break;
        case 'onStopped':
          _isActive = false;
          break;
        case 'onCodeScanned':
          debugPrint(
            'CameraController: onCodeScanned with arguments: ${call.arguments}',
          );
          final List<dynamic> codesJson = call.arguments;
          final codes = codesJson
              .map((c) => Code.fromMap(Map<String, dynamic>.from(c as Map)))
              .toList();
          debugPrint(
            'CameraController: Scanned ${codes.length} codes: $codesJson',
          );
          if (kDebugMode && codes.isNotEmpty) {
            debugPrint(
              'CameraController: Distributed ${codes.length} codes to listeners',
            );
          }
          _onCodeScannedController.add(codes);
          break;
        case 'onError':
          final Map<String, dynamic> error = Map<String, dynamic>.from(
            call.arguments as Map,
          );
          _onErrorController.add(
            CameraError(
              code: error['code'] as String,
              message: error['message'] as String,
            ),
          );
          break;
      }
    } catch (e, stack) {
      debugPrint(
        'CameraController: Error handling method call ${call.method}: $e',
      );
      debugPrint(stack.toString());
    }
  }
}

/// Represents a camera runtime error.
class CameraError {
  /// Platform-specific error code.
  final String code;

  /// Human-readable error message.
  final String message;

  const CameraError({required this.code, required this.message});

  @override
  String toString() => 'CameraError($code: $message)';
}
