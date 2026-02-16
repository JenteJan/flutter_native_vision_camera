import 'package:flutter/foundation.dart';

/// Represents a video recorded by the camera and written to the filesystem.
///
/// Maps to `VideoFile` from react-native-vision-camera.
@immutable
class VideoFile {
  /// The local file path of the recorded video.
  final String path;

  /// The duration of the video in seconds.
  final double duration;

  /// The width of the video in pixels.
  final int width;

  /// The height of the video in pixels.
  final int height;

  /// Creates a [VideoFile] with all required fields.
  const VideoFile({
    required this.path,
    required this.duration,
    required this.width,
    required this.height,
  });

  /// Deserializes a [VideoFile] from a platform map.
  factory VideoFile.fromMap(Map<String, dynamic> map) {
    return VideoFile(
      path: map['path'] as String,
      duration: (map['duration'] as num).toDouble(),
      width: map['width'] as int,
      height: map['height'] as int,
    );
  }

  /// Serializes this video to a map.
  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'duration': duration,
      'width': width,
      'height': height,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is VideoFile &&
          other.path == path &&
          other.duration == duration &&
          other.width == width &&
          other.height == height;

  @override
  int get hashCode => Object.hash(path, duration, width, height);

  @override
  String toString() =>
      'VideoFile(${width}x$height, ${duration.toStringAsFixed(1)}s, path: $path)';
}
