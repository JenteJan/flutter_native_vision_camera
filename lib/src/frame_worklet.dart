import 'dart:async';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import 'frame.dart';

/// A top-level (or static) function that sets up a frame worklet. It runs
/// **once on the worker isolate**: initialise any persistent state (load a
/// model, etc.), then register a handler with [FrameWorklet.onFrame] and return
/// results with [FrameWorklet.send].
///
/// It MUST be a top-level or static function — Dart cannot send a closure that
/// captures state to another isolate. Pass it to
/// `CameraController.setFrameWorklet`.
typedef FrameWorkletEntry = FutureOr<void> Function(FrameWorklet worklet);

/// The context handed to a [FrameWorkletEntry], living on the worker isolate.
class FrameWorklet {
  FrameWorklet._(this._send, this.args);

  final void Function(Object? result) _send;

  /// The sendable initialization value passed to `setFrameWorklet(entry,
  /// args:)`. Use it for data the worklet can't obtain itself — most importantly
  /// **assets**: a background isolate can't read `rootBundle`, so load your model
  /// bytes on the main isolate and pass them here (then `Interpreter.fromBuffer`).
  final Object? args;

  void Function(Frame frame)? _handler;

  /// Registers the per-frame [handler]. It runs on the worker isolate for every
  /// dispatched camera frame; the [Frame] (and its buffers) are valid only for
  /// the duration of the call.
  void onFrame(void Function(Frame frame) handler) => _handler = handler;

  /// Sends a **sendable** [result] back to the main isolate, where it surfaces
  /// on `CameraController.frameResults`. Use plain data (numbers, strings,
  /// lists, maps, records) — not platform handles or widgets.
  void send(Object? result) => _send(result);
}

/// Opens the plugin's dynamic library on the current isolate. The binding
/// globals in `frame.dart` are per-isolate `late` fields, so a worker isolate
/// must open the library and call [initializeFrameBindings] itself.
DynamicLibrary _openDylib() {
  const name = 'flutter_native_vision_camera';
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$name.framework/$name');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$name.so');
  }
  if (Platform.isWindows) return DynamicLibrary.open('$name.dll');
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}

class _WorkletBootstrap {
  const _WorkletBootstrap(this.entry, this.toMain, this.rootToken, this.args);
  final FrameWorkletEntry entry;
  final SendPort toMain;
  final RootIsolateToken? rootToken;
  final Object? args;
}

/// Spawns the worker isolate that runs [entry]. The worker sends its control
/// [SendPort] (first message) and then each `send()` result to [toMain].
Future<Isolate> spawnFrameWorklet(
  FrameWorkletEntry entry,
  SendPort toMain,
  RootIsolateToken? rootToken,
  Object? args,
) {
  return Isolate.spawn(
    _workletMain,
    _WorkletBootstrap(entry, toMain, rootToken, args),
    debugName: 'FrameWorklet',
  );
}

Future<void> _workletMain(_WorkletBootstrap b) async {
  // Enable platform channels / rootBundle on this isolate (so the worklet can
  // load assets, e.g. a .tflite model).
  final token = b.rootToken;
  if (token != null) {
    BackgroundIsolateBinaryMessenger.ensureInitialized(token);
  }
  initializeFrameBindings(_openDylib());

  final control = ReceivePort();
  b.toMain.send(control.sendPort); // hand main a stop channel + keep us alive

  final ctx = FrameWorklet._(b.toMain.send, b.args);
  late final NativeCallable<NativeFrameProcessorCallbackFunc> callable;

  void dispatch(Pointer<Void> handle, FrameMetadataNative metadata) {
    final frame = Frame.fromNative(handle, metadata);
    try {
      ctx._handler?.call(frame);
    } catch (e, s) {
      if (kDebugMode) debugPrint('FrameWorklet handler threw: $e\n$s');
    } finally {
      // Release the reference the native dispatcher took on our behalf.
      frame.decrementRefCount();
    }
  }

  callable = NativeCallable<NativeFrameProcessorCallbackFunc>.listener(
    dispatch,
  );

  // Run the user's setup (may await, e.g. loading a model). Frames don't flow
  // until we register the native callback below, so there's no early race.
  try {
    await b.entry(ctx);
  } catch (e, s) {
    if (kDebugMode) debugPrint('FrameWorklet entry failed: $e\n$s');
  }
  setNativeFrameProcessorCallback(callable.nativeFunction);

  control.listen((msg) {
    if (msg == 'stop') {
      // Detach the native side first (mutex-guarded in C, so no dispatch is in
      // flight), then tear down and confirm before this isolate exits.
      setNativeFrameProcessorCallback(nullptr);
      callable.close();
      b.toMain.send(_workletStopped);
      control.close();
    }
  });
}

/// Sentinel the worker sends once it has cleared the native callback, so the
/// main isolate can safely start a new processor without a teardown race.
const String _workletStopped = '__frame_worklet_stopped__';

/// Exposed so the controller recognises the stop-confirmation sentinel.
const String frameWorkletStoppedSignal = _workletStopped;
