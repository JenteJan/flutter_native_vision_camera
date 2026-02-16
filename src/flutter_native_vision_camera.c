#ifdef ANDROID
#include <jni.h>
#include <android/log.h>
static JavaVM* g_javaVM = NULL;
static jclass g_pluginClass = NULL;
static jmethodID g_releaseFrameMethod = NULL;

#define FRAME_MAGIC 0xFEEDFACE

typedef struct {
    uint32_t magic;
    uint32_t padding;
    uint64_t id;
    void* address;
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
    // Updated signature: returns Int (I)
    g_releaseFrameMethod = (*env)->GetStaticMethodID(env, g_pluginClass, "releaseFrame", "(J)I");
    
    if (!g_releaseFrameMethod) {
        __android_log_print(ANDROID_LOG_ERROR, "VisionCamera", "Failed to find releaseFrame(J)I");
        return JNI_ERR;
    }
    
    return JNI_VERSION_1_6;
}
#else
#include <CoreVideo/CoreVideo.h>
#endif

#include <math.h>
#include <string.h>
#include <stdlib.h>
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
#ifdef ANDROID
    // In YUV_420_888, planes might have different strides. 
    // This is a simplified return for the Y plane.
    return 0; // Better to get this from metadata or a separate helper
#else
    if (handle == NULL) return 0;
    return (int32_t)CVPixelBufferGetBytesPerRow((CVPixelBufferRef)handle);
#endif
}

FFI_PLUGIN_EXPORT int32_t Frame_getPlanesCount(FrameHandle handle) {
#ifdef ANDROID
    return 3; // Y, U, V
#else
    if (handle == NULL) return 0;
    return (int32_t)CVPixelBufferGetPlaneCount((CVPixelBufferRef)handle);
#endif
}

FFI_PLUGIN_EXPORT void* Frame_getPlanePointer(FrameHandle handle, int32_t planeIndex) {
#ifdef ANDROID
    if (handle == NULL) return NULL;
    NativeFrame* frame = (NativeFrame*)handle;
    if (frame->magic != FRAME_MAGIC) return NULL;
    return frame->address; 
#else
    if (handle == NULL) return NULL;
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
    CVPixelBufferLockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
        return CVPixelBufferGetBaseAddressOfPlane(pixelBuffer, planeIndex);
    } else {
        return CVPixelBufferGetBaseAddress(pixelBuffer);
    }
#endif
}

FFI_PLUGIN_EXPORT int32_t Frame_getPlaneSize(FrameHandle handle, FrameMetadata metadata, int32_t planeIndex) {
    if (handle == NULL) return 0;
#ifdef ANDROID
    if (planeIndex == 0) return metadata.width * metadata.height;
    return (metadata.width / 2) * (metadata.height / 2);
#else
    CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
    if (CVPixelBufferIsPlanar(pixelBuffer)) {
        return (int32_t)(CVPixelBufferGetHeightOfPlane(pixelBuffer, planeIndex) * CVPixelBufferGetBytesPerRowOfPlane(pixelBuffer, planeIndex));
    } else {
        return (int32_t)(metadata.height * CVPixelBufferGetBytesPerRow(pixelBuffer));
    }
#endif
}

FFI_PLUGIN_EXPORT void Frame_incrementRefCount(FrameHandle handle) {
#ifndef ANDROID
    if (handle != NULL) {
        CFRetain((CVPixelBufferRef)handle);
    }
#endif
}

FFI_PLUGIN_EXPORT void Frame_decrementRefCount(FrameHandle handle) {
#ifdef ANDROID
    if (handle == NULL) return;
    NativeFrame* frame = (NativeFrame*)handle;
    
    // Safety check: only process and free if magic matches
    if (frame->magic != FRAME_MAGIC) {
        __android_log_print(ANDROID_LOG_WARN, "VisionCamera", "Attempted to release invalid handle %p!", handle);
        return;
    }

    if (g_javaVM != NULL && g_releaseFrameMethod != NULL) {
        JNIEnv* env;
        int status = (*g_javaVM)->GetEnv(g_javaVM, (void**)&env, JNI_VERSION_1_6);
        int attached = 0;
        if (status == JNI_EDETACHED) {
            status = (*g_javaVM)->AttachCurrentThread(g_javaVM, (void**)&env, NULL);
            attached = 1;
        }
        
        if (status == JNI_OK && env != NULL) {
            // Call Kotlin releaseFrame
            (*env)->CallStaticIntMethod(env, g_pluginClass, g_releaseFrameMethod, (jlong)frame->id);
            
            if (attached) (*g_javaVM)->DetachCurrentThread(g_javaVM);
        } else {
            __android_log_print(ANDROID_LOG_ERROR, "VisionCamera", "Failed to get JNIEnv to release frame %lld", (long long)frame->id);
        }
    } else {
        __android_log_print(ANDROID_LOG_ERROR, "VisionCamera", "JNI not initialized, leaking frame %lld", (long long)frame->id);
    }
    
    // Mark as invalid BEFORE freeing to catch double-frees
    frame->magic = 0;
    free(frame);
#else
    if (handle != NULL) {
        CVPixelBufferRef pixelBuffer = (CVPixelBufferRef)handle;
        CVPixelBufferUnlockBaseAddress(pixelBuffer, kCVPixelBufferLock_ReadOnly);
        CFRelease(pixelBuffer);
    }
#endif
}

static FrameProcessorCallback g_frameProcessorCallback = NULL;

FFI_PLUGIN_EXPORT void VisionCamera_setFrameProcessorCallback(FrameProcessorCallback callback) {
    g_frameProcessorCallback = callback;
}

FFI_PLUGIN_EXPORT void VisionCamera_dispatchFrame(FrameHandle handle, FrameMetadata metadata) {
    // 1. Notify C/C++ Plugins first (Zero latency, synchronous)
    for (int i = 0; i < g_pluginCount; i++) {
        g_plugins[i].onFrame(handle, metadata);
    }

    // 2. Notify Dart (FFI Isolate dispatch)
    if (g_frameProcessorCallback != NULL) {
        // Dart will be responsible for calling Frame_decrementRefCount
        g_frameProcessorCallback(handle, metadata);
    } else {
        // No Dart listener, release the reference taken by the native side
        Frame_decrementRefCount(handle);
    }
}

// ─── Image Processing Helpers ────────────────────────────────────────

FFI_PLUGIN_EXPORT double VisionCamera_computeLuminance(const uint8_t* yPlane, int32_t width, int32_t height, int32_t startX, int32_t startY, int32_t endX, int32_t endY) {
    if (yPlane == NULL) return 0.0;
    
    if (startX < 0) startX = 0;
    if (startY < 0) startY = 0;
    if (endX >= width) endX = width - 1;
    if (endY >= height) endY = height - 1;
    
    if (startX > endX || startY > endY) return 0.0;
    
    uint64_t sum = 0;
    int32_t count = 0;
    
    for (int y = startY; y <= endY; y++) {
        for (int x = startX; x <= endX; x++) {
            sum += yPlane[y * width + x];
            count++;
        }
    }
    
    if (count == 0) return 0.0;
    return (double)sum / (double)count;
}

#ifdef ANDROID
JNIEXPORT void JNICALL
Java_dev_jentejan_flutter_1native_1vision_1camera_FlutterNativeVisionCameraPlugin_nativeDispatchFrame(
    JNIEnv* env, jobject thiz, jobject buffer, jint width, jint height, jint format, jint orientation, jdouble timestamp, jlong id, jlong address) {
    
    NativeFrame* frame = (NativeFrame*)malloc(sizeof(NativeFrame));
    frame->magic = FRAME_MAGIC;
    frame->id = (uint64_t)id;
    
    // If address wasn't passed or is 0, try to get it from the direct buffer
    if (address == 0 && buffer != NULL) {
        frame->address = (*env)->GetDirectBufferAddress(env, buffer);
    } else {
        frame->address = (void*)address;
    }

    FrameMetadata metadata = {
        .width = width,
        .height = height,
        .pixelFormat = format,
        .orientation = orientation,
        .timestamp = timestamp
    };

    VisionCamera_dispatchFrame((FrameHandle)frame, metadata);
}

JNIEXPORT void JNICALL
Java_dev_jentejan_flutter_1native_1vision_1camera_FlutterNativeVisionCameraPlugin_nativeSetFrameProcessorCallback(
    JNIEnv* env, jobject thiz, jlong callback) {
    VisionCamera_setFrameProcessorCallback((FrameProcessorCallback)callback);
}
#endif

FFI_PLUGIN_EXPORT int sum(int a, int b) { return a + b; }
