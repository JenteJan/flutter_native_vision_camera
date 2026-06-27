import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';

void main() {
  group('CameraPosition', () {
    test('CameraPosition values', () {
      expect(CameraPosition.back.value, 'back');
      expect(CameraPosition.front.value, 'front');
      expect(CameraPosition.external_.value, 'external');
    });

    test('CameraPosition.fromString', () {
      expect(CameraPosition.fromString('back'), CameraPosition.back);
      expect(CameraPosition.fromString('front'), CameraPosition.front);
      expect(CameraPosition.fromString('external'), CameraPosition.external_);
      expect(() => CameraPosition.fromString('invalid'), throwsArgumentError);
    });
  });

  group('Orientation', () {
    test('Orientation.fromString', () {
      expect(Orientation.fromString('portrait'), Orientation.portrait);
      expect(
        Orientation.fromString('landscape-left'),
        Orientation.landscapeLeft,
      );
      expect(
        Orientation.fromString('landscape-right'),
        Orientation.landscapeRight,
      );
      expect(
        Orientation.fromString('portrait-upside-down'),
        Orientation.portraitUpsideDown,
      );
    });

    test('Orientation.degrees (drives preview rotation)', () {
      expect(Orientation.portrait.degrees, 0);
      expect(Orientation.landscapeLeft.degrees, 90);
      expect(Orientation.portraitUpsideDown.degrees, 180);
      expect(Orientation.landscapeRight.degrees, 270);
    });
  });

  group('FrameProcessorThrottler', () {
    test('admits at most targetFps frames per second', () {
      final throttler = FrameProcessorThrottler(
        targetFps: 10,
      ); // 100ms interval
      // Real camera timestamps are large, so the first frame is admitted.
      expect(throttler.shouldProcess(1000), true);
      expect(throttler.shouldProcess(1050), false);
      expect(throttler.shouldProcess(1100), true);
      expect(throttler.shouldProcess(1150), false);
      expect(throttler.shouldProcess(1200), true);
    });
  });
}
