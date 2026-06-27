# Flutter Native Vision Camera

A high-performance, FFI-powered camera plugin for Flutter that puts efficiency and hardware control first.

Built for developers who need more than just a preview: **real-time on-device vision (ML/CV), low-latency frame access, and direct hardware control.**

[![pub package](https://img.shields.io/pub/v/flutter_native_vision_camera.svg)](https://pub.dev/packages/flutter_native_vision_camera)

> **Status:** Active development (`0.0.x`). The API is not yet stable and may change before `1.0.0`.
> See [Platform Support](#platform-support) for the current per-platform feature matrix.

## Why use this instead of `camera`?

The official [`camera`](https://pub.dev/packages/camera) package is excellent for general capture. This package targets a
different niche: **real-time vision pipelines** where you need direct, low-overhead access to raw camera frames for your own
ML/CV code, plus integrated barcode scanning, all sharing a single GPU-texture preview.

| Feature | `camera` (standard) | `flutter_native_vision_camera` |
|---------|---------------------|--------------------------------|
| **Preview** | Platform texture | **GPU texture** (Android: zero-copy `SurfaceProducer`; iOS: `CVPixelBuffer` texture) |
| **Frame access** | `startImageStream` over the platform channel (serialized) | **Direct FFI pointer access** to plane buffers — no channel serialization |
| **Native frame hook** | — | **Synchronous C/C++ plugin** invoked on the camera thread (zero-latency) |
| **Barcodes / QR** | Separate plugin | **Integrated** (Android MLKit, iOS Vision) |

## Features

- **GPU-texture preview.** Frames render through Flutter's `Texture` widget. On Android this is a zero-copy
  `SurfaceProducer` (Impeller/Vulkan friendly); on iOS the `CVPixelBuffer` is handed to the texture registry.
- **FFI frame access.** Frame processors receive a `Frame` backed by a native pointer, so you read the raw
  Y/U/V (Android) or BGRA (iOS) plane data directly — no expensive bitmap conversion or channel hop.
- **Synchronous native plugins.** Register a C/C++ `VisionCameraPlugin` that is called on the camera thread the
  instant a frame is available — ideal for heavy SIMD/AI math with zero added latency.
- **Integrated barcode scanning.** Hardware-accelerated barcode/QR scanning (Android MLKit, iOS Vision).
- **Hardware controls.** Zoom, torch, exposure, tap-to-focus, and (Android) video recording with audio.

## Frame Processors

Frame processors let you run code for every frame the camera captures.

### Threading model — read this

- **Dart frame callback:** delivered **asynchronously on Dart's main isolate event loop** (via `dart:ffi`
  `NativeCallable.listener`). It does **not** run on a separate background isolate, and it does **not** block the
  camera thread. Keep the work light, or hand the data off to your own isolate. (A true off-isolate/worklet
  processing model is on the roadmap for a future release.)
- **Native C/C++ hook:** runs **synchronously on the camera thread** with zero added latency. Use this path for
  the heaviest work.

The `Frame` object and its buffers are only valid for the duration of the callback. To keep data, copy it out
(or call `frame.incrementRefCount()` / `frame.decrementRefCount()` to extend its lifetime).

### Dart frame processor

```dart
await controller.setFrameProcessor((frame) {
  // Direct access to the native plane buffers (zero-copy view).
  final yPlane = frame.getPlaneData(0); // Uint8List view of the Y plane (Android)
  final avgLuma = frame.computeLuminance(0, 0, frame.width, frame.height);
  // ...your analysis...
});
```

### High-performance C/C++ plugin

Hook directly into the synchronous native frame loop instead of crossing into Dart:

```cpp
void onFrame(FrameHandle frame, FrameMetadata meta) {
    void* yPlane = Frame_getPlanePointer(frame, 0);
    // Heavy AI/CV math here, on the camera thread.
}
```

## Getting Started

### Installation

```bash
flutter pub add flutter_native_vision_camera
```

### Permissions

**iOS** — add to `ios/Runner/Info.plist`:

```xml
<key>NSCameraUsageDescription</key>
<string>This app needs camera access to capture photos and video.</string>
<key>NSMicrophoneUsageDescription</key>
<string>This app needs microphone access to record video with audio.</string>
```

**Android** — `CAMERA` and `RECORD_AUDIO` are declared by the plugin. Request them at runtime via
`CameraPermissions` before initializing the camera.

### Basic usage

```dart
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';

// Once, at startup:
initializeVisionCamera();

final controller = CameraController();

// 1. Pick a device and initialize.
final devices = await CameraDevices.getAvailableCameraDevices();
await controller.initialize(
  devices.first,
  enableVideo: true,
  codeScanner: CodeScannerConfiguration(),
);

// 2. Start streaming.
await controller.setActive(true);

// 3. Listen for codes.
controller.onCodeScanned.listen((codes) {
  debugPrint('Detected: ${codes.first.value}');
});

// 4. Render in your widget tree.
CameraPreview(controller: controller);
```

### Lifecycle management

The camera hardware is resource-intensive. You **must** dispose the controller when it's no longer needed.

```dart
@override
void dispose() {
  controller.dispose(); // Releases hardware, sessions, and frame processors.
  super.dispose();
}
```

### Orientation & mirroring

The preview is **oriented automatically**. The sensor is mounted at an angle, so
the raw texture arrives rotated; `CameraPreview` reads the rotation the camera
framework reports and applies it for you (Android: `TransformationInfo`; iOS:
sensor-relative). Don't wrap it in `RotatedBox`/`AspectRatio` to "fix" rotation —
if you draw an overlay, size it against `controller.displayPreviewSize`.

A single `mirror` flag controls the front-camera "selfie" mirror for **both** the
preview and the captured photo/video:

```dart
await controller.initialize(
  device,
  enablePhoto: true,
  enableVideo: true,
  mirror: false, // false = save what the camera actually sees; true = selfie mirror
);
```

Use `ResizeMode.cover` to fill the view (cropping) or `ResizeMode.contain` to fit
the whole frame (letterboxed):

```dart
CameraPreview(controller: controller, resizeMode: ResizeMode.contain);
```

## Platform Support

| Capability | Android | iOS |
|------------|:-------:|:---:|
| Preview (GPU texture) | ✅ | ✅ |
| Photo capture | ✅ | ✅ |
| Barcode / QR scanning | ✅ MLKit | ✅ Vision |
| Zoom / torch / exposure / focus | ✅ | ✅ |
| FFI frame access | ✅ (YUV planes) | ✅ (BGRA) |
| Video recording | ✅ | ✅ |
| Manual focus distance | ⬜ | ✅ |

Legend: ✅ supported · ⬜ not yet implemented.

## Credits & Attribution

This package is inspired by [react-native-vision-camera](https://github.com/mrousavy/react-native-vision-camera) by
[Marc Rousavy](https://github.com/mrousavy), bringing the same high-performance, low-level camera philosophy to Flutter
while leveraging Flutter's strengths like synchronous FFI and `Texture` rendering.

## License

MIT
