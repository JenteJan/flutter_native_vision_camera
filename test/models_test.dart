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
  });
}
