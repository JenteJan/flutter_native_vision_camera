import 'package:flutter/material.dart' hide Orientation;

import 'camera_controller.dart';
import 'types/types.dart';

/// The camera preview widget.
///
/// Displays the live camera feed using Flutter's [Texture] widget.
///
/// ## Orientation
/// The camera sensor is physically mounted at an angle, so the texture arrives
/// rotated relative to the screen. **This widget is the single place that
/// rotation is corrected** — it applies [CameraController.previewRotation] so
/// the preview is always upright. Do not wrap it in `RotatedBox`/`AspectRatio`
/// hacks; if you draw an overlay on top, size it against
/// [CameraController.displayPreviewSize] so it stays aligned.
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

  /// Whether the preview should be displayed mirror-like (the selfie look).
  ///
  /// By default this follows the controller's `mirror` setting for front
  /// cameras (so one variable drives both the preview and the captured image);
  /// pass [isMirrored] to override the preview independently.
  bool get _wantsMirrorLike {
    if (isMirrored != null) return isMirrored!;
    return controller.device?.position == CameraPosition.front &&
        controller.mirror;
  }

  @override
  Widget build(BuildContext context) {
    // Rebuild whenever the controller changes (e.g. after async init or
    // device switch) so the preview appears instead of staying black.
    return ListenableBuilder(
      listenable: controller,
      builder: (context, _) {
        final textureId = controller.textureId;
        if (textureId == null || !controller.isInitialized) {
          return const ColoredBox(color: Colors.black);
        }

        // Raw (sensor-space) texture dimensions and the rotation needed to
        // make them upright. Rotation is applied here and ONLY here.
        final rawWidth = controller.previewWidth?.toDouble() ?? 1920.0;
        final rawHeight = controller.previewHeight?.toDouble() ?? 1080.0;
        final turns = controller.previewRotation;
        final fit = resizeMode == ResizeMode.cover
            ? BoxFit.cover
            : BoxFit.contain;

        Widget content = SizedBox(
          width: rawWidth,
          height: rawHeight,
          child: Texture(textureId: textureId),
        );
        // 1. Rotate the raw texture upright.
        content = RotatedBox(quarterTurns: turns, child: content);
        // 2. Flip horizontally only when needed to reach the desired mirror-like
        // look — the native preview may already be mirrored (e.g. Android front
        // camera), so a blind flip would double-mirror it.
        final flip = _wantsMirrorLike != controller.previewMirrored;
        if (flip) {
          content = Transform.scale(scaleX: -1, child: content);
        }

        final output = SizedBox.expand(
          child: FittedBox(
            fit: fit,
            clipBehavior: Clip.hardEdge,
            child: content,
          ),
        );

        if (!onTapToFocus) return output;

        // Upright (display-space) preview size, used to map taps through the fit.
        final displaySize =
            controller.displayPreviewSize ?? Size(rawWidth, rawHeight);

        return LayoutBuilder(
          builder: (context, constraints) {
            final widgetSize = constraints.biggest;
            return GestureDetector(
              onTapUp: (details) {
                if (!widgetSize.isFinite ||
                    widgetSize.isEmpty ||
                    !controller.isActive) {
                  return;
                }
                final fitted = applyBoxFit(fit, displaySize, widgetSize);
                final dest = fitted.destination;
                if (dest.width <= 0 || dest.height <= 0) return;

                final dx0 = (widgetSize.width - dest.width) / 2;
                final dy0 = (widgetSize.height - dest.height) / 2;
                final ndx = ((details.localPosition.dx - dx0) / dest.width)
                    .clamp(0.0, 1.0);
                final ndy = ((details.localPosition.dy - dy0) / dest.height)
                    .clamp(0.0, 1.0);
                // Invert the *actual* rendered transform (rotation + the flip we
                // applied), not the desired mirror-like state, so the focus
                // point matches what the user sees.
                controller.focus(_displayToSensor(ndx, ndy, turns, flip));
              },
              child: output,
            );
          },
        );
      },
    );
  }

  /// Maps a normalized point in upright **display** space back to **sensor**
  /// space, inverting [previewRotation] and the front-camera mirror so the
  /// native focus call targets the location the user actually tapped.
  static Point _displayToSensor(double dx, double dy, int turns, bool mirror) {
    if (mirror) dx = 1.0 - dx;
    switch (turns % 4) {
      case 1:
        return Point(x: dy, y: 1.0 - dx);
      case 2:
        return Point(x: 1.0 - dx, y: 1.0 - dy);
      case 3:
        return Point(x: 1.0 - dy, y: dx);
      default:
        return Point(x: dx, y: dy);
    }
  }
}

/// How the camera preview is sized within its parent.
enum ResizeMode {
  /// Fill the entire parent, cropping edges if the aspect ratio doesn't match.
  cover,

  /// Fit inside the parent, adding letterboxing if needed.
  contain,
}
