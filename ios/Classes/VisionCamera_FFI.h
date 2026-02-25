#ifndef VisionCamera_FFI_h
#define VisionCamera_FFI_h

#import <Flutter/Flutter.h>

#ifdef __cplusplus
extern "C"
{
#endif

    // Redefining types to avoid relative include issues in frameworks
    typedef void *FrameHandle;

    typedef struct
    {
        int32_t width;
        int32_t height;
        int32_t pixelFormat; // 0 for YUV_420_888, 1 for BGRA
        int32_t orientation; // 0, 90, 180, 270
        double timestamp;    // Presentation timestamp in seconds
    } FrameMetadata;

    void VisionCamera_dispatchFrame(FrameHandle handle, FrameMetadata metadata);

#ifdef __cplusplus
}
#endif

#endif /* VisionCamera_FFI_h */
