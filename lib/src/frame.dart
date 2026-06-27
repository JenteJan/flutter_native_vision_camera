import 'dart:ffi';
import 'dart:typed_data';

import 'types/orientation.dart';
import 'types/pixel_format.dart';

/// The native metadata struct for a frame.
final class FrameMetadataNative extends Struct {
  @Int32()
  external int width;

  @Int32()
  external int height;

  @Int32()
  external int pixelFormat;

  @Int32()
  external int orientation;

  @Double()
  external double timestamp;
}

/// A single frame from the camera.
///
/// This class is backed by a native memory pointer (zero-copy).
/// It allows high-performance access to the raw image data on a background Isolate.
///
/// Maps to `Frame` from react-native-vision-camera.
class Frame {
  /// The native pointer to the platform-specific frame handle.
  /// (e.g., `AHardwareBuffer*` on Android, `CVPixelBufferRef` on iOS).
  final Pointer<Void> _pointer;

  /// The width of the frame in pixels.
  final int width;

  /// The height of the frame in pixels.
  final int height;

  /// The pixel format of the frame.
  final PixelFormat pixelFormat;

  /// The orientation of the frame relative to the sensor.
  final Orientation orientation;

  /// The timestamp of the frame in seconds since epoch or boot.
  final double timestamp;

  /// Creates a [Frame] from a native pointer.
  ///
  /// This is usually called by the generated FFI bindings.
  Frame(
    this._pointer, {
    required this.width,
    required this.height,
    required this.pixelFormat,
    required this.orientation,
    required this.timestamp,
  });

  /// The number of bytes in each row of the frame's image data.
  int get bytesPerRow => _getBytesPerRow(_pointer);

  /// The number of planes in the frame (e.g., 3 for YUV, 1 for RGB).
  int get planesCount => _getPlanesCount(_pointer);

  /// Returns a [Uint8List] view of the frame's data for the given [planeIndex].
  ///
  /// This is a **direct view** of the native memory. Modifying it will
  /// modify the original frame buffer if supported by the platform.
  Uint8List getPlaneData(int planeIndex) {
    final nativeMetadata = Struct.create<FrameMetadataNative>();
    nativeMetadata.width = width;
    nativeMetadata.height = height;
    nativeMetadata.pixelFormat = pixelFormat.index;
    nativeMetadata.orientation = orientation.index;
    nativeMetadata.timestamp = timestamp;

    final dataPointer = _getPlanePointer(_pointer, planeIndex);
    final dataSize = _getPlaneSize(_pointer, nativeMetadata, planeIndex);
    return dataPointer.cast<Uint8>().asTypedList(dataSize);
  }

  /// Increments the reference count of the native frame.
  ///
  /// Frames are typically managed by a `NativeFinalizer`, but if you
  /// want to keep a frame beyond the scope of a frame processor,
  /// you must increment the ref-count.
  void incrementRefCount() => _incrementRefCount(_pointer);

  /// Decrements the reference count.
  ///
  /// If the count hits zero, the native frame is freed.
  void decrementRefCount() => _decrementRefCount(_pointer);

  /// Computes the average luminance of a specific region in the frame.
  /// (startX, startY, endX, endY) are pixel coordinates.
  double computeLuminance(int startX, int startY, int endX, int endY) {
    if (pixelFormat != PixelFormat.yuv) return 0.0;
    // Use the native function directly on the Y plane pointer. The Y plane's
    // row stride (which may exceed [width] due to hardware padding) is passed
    // so indexing stays correct.
    return _computeLuminance(
      _getPlanePointer(_pointer, 0).cast<Uint8>(),
      width,
      height,
      bytesPerRow,
      startX,
      startY,
      endX,
      endY,
    );
  }

  @override
  String toString() =>
      'Frame(${width}x$height, ${pixelFormat.value}, orientation: ${orientation.value})';
}

// These are FFI binding placeholders that will be implemented in the C layer.
// They bridge the Kotlin/Swift objects to Dart.

typedef _GetBytesPerRowFunc = Int32 Function(Pointer<Void>);
typedef _GetBytesPerRow = int Function(Pointer<Void>);
late _GetBytesPerRow _getBytesPerRow;

typedef _GetPlanesCountFunc = Int32 Function(Pointer<Void>);
typedef _GetPlanesCount = int Function(Pointer<Void>);
late _GetPlanesCount _getPlanesCount;

typedef _GetPlanePointerFunc = Pointer<Void> Function(Pointer<Void>, Int32);
typedef _GetPlanePointer = Pointer<Void> Function(Pointer<Void>, int);
late _GetPlanePointer _getPlanePointer;

typedef _GetPlaneSizeFunc =
    Int32 Function(Pointer<Void>, FrameMetadataNative, Int32);
typedef _GetPlaneSize = int Function(Pointer<Void>, FrameMetadataNative, int);
late _GetPlaneSize _getPlaneSize;

typedef _IncrementRefCountFunc = Void Function(Pointer<Void>);
typedef _IncrementRefCount = void Function(Pointer<Void>);
late _IncrementRefCount _incrementRefCount;

typedef _DecrementRefCountFunc = Void Function(Pointer<Void>);
typedef _DecrementRefCount = void Function(Pointer<Void>);
late _DecrementRefCount _decrementRefCount;

typedef NativeFrameProcessorCallbackFunc =
    Void Function(Pointer<Void> handle, FrameMetadataNative metadata);

typedef _SetFrameProcessorCallbackFunc =
    Void Function(
      Pointer<NativeFunction<NativeFrameProcessorCallbackFunc>> callback,
    );
typedef _SetFrameProcessorCallback =
    void Function(
      Pointer<NativeFunction<NativeFrameProcessorCallbackFunc>> callback,
    );
late _SetFrameProcessorCallback _setFrameProcessorCallback;

bool _isFrameBindingsInitialized = false;

void initializeFrameBindings(DynamicLibrary dylib) {
  if (_isFrameBindingsInitialized) return;

  try {
    _getBytesPerRow = dylib
        .lookup<NativeFunction<_GetBytesPerRowFunc>>('Frame_getBytesPerRow')
        .asFunction();
    _getPlanesCount = dylib
        .lookup<NativeFunction<_GetPlanesCountFunc>>('Frame_getPlanesCount')
        .asFunction();
    _getPlanePointer = dylib
        .lookup<NativeFunction<_GetPlanePointerFunc>>('Frame_getPlanePointer')
        .asFunction();
    _getPlaneSize = dylib
        .lookup<NativeFunction<_GetPlaneSizeFunc>>('Frame_getPlaneSize')
        .asFunction();
    _incrementRefCount = dylib
        .lookup<NativeFunction<_IncrementRefCountFunc>>(
          'Frame_incrementRefCount',
        )
        .asFunction();
    _decrementRefCount = dylib
        .lookup<NativeFunction<_DecrementRefCountFunc>>(
          'Frame_decrementRefCount',
        )
        .asFunction();
    _setFrameProcessorCallback = dylib
        .lookup<NativeFunction<_SetFrameProcessorCallbackFunc>>(
          'VisionCamera_setFrameProcessorCallback',
        )
        .asFunction();

    _computeLuminance = dylib
        .lookup<NativeFunction<_ComputeLuminanceFunc>>(
          'VisionCamera_computeLuminance',
        )
        .asFunction();

    _isFrameBindingsInitialized = true;
  } catch (e) {
    rethrow;
  }
}

void setNativeFrameProcessorCallback(
  Pointer<NativeFunction<NativeFrameProcessorCallbackFunc>> callback,
) {
  if (!_isFrameBindingsInitialized) {
    throw StateError(
      'Vision Camera FFI not initialized. Call initializeVisionCamera() first.',
    );
  }
  _setFrameProcessorCallback(callback);
}

typedef _ComputeLuminanceFunc =
    Double Function(
      Pointer<Uint8> yPlane,
      Int32 width,
      Int32 height,
      Int32 rowStride,
      Int32 startX,
      Int32 startY,
      Int32 endX,
      Int32 endY,
    );
typedef _ComputeLuminance =
    double Function(Pointer<Uint8>, int, int, int, int, int, int, int);
late _ComputeLuminance _computeLuminance;
