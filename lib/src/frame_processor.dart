import 'dart:async';
import 'dart:ffi';

import 'package:flutter/foundation.dart';

import 'frame.dart';
import 'types/orientation.dart';
import 'types/pixel_format.dart';

/// The signature of a frame processor callback.
///
/// This callback is invoked for every camera frame.
///
/// ## Threading
/// The callback is delivered **asynchronously on the main isolate's event
/// loop** via `dart:ffi` [NativeCallable.listener]. It does **not** run on a
/// separate background isolate and it does **not** block the camera thread.
/// Keep the work light, or copy the data out and hand it to your own isolate.
/// For the heaviest work, register a synchronous native C/C++ plugin instead,
/// which runs on the camera thread with zero added latency.
typedef FrameProcessorCallback = void Function(Frame frame);

/// Manages the native frame-processor callback for a camera session.
///
/// Each pipeline owns its own [NativeCallable]; only one pipeline should be
/// active per native frame source at a time (the C layer holds a single
/// callback slot).
class FrameProcessorPipeline {
  /// Creates a pipeline that forwards native frames to [callback].
  FrameProcessorPipeline(this.callback);

  /// The user-provided frame processor.
  final FrameProcessorCallback callback;

  NativeCallable<NativeFrameProcessorCallbackFunc>? _nativeCallable;
  bool _stopped = false;

  /// Registers the native callback so frames begin flowing to [callback].
  Future<void> start() async {
    _stopped = false;
    final callable = NativeCallable<NativeFrameProcessorCallbackFunc>.listener(
      _onNativeFrame,
    );
    _nativeCallable = callable;
    setNativeFrameProcessorCallback(callable.nativeFunction);
  }

  /// Invoked asynchronously on the main isolate for each dispatched frame.
  ///
  /// The native side has taken a reference on our behalf; we are responsible
  /// for releasing it via [Frame.decrementRefCount] exactly once — even if the
  /// pipeline was stopped between dispatch and delivery, or the user callback
  /// throws.
  void _onNativeFrame(Pointer<Void> handle, FrameMetadataNative metadata) {
    final frame = Frame(
      handle,
      width: metadata.width,
      height: metadata.height,
      pixelFormat: _mapPixelFormat(metadata.pixelFormat),
      orientation: _mapOrientation(metadata.orientation),
      timestamp: metadata.timestamp,
    );
    try {
      if (!_stopped) callback(frame);
    } catch (e, stack) {
      // A throwing frame processor must not tear down the listener or leak
      // the frame; log and continue.
      if (kDebugMode) {
        debugPrint('FrameProcessor callback threw: $e\n$stack');
      }
    } finally {
      frame.decrementRefCount();
    }
  }

  /// Unregisters the native callback and releases the [NativeCallable].
  void stop() {
    _stopped = true;
    // Detach the native side first so no new frames are dispatched into a
    // callable we are about to close.
    setNativeFrameProcessorCallback(nullptr);
    _nativeCallable?.close();
    _nativeCallable = null;
  }

  static PixelFormat _mapPixelFormat(int nativeFormat) {
    switch (nativeFormat) {
      case 35: // android.graphics.ImageFormat.YUV_420_888
      case 842094169: // android.graphics.ImageFormat.YV12
        return PixelFormat.yuv;
      case 1: // BGRA (iOS) / RGB family
      case 22: // android.graphics.ImageFormat.RGBA_8888
        return PixelFormat.rgb;
      default:
        if (nativeFormat >= 0 && nativeFormat < PixelFormat.values.length) {
          return PixelFormat.values[nativeFormat];
        }
        return PixelFormat.unknown;
    }
  }

  static Orientation _mapOrientation(int nativeOrientation) {
    switch (nativeOrientation) {
      case 0:
        return Orientation.portrait;
      case 90:
        return Orientation.landscapeLeft;
      case 180:
        return Orientation.portraitUpsideDown;
      case 270:
        return Orientation.landscapeRight;
      default:
        if (nativeOrientation >= 0 &&
            nativeOrientation < Orientation.values.length) {
          return Orientation.values[nativeOrientation];
        }
        return Orientation.portrait;
    }
  }
}

/// Helper to throttle frame processing to a target FPS.
///
/// Maps to `runAtTargetFps` from react-native-vision-camera.
class FrameProcessorThrottler {
  /// Creates a throttler that admits at most [targetFps] frames per second.
  FrameProcessorThrottler({required this.targetFps});

  /// The maximum number of frames to process per second.
  final int targetFps;
  int _lastProcessedTimestamp = 0;

  /// Returns `true` if a frame at [timestampMs] should be processed.
  bool shouldProcess(int timestampMs) {
    final interval = 1000 ~/ targetFps;
    if (timestampMs - _lastProcessedTimestamp >= interval) {
      _lastProcessedTimestamp = timestampMs;
      return true;
    }
    return false;
  }
}
