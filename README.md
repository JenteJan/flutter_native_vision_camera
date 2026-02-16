# Flutter Native Vision Camera

A high-performance, FFI-powered camera plugin for Flutter that puts efficiency and hardware control first. 

Built for developers who need more than just a preview: **Real-time AI, low-latency filters, and professional-grade video control.**

[![pub package](https://img.shields.io/pub/v/flutter_native_vision_camera.svg)](https://pub.dev/packages/flutter_native_vision_camera)

## Why use this instead of `camera`?

The official `camera` package is great for simple use cases, but it often falls short when building high-performance vision applications (AI, QR scanning, custom filters). This package was built to solve those limitations.

### 🚀 Key Advantages

| Feature | `camera` (standard) | `flutter_native_vision_camera` |
|---------|---------------------|--------------------------------|
| **Rendering** | Platform Channels (YUV -> Bitmap -> Skia) | **Zero-Copy GPU Textures** (OES -> Flutter Texture) |
| **Orientation** | Matches UI Orientation (Buggy for video) | **Hardware-Level Sensing** (Correct even if UI is locked) |
| **Frame Processing** | Async via Isolate (High Latency) | **Synchronous Background FFI** (Near Zero Latency) |
| **QR/Barcodes** | Third-party plugin required | **Optimized MLKit Integration** built-in |
| **Zoom/Focus** | Basic level support | Unified request management (Works during recording) |

## Features

- **Zero-Copy Rendering**: Frames go directly from the camera sensor to the GPU and then to Flutter's `Texture` widget. No expensive copying or CPU-side bitmap conversion.
- **Physical Orientation Engine**: High-fidelity rotation sensing using native `OrientationEventListener`. Recorded videos and previews always have the correct orientation, even on orientation-locked apps.
- **Integrated MLKit**: High-speed, hardware-accelerated barcode and QR code scanning.
- **Unified Request Loop**: Change zoom, torch, exposure, or recording state without dropping frame buffers.
- **FFI Background Pipeline**: Process camera frames in C++/Rust/Dart FFI with zero memory copying.

## Frame Processors

Frame processors allow you to run code for every frame the camera captures. Unlike the standard `camera` plugin, `flutter_native_vision_camera` runs these **synchronously on a background thread**.

### How it works
1. **Zero Latency**: Frames are delivered to the processor as soon as they are available from the sensor.
2. **Background Execution**: Your code runs on a separate background Isolate or in Native C++, so the main UI thread stays at a silky smooth 60/120 FPS.
3. **Memory Safety**: The `Frame` object is valid only for the duration of the callback. If you need to keep data, copy it out of the frame's buffer.

### Dart Frame Processor

Use for ML tasks (using `google_mlkit_*` or `tflite_flutter`) or image manipulation in Dart.

```dart
await controller.setFrameProcessor((frame) {
  // 'frame' contains pointers to YUV/RGB buffers
  final bytes = frame.getPlane(0).bytes; // Direct access to Y-plane
  
  // Do your analysis here...
});
```

### 🚀 High-Performance FFI Plugins

One of the unique features of `flutter_native_vision_camera` is the ability to write **Synchronous C++ Plugins**. 

Instead of sending expensive image data back and forth over Method Channels or into separate Dart Isolates, you can hook directly into the native frame loop.

```cpp
// Your high-performance C++ code
void onFrame(FrameHandle frame) {
    void* y_plane = Frame_getPlanePointer(frame, 0);
    // Do heavy AI math here on the background thread
}
```

## Getting Started

### Installation

Add to your `pubspec.yaml`:

```yaml
dependencies:
  flutter_native_vision_camera: ^1.0.0
```

### Basic Usage

```dart
final controller = CameraController();

// 1. Initialize with a device
await controller.initialize(
  devices.first,
  enableVideo: true,
  codeScanner: CodeScannerConfiguration(),
);

// 2. Start streaming
await controller.setActive(true);

// 3. Listen for codes
controller.onCodeScanned.listen((codes) {
  print('Detected: ${codes.first.value}');
});

// 4. Render in your widget tree
ValueListenableBuilder<CameraState>(
  valueListenable: controller,
  builder: (context, state, _) {
    if (state == CameraState.uninitialized) return CircularProgressIndicator();
    return Texture(textureId: controller.textureId!);
  },
)
```

### Lifecycle Management

Keeping the camera hardware active is resource-intensive. You **must** dispose of the controller when it's no longer needed to release the hardware and stop background threads.

```dart
@override
void dispose() {
  // Shuts down the camera, sessions, and background isolates
  controller.dispose(); 
  super.dispose();
}
```

### Video Recording & Zooming

Unlike many other plugins, you can smoothly zoom or toggle the torch *while* recording video without causing any frame drops or freezes.

```dart
await controller.startRecording('/path/to/video.mp4');

// This call seamlessly updates the ongoing recording request
await controller.setZoom(2.5); 

await controller.stopRecording();
```

## Platform Support

| Platform | Support | Notes |
|----------|---------|-------|
| **Android** | ✅ Full | Camera2, MLKit, FFI, Recording |
| **iOS** | ⚠️ Partial | AVFoundation, Vision API, Preview only. Recording & FFI coming soon. |

## Credits & Attribution

This package is a Flutter port and expansion of the concepts introduced by [react-native-vision-camera](https://github.com/mrousavy/react-native-vision-camera), originally created by [Marc Rousavy](https://github.com/mrousavy).

We aim to bring the same high-performance, low-level camera control to the Flutter ecosystem, while leveraging Flutter's unique strengths like synchronous FFI and specialized `Texture` rendering.

## License

MIT
