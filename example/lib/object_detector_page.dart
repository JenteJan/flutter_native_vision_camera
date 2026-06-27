import 'dart:ui' as ui;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart' hide Orientation;
import 'package:flutter/services.dart' show rootBundle;
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';
import 'package:tflite_flutter/tflite_flutter.dart';

/// A real-time multi-class object detector that runs entirely **off the main
/// isolate** via the package's frame-worklet API.
///
/// The heavy work — YUV→RGB preprocessing and EfficientDet-Lite0 inference (90
/// COCO classes) — happens in [objectDetectorWorklet] on a worker isolate. It
/// `send`s plain detection data back; the UI isolate only maps boxes into
/// preview space (cheap) and paints. The main thread never touches a frame, so
/// the preview and UI stay smooth no matter how heavy the model is.
class ObjectDetectorPage extends StatefulWidget {
  const ObjectDetectorPage({super.key});

  @override
  State<ObjectDetectorPage> createState() => _ObjectDetectorPageState();
}

class _ObjectDetectorPageState extends State<ObjectDetectorPage>
    with WidgetsBindingObserver {
  final CameraController _controller = CameraController();

  // Cat-certainty voting (lives on the UI isolate — it's trivial).
  final List<double> _catWindow = [];
  static const int _windowSize = 8;
  static const int _needHits = 4;
  static const double _gate = 0.40;

  List<_Obj> _objects = [];
  double _catScore = 0;
  bool _catCertain = false;
  bool _isInitialized = false;
  String? _error;
  int _uiTicks = 0; // proves the main isolate stays free

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _init();
    _spin();
  }

  Future<void> _spin() async {
    while (mounted) {
      await Future.delayed(const Duration(milliseconds: 16));
      if (mounted) setState(() => _uiTicks++);
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _controller.dispose();
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
      final devices = await CameraDevices.getAvailableCameraDevices();
      if (devices.isEmpty) {
        setState(() => _error = 'No camera found.');
        return;
      }
      final device =
          CameraDevices.getCameraDevice(devices, CameraPosition.back) ??
          devices.first;

      await _controller.initialize(device, pixelFormat: PixelFormat.yuv);
      _controller.frameResults.listen(_onResult);
      // A worker isolate can't read rootBundle, so load the model + labels on
      // the main isolate and hand them to the worklet via `args`.
      final model = (await rootBundle.load(
        'assets/efficientdet.tflite',
      )).buffer.asUint8List();
      final labels = await rootBundle.loadString('assets/coco_labels.txt');
      await _controller.setFrameWorklet(
        objectDetectorWorklet,
        args: (model: model, labels: labels),
      );
      await _controller.setActive(true);
      setState(() => _isInitialized = true);
    } catch (e) {
      setState(() => _error = 'Init failed: $e');
    }
  }

  // Runs on the UI isolate: map the worker's frame-space boxes into preview
  // space and update the overlay. This is the only per-frame main-isolate work.
  void _onResult(Object? msg) {
    if (msg is! _DetResult || !mounted) return;
    final objs = <_Obj>[];
    var catScore = 0.0;
    for (final d in msg.dets) {
      final box = _controller.previewRectFromFrame(
        Rect.fromLTRB(d.xmin, d.ymin, d.xmax, d.ymax),
        sourceRotationDegrees: msg.rotation,
      );
      final isCat = d.label == 'cat';
      objs.add(_Obj(box, d.label, d.score, isCat));
      if (isCat && d.score > catScore) catScore = d.score;
    }
    _catWindow.add(catScore);
    if (_catWindow.length > _windowSize) _catWindow.removeAt(0);
    final hits = _catWindow.where((s) => s >= _gate).length;
    setState(() {
      _objects = objs;
      _catScore = catScore;
      _catCertain = _catWindow.length >= _windowSize && hits >= _needHits;
    });
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
                      _catScore >= _gate
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
          Text(
            'EfficientDet-Lite0 off-isolate · UI ticks $_uiTicks (smooth ⇒ main free)',
            style: const TextStyle(color: Colors.white70, fontSize: 11),
          ),
        ],
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// Worklet — everything below runs on the WORKER isolate (top-level only).
// ---------------------------------------------------------------------------

typedef _Det = ({
  String label,
  double score,
  double ymin,
  double xmin,
  double ymax,
  double xmax,
});
typedef _DetResult = ({int rotation, List<_Det> dets});

/// Frame worklet: loads EfficientDet-Lite0 once, then runs YUV→RGB + inference
/// per frame on the worker isolate and sends back frame-space detections.
void objectDetectorWorklet(FrameWorklet w) {
  final args = w.args as ({Uint8List model, String labels});
  final interpreter = Interpreter.fromBuffer(args.model);
  final inputSize = interpreter.getInputTensor(0).shape[1];
  final outShapes = interpreter
      .getOutputTensors()
      .map((t) => t.shape)
      .toList(growable: false);
  final labels = args.labels
      .split('\n')
      .map((e) => e.trim())
      .where((e) => e.isNotEmpty)
      .toList();
  final throttler = FrameProcessorThrottler(targetFps: 8);

  w.onFrame((frame) {
    if (!throttler.shouldProcess((frame.timestamp * 1000).toInt())) return;
    final rotation = frame.orientation.degrees;
    final rgb = _frameToRgb(frame, inputSize, rotation);
    final dets = _runDetection(interpreter, outShapes, labels, rgb, inputSize);
    w.send((rotation: rotation, dets: dets));
  });
}

List<_Det> _runDetection(
  Interpreter interpreter,
  List<List<int>> outShapes,
  List<String> labels,
  Uint8List rgb,
  int size,
) {
  final inputs = [
    rgb.reshape([1, size, size, 3]),
  ];
  final outputs = <int, Object>{
    for (var i = 0; i < outShapes.length; i++) i: _alloc(outShapes[i]),
  };
  interpreter.runForMultipleInputs(inputs, outputs);

  List<List<double>>? boxes; // [N][4] ymin,xmin,ymax,xmax
  final twoDim = <List<double>>[];
  for (var i = 0; i < outShapes.length; i++) {
    final shape = outShapes[i];
    if (shape.length == 3 && shape.last == 4) {
      boxes = _flatten2(outputs[i]);
    } else if (shape.length == 2) {
      twoDim.add(_flatten1(outputs[i]));
    }
  }
  if (boxes == null || twoDim.length < 2) return const [];

  // Of the two [1,N] tensors, classes holds indices (larger max); scores [0,1].
  twoDim.sort((a, b) => _max(b).compareTo(_max(a)));
  final classes = twoDim[0], scores = twoDim[1];

  final dets = <_Det>[];
  for (var j = 0; j < scores.length; j++) {
    if (scores[j] < 0.40) continue;
    final ci = classes[j].round();
    if (ci < 0 || ci >= labels.length) continue;
    final label = labels[ci];
    if (label == '???') continue;
    final b = boxes[j];
    dets.add((
      label: label,
      score: scores[j],
      ymin: b[0],
      xmin: b[1],
      ymax: b[2],
      xmax: b[3],
    ));
  }
  return dets;
}

/// Samples a YUV_420_888 frame into a packed RGB `uint8` buffer of [size]×[size],
/// applying [rotationDegrees] (stride-correct — honours row/pixel strides).
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
    final tv = (oy + 0.5) / size;
    for (var ox = 0; ox < size; ox++) {
      final tu = (ox + 0.5) / size;
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

int _clip(int v) => v < 0 ? 0 : (v > 255 ? 255 : v);

Object _alloc(List<int> shape) {
  if (shape.length == 1) return List<double>.filled(shape[0], 0);
  return List.generate(shape[0], (_) => _alloc(shape.sublist(1)));
}

List<double> _flatten1(Object? o) =>
    ((o as List)[0] as List).cast<num>().map((e) => e.toDouble()).toList();

List<List<double>> _flatten2(Object? o) => ((o as List)[0] as List)
    .map((r) => (r as List).cast<num>().map((e) => e.toDouble()).toList())
    .toList();

double _max(List<double> l) {
  var m = double.negativeInfinity;
  for (final v in l) {
    if (v > m) m = v;
  }
  return m;
}

// ---------------------------------------------------------------------------
// UI-isolate types.
// ---------------------------------------------------------------------------

class _Obj {
  final Rect box; // preview-display space
  final String label;
  final double score;
  final bool isCat;
  const _Obj(this.box, this.label, this.score, this.isCat);
}

class _BoxPainter extends CustomPainter {
  final List<_Obj> objects;
  final Size? previewSize;
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
