import 'package:flutter/services.dart';

/// The method channel used for permission requests.
const MethodChannel _channel = MethodChannel(
  'dev.jentejan.flutter_native_vision_camera/camera',
);

/// Permission status for camera or microphone.
enum PermissionStatus {
  /// The user has not yet been asked for permission.
  notDetermined('not-determined'),

  /// The user has denied permission.
  denied('denied'),

  /// The permission has been restricted by the system (e.g. parental controls).
  restricted('restricted'),

  /// The user has granted permission.
  granted('granted');

  const PermissionStatus(this.value);
  final String value;

  static PermissionStatus fromString(String value) {
    return PermissionStatus.values.firstWhere(
      (e) => e.value == value,
      orElse: () => PermissionStatus.denied,
    );
  }
}

/// Provides methods for querying and requesting camera/microphone permissions.
class CameraPermissions {
  CameraPermissions._();

  /// Returns the current camera permission status.
  static Future<PermissionStatus> getCameraPermissionStatus() async {
    final result = await _channel.invokeMethod<String>(
      'getCameraPermissionStatus',
    );
    return PermissionStatus.fromString(result ?? 'denied');
  }

  /// Requests camera permission and returns the new status.
  static Future<PermissionStatus> requestCameraPermission() async {
    final result = await _channel.invokeMethod<String>(
      'requestCameraPermission',
    );
    return PermissionStatus.fromString(result ?? 'denied');
  }

  /// Returns the current microphone permission status.
  static Future<PermissionStatus> getMicrophonePermissionStatus() async {
    final result = await _channel.invokeMethod<String>(
      'getMicrophonePermissionStatus',
    );
    return PermissionStatus.fromString(result ?? 'denied');
  }

  /// Requests microphone permission and returns the new status.
  static Future<PermissionStatus> requestMicrophonePermission() async {
    final result = await _channel.invokeMethod<String>(
      'requestMicrophonePermission',
    );
    return PermissionStatus.fromString(result ?? 'denied');
  }
}
