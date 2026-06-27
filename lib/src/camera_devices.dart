import 'package:flutter/services.dart';

import 'types/types.dart';

/// The method channel used for device discovery.
const MethodChannel _channel = MethodChannel(
  'dev.jentejan.flutter_native_vision_camera/camera',
);

/// Provides static methods for camera device discovery.
///
/// This replicates the `CameraDevices` module from react-native-vision-camera,
/// allowing enumeration (and future hot-plug) of available camera devices.
class CameraDevices {
  CameraDevices._();

  /// Returns all available camera devices on this phone.
  ///
  /// This includes front, back, and external cameras.
  /// The result is ordered by "best" device first (back wide-angle first).
  static Future<List<CameraDevice>> getAvailableCameraDevices() async {
    final result = await _channel.invokeListMethod<Map<dynamic, dynamic>>(
      'getAvailableCameraDevices',
    );

    if (result == null) return [];

    return result.map((map) {
      return CameraDevice.fromMap(Map<String, dynamic>.from(map));
    }).toList();
  }

  /// Gets the best matching camera device for the given [position].
  ///
  /// Optionally pass [physicalDeviceTypes] to prefer specific lens types
  /// (e.g., ultra-wide-angle). If no filter is specified, returns the
  /// "best" device (widest lens / multi-camera).
  static CameraDevice? getCameraDevice(
    List<CameraDevice> devices,
    CameraPosition position, {
    List<PhysicalCameraDeviceType>? physicalDeviceTypes,
  }) {
    final matching = devices.where((d) => d.position == position);
    if (matching.isEmpty) return null;

    if (physicalDeviceTypes != null && physicalDeviceTypes.isNotEmpty) {
      // Prefer devices whose physical devices contain at least one of
      // the requested types.
      final filtered = matching.where((d) {
        return d.physicalDevices.any((pd) => physicalDeviceTypes.contains(pd));
      });
      if (filtered.isNotEmpty) return filtered.first;
    }

    // Default: prefer multi-camera, then fall back to first.
    final multiCam = matching.where((d) => d.isMultiCam);
    return multiCam.isNotEmpty ? multiCam.first : matching.first;
  }

  /// Picks the [CameraDeviceFormat] from [device] that best matches the desired
  /// video resolution ([targetWidth] x [targetHeight]) and supports [targetFps].
  ///
  /// Pass it to `CameraController.initialize(device, format: ...)`. With no
  /// targets it returns the highest-resolution format. Returns `null` if the
  /// device exposes no formats.
  static CameraDeviceFormat? getCameraFormat(
    CameraDevice device, {
    int? targetWidth,
    int? targetHeight,
    int? targetFps,
  }) {
    if (device.formats.isEmpty) return null;

    var candidates = device.formats;
    if (targetFps != null) {
      final supported = candidates
          .where((f) => f.minFps <= targetFps && targetFps <= f.maxFps)
          .toList();
      if (supported.isNotEmpty) candidates = supported;
    }

    if (targetWidth != null && targetHeight != null) {
      final targetArea = targetWidth * targetHeight;
      return ([...candidates]..sort((a, b) {
            final da = (a.videoWidth * a.videoHeight - targetArea).abs();
            final db = (b.videoWidth * b.videoHeight - targetArea).abs();
            return da.compareTo(db);
          }))
          .first;
    }

    return ([...candidates]..sort(
          (a, b) => (b.videoWidth * b.videoHeight).compareTo(
            a.videoWidth * a.videoHeight,
          ),
        ))
        .first;
  }
}
