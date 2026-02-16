import 'package:flutter/foundation.dart';

import 'auto_focus_system.dart';
import 'video_stabilization_mode.dart';

/// A camera device's stream-configuration format.
///
/// A format specifies video/photo resolution, FPS ranges, HDR support,
/// depth capture capability, autofocus system, and stabilization modes.
///
/// Maps to `CameraDeviceFormat` from react-native-vision-camera.
@immutable
class CameraDeviceFormat {
  /// The maximum photo height in pixels.
  final int photoHeight;

  /// The maximum photo width in pixels.
  final int photoWidth;

  /// The video resolution height in pixels.
  final int videoHeight;

  /// The video resolution width in pixels.
  final int videoWidth;

  /// Maximum supported ISO value.
  final double maxISO;

  /// Minimum supported ISO value.
  final double minISO;

  /// The video field of view in degrees.
  final double fieldOfView;

  /// Whether this format supports HDR mode for video capture.
  final bool supportsVideoHdr;

  /// Whether this format supports HDR mode for photo capture.
  final bool supportsPhotoHdr;

  /// Whether this format supports depth data capture.
  final bool supportsDepthCapture;

  /// The minimum frame rate this format requires.
  final double minFps;

  /// The maximum frame rate this format supports.
  final double maxFps;

  /// The autofocus system used by this format.
  final AutoFocusSystem autoFocusSystem;

  /// All supported video stabilization modes for this format.
  final List<VideoStabilizationMode> videoStabilizationModes;

  /// Creates a [CameraDeviceFormat] with all required fields.
  const CameraDeviceFormat({
    required this.photoHeight,
    required this.photoWidth,
    required this.videoHeight,
    required this.videoWidth,
    required this.maxISO,
    required this.minISO,
    required this.fieldOfView,
    required this.supportsVideoHdr,
    required this.supportsPhotoHdr,
    required this.supportsDepthCapture,
    required this.minFps,
    required this.maxFps,
    required this.autoFocusSystem,
    required this.videoStabilizationModes,
  });

  /// Deserializes a [CameraDeviceFormat] from a platform map.
  factory CameraDeviceFormat.fromMap(Map<String, dynamic> map) {
    return CameraDeviceFormat(
      photoHeight: map['photoHeight'] as int,
      photoWidth: map['photoWidth'] as int,
      videoHeight: map['videoHeight'] as int,
      videoWidth: map['videoWidth'] as int,
      maxISO: (map['maxISO'] as num).toDouble(),
      minISO: (map['minISO'] as num).toDouble(),
      fieldOfView: (map['fieldOfView'] as num).toDouble(),
      supportsVideoHdr: map['supportsVideoHdr'] as bool,
      supportsPhotoHdr: map['supportsPhotoHdr'] as bool,
      supportsDepthCapture: map['supportsDepthCapture'] as bool,
      minFps: (map['minFps'] as num).toDouble(),
      maxFps: (map['maxFps'] as num).toDouble(),
      autoFocusSystem: AutoFocusSystem.fromString(
        map['autoFocusSystem'] as String,
      ),
      videoStabilizationModes: (map['videoStabilizationModes'] as List<dynamic>)
          .map((e) => VideoStabilizationMode.fromString(e as String))
          .toList(),
    );
  }

  /// Serializes this format to a map suitable for platform channel transfer.
  Map<String, dynamic> toMap() {
    return {
      'photoHeight': photoHeight,
      'photoWidth': photoWidth,
      'videoHeight': videoHeight,
      'videoWidth': videoWidth,
      'maxISO': maxISO,
      'minISO': minISO,
      'fieldOfView': fieldOfView,
      'supportsVideoHdr': supportsVideoHdr,
      'supportsPhotoHdr': supportsPhotoHdr,
      'supportsDepthCapture': supportsDepthCapture,
      'minFps': minFps,
      'maxFps': maxFps,
      'autoFocusSystem': autoFocusSystem.value,
      'videoStabilizationModes': videoStabilizationModes
          .map((e) => e.value)
          .toList(),
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CameraDeviceFormat &&
        other.photoHeight == photoHeight &&
        other.photoWidth == photoWidth &&
        other.videoHeight == videoHeight &&
        other.videoWidth == videoWidth &&
        other.maxISO == maxISO &&
        other.minISO == minISO &&
        other.fieldOfView == fieldOfView &&
        other.supportsVideoHdr == supportsVideoHdr &&
        other.supportsPhotoHdr == supportsPhotoHdr &&
        other.supportsDepthCapture == supportsDepthCapture &&
        other.minFps == minFps &&
        other.maxFps == maxFps &&
        other.autoFocusSystem == autoFocusSystem &&
        listEquals(other.videoStabilizationModes, videoStabilizationModes);
  }

  @override
  int get hashCode => Object.hash(
    photoHeight,
    photoWidth,
    videoHeight,
    videoWidth,
    maxISO,
    minISO,
    fieldOfView,
    supportsVideoHdr,
    supportsPhotoHdr,
    supportsDepthCapture,
    minFps,
    maxFps,
    autoFocusSystem,
    Object.hashAll(videoStabilizationModes),
  );

  @override
  String toString() =>
      'CameraDeviceFormat(${videoWidth}x$videoHeight @ $minFps-${maxFps}fps)';
}
