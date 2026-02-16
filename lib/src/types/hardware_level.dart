/// The hardware level of a camera device.
///
/// On Android, some older devices run at [legacy] or [limited] level,
/// meaning they operate in a backwards-compatible mode with reduced features.
/// On iOS, all devices are [full].
///
/// Maps to `CameraDevice.hardwareLevel` from react-native-vision-camera.
enum HardwareLevel {
  /// Backwards-compatible mode with the fewest features.
  legacy('legacy'),

  /// Limited feature set; more capable than [legacy].
  limited('limited'),

  /// Full hardware-level support.
  full('full');

  const HardwareLevel(this.value);

  /// The string value used by the native platform.
  final String value;

  /// Deserializes a [HardwareLevel] from a platform string.
  ///
  /// Throws [ArgumentError] if [value] is not a recognized level.
  static HardwareLevel fromString(String value) {
    return HardwareLevel.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown HardwareLevel: $value'),
    );
  }
}
