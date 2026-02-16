/// Represents orientation relative to the device or sensor.
///
/// - [portrait]: 0° (home-button at the bottom)
/// - [landscapeLeft]: 90° (home-button on the left)
/// - [portraitUpsideDown]: 180° (home-button at the top)
/// - [landscapeRight]: 270° (home-button on the right)
///
/// Maps to `Orientation` from react-native-vision-camera.
enum Orientation {
  /// 0° — upright portrait.
  portrait('portrait', 0),

  /// 90° — rotated with home-button on the left.
  landscapeLeft('landscape-left', 90),

  /// 180° — upside-down portrait.
  portraitUpsideDown('portrait-upside-down', 180),

  /// 270° — rotated with home-button on the right.
  landscapeRight('landscape-right', 270);

  const Orientation(this.value, this.degrees);

  /// The kebab-case string used by the native platform.
  final String value;

  /// The clockwise rotation in degrees from the natural portrait orientation.
  final int degrees;

  /// Deserializes an [Orientation] from a platform string.
  ///
  /// Throws [ArgumentError] if [value] is not a recognized orientation.
  static Orientation fromString(String value) {
    return Orientation.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown Orientation: $value'),
    );
  }
}
