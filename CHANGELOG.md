# Changelog

## 0.0.5

* **Docs:** added demo GIFs to the README (live preview + orientation, barcode/QR scanning with overlay,
  and the FFI frame processor's live brightness read). The GIFs live in the repo and are referenced by raw
  URL, so they're excluded from the published package.

## 0.0.4

Correctness, honesty, and packaging pass.

* **Fixed:** removed the deprecated `package` attribute from the Android manifest (broke builds under AGP 8.x;
  the namespace is set in `build.gradle`).
* **Fixed:** Android video recording no longer crashes — `RECORD_AUDIO` is now declared and audio is gated behind a
  runtime permission check, falling back to video-only when the mic is unavailable.
* **Fixed:** `requestMicrophonePermission` now actually awaits the permission dialog result.
* **Fixed:** frame processor no longer routes frames through a no-op relay isolate. The Dart callback is now
  delivered directly via `NativeCallable.listener`; documentation corrected to state it runs on the main isolate
  event loop (not a background isolate).
* **Fixed:** `CameraPreview` now rebuilds when the controller updates (e.g. after async init or device switch).
* **Fixed:** Android tap-to-focus now targets the correct metering point.
* **Improved:** Android frames now expose all YUV planes with correct row strides (previously only the Y plane).
* **Improved:** iOS reports the real frame pixel format and retains preview buffers safely.
* **Packaging:** real podspec metadata, version lockstep, honest README/feature matrix, `topics`/`issue_tracker`,
  CI (format/analyze/test/dry-run/pana + per-platform native builds), dropped the unused
  `plugin_platform_interface` dependency.
* **iOS:** implemented video recording (AVAssetWriter, keeps the frame stream live), `setFocusDistance`,
  barcode symbology filtering, teardown-on-reinit, `CVPixelBuffer` retain/lock balance, honest pixel format,
  main-thread results. Device-verified on iOS 18 (preview, photo, video, scanning).
* **Orientation (structural):** preview rotation is now read from the camera framework
  (Android `SurfaceRequest.TransformationInfo`, iOS sensor-relative) and applied once in `CameraPreview` —
  fixing the recurring 90° tilt. Added `controller.previewRotation` / `displayPreviewSize`; scanner overlay
  and camera page no longer compensate for rotation themselves. iOS Vision boxes now use the buffer orientation.
* **Mirroring:** a single `mirror` flag on `initialize` drives both the front-camera preview and the saved
  photo/video; the preview no longer double-mirrors on Android. `CameraPreview` gains `ResizeMode.contain`.
* **Android:** dynamic capture orientation, correct tap-to-focus metering, real photo orientation.
* **API:** exposed per-plane strides (`Frame.planeBytesPerRow`/`planePixelStride`) so chroma planes can be
  walked correctly; added `CameraDevices.getCameraFormat(...)` to pick a format by resolution/fps.
* **Docs:** comprehensive README (compile-correct quickstart with permissions, photo/video/scan/lifecycle
  snippets, a correct native C/C++ plugin guide, requirements, expanded platform matrix, Limitations & Roadmap);
  rewrote the example README; corrected the "background isolate" claim in the API docs to match reality
  (main isolate); documented `takeSnapshot` (iOS-only), `setExposure` units, and `initialize`'s
  `pixelFormat`/`mirror`.
* **Example:** the Native Vision Camera page now reads the raw frame buffer over FFI and shows a live average
  brightness, demonstrating the headline feature; fixed the C++ sample's row-stride indexing.

## 0.0.3

* Migrated the Android embedding to AndroidX for better compatibility.

## 0.0.2

* Fixed pubspec metadata (homepage, repository).

## 0.0.1

* Initial release of `flutter_native_vision_camera`.
* FFI pipeline for frame access, zero-copy preview textures, basic camera controls (zoom, focus, flash),
  and real-time barcode scanning.
