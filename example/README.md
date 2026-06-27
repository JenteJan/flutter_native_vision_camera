# flutter_native_vision_camera — example

A showcase of [`flutter_native_vision_camera`](../) with three pages.

## Run it

```bash
cd example
flutter run        # use a PHYSICAL device — simulators/emulators have no camera
```

Grant the camera (and microphone, for video) permission prompts on first launch.

## What's inside

- **Native Vision Camera** — the FFI preview with a live **frame processor**:
  an FPS meter *and* an average-brightness readout computed from the raw pixel
  buffer (`Frame.computeLuminance` / `getPlaneData`), plus photo, video,
  zoom, torch, tap-to-focus, and front/back switching. This is the page that
  demonstrates the package's headline feature — reading frames for your own
  ML/CV. The hot path is in `lib/native_camera_page.dart` (`setFrameProcessor`).
- **Barcode / QR Scanner** — real-time scanning (MLKit on Android, Vision on
  iOS) with a live bounding-box overlay. See `lib/code_scanner_page.dart`.
- **Standard Camera** — the official `camera` package, side-by-side, so you can
  compare delivery FPS and latency. See `lib/standard_camera_page.dart`.

## Read this first

- `lib/native_camera_page.dart` → `setFrameProcessor(...)` is where per-frame
  pixel data is read on the FFI hot path.
- `../src/VisionCamera_NativePluginExample.cpp` is a native C++ frame plugin
  (registered via `initializeNativeExamplePlugin()` in `lib/main.dart`) — the
  template for shipping your own zero-latency C/C++ vision code.
