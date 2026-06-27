import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Orientation;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// A real-time multi-class object detector built on the package's FFI frame
/// pipeline.
///
/// Pipeline: [CameraController.setFrameProcessor] delivers each frame → we read
/// the raw YUV/BGRA buffers over FFI and resize+rotate them into the model's
/// input tensor → an **EfficientDet-Lite0** detector (90 COCO classes) runs in a
/// background isolate → we draw a labelled box for every object.
///
/// On top of the general detection it keeps a **single-class certainty trigger**
/// for "cat": temporal voting turns the jittery per-frame score into a stable
/// "certain" verdict — the technique you'd use for a reliable real-time alert.
///
/// The frame pipeline is generic, so swapping EfficientDet for your own
/// `.tflite` is a one-line change — that's the whole point of the FFI access.
class ObjectDetectorPage extends StatefulWidget {
  const ObjectDetectorPage({super.key});

  @override
  State<ObjectDetectorPage> createState() => _ObjectDetectorPageState();
}

class _ObjectDetectorPageState extends State<ObjectDetectorPage>
    with WidgetsBindingObserver {
  final CameraController _controller = CameraController();
  final FrameProcessorThrottler _throttler = FrameProcessorThrottler(
    targetFps: 5,
  );

  Interpreter? _interpreter;
  IsolateInterpreter? _isolate;
  List<String> _labels = [];
  int _inputSize = 320;
  List<List<int>> _outShapes = [];

  static const double _displayGate = 0.40; // min score to draw a box
  // Temporal voting for the "cat" trigger.
  final List<double> _catWindow = [];
  static const int _windowSize = 8;
  static const int _needHits = 4;

  bool _isInitialized = false;
  bool _busy = false;
  int _lastFrameDeg = -1; // diagnostics: log rotation only when it changes
  List<_Obj> _objects = [];
  double _catScore = 0;
  bool _catCertain = false;
  String? _error;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
    _isolate?.close();
    _interpreter?.close();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (!_isInitialized) return;
    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _controller.setActive(false);
    } else if (state == AppLifecycleState.resumed) {
      _controller.setActive(true);
    }
  }

  Future<void> _init() async {
    try {
      if (await CameraPermissions.requestCameraPermission() !=
          PermissionStatus.granted) {
        setState(() => _error = 'Camera permission denied.');
        return;
      }
      await _loadModel();

      final devices = await CameraDevices.getAvailableCameraDevices();
      if (devices.isEmpty) {
        setState(() => _error = 'No camera found.');
        return;
      }
      final device =
          CameraDevices.getCameraDevice(devices, CameraPosition.back) ??
          devices.first;

      await _controller.initialize(device, pixelFormat: PixelFormat.yuv);
      await _controller.setFrameProcessor(_onFrame);
      await _controller.setActive(true);
      setState(() => _isInitialized = true);
    } catch (e) {
      setState(() => _error = 'Init failed: $e');
    }
  }

  Future<void> _loadModel() async {
    final interpreter = await Interpreter.fromAsset(
      'assets/efficientdet.tflite',
    );
    _interpreter = interpreter;
    _isolate = await IsolateInterpreter.create(address: interpreter.address);

    _inputSize = interpreter.getInputTensor(0).shape[1];
    _outShapes = interpreter
        .getOutputTensors()
        .map((t) => t.shape)
        .toList(growable: false);

    final raw = await rootBundle.loadString('assets/coco_labels.txt');
    _labels = raw
        .split('\n')
        .map((e) => e.trim())
        .where((e) => e.isNotEmpty)
        .toList();

    debugPrint(
      'ObjectDetector: input=${interpreter.getInputTensor(0).shape}, '
      'outputs=$_outShapes, labels=${_labels.length}',
    );
  }

  void _onFrame(Frame frame) {
    if (_isolate == null) return;
    if (!_throttler.shouldProcess((frame.timestamp * 1000).toInt())) return;
    if (_busy) return;
    _busy = true;

    // DIAGNOSTIC: how do the frame's orientation and the preview's rotation
    // relate as the phone turns? (Logged only when the frame orientation flips.)
    final fdeg = _degreesOf(frame.orientation);
    if (fdeg != _lastFrameDeg) {
      _lastFrameDeg = fdeg;
      debugPrint(
        'ObjRot: frame.orientation=$fdeg° previewQuarterTurns='
        '${_controller.previewRotation} mirrored=${_controller.previewMirrored} '
        'displaySize=${_controller.displayPreviewSize}',
      );
    }

    // Read+resize+rotate the frame into the model input NOW (the FFI buffer is
    // only valid inside this callback).
    final Uint8List input;
    try {
      input = _frameToRgb(frame, _inputSize, fdeg);
    } catch (_) {
      _busy = false;
      return;
    }

    _detect(input, fdeg).then(_apply).whenComplete(() => _busy = false);
  }

  Future<_Detection> _detect(Uint8List rgb, int frameDeg) async {
    try {
      final s = _inputSize;
      final inputs = [rgb.reshape([1, s, s, 3])];
      final outputs = <int, Object>{
        for (var i = 0; i < _outShapes.length; i++) i: _alloc(_outShapes[i]),
      };
      await _isolate!.runForMultipleInputs(inputs, outputs);

      // EfficientDet's 4 outputs come back in a converter-dependent order, so
      // classify them by shape (and value range) instead of assuming.
      List<List<double>>? boxes; // [N][4]  ymin,xmin,ymax,xmax
      final twoDim = <List<double>>[]; // candidate scores/classes
      for (var i = 0; i < _outShapes.length; i++) {
        final shape = _outShapes[i];
        if (shape.length == 3 && shape.last == 4) {
          boxes = _flatten2(outputs[i]);
        } else if (shape.length == 2) {
          twoDim.add(_flatten1(outputs[i]));
        }
      }
      if (boxes == null || twoDim.length < 2) return const _Detection(0, []);

      // Of the two [1,N] tensors, classes holds indices (0..89) → larger max;
      // scores are probabilities in [0,1].
      twoDim.sort((a, b) => _max(b).compareTo(_max(a)));
      final classes = twoDim[0];
      final scores = twoDim[1];

      var catScore = 0.0;
      final objs = <_Obj>[];
      for (var j = 0; j < scores.length; j++) {
        if (scores[j] < _displayGate) continue;
        final ci = classes[j].round();
        if (ci < 0 || ci >= _labels.length) continue;
        final label = _labels[ci];
        if (label == '???') continue; // COCO index gaps
        final b = boxes[j]; // ymin, xmin, ymax, xmax (in the upright frame)
        final isCat = label == 'cat';
        // Map the box into preview-display space with the package helper so it
        // tracks the preview at any device orientation.
        final box = _controller.previewRectFromFrame(
          Rect.fromLTRB(b[1], b[0], b[3], b[2]),
          sourceRotationDegrees: frameDeg,
        );
        objs.add(_Obj(box, label, scores[j], isCat));
        if (isCat && scores[j] > catScore) catScore = scores[j];
      }
      return _Detection(catScore, objs);
    } catch (e) {
      debugPrint('ObjectDetector inference error: $e');
      return const _Detection(0, []);
    }
  }

  void _apply(_Detection d) {
    if (!mounted) return;
    _catWindow.add(d.catScore);
    if (_catWindow.length > _windowSize) _catWindow.removeAt(0);
    final hits = _catWindow.where((s) => s >= _displayGate).length;
    setState(() {
      _objects = d.objects;
      _catScore = d.catScore;
      _catCertain = _catWindow.length >= _windowSize && hits >= _needHits;
    });
  }

  /// Samples the YUV_420_888 frame into a packed RGB `uint8` buffer of
  /// [size]x[size], applying [rotationDegrees] so the model sees an upright
  /// image. Stride-correct (honours row/pixel strides) — the reason the package
  /// exposes [Frame.planeBytesPerRow] / [Frame.planePixelStride].
  Uint8List _frameToRgb(Frame frame, int size, int rotationDegrees) {
    final fw = frame.width, fh = frame.height;
    final y = frame.getPlaneData(0);
    final u = frame.getPlaneData(1);
    final v = frame.getPlaneData(2);
    final yRow = frame.planeBytesPerRow(0);
    final uRow = frame.planeBytesPerRow(1);
    final vRow = frame.planeBytesPerRow(2);
    final uPix = frame.planePixelStride(1);
    final vPix = frame.planePixelStride(2);

    final out = Uint8List(size * size * 3);
    var o = 0;
    for (var oy = 0; oy < size; oy++) {
      final tv = (oy + 0.5) / size; // normalized in upright image
      for (var ox = 0; ox < size; ox++) {
        final tu = (ox + 0.5) / size;
        // Map upright (tu,tv) back to the sensor-oriented frame.
        final double nu, nv;
        switch (rotationDegrees) {
          case 90:
            nu = tv;
            nv = 1 - tu;
            break;
          case 180:
            nu = 1 - tu;
            nv = 1 - tv;
            break;
          case 270:
            nu = 1 - tv;
            nv = tu;
            break;
          default:
            nu = tu;
            nv = tv;
        }
        var fx = (nu * fw).toInt();
        var fy = (nv * fh).toInt();
        if (fx < 0) fx = 0;
        if (fx >= fw) fx = fw - 1;
        if (fy < 0) fy = 0;
        if (fy >= fh) fy = fh - 1;

        final yy = y[fy * yRow + fx];
        final cx = fx >> 1, cy = fy >> 1;
        final uu = u[cy * uRow + cx * uPix] - 128;
        final vv = v[cy * vRow + cx * vPix] - 128;

        out[o++] = _clip(yy + ((1436 * vv) >> 10)); // R
        out[o++] = _clip(yy - ((352 * uu + 731 * vv) >> 10)); // G
        out[o++] = _clip(yy + ((1814 * uu) >> 10)); // B
      }
    }
    return out;
  }

  static int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

  static int _degreesOf(Orientation o) {
    switch (o) {
      case Orientation.landscapeLeft:
        return 90;
      case Orientation.portraitUpsideDown:
        return 180;
      case Orientation.landscapeRight:
        return 270;
      case Orientation.portrait:
        return 0;
    }
  }

  // Output-buffer helpers.
  static Object _alloc(List<int> shape) {
    if (shape.length == 1) return List<double>.filled(shape[0], 0);
    return List.generate(shape[0], (_) => _alloc(shape.sublist(1)));
  }

  static List<double> _flatten1(Object? o) =>
      ((o as List)[0] as List).cast<num>().map((e) => e.toDouble()).toList();

  static List<List<double>> _flatten2(Object? o) => ((o as List)[0] as List)
      .map((r) => (r as List).cast<num>().map((e) => e.toDouble()).toList())
      .toList();

  static double _max(List<double> l) {
    var m = double.negativeInfinity;
    for (final v in l) {
      if (v > m) m = v;
    }
    return m;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: const Text('Object Detector'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: _error != null
          ? Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white),
                ),
              ),
            )
          : !_isInitialized
          ? const Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  CircularProgressIndicator(),
                  SizedBox(height: 16),
                  Text(
                    'Loading detector…',
                    style: TextStyle(color: Colors.white70),
                  ),
                ],
              ),
            )
          : Stack(
              children: [
                Positioned.fill(
                  child: CameraPreview(
                    controller: _controller,
                    resizeMode: ResizeMode.contain,
                  ),
                ),
                Positioned.fill(
                  child: CustomPaint(
                    painter: _BoxPainter(
                      _objects,
                      _controller.displayPreviewSize,
                      _catCertain ? Colors.green : Colors.amber,
                    ),
                  ),
                ),
                Positioned(left: 16, right: 16, bottom: 32, child: _panel()),
              ],
            ),
    );
  }

  Widget _panel() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: (_catCertain ? Colors.green : Colors.black).withValues(
          alpha: 0.72,
        ),
        borderRadius: BorderRadius.circular(16),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  _catCertain ? '🐱  CAT — certain' : '👀  watching for a cat…',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
              Text(
                '${_objects.length} object${_objects.length == 1 ? '' : 's'}',
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              const Text(
                'cat',
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(4),
                  child: LinearProgressIndicator(
                    value: _catScore,
                    minHeight: 8,
                    backgroundColor: Colors.white24,
                    valueColor: AlwaysStoppedAnimation(
                      _catScore >= _displayGate
                          ? Colors.greenAccent
                          : Colors.amberAccent,
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Text(
                '${(_catScore * 100).round()}%',
                style: const TextStyle(
                  color: Colors.white,
                  fontFamily: 'monospace',
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          const Text(
            'EfficientDet-Lite0 · 90 COCO classes · cat-certainty by voting',
            style: TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

/// One frame's detections.
class _Detection {
  final double catScore; // best cat score this frame (drives the cat trigger)
  final List<_Obj> objects;
  const _Detection(this.catScore, this.objects);
}

class _Obj {
  final Rect box; // normalized 0..1 in the upright image
  final String label;
  final double score;
  final bool isCat;
  const _Obj(this.box, this.label, this.score, this.isCat);
}

/// Draws each detection, mapping a normalized box in the upright image onto the
/// `contain`-fitted preview rect. Cats use [catColor]; other objects are cyan.
class _BoxPainter extends CustomPainter {
  final List<_Obj> objects;
  final Size? previewSize; // upright preview dimensions
  final Color catColor;

  _BoxPainter(this.objects, this.previewSize, this.catColor);

  @override
  void paint(Canvas canvas, Size size) {
    final ps = previewSize;
    Rect img;
    if (ps == null || ps.width == 0 || ps.height == 0) {
      img = Offset.zero & size;
    } else {
      final scale = (size.width / ps.width) < (size.height / ps.height)
          ? size.width / ps.width
          : size.height / ps.height;
      final w = ps.width * scale, h = ps.height * scale;
      img = Rect.fromLTWH((size.width - w) / 2, (size.height - h) / 2, w, h);
    }

    for (final obj in objects) {
      final color = obj.isCat ? catColor : Colors.cyanAccent;
      // obj.box is already in preview-display space (see previewRectFromFrame).
      final r = Rect.fromLTRB(
        img.left + obj.box.left * img.width,
        img.top + obj.box.top * img.height,
        img.left + obj.box.right * img.width,
        img.top + obj.box.bottom * img.height,
      );
      canvas.drawRRect(
        RRect.fromRectAndRadius(r, const Radius.circular(8)),
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = obj.isCat ? 4 : 3
          ..color = color,
      );
      final tp = TextPainter(
        text: TextSpan(
          text: ' ${obj.label} ${(obj.score * 100).round()}% ',
          style: TextStyle(
            color: Colors.black,
            fontSize: 13,
            fontWeight: FontWeight.bold,
            background: Paint()..color = color,
          ),
        ),
        textDirection: ui.TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(r.left, (r.top - 18).clamp(0.0, size.height)));
    }
  }

  @override
  bool shouldRepaint(_BoxPainter old) =>
      old.objects != objects || old.catColor != catColor;
}
