import 'package:flutter/foundation.dart';

/// GPS Coordinates for EXIF tagging.
@immutable
class Location {
  final double latitude;
  final double longitude;
  final double? altitude;
  final double? accuracy;

  const Location({
    required this.latitude,
    required this.longitude,
    this.altitude,
    this.accuracy,
  });

  Map<String, dynamic> toMap() {
    return {
      'latitude': latitude,
      'longitude': longitude,
      if (altitude != null) 'altitude': altitude,
      if (accuracy != null) 'accuracy': accuracy,
    };
  }
}

/// Options for taking a photo.
///
/// Maps to `TakePhotoOptions` from react-native-vision-camera.
@immutable
class TakePhotoOptions {
  /// Whether the flash should be enabled. Defaults to `'off'`.
  final FlashMode flash;

  /// Custom directory path to save the photo. VisionCamera generates the filename.
  final String? path;

  /// Whether to apply automatic red-eye reduction on flash captures (iOS only).
  final bool enableAutoRedEyeReduction;

  /// Whether to apply content-aware distortion correction (iOS only).
  final bool enableAutoDistortionCorrection;

  /// Whether to play the default shutter sound. Defaults to `true`.
  final bool enableShutterSound;

  /// Whether to enable HDR for this photo.
  final bool enableHdr;

  /// GPS location to be embedded in the photo's EXIF metadata.
  final Location? location;

  const TakePhotoOptions({
    this.flash = FlashMode.off,
    this.path,
    this.enableAutoRedEyeReduction = false,
    this.enableAutoDistortionCorrection = false,
    this.enableShutterSound = true,
    this.enableHdr = false,
    this.location,
  });

  Map<String, dynamic> toMap() {
    return {
      'flash': flash.value,
      if (path != null) 'path': path,
      'enableAutoRedEyeReduction': enableAutoRedEyeReduction,
      'enableAutoDistortionCorrection': enableAutoDistortionCorrection,
      'enableShutterSound': enableShutterSound,
      'enableHdr': enableHdr,
      if (location != null) 'location': location!.toMap(),
    };
  }
}

/// Flash mode for photo/video capture.
enum FlashMode {
  on('on'),
  off('off'),
  auto_('auto');

  const FlashMode(this.value);
  final String value;
}

/// Options for recording a video.
///
/// Maps to `RecordVideoOptions` from react-native-vision-camera.
@immutable
class RecordVideoOptions {
  /// Flash mode during recording. Natively enables the torch.
  final FlashMode flash;

  /// Output file type.
  final VideoFileType fileType;

  /// Custom directory path to save the video.
  final String? path;

  /// The video codec to use.
  final VideoCodec videoCodec;

  /// Whether to enable HDR for this video.
  final bool enableHdr;

  /// GPS location to be embedded in the video's metadata.
  final Location? location;

  const RecordVideoOptions({
    this.flash = FlashMode.off,
    this.fileType = VideoFileType.mp4,
    this.path,
    this.videoCodec = VideoCodec.h264,
    this.enableHdr = false,
    this.location,
  });

  Map<String, dynamic> toMap() {
    return {
      'flash': flash.value,
      'fileType': fileType.value,
      if (path != null) 'path': path,
      'videoCodec': videoCodec.value,
      'enableHdr': enableHdr,
      if (location != null) 'location': location!.toMap(),
    };
  }
}

/// Video file container format.
enum VideoFileType {
  mov('mov'),
  mp4('mp4');

  const VideoFileType(this.value);
  final String value;
}

/// Video codec for recording.
enum VideoCodec {
  /// Widely supported, less efficient with large sizes.
  h264('h264'),

  /// HEVC — up to 50% smaller file sizes.
  h265('h265');

  const VideoCodec(this.value);
  final String value;
}

/// Options for taking a snapshot (GPU screenshot of the preview).
///
/// Maps to `TakeSnapshotOptions` from react-native-vision-camera.
@immutable
class TakeSnapshotOptions {
  /// JPEG quality (0–100). Defaults to 100.
  final int quality;

  /// Custom directory path to save the snapshot.
  final String? path;

  const TakeSnapshotOptions({this.quality = 100, this.path});

  Map<String, dynamic> toMap() {
    return {'quality': quality, if (path != null) 'path': path};
  }
}
