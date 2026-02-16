/// Identifiers for a physical camera sensor on the device.
///
/// Logical camera devices may combine multiple physical cameras:
/// - `ultraWideAngleCamera` + `wideAngleCamera` = **dual wide-angle camera**
/// - `wideAngleCamera` + `telephotoCamera` = **dual camera**
/// - All three = **triple camera**
///
/// Maps to `PhysicalCameraDeviceType` from react-native-vision-camera.
enum PhysicalCameraDeviceType {
  /// A built-in camera with a shorter focal length (FOV ≥ 94°).
  ultraWideAngleCamera('ultra-wide-angle-camera'),

  /// A built-in wide-angle camera (FOV between 60°–94°).
  wideAngleCamera('wide-angle-camera'),

  /// A built-in camera with a longer focal length (FOV ≤ 60°).
  telephotoCamera('telephoto-camera');

  const PhysicalCameraDeviceType(this.value);

  /// The kebab-case string used by the native platform.
  final String value;

  /// Deserializes a [PhysicalCameraDeviceType] from a platform string.
  ///
  /// Throws [ArgumentError] if [value] is not a recognized type.
  static PhysicalCameraDeviceType fromString(String value) {
    return PhysicalCameraDeviceType.values.firstWhere(
      (e) => e.value == value,
      orElse: () =>
          throw ArgumentError('Unknown PhysicalCameraDeviceType: $value'),
    );
  }
}
