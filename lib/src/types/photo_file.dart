import 'package:flutter/foundation.dart';

import 'orientation.dart';

/// Represents a photo captured by the camera and written to the filesystem.
///
/// Maps to `PhotoFile` from react-native-vision-camera.
@immutable
class PhotoFile {
  /// The local file path of the captured photo.
  final String path;

  /// The width of the photo in pixels.
  final int width;

  /// The height of the photo in pixels.
  final int height;

  /// Whether this photo is in RAW format.
  final bool isRawPhoto;

  /// Display orientation of the photo relative to the sensor.
  final Orientation orientation;

  /// Whether this photo is mirrored (e.g. selfie camera).
  final bool isMirrored;

  /// Creates a [PhotoFile] with all required fields.
  const PhotoFile({
    required this.path,
    required this.width,
    required this.height,
    required this.isRawPhoto,
    required this.orientation,
    required this.isMirrored,
  });

  /// Deserializes a [PhotoFile] from a platform map.
  factory PhotoFile.fromMap(Map<String, dynamic> map) {
    return PhotoFile(
      path: map['path'] as String,
      width: map['width'] as int,
      height: map['height'] as int,
      isRawPhoto: map['isRawPhoto'] as bool? ?? false,
      orientation: Orientation.fromString(map['orientation'] as String),
      isMirrored: map['isMirrored'] as bool? ?? false,
    );
  }

  /// Serializes this photo to a map.
  Map<String, dynamic> toMap() {
    return {
      'path': path,
      'width': width,
      'height': height,
      'isRawPhoto': isRawPhoto,
      'orientation': orientation.value,
      'isMirrored': isMirrored,
    };
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is PhotoFile &&
          other.path == path &&
          other.width == width &&
          other.height == height &&
          other.isRawPhoto == isRawPhoto &&
          other.orientation == orientation &&
          other.isMirrored == isMirrored;

  @override
  int get hashCode =>
      Object.hash(path, width, height, isRawPhoto, orientation, isMirrored);

  @override
  String toString() => 'PhotoFile(${width}x$height, path: $path)';
}
