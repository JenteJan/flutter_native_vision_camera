/// Represents the pixel format of a camera frame.
///
/// Most ML models operate in either [yuv] (recommended) or [rgb].
///
/// Maps to `PixelFormat` from react-native-vision-camera.
enum PixelFormat {
  /// YUV pixel format (Y'CbCr 4:2:0 or NV21, 8-bit). Most efficient.
  yuv('yuv'),

  /// RGB pixel format (RGBA or BGRA, 8-bit). Required by some ML models.
  rgb('rgb'),

  /// Unknown or unsupported pixel format.
  unknown('unknown');

  const PixelFormat(this.value);

  /// The string value used by the native platform.
  final String value;

  /// Deserializes a [PixelFormat] from a platform string.
  static PixelFormat fromString(String value) {
    return PixelFormat.values.firstWhere(
      (e) => e.value == value,
      orElse: () => PixelFormat.unknown,
    );
  }
}
