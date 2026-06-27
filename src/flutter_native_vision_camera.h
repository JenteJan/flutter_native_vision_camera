#ifndef FLUTTER_NATIVE_VISION_CAMERA_H
#define FLUTTER_NATIVE_VISION_CAMERA_H

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

#if _WIN32
#include <windows.h>
#else
#include <pthread.h>
#include <unistd.h>
#endif

#if _WIN32
#define FFI_PLUGIN_EXPORT __declspec(dllexport)
#else
#define FFI_PLUGIN_EXPORT __attribute__((visibility("default")))
#endif

#ifdef __cplusplus
extern "C"
{
#endif

    // Opaque handle for a native frame.
    // Android: NativeFrame struct (id + per-plane pointers/strides)
    // iOS: CVPixelBufferRef
    typedef void *FrameHandle;

    /**
     * Metadata for a single camera frame.
     */
    typedef struct
    {
        int32_t width;
        int32_t height;
        int32_t pixelFormat; // 0 for YUV_420_888, 1 for BGRA
        int32_t orientation; // 0, 90, 180, 270
        double timestamp;    // Presentation timestamp in seconds
    } FrameMetadata;

    typedef void (*FrameProcessorCallback)(FrameHandle handle, FrameMetadata metadata);

    /**
     * A native C/C++ plugin for Vision Camera.
     */
    typedef struct VisionCameraPlugin
    {
        const char *name;
        // Called when a new frame is available.
        // Return 1 to consume/process, 0 to ignore.
        void (*onFrame)(FrameHandle handle, FrameMetadata metadata);
        // Called when the plugin is removed.
        void (*onDestroy)();
    } VisionCameraPlugin;

    FFI_PLUGIN_EXPORT int32_t Frame_getBytesPerRow(FrameHandle handle);
    FFI_PLUGIN_EXPORT int32_t Frame_getPlanesCount(FrameHandle handle);
    FFI_PLUGIN_EXPORT void *Frame_getPlanePointer(FrameHandle handle, int32_t planeIndex);
    FFI_PLUGIN_EXPORT int32_t Frame_getPlaneSize(FrameHandle handle, FrameMetadata metadata, int32_t planeIndex);
    FFI_PLUGIN_EXPORT void Frame_incrementRefCount(FrameHandle handle);
    FFI_PLUGIN_EXPORT void Frame_decrementRefCount(FrameHandle handle);

    // Registration for C-level plugins (Zero-latency processing)
    FFI_PLUGIN_EXPORT void VisionCamera_registerPlugin(VisionCameraPlugin plugin);
    FFI_PLUGIN_EXPORT void VisionCamera_unregisterPlugin(const char *name);

    // Bridge to Dart (High-level processing)
    FFI_PLUGIN_EXPORT void VisionCamera_setFrameProcessorCallback(FrameProcessorCallback callback);
    FFI_PLUGIN_EXPORT void VisionCamera_dispatchFrame(FrameHandle handle, FrameMetadata metadata);

    FFI_PLUGIN_EXPORT double VisionCamera_computeLuminance(const uint8_t *yPlane, int32_t width, int32_t height, int32_t rowStride, int32_t startX, int32_t startY, int32_t endX, int32_t endY);

#ifdef __cplusplus
}
#endif

#endif // FLUTTER_NATIVE_VISION_CAMERA_H
