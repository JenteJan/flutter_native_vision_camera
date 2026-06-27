#ifndef FlutterNativeVisionCameraPlugin_h
#define FlutterNativeVisionCameraPlugin_h

// Forward everything to the Swift-implemented functionality by using a module import.
// This is required because Flutter's GeneratedPluginRegistrant.m still expects to
// find the header, but defining the interface here would collide with the
// automatic Swift-to-ObjC bridging header.
#import <Flutter/Flutter.h>
#import "VisionCamera_FFI.h"

// Objective-C interface that the Flutter registrant expects.
@interface FlutterNativeVisionCameraPlugin : NSObject <FlutterPlugin>
@end

#endif /* FlutterNativeVisionCameraPlugin_h */
