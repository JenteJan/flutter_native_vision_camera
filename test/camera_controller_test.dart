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

    CameraDevice makeDevice({
      Orientation sensorOrientation = Orientation.portrait,
      CameraPosition position = CameraPosition.back,
    }) {
      return CameraDevice(
        id: 'cam',
        name: 'Camera',
        position: position,
        hasFlash: true,
        hasTorch: true,
        minFocusDistance: 0.0,
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
        sensorOrientation: sensorOrientation,
        physicalDevices: const [PhysicalCameraDeviceType.wideAngleCamera],
        formats: const [],
      );
    }

    // Simulates a native -> Dart method call (e.g. onPreviewConfigurationChanged).
    Future<void> sendNative(String method, dynamic arguments) {
      return TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .handlePlatformMessage(
            channel.name,
            const StandardMethodCodec().encodeMethodCall(
              MethodCall(method, arguments),
            ),
            (_) {},
          );
    }

    test(
      'previewRotation falls back to sensorOrientation before native reports',
      () async {
        await controller.initialize(
          makeDevice(sensorOrientation: Orientation.landscapeLeft),
        );
        expect(controller.previewRotation, 1); // 90 / 90
        // Landscape preview (1280x720) is swapped to portrait in display space.
        expect(controller.displayPreviewSize, const Size(720, 1280));
      },
    );

    test(
      'previewRotation uses the native rotationDegrees once reported',
      () async {
        await controller.initialize(
          makeDevice(sensorOrientation: Orientation.landscapeLeft),
        );
        await sendNative('onPreviewConfigurationChanged', {
          'rotationDegrees': 0,
          'mirrored': false,
        });
        expect(controller.previewRotation, 0);
        expect(
          controller.displayPreviewSize,
          const Size(1280, 720),
        ); // not swapped
      },
    );

    test('previewRectFromFrame maps boxes into preview space', () async {
      await controller.initialize(
        makeDevice(sensorOrientation: Orientation.landscapeLeft),
        mirror: false,
      );
      await sendNative('onPreviewConfigurationChanged', {
        'rotationDegrees': 90, // preview is one quarter-turn
        'mirrored': false,
      });
      const box = Rect.fromLTRB(0.1, 0.2, 0.4, 0.6);

      // Frame rotated to match the preview (90°) → identity (the portrait case).
      expect(
        controller.previewRectFromFrame(box, sourceRotationDegrees: 90),
        box,
      );

      // 90° difference → one quarter-turn clockwise: (x,y) -> (1-y, x).
      final rotated = controller.previewRectFromFrame(
        box,
        sourceRotationDegrees: 0,
      );
      expect(rotated.left, closeTo(0.4, 1e-9));
      expect(rotated.top, closeTo(0.1, 1e-9));
      expect(rotated.right, closeTo(0.8, 1e-9));
      expect(rotated.bottom, closeTo(0.4, 1e-9));
    });

    test('previewMirrored reflects the native report', () async {
      await controller.initialize(makeDevice(position: CameraPosition.front));
      expect(controller.previewMirrored, false);
      await sendNative('onPreviewConfigurationChanged', {
        'rotationDegrees': 90,
        'mirrored': true,
      });
      expect(controller.previewMirrored, true);
    });

    test('mirror reflects the init argument (defaults to true)', () async {
      await controller.initialize(makeDevice());
      expect(controller.mirror, true);

      final c2 = CameraController();
      await c2.initialize(makeDevice(), mirror: false);
      expect(c2.mirror, false);
      c2.dispose();
    });

    test('dispose clean up correctly', () {
      controller.dispose();
      expect(controller.value, CameraState.disposed);
    });
  });
}
