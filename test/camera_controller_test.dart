import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const MethodChannel channel = MethodChannel(
    'dev.jentejan.flutter_native_vision_camera/camera',
  );

  group('CameraController', () {
    late CameraController controller;
    final List<MethodCall> log = <MethodCall>[];

    setUp(() {
      controller = CameraController();

      // We need to use TestDefaultBinaryMessenger to handle method calls in newer Flutter versions
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall methodCall) async {
            log.add(methodCall);
            switch (methodCall.method) {
              case 'initialize':
                return {
                  'textureId': 10,
                  'previewWidth': 1280,
                  'previewHeight': 720,
                };
              case 'setActive':
                return null;
              case 'setZoom':
                return null;
              default:
                return null;
            }
          });
    });

    tearDown(() {
      log.clear();
      // Reset the handler
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    test('initial state is uninitialized', () {
      expect(controller.value, CameraState.uninitialized);
      expect(controller.isInitialized, false);
    });

    test('initialize calls native and updates state', () async {
      final device = CameraDevice(
        id: 'back',
        name: 'Back Camera',
        position: CameraPosition.back,
        hasFlash: true,
        hasTorch: true,
        minFocusDistance: 10.0,
        isMultiCam: false,
        minZoom: 1.0,
        maxZoom: 10.0,
        neutralZoom: 1.0,
        minExposure: -2.0,
        maxExposure: 2.0,
        supportsLowLightBoost: false,
        supportsRawCapture: false,
        supportsFocus: true,
        hardwareLevel: HardwareLevel.full,
        sensorOrientation: Orientation.portrait,
        physicalDevices: [PhysicalCameraDeviceType.wideAngleCamera],
        formats: [],
      );

      await controller.initialize(device);

      expect(
        log,
        contains(predicate((MethodCall call) => call.method == 'initialize')),
      );
      expect(controller.value, CameraState.initialized);
      expect(controller.isInitialized, true);
      expect(controller.textureId, 10);
      expect(controller.previewWidth, 1280);
      expect(controller.previewHeight, 720);
    });

    test('setActive(true) calls native and updates state', () async {
      // Mock initialized state first
      final device = CameraDevice(
        id: 'back',
        name: 'Back Camera',
        position: CameraPosition.back,
        hasFlash: true,
        hasTorch: true,
        minFocusDistance: 10.0,
        isMultiCam: false,
        minZoom: 1.0,
        maxZoom: 10.0,
        neutralZoom: 1.0,
        minExposure: -2.0,
        maxExposure: 2.0,
        supportsLowLightBoost: false,
        supportsRawCapture: false,
        supportsFocus: true,
        hardwareLevel: HardwareLevel.full,
        sensorOrientation: Orientation.portrait,
        physicalDevices: [PhysicalCameraDeviceType.wideAngleCamera],
        formats: [],
      );
      await controller.initialize(device);
      log.clear();

      await controller.setActive(true);

      expect(
        log,
        contains(predicate((MethodCall call) => call.method == 'setActive')),
      );
      expect(controller.value, CameraState.active);
      expect(controller.isActive, true);
    });

    test('dispose clean up correctly', () {
      controller.dispose();
      expect(controller.value, CameraState.disposed);
    });
  });
}
