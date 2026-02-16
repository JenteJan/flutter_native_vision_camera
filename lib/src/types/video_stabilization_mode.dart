/// Indicates a format's supported video stabilization mode.
///
/// Enabling video stabilization may introduce additional latency into
/// the video capture pipeline.
///
/// Maps to `VideoStabilizationMode` from react-native-vision-camera.
enum VideoStabilizationMode {
  /// No video stabilization.
  off('off'),

  /// Standard software-based stabilization (~10% FOV reduction).
  standard('standard'),

  /// Advanced software-based cinematic stabilization.
  cinematic('cinematic'),

  /// Extended hardware+software cinematic stabilization with aggressive cropping.
  cinematicExtended('cinematic-extended'),

  /// Automatically select the most appropriate stabilization mode.
  auto_('auto');

  const VideoStabilizationMode(this.value);

  /// The kebab-case string used by the native platform.
  final String value;

  /// Deserializes a [VideoStabilizationMode] from a platform string.
  ///
  /// Throws [ArgumentError] if [value] is not a recognized mode.
  static VideoStabilizationMode fromString(String value) {
    return VideoStabilizationMode.values.firstWhere(
      (e) => e.value == value,
      orElse: () =>
          throw ArgumentError('Unknown VideoStabilizationMode: $value'),
    );
  }
}
