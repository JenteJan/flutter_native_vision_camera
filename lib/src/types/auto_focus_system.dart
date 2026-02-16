/// Indicates a camera format's autofocus system.
///
/// Maps to `AutoFocusSystem` from react-native-vision-camera.
enum AutoFocusSystem {
  /// Autofocus via contrast detection (performs a focus scan).
  contrastDetection('contrast-detection'),

  /// Autofocus via phase detection (faster, less visually intrusive).
  phaseDetection('phase-detection'),

  /// Autofocus is not available.
  none('none');

  const AutoFocusSystem(this.value);

  /// The kebab-case string used by the native platform.
  final String value;

  /// Deserializes an [AutoFocusSystem] from a platform string.
  ///
  /// Throws [ArgumentError] if [value] is not a recognized system.
  static AutoFocusSystem fromString(String value) {
    return AutoFocusSystem.values.firstWhere(
      (e) => e.value == value,
      orElse: () => throw ArgumentError('Unknown AutoFocusSystem: $value'),
    );
  }
}
