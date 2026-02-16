import 'package:flutter/foundation.dart';

import 'point.dart';

/// The type of barcode or QR code to scan.
///
/// Maps to `CodeType` from react-native-vision-camera.
enum CodeType {
  code128('code-128'),
  code39('code-39'),
  code93('code-93'),
  codabar('codabar'),
  gs1DataBar('gs1-data-bar'),
  gs1DataBarLimited('gs1-data-bar-limited'),
  gs1DataBarExpanded('gs1-data-bar-expanded'),
  ean13('ean-13'),
  ean8('ean-8'),
  itf('itf'),
  itf14('itf-14'),
  upcE('upc-e'),
  upcA('upc-a'),
  qr('qr'),
  pdf417('pdf-417'),
  aztec('aztec'),
  dataMatrix('data-matrix'),
  unknown('unknown');

  const CodeType(this.value);
  final String value;

  /// Deserializes a [CodeType] from a platform string.
  static CodeType fromString(String value) {
    return CodeType.values.firstWhere(
      (e) => e.value == value,
      orElse: () => CodeType.unknown,
    );
  }
}

/// The dimensions of the frame used for code scanning.
@immutable
class CodeScannerFrame {
  /// The width of the scanner frame.
  final int width;

  /// The height of the scanner frame.
  final int height;

  const CodeScannerFrame({required this.width, required this.height});

  factory CodeScannerFrame.fromMap(Map<String, dynamic> map) {
    return CodeScannerFrame(
      width: map['width'] as int,
      height: map['height'] as int,
    );
  }

  Map<String, dynamic> toMap() => {'width': width, 'height': height};
}

/// A single scanned code (barcode, QR code, etc.).
@immutable
class Code {
  /// The type of the scanned code.
  final CodeType type;

  /// The decoded string value, or `null` if it cannot be decoded.
  final String? value;

  /// The bounding rectangle of the code relative to the camera preview.
  final CodeFrame? frame;

  /// The corner points of the code relative to the camera preview.
  final List<Point>? corners;

  const Code({required this.type, this.value, this.frame, this.corners});

  factory Code.fromMap(Map<String, dynamic> map) {
    return Code(
      type: CodeType.fromString(map['type'] as String),
      value: map['value'] as String?,
      frame: map['frame'] != null
          ? CodeFrame.fromMap(Map<String, dynamic>.from(map['frame'] as Map))
          : null,
      corners: (map['corners'] as List<dynamic>?)
          ?.map((e) => Point.fromMap(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}

/// The bounding rectangle of a scanned code.
@immutable
class CodeFrame {
  final double x;
  final double y;
  final double width;
  final double height;

  const CodeFrame({
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  factory CodeFrame.fromMap(Map<String, dynamic> map) {
    return CodeFrame(
      x: (map['x'] as num).toDouble(),
      y: (map['y'] as num).toDouble(),
      width: (map['width'] as num).toDouble(),
      height: (map['height'] as num).toDouble(),
    );
  }
}

/// Configuration for the code scanner.
///
/// Maps to `CodeScanner` from react-native-vision-camera.
@immutable
class CodeScannerConfiguration {
  /// The types of codes to detect.
  final List<CodeType> codeTypes;

  /// Optional region of interest to crop the scanning area (iOS only).
  final CodeFrame? regionOfInterest;

  const CodeScannerConfiguration({
    required this.codeTypes,
    this.regionOfInterest,
  });

  Map<String, dynamic> toMap() {
    return {
      'codeTypes': codeTypes.map((e) => e.value).toList(),
      if (regionOfInterest != null)
        'regionOfInterest': {
          'x': regionOfInterest!.x,
          'y': regionOfInterest!.y,
          'width': regionOfInterest!.width,
          'height': regionOfInterest!.height,
        },
    };
  }
}
