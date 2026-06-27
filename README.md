# Flutter Native Vision Camera

A high-performance, FFI-powered camera plugin for Flutter, built for **real-time
on-device vision**: direct, low-overhead access to camera frames for your own
ML/CV code, integrated barcode/QR scanning, and full hardware control.

[![pub package](https://img.shields.io/pub/v/flutter_native_vision_camera.svg)](https://pub.dev/packages/flutter_native_vision_camera)

> **Status:** Active development (`0.0.x`) — the API may change before `1.0.0`.
> **Device-verified** on Android (Pixel 8) and iOS 18: preview, photo, video
> recording, barcode/QR scanning, zoom/torch/focus, orientation, and mirroring.

## Demo

| Preview + orientation | Barcode / QR scanning | FFI frame processor |
|:---------------------:|:---------------------:|:-------------------:|
| ![preview](https://raw.githubusercontent.com/JenteJan/flutter_native_vision_camera/main/doc/preview.gif) | ![scanner](https://raw.githubusercontent.com/JenteJan/flutter_native_vision_camera/main/doc/scanner.gif) | ![frame processor](https://raw.githubusercontent.com/JenteJan/flutter_native_vision_camera/main/doc/frame_processor.gif) |

## Why use this instead of `camera`?

The official [`camera`](https://pub.dev/packages/camera) package is excellent for
general capture. This package targets the niche it doesn't cover: a **real-time
frame pipeline** where you read raw camera buffers for your own vision code,
with integrated scanning, all sharing one GPU-texture preview.

| Feature | `camera` (standard) | `flutter_native_vision_camera` |
|---------|---------------------|--------------------------------|
| **Preview** | Platform texture | **GPU texture** (Android zero-copy `SurfaceProducer`; iOS `CVPixelBuffer`) |
| **Frame access** | `startImageStream` over the platform channel (serialized) | **Direct FFI pointer access** to plane buffers — no channel serialization |
| **Native frame hook** | — | **Synchronous C/C++ plugin** on the camera thread (zero-latency) |
| **Barcodes / QR** | Separate plugin | **Integrated** (Android MLKit, iOS Vision) |

## Features

- **GPU-texture preview** with automatic orientation.
- **FFI frame access** — read raw Y/U/V (Android) or BGRA (iOS) planes directly.
- **Synchronous native C/C++ plugins** invoked on the camera thread.
- **Integrated barcode/QR scanning** (Android MLKit, iOS Vision).
- **Hardware controls** — zoom, torch, exposure, tap-to-focus, video recording.

## Requirements

- **Flutter** ≥ 3.22, **Dart** ≥ 3.8
- **iOS** 13.0+, **Android** `minSdk` 21+
- A **physical device** — simulators/emulators have no real camera.

## Getting Started

### Install

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

**Android** — `CAMERA` and `RECORD_AUDIO` are declared by the plugin; request
them at runtime (shown below).

### Basic usage — preview

```dart
import 'package:flutter/material.dart';
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';

// Once, at startup (e.g. in main()):
initializeVisionCamera();

class CameraScreen extends StatefulWidget {
  const CameraScreen({super.key});
  @override
  State<CameraScreen> createState() => _CameraScreenState();
}

class _CameraScreenState extends State<CameraScreen> {
  final controller = CameraController();

  @override
  void initState() {
    super.initState();
    _start();
  }

  Future<void> _start() async {
    // 0. Permission (otherwise you get a black preview).
    if (await CameraPermissions.requestCameraPermission() !=
        PermissionStatus.granted) {
      return;
    }
    // 1. Pick a device.
    final devices = await CameraDevices.getAvailableCameraDevices();
    final back =
        CameraDevices.getCameraDevice(devices, CameraPosition.back) ??
        devices.first;
    // 2. Initialize + start.
    await controller.initialize(back, enablePhoto: true);
    await controller.setActive(true);
    if (mounted) setState(() {});
  }

  @override
  void dispose() {
    controller.dispose(); // Release the hardware.
    super.dispose();
  }

  @override
  Widget build(BuildContext context) =>
      CameraPreview(controller: controller, resizeMode: ResizeMode.cover);
}
```

### Take a photo

`takePhoto()` requires `enablePhoto: true` at init.

```dart
final photo = await controller.takePhoto();
Image.file(File(photo.path)); // photo.width / photo.height / photo.path
```

### Record video

Initialize with `enableVideo: true`, then:

```dart
final dir = await getTemporaryDirectory();
await controller.startRecording('${dir.path}/clip.mp4');
// ... seamlessly zoom / toggle torch while recording ...
await controller.stopRecording();
```

> The `mirror` flag on `initialize` controls the front-camera selfie mirror for
> **both** the preview and the saved photo/video (default `true`; set `false` to
> save what the camera actually sees).

### Scan barcodes / QR codes

```dart
await controller.initialize(
  device,
  codeScanner: CodeScannerConfiguration(
    codeTypes: [CodeType.qr, CodeType.ean13, CodeType.code128],
  ),
);
controller.onCodeScanned.listen((codes) {
  for (final code in codes) debugPrint('${code.type}: ${code.value}');
});
```

### Lifecycle management

Release the hardware on `dispose()`, and pause/resume with the app lifecycle:

```dart
class _S extends State<MyCam> with WidgetsBindingObserver {
  @override
  void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); }
  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    controller.dispose();
    super.dispose();
  }
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!controller.isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      controller.setActive(false);
    } else if (state == AppLifecycleState.resumed) {
      controller.setActive(true);
    }
  }
}
```

## Frame Processors

Run code for every camera frame — the package's headline feature.

### Threading model — read this

- **Dart frame callback:** delivered **asynchronously on the main isolate's
  event loop** (via `dart:ffi` `NativeCallable.listener`). It does **not** run
  on a background isolate and does **not** block the camera thread. Keep the work
  light, or copy data out and hand it to your own isolate. (A true off-isolate
  worklet model is on the roadmap.)
- **Native C/C++ hook:** runs **synchronously on the camera thread** with zero
  added latency — use this for the heaviest work.

```dart
await controller.setFrameProcessor((frame) {
  // FFI hot path: read pixels here for ML/CV.
  final yPlane = frame.getPlaneData(0);                 // Uint8List view
  final stride = frame.planeBytesPerRow(0);             // bytes per row (>= width)
  final avgLuma = frame.computeLuminance(0, 0, frame.width, frame.height);
});
```

> `getPlaneData(i)` returns a **direct view** of native memory. Use
> `planeBytesPerRow(i)` / `planePixelStride(i)` to walk it correctly (rows are
> padded). `computeLuminance` is **YUV/Android-only** — on iOS (BGRA) it returns
> `0.0`; read `getPlaneData(0)` instead.

### Keeping a frame past the callback

The `Frame` and its buffers are valid **only during the callback**. To use the
data later (e.g. on another isolate), either copy it out synchronously:

```dart
final bytes = Uint8List.fromList(frame.getPlaneData(0)); // owns a copy
```

…or extend the native lifetime by balancing the ref-count exactly once:

```dart
frame.incrementRefCount();              // keep the buffer alive
// ... use frame asynchronously ...
frame.decrementRefCount();              // release it (mandatory)
```

### High-performance native C/C++ plugin

For the heaviest work, hook the synchronous frame loop in C++ (`src/VisionCamera.hpp`):

```cpp
#include "VisionCamera.hpp"

class BrightnessPlugin : public vision::Plugin {
public:
  const char* name() const override { return "brightness"; }
  void onFrame(const vision::Frame& frame) override {
    const uint8_t* y = frame.data();          // Y / first plane
    int stride = frame.bytesPerRow();
    // ...heavy SIMD/AI math on the camera thread...
  }
};

// Register once (e.g. from an init function you call via FFI at startup):
extern "C" __attribute__((visibility("default"))) void registerMyPlugins() {
  vision::Registry::instance().addPlugin(std::make_shared<BrightnessPlugin>());
}
```

Put your `.cpp` alongside the plugin sources; it links via CMake on Android and
the podspec on iOS. See `src/VisionCamera_NativePluginExample.cpp` for a full
working example.

## Platform Support

| Capability | Android | iOS |
|------------|:-------:|:---:|
| Preview (GPU texture) | ✅ | ✅ |
| Photo capture | ✅ | ✅ |
| Video recording (+ audio) | ✅ CameraX | ✅ AVAssetWriter |
| Barcode / QR scanning | ✅ MLKit | ✅ Vision |
| Frame processor (Dart, main isolate) | ✅ YUV planes | ✅ BGRA |
| Native C/C++ plugin (camera thread) | ✅ | ✅ |
| Zoom / torch / exposure / tap-focus | ✅ | ✅ |
| Manual focus distance | ⬜ | ✅ |
| `takeSnapshot` | ⬜ | ✅ |
| `regionOfInterest` (scanning) | ⬜ | ✅ |
| Minimum OS | `minSdk` 21 | iOS 13.0 |

Legend: ✅ supported · ⬜ not implemented yet. Symbology coverage differs slightly
between MLKit (Android) and Vision (iOS).

## Limitations & Roadmap

- **No web / desktop** — Android + iOS only.
- **Frame processor runs on the main isolate** today; a true off-isolate worklet
  model is planned.
- **Recording options** (`RecordVideoOptions`, codec/HDR) and **pause/resume**
  are not yet wired on all platforms; `startRecording` takes a path string.
- **Mirror** is set at `initialize` time (no runtime toggle yet).
- **Controls** (`setZoom`/`setTorch`/etc.) are no-ops until `setActive(true)`.
- No RAW capture / multi-camera; `takeSnapshot` is iOS-only.
- Planned API polish: typed `CameraException`, `TorchMode` enum, `switchCamera`,
  richer error reporting.

## Credits & Attribution

Inspired by [react-native-vision-camera](https://github.com/mrousavy/react-native-vision-camera)
by [Marc Rousavy](https://github.com/mrousavy) — bringing the same high-performance,
low-level camera philosophy to Flutter via synchronous FFI and `Texture` rendering.

## License

MIT
