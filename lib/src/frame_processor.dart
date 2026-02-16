import 'dart:async';
import 'dart:ffi';
import 'dart:isolate';

import 'frame.dart';
import 'types/orientation.dart';
import 'types/pixel_format.dart';

/// The signature of a frame processor callback.
///
/// This callback is executed on a background Isolate for every frame.
typedef FrameProcessorCallback = void Function(Frame frame);

/// Manages the background Isolate and communication for frame processors.
class FrameProcessorPipeline {
  final FrameProcessorCallback callback;
  final ReceivePort _receivePort = ReceivePort();
  Isolate? _isolate;
  SendPort? _mainToIsolateSendPort;

  FrameProcessorPipeline(this.callback);

  static late NativeCallable<NativeFrameProcessorCallbackFunc> _nativeCallable;
  static SendPort? _currentIsolateSendPort;

  /// Initializes the pipeline and starts the background Isolate.
  Future<void> start() async {
    _nativeCallable = NativeCallable.listener(_staticFrameCallback);
    setNativeFrameProcessorCallback(_nativeCallable.nativeFunction);

    _isolate = await Isolate.spawn(_isolateEntry, _receivePort.sendPort);

    // Wait for the isolate to send its SendPort
    final completer = Completer<SendPort>();
    _receivePort.listen((message) {
      if (message is SendPort) {
        completer.complete(message);
      } else {
        _handleMessage(message);
      }
    });

    _mainToIsolateSendPort = await completer.future;
    _currentIsolateSendPort = _mainToIsolateSendPort;
  }

  void _handleMessage(dynamic message) {
    if (message is Map<String, dynamic>) {
      // Map native format codes to PixelFormat enum
      final int nativeFormat = message['pixelFormat'] as int;
      PixelFormat pixelFormat;
      switch (nativeFormat) {
        case 35: // android.graphics.ImageFormat.YUV_420_888
        case 842094169: // android.graphics.ImageFormat.YV12
          pixelFormat = PixelFormat.yuv;
          break;
        case 1: // android.graphics.ImageFormat.RGB_565 (approx)
        case 22: // android.graphics.ImageFormat.RGBA_8888
          pixelFormat = PixelFormat.rgb;
          break;
        default:
          if (nativeFormat >= 0 && nativeFormat < PixelFormat.values.length) {
            pixelFormat = PixelFormat.values[nativeFormat];
          } else {
            pixelFormat = PixelFormat.unknown;
          }
      }

      // Map native orientation degrees to Orientation enum
      final int nativeOrientation = message['orientation'] as int;
      Orientation orientation;
      switch (nativeOrientation) {
        case 0:
          orientation = Orientation.portrait;
          break;
        case 90:
          orientation = Orientation.landscapeLeft;
          break;
        case 180:
          orientation = Orientation.portraitUpsideDown;
          break;
        case 270:
          orientation = Orientation.landscapeRight;
          break;
        default:
          if (nativeOrientation >= 0 &&
              nativeOrientation < Orientation.values.length) {
            orientation = Orientation.values[nativeOrientation];
          } else {
            orientation = Orientation.portrait;
          }
      }

      final frame = Frame(
        Pointer.fromAddress(message['pointer'] as int),
        width: message['width'] as int,
        height: message['height'] as int,
        pixelFormat: pixelFormat,
        orientation: orientation,
        timestamp: message['timestamp'] as double,
      );

      try {
        callback(frame);
      } finally {
        frame.decrementRefCount();
      }
    }
  }

  static void _staticFrameCallback(
    Pointer<Void> handle,
    FrameMetadataNative metadata,
  ) {
    _currentIsolateSendPort?.send({
      'pointer': handle.address,
      'width': metadata.width,
      'height': metadata.height,
      'pixelFormat': metadata.pixelFormat,
      'orientation': metadata.orientation,
      'timestamp': metadata.timestamp,
    });
  }

  static void _isolateEntry(SendPort mainSendPort) {
    final receivePort = ReceivePort();
    mainSendPort.send(receivePort.sendPort);

    receivePort.listen((message) {
      mainSendPort.send(message);
    });
  }

  /// Stops the pipeline and kills the Isolate.
  void stop() {
    _nativeCallable.close();
    setNativeFrameProcessorCallback(nullptr);
    _isolate?.kill();
    _receivePort.close();
    _currentIsolateSendPort = null;
  }
}

/// Helper to throttle frame processing to a target FPS.
///
/// Maps to `runAtTargetFps` from react-native-vision-camera.
class FrameProcessorThrottler {
  final int targetFps;
  int _lastProcessedTimestamp = 0;

  FrameProcessorThrottler({required this.targetFps});

  bool shouldProcess(int timestampMs) {
    final interval = 1000 ~/ targetFps;
    if (timestampMs - _lastProcessedTimestamp >= interval) {
      _lastProcessedTimestamp = timestampMs;
      return true;
    }
    return false;
  }
}
