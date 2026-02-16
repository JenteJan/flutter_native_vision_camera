import 'package:flutter/material.dart' hide Orientation;

import 'camera_controller.dart';
import 'types/types.dart';

/// The camera preview widget.
///
/// Displays the live camera feed using Flutter's [Texture] widget,
/// which renders directly from the GPU surface provided by the native
/// camera session — zero-copy preview as per project rules.
///
/// ## Usage
/// ```dart
/// CameraPreview(
///   controller: cameraController,
///   resizeMode: ResizeMode.cover,
///   onTapToFocus: true,
/// )
/// ```
class CameraPreview extends StatelessWidget {
  /// The camera controller providing the texture and device info.
  final CameraController controller;

  /// How the preview should be sized within its parent.
  ///
  /// - [ResizeMode.cover]: Fill entire area, cropping if needed.
  /// - [ResizeMode.contain]: Fit inside area, adding letterbox if needed.
  final ResizeMode resizeMode;

  /// Whether to enable tap-to-focus gesture.
  final bool onTapToFocus;

  /// Whether to mirror the preview (typically for front camera).
  /// If `null`, automatically mirrors front-facing cameras.
  final bool? isMirrored;

  const CameraPreview({
    super.key,
    required this.controller,
    this.resizeMode = ResizeMode.contain,
    this.onTapToFocus = true,
    this.isMirrored,
  });

  bool get _shouldMirror {
    if (isMirrored != null) return isMirrored!;
    return controller.device?.position == CameraPosition.front;
  }

  @override
  Widget build(BuildContext context) {
    final textureId = controller.textureId;
    if (textureId == null || !controller.isInitialized) {
      return const ColoredBox(color: Colors.black);
    }

    // The dimensions from the native stream
    // Since we set targetRotation in CameraX, these dimensions already
    // reflect the correct orientation for the current display.
    final nativeWidth = controller.previewWidth?.toDouble() ?? 1920.0;
    final nativeHeight = controller.previewHeight?.toDouble() ?? 1080.0;

    Widget previewWidget = SizedBox(
      width: nativeWidth,
      height: nativeHeight,
      child: Texture(textureId: textureId),
    );

    final fit = resizeMode == ResizeMode.cover ? BoxFit.cover : BoxFit.contain;

    Widget outputWidget = SizedBox.expand(
      child: FittedBox(
        fit: fit,
        clipBehavior: Clip.hardEdge,
        child: _shouldMirror
            ? Transform.scale(
                scaleX: -1, // Mirror horizontally
                child: previewWidget,
              )
            : previewWidget,
      ),
    );

    // Tap-to-focus gesture
    if (onTapToFocus) {
      outputWidget = GestureDetector(
        onTapUp: (details) {
          final box = context.findRenderObject() as RenderBox;
          final size = box.size;
          final normalizedPoint = Point(
            x: details.localPosition.dx / size.width,
            y: details.localPosition.dy / size.height,
          );
          controller.focus(normalizedPoint);
        },
        child: outputWidget,
      );
    }

    return outputWidget;
  }
}

/// How the camera preview is sized within its parent.
enum ResizeMode {
  /// Fill the entire parent, cropping edges if the aspect ratio doesn't match.
  cover,

  /// Fit inside the parent, adding letterboxing if needed.
  contain,
}
