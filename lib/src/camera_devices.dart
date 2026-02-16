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
}
