/// Represents the camera device position relative to the phone.
///
/// Maps to `CameraPosition` from react-native-vision-camera.
enum CameraPosition {
  /// The camera is on the back of the device (main camera).
  back('back'),

  /// The camera is on the front of the device (selfie camera).
  front('front'),

  /// The camera is external (USB, Continuity Camera, etc.).
  external_('external');

  const CameraPosition(this.value);

  /// The serialized string value used by the native platform.
  final String value;

  /// Deserializes a [CameraPosition] from a platform string.
  ///
  /// Throws [ArgumentError] if [value] is not a known position.
  static CameraPosition fromString(String value) {
    return CameraPosition.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown CameraPosition: $value'),
    );
  }
}
