/// Flutter Native Vision Camera — a high-performance camera plugin for real-time
/// vision applications.
///
/// Built on top of the native Camera2 (Android) and AVFoundation (iOS) APIs,
/// providing zero-copy GPU textures for previews and low-latency FFI access
/// to raw frame data.
library;

import 'dart:ffi';
import 'dart:io';

import 'src/frame.dart';

export 'src/camera_controller.dart';
export 'src/camera_devices.dart';
export 'src/camera_permissions.dart';
export 'src/camera_preview.dart';
export 'src/frame.dart';
export 'src/frame_processor.dart';
export 'src/frame_worklet.dart' show FrameWorklet, FrameWorkletEntry;
export 'src/types/types.dart';
export 'src/types/code_scanner.dart';

const String _libName = 'flutter_native_vision_camera';

/// The dynamic library for this plugin.
final DynamicLibrary _dylib = () {
  if (Platform.isMacOS || Platform.isIOS) {
    return DynamicLibrary.open('$_libName.framework/$_libName');
  }
  if (Platform.isAndroid || Platform.isLinux) {
    return DynamicLibrary.open('lib$_libName.so');
  }
  if (Platform.isWindows) {
    return DynamicLibrary.open('$_libName.dll');
  }
  throw UnsupportedError('Unknown platform: ${Platform.operatingSystem}');
}();

/// Initializes the plugin's FFI bindings.
///
/// Call this once before using any camera features.
void initializeVisionCamera() {
  initializeFrameBindings(_dylib);
}

/// Initializes the bundled **demo** C++ frame plugin (the `BrightnessPlugin`
/// showcase in `src/VisionCamera_NativePluginExample.cpp`).
///
/// This is a reference/demo only — you do **not** need to call it in your app.
/// It exists to show how to register a native C/C++ plugin that hooks the
/// camera pipeline with zero latency; ship your own plugin the same way.
void initializeNativeExamplePlugin() {
  final init = _dylib.lookupFunction<Void Function(), void Function()>(
    'VisionCamera_initExamplePlugin',
  );
  init();
}
