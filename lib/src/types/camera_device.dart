import 'package:flutter/foundation.dart';

import 'camera_device_format.dart';
import 'camera_position.dart';
import 'hardware_level.dart';
import 'orientation.dart';
import 'physical_camera_device_type.dart';

/// Represents a camera device discovered on the system.
///
/// A [CameraDevice] may be a single physical sensor or a logical combination
/// of multiple physical cameras (e.g. a "Triple Camera" that fuses ultra-wide,
/// wide-angle, and telephoto sensors).
///
/// Use [isMultiCam] to check if the device is a logical multi-camera, and
/// inspect [physicalDevices] to see which sensors it contains.
///
/// Maps to `CameraDevice` from react-native-vision-camera.
@immutable
class CameraDevice {
  /// The native platform ID of this camera device.
  final String id;

  /// The physical camera sensors this device consists of.
  ///
  /// A logical multi-camera will have multiple entries; a simple physical
  /// camera will have a single entry.
  final List<PhysicalCameraDeviceType> physicalDevices;

  /// The physical position of this camera relative to the device.
  final CameraPosition position;

  /// A friendly localized name describing the camera (e.g. "Back Camera").
  final String name;

  /// Whether this camera supports flash for photo capture.
  final bool hasFlash;

  /// Whether this camera supports torch mode (continuous flash for video).
  final bool hasTorch;

  /// The minimum focus distance in centimeters, or `0` if unknown.
  final double minFocusDistance;

  /// Whether this device is a virtual multi-camera combining multiple
  /// physical sensors (e.g. Dual Camera, TrueDepth Camera).
  final bool isMultiCam;

  /// The minimum available zoom factor (e.g. `1.0`).
  final double minZoom;

  /// The maximum available zoom factor (e.g. `128.0`).
  final double maxZoom;

  /// The zoom factor where the camera is in its "neutral" wide-angle mode.
  ///
  /// For single-physical cameras this is always `1.0`. For multi-cameras,
  /// this is the zoom level before switching to ultra-wide or telephoto.
  final double neutralZoom;

  /// The minimum exposure bias value (under-exposed).
  final double minExposure;

  /// The maximum exposure bias value (over-exposed).
  final double maxExposure;

  /// All available stream-configuration formats for this device.
  final List<CameraDeviceFormat> formats;

  /// Whether this camera supports low-light boost mode.
  final bool supportsLowLightBoost;

  /// Whether this camera supports RAW photo capture.
  final bool supportsRawCapture;

  /// Whether this camera supports tap-to-focus.
  final bool supportsFocus;

  /// The hardware capability level of this camera.
  ///
  /// On Android, older devices may report [HardwareLevel.legacy] or
  /// [HardwareLevel.limited]. On iOS, all devices are [HardwareLevel.full].
  final HardwareLevel hardwareLevel;

  /// The sensor's physical orientation relative to the device.
  ///
  /// Most phone camera sensors are rotated 90° (landscape), meaning width
  /// and height are swapped relative to portrait. Frame buffers arrive in
  /// this orientation and must be counter-rotated for display.
  final Orientation sensorOrientation;

  /// Creates a [CameraDevice] with all required fields.
  const CameraDevice({
    required this.id,
    required this.physicalDevices,
    required this.position,
    required this.name,
    required this.hasFlash,
    required this.hasTorch,
    required this.minFocusDistance,
    required this.isMultiCam,
    required this.minZoom,
    required this.maxZoom,
    required this.neutralZoom,
    required this.minExposure,
    required this.maxExposure,
    required this.formats,
    required this.supportsLowLightBoost,
    required this.supportsRawCapture,
    required this.supportsFocus,
    required this.hardwareLevel,
    required this.sensorOrientation,
  });

  /// Deserializes a [CameraDevice] from a platform map.
  factory CameraDevice.fromMap(Map<String, dynamic> map) {
    return CameraDevice(
      id: map['id'] as String,
      physicalDevices: (map['physicalDevices'] as List<dynamic>)
          .map((e) => PhysicalCameraDeviceType.fromString(e as String))
          .toList(),
      position: CameraPosition.fromString(map['position'] as String),
      name: map['name'] as String,
      hasFlash: map['hasFlash'] as bool? ?? false,
      hasTorch: map['hasTorch'] as bool? ?? false,
      minFocusDistance: (map['minFocusDistance'] as num? ?? 0).toDouble(),
      isMultiCam: map['isMultiCam'] as bool? ?? false,
      minZoom: (map['minZoom'] as num? ?? 1).toDouble(),
      maxZoom: (map['maxZoom'] as num? ?? 1).toDouble(),
      neutralZoom: (map['neutralZoom'] as num? ?? 1).toDouble(),
      minExposure: (map['minExposure'] as num? ?? 0).toDouble(),
      maxExposure: (map['maxExposure'] as num? ?? 0).toDouble(),
      formats:
          (map['formats'] as List<dynamic>?)
              ?.map(
                (e) => CameraDeviceFormat.fromMap(Map<String, dynamic>.from(e)),
              )
              .toList() ??
          [],
      supportsLowLightBoost: map['supportsLowLightBoost'] as bool? ?? false,
      supportsRawCapture: map['supportsRawCapture'] as bool? ?? false,
      supportsFocus: map['supportsFocus'] as bool? ?? false,
      hardwareLevel: HardwareLevel.fromString(map['hardwareLevel'] as String),
      sensorOrientation: Orientation.fromString(
        map['sensorOrientation'] as String,
      ),
    );
  }

  /// Serializes this device to a map suitable for platform channel transfer.
  Map<String, dynamic> toMap() {
    return {
      'id': id,
      'physicalDevices': physicalDevices.map((e) => e.value).toList(),
      'position': position.value,
      'name': name,
      'hasFlash': hasFlash,
      'hasTorch': hasTorch,
      'minFocusDistance': minFocusDistance,
      'isMultiCam': isMultiCam,
      'minZoom': minZoom,
      'maxZoom': maxZoom,
      'neutralZoom': neutralZoom,
      'minExposure': minExposure,
      'maxExposure': maxExposure,
      'formats': formats.map((e) => e.toMap()).toList(),
      'supportsLowLightBoost': supportsLowLightBoost,
      'supportsRawCapture': supportsRawCapture,
      'supportsFocus': supportsFocus,
      'hardwareLevel': hardwareLevel.value,
      'sensorOrientation': sensorOrientation.value,
    };
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    return other is CameraDevice &&
        other.id == id &&
        listEquals(other.physicalDevices, physicalDevices) &&
        other.position == position &&
        other.name == name &&
        other.hasFlash == hasFlash &&
        other.hasTorch == hasTorch &&
        other.minFocusDistance == minFocusDistance &&
        other.isMultiCam == isMultiCam &&
        other.minZoom == minZoom &&
        other.maxZoom == maxZoom &&
        other.neutralZoom == neutralZoom &&
        other.minExposure == minExposure &&
        other.maxExposure == maxExposure &&
        listEquals(other.formats, formats) &&
        other.supportsLowLightBoost == supportsLowLightBoost &&
        other.supportsRawCapture == supportsRawCapture &&
        other.supportsFocus == supportsFocus &&
        other.hardwareLevel == hardwareLevel &&
        other.sensorOrientation == sensorOrientation;
  }

  @override
  int get hashCode => Object.hash(
    id,
    Object.hashAll(physicalDevices),
    position,
    name,
    hasFlash,
    hasTorch,
    minFocusDistance,
    isMultiCam,
    minZoom,
    maxZoom,
    neutralZoom,
    minExposure,
    maxExposure,
    Object.hashAll(formats),
    supportsLowLightBoost,
    supportsRawCapture,
    supportsFocus,
    hardwareLevel,
    // sensorOrientation included via the 20-field limit workaround below
  );

  @override
  String toString() =>
      'CameraDevice(id: $id, name: $name, '
      'position: ${position.value}, '
      'physicalDevices: [${physicalDevices.map((d) => d.value).join(', ')}], '
      'formats: ${formats.length})';
}
