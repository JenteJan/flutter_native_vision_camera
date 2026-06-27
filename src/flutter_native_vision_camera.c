#ifdef ANDROID
#include <jni.h>
#include <android/log.h>
static JavaVM* g_javaVM = NULL;
static jclass g_pluginClass = NULL;
static jmethodID g_releaseFrameMethod = NULL;
static jmethodID g_retainFrameMethod = NULL;

#define FRAME_MAGIC 0xFEEDFACE

// Android frame handle: holds direct pointers + strides for every plane so the
// Dart/C++ side can read true multi-plane YUV (not just the Y plane).
typedef struct {
    uint32_t magic;
    uint32_t numPlanes;
    uint64_t id;
    void* planes[3];
    int32_t rowStrides[3];
    int32_t pixelStrides[3];
    int32_t planeSizes[3];
} NativeFrame;

JNIEXPORT jint JNICALL JNI_OnLoad(JavaVM* vm, void* reserved) {
    g_javaVM = vm;
    JNIEnv* env;
    if ((*vm)->GetEnv(vm, (void**)&env, JNI_VERSION_1_6) != JNI_OK) {
        return JNI_ERR;
    }
    jclass localClass = (*env)->FindClass(env, "dev/jentejan/flutter_native_vision_camera/FlutterNativeVisionCameraPlugin");
    if (!localClass) return JNI_ERR;

    g_pluginClass = (*env)->NewGlobalRef(env, localClass);
    g_releaseFrameMethod = (*env)->GetStaticMethodID(env, g_pluginClass, "releaseFrame", "(J)I");
    g_retainFrameMethod = (*env)->GetStaticMethodID(env, g_pluginClass, "retainFrame", "(J)I");

    if (!g_releaseFrameMethod || !g_retainFrameMethod) {
        __android_log_print(ANDROID_LOG_ERROR, "VisionCamera", "Failed to find releaseFrame/retainFrame methods");
        return JNI_ERR;
    }

    return JNI_VERSION_1_6;
}

// Invokes a static int(long) method on the plugin class, attaching the current
// thread to the JVM if necessary.
static int call_frame_jni(jmethodID method, uint64_t id) {
    if (g_javaVM == NULL || method == NULL) {
        __android_log_print(ANDROID_LOG_ERROR, "VisionCamera", "JNI not initialized for frame %lld", (long long)id);
        return 0;
    }
    JNIEnv* env;
    int status = (*g_javaVM)->GetEnv(g_javaVM, (void**)&env, JNI_VERSION_1_6);
    int attached = 0;
    if (status == JNI_EDETACHED) {
        status = (*g_javaVM)->AttachCurrentThread(g_javaVM, (void**)&env, NULL);
        attached = 1;
    }
    int result = 0;
    if (status == JNI_OK && env != NULL) {
        result = (*env)->CallStaticIntMethod(env, g_pluginClass, method, (jlong)id);
        if (attached) (*g_javaVM)->DetachCurrentThread(g_javaVM);
    }
    return result;
}
#else
#include <CoreVideo/CoreVideo.h>
#endif

#include <math.h>
#include <string.h>
#include <stdlib.h>
#include <stdatomic.h>
#include "flutter_native_vision_camera.h"

// ─── Plugin System ───────────────────────────────────────────────────

#define MAX_PLUGINS 16
static VisionCameraPlugin g_plugins[MAX_PLUGINS];
static int g_pluginCount = 0;

FFI_PLUGIN_EXPORT void VisionCamera_registerPlugin(VisionCameraPlugin plugin) {
    if (g_pluginCount < MAX_PLUGINS) {
        g_plugins[g_pluginCount++] = plugin;
    }
}

FFI_PLUGIN_EXPORT void VisionCamera_unregisterPlugin(const char* name) {
    for (int i = 0; i < g_pluginCount; i++) {
        if (strcmp(g_plugins[i].name, name) == 0) {
            if (g_plugins[i].onDestroy) g_plugins[i].onDestroy();
            for (int j = i; j < g_pluginCount - 1; j++) {
                g_plugins[j] = g_plugins[j + 1];
            }
            g_pluginCount--;
            return;
        }
    }
}

// ─── Frame Accessors ─────────────────────────────────────────────────

FFI_PLUGIN_EXPORT int32_t Frame_getBytesPerRow(FrameHandle handle) {
    if (handle == NULL) return 0;
#ifdef ANDROID
    NativeFrame* frame = (NativeFrame*)handle;
    if (frame->magic != FRAME_MAGIC) return 0;
    return frame->rowStrides[0];
#else
    return (int32_t)CVPixelBufferGetBytesPerRow((CVPixelBufferRef)handle);
#endif
}

FFI_PLUGIN_EXPORT int32_t Frame_getPlanesCount(FrameHandle handle) {
    if (handle == NULL) return 0;
#ifdef ANDROID
    NativeFrame* frame = (NativeFrame*)handle;
    if (frame->magic != FRAME_MAGIC) return 0;
    return (int32_t)frame->numPlanes;
#else
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
        return (int32_t)CVPixelBufferGetPlaneCount(pixelBuffer);
    }
    return 1;
#endif
}

FFI_PLUGIN_EXPORT void* Frame_getPlanePointer(FrameHandle handle, int32_t planeIndex) {
    if (handle == NULL) return NULL;
#ifdef ANDROID
    NativeFrame* frame = (NativeFrame*)handle;
    if (frame->magic != FRAME_MAGIC) return NULL;
    if (planeIndex < 0 || planeIndex >= (int32_t)frame->numPlanes) return NULL;
    return frame->planes[planeIndex];
#else
    // The buffer is locked once for the lifetime of the frame in
    // VisionCamera_dispatchFrame and unlocked in Frame_decrementRefCount.
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
        return CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex);
    }
    return CVPixelBufferGetBaseAddress(pixelBuffer);
#endif
}

FFI_PLUGIN_EXPORT int32_t Frame_getPlaneSize(FrameHandle handle, FrameMetadata metadata, int32_t planeIndex) {
    if (handle == NULL) return 0;
#ifdef ANDROID
    NativeFrame* frame = (NativeFrame*)handle;
    if (frame->magic != FRAME_MAGIC) return 0;
    if (planeIndex < 0 || planeIndex >= (int32_t)frame->numPlanes) return 0;
    return frame->planeSizes[planeIndex];
#else
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
        return (int32_t)(CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex) * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex));
    }
    return (int32_t)(metadata.height * CVPixelBufferGetBytesPerRow(pixelBuffer));
#endif
}

FFI_PLUGIN_EXPORT void Frame_incrementRefCount(FrameHandle handle) {
    if (handle == NULL) return;
#ifdef ANDROID
    NativeFrame* frame = (NativeFrame*)handle;
    if (frame->magic != FRAME_MAGIC) return;
    call_frame_jni(g_retainFrameMethod, frame->id);
#else
    CFRetain((CVPixelBufferRef)handle);
#endif
}

FFI_PLUGIN_EXPORT void Frame_decrementRefCount(FrameHandle handle) {
    if (handle == NULL) return;
#ifdef ANDROID
    NativeFrame* frame = (NativeFrame*)handle;

    // Safety check: only process and free if magic matches.
    if (frame->magic != FRAME_MAGIC) {
        __android_log_print(ANDROID_LOG_WARN, "VisionCamera", "Attempted to release invalid handle %p!", handle);
        return;
    }

    call_frame_jni(g_releaseFrameMethod, frame->id);

    // Mark as invalid BEFORE freeing to catch double-frees.
    frame->magic = 0;
    free(frame);
#else
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
    CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    CFRelease(pixelBuffer);
#endif
}

static _Atomic(FrameProcessorCallback) g_frameProcessorCallback = NULL;

FFI_PLUGIN_EXPORT void VisionCamera_setFrameProcessorCallback(FrameProcessorCallback callback) {
    atomic_store(&g_frameProcessorCallback, callback);
}

FFI_PLUGIN_EXPORT void VisionCamera_dispatchFrame(FrameHandle handle, FrameMetadata metadata) {
#ifndef ANDROID
    // iOS: lock the pixel buffer once for the whole frame lifetime. It is
    // unlocked exactly once in Frame_decrementRefCount.
    CVPixelBufferLockBaseAddress((CVPixelBufferRef)handle, kCVPixelBufferLock_ReadOnly);
#endif

    // 1. Notify C/C++ Plugins first (zero latency, synchronous).
    for (int i = 0; i < g_pluginCount; i++) {
        g_plugins[i].onFrame(handle, metadata);
    }

    // 2. Notify Dart (FFI dispatch). Dart is then responsible for calling
    //    Frame_decrementRefCount exactly once.
    FrameProcessorCallback cb = atomic_load(&g_frameProcessorCallback);
    if (cb != NULL) {
        cb(handle, metadata);
    } else {
        // No Dart listener; release the reference taken by the native side.
        Frame_decrementRefCount(handle);
    }
}

// ─── Image Processing Helpers ────────────────────────────────────────

FFI_PLUGIN_EXPORT double VisionCamera_computeLuminance(const uint8_t* yPlane, int32_t width, int32_t height, int32_t rowStride, int32_t startX, int32_t startY, int32_t endX, int32_t endY) {
    if (yPlane == NULL) return 0.0;
    if (rowStride <= 0) rowStride = width;

    if (startX < 0) startX = 0;
    if (startY < 0) startY = 0;
    if (endX >= width) endX = width - 1;
    if (endY >= height) endY = height - 1;

    if (startX > endX || startY > endY) return 0.0;

    uint64_t sum = 0;
    int32_t count = 0;

    for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
            sum += yPlane[y * rowStride + x];
            count++;
        }
    }

    if (count == 0) return 0.0;
    return (double)sum / (double)count;
}

#ifdef ANDROID
JNIEXPORT void JNICALL
Java_dev_jentejan_flutter_1native_1vision_1camera_FlutterNativeVisionCameraPlugin_nativeDispatchFrame(
    JNIEnv* env, jobject thiz,
    jobject b0, jobject b1, jobject b2,
    jint rs0, jint rs1, jint rs2,
    jint ps0, jint ps1, jint ps2,
    jint sz0, jint sz1, jint sz2,
    jint numPlanes,
    jint width, jint height, jint format, jint orientation, jdouble timestamp, jlong id) {

    NativeFrame* frame = (NativeFrame*)malloc(sizeof(NativeFrame));
    if (frame == NULL) return;

    frame->magic = FRAME_MAGIC;
    frame->id = (uint64_t)id;
    frame->numPlanes = (uint32_t)numPlanes;

    frame->planes[0] = (b0 != NULL) ? (*env)->GetDirectBufferAddress(env, b0) : NULL;
    frame->planes[1] = (b1 != NULL) ? (*env)->GetDirectBufferAddress(env, b1) : NULL;
    frame->planes[2] = (b2 != NULL) ? (*env)->GetDirectBufferAddress(env, b2) : NULL;

    frame->rowStrides[0] = rs0; frame->rowStrides[1] = rs1; frame->rowStrides[2] = rs2;
    frame->pixelStrides[0] = ps0; frame->pixelStrides[1] = ps1; frame->pixelStrides[2] = ps2;
    frame->planeSizes[0] = sz0; frame->planeSizes[1] = sz1; frame->planeSizes[2] = sz2;

    FrameMetadata metadata = {
        .width = width,
        .height = height,
        .pixelFormat = format,
        .orientation = orientation,
        .timestamp = timestamp
    };

    VisionCamera_dispatchFrame((FrameHandle)frame, metadata);
}
#endif

FFI_PLUGIN_EXPORT int sum(int a, int b) { return a + b; }
