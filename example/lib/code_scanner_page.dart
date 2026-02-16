import 'package:flutter/material.dart' hide Orientation;
import 'package:flutter/services.dart';
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';

class CodeScannerPage extends StatefulWidget {
  const CodeScannerPage({super.key});

  @override
  State<CodeScannerPage> createState() => _CodeScannerPageState();
}

class _CodeScannerPageState extends State<CodeScannerPage>
    with WidgetsBindingObserver {
  late final CameraController _controller;
  bool _isInitialized = false;
  List<Code> _scannedCodes = [];
  final List<String> _scanHistory = [];
  String? _lastResult;
  bool _isPaused = false;
  DateTime _lastDetectionTime = DateTime.now();

  @override
  void initState() {
    super.initState();
    _controller = CameraController();
    WidgetsBinding.instance.addObserver(this);
    _initialize();
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

  Future<void> _initialize() async {
    final devices = await CameraDevices.getAvailableCameraDevices();
    if (devices.isEmpty) return;

    final device =
        CameraDevices.getCameraDevice(devices, CameraPosition.back) ??
        devices.first;

    await _controller.initialize(
      device,
      codeScanner: const CodeScannerConfiguration(
        codeTypes: [CodeType.qr, CodeType.ean13, CodeType.code128],
      ),
    );

    _controller.onCodeScanned.listen((codes) {
      if (!mounted) return;
      debugPrint("UI: Received ${codes.length} codes");

      setState(() {
        _scannedCodes = codes;
        if (codes.isNotEmpty) {
          _lastDetectionTime = DateTime.now();
          final code = codes.first;

          if (code.value != null && !_isPaused) {
            if (code.value != _lastResult) {
              debugPrint("New code detected: ${code.value}");
              _lastResult = code.value;

              // Feed back
              HapticFeedback.vibrate();

              // Add to history (move to top if exists)
              if (_scanHistory.contains(code.value!)) {
                _scanHistory.remove(code.value!);
              }
              _scanHistory.insert(0, code.value!);
              if (_scanHistory.length > 10) _scanHistory.removeLast();
            }
          }
        } else {
          // Clear last result after 500ms of no codes to allow immediate re-scanning
          if (DateTime.now().difference(_lastDetectionTime).inMilliseconds >
              500) {
            _lastResult = null;
          }
        }
      });
    });

    await _controller.setActive(true);
    setState(() => _isInitialized = true);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text("Vision Scanner"),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
        actions: [
          IconButton(
            icon: Icon(_isPaused ? Icons.play_arrow : Icons.pause),
            onPressed: () => setState(() => _isPaused = !_isPaused),
          ),
        ],
      ),
      backgroundColor: Colors.black,
      body: Stack(
        children: [
          if (_isInitialized)
            Positioned.fill(
              child: CameraPreview(
                controller: _controller,
                resizeMode: ResizeMode.cover,
              ),
            ),

          // High-Tech Viewfinder
          const Center(child: ViewfinderGuide()),

          // Overlay Boxes
          if (_isInitialized)
            Positioned.fill(
              child: Builder(
                builder: (context) {
                  final orientation =
                      _controller.device?.sensorOrientation ??
                      Orientation.portrait;
                  final bool isSwapped =
                      orientation == Orientation.landscapeLeft ||
                      orientation == Orientation.landscapeRight;

                  final previewWidth = isSwapped
                      ? (_controller.previewHeight?.toDouble() ?? 1080)
                      : (_controller.previewWidth?.toDouble() ?? 1920);
                  final previewHeight = isSwapped
                      ? (_controller.previewWidth?.toDouble() ?? 1920)
                      : (_controller.previewHeight?.toDouble() ?? 1080);

                  return CustomPaint(
                    painter: ScannerOverlayPainter(
                      _scannedCodes,
                      previewWidth,
                      previewHeight,
                    ),
                  );
                },
              ),
            ),

          // Bottom Sheet Controls & History
          Positioned(
            bottom: 0,
            left: 0,
            right: 0,
            child: Container(
              padding: const EdgeInsets.all(20),
              decoration: const BoxDecoration(
                color: Colors.black54,
                borderRadius: BorderRadius.vertical(top: Radius.circular(24)),
              ),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_scanHistory.isNotEmpty) ...[
                    Text(
                      "RECENT SCANS (${_scanHistory.length})",
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 10,
                        letterSpacing: 1.2,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 10),
                    SizedBox(
                      height: 100,
                      child: ListView.builder(
                        itemCount: _scanHistory.length,
                        itemBuilder: (context, index) {
                          final item = _scanHistory[index];
                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 4),
                            child: Row(
                              children: [
                                const Icon(
                                  Icons.qr_code,
                                  color: Colors.greenAccent,
                                  size: 16,
                                ),
                                const SizedBox(width: 10),
                                Expanded(
                                  child: Text(
                                    item,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                                IconButton(
                                  icon: const Icon(
                                    Icons.copy,
                                    color: Colors.white54,
                                    size: 16,
                                  ),
                                  onPressed: () => Clipboard.setData(
                                    ClipboardData(text: item),
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                    const Divider(color: Colors.white24),
                  ],
                  Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(
                        _isPaused ? Icons.pause_circle : Icons.sensors,
                        color: _isPaused ? Colors.orange : Colors.greenAccent,
                        size: 16,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _isPaused ? "SCANNER PAUSED" : "ACTIVE SCANNING",
                        style: TextStyle(
                          color: _isPaused ? Colors.orange : Colors.greenAccent,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class ViewfinderGuide extends StatelessWidget {
  const ViewfinderGuide({super.key});

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      height: 250,
      decoration: BoxDecoration(
        border: Border.all(color: Colors.white24, width: 1),
        borderRadius: BorderRadius.circular(20),
      ),
      child: Stack(
        children: [
          _corner(top: 0, left: 0, angle: 0),
          _corner(top: 0, right: 0, angle: 90),
          _corner(bottom: 0, left: 0, angle: 270),
          _corner(bottom: 0, right: 0, angle: 180),
        ],
      ),
    );
  }

  Widget _corner({
    double? top,
    double? left,
    double? right,
    double? bottom,
    required double angle,
  }) {
    return Positioned(
      top: top,
      left: left,
      right: right,
      bottom: bottom,
      child: Transform.rotate(
        angle: angle * 3.14159 / 180,
        child: Container(
          width: 30,
          height: 30,
          decoration: const BoxDecoration(
            border: Border(
              top: BorderSide(color: Colors.greenAccent, width: 4),
              left: BorderSide(color: Colors.greenAccent, width: 4),
            ),
          ),
        ),
      ),
    );
  }
}

class ScannerOverlayPainter extends CustomPainter {
  final List<Code> codes;
  final double previewWidth;
  final double previewHeight;

  ScannerOverlayPainter(this.codes, this.previewWidth, this.previewHeight);

  @override
  void paint(Canvas canvas, Size size) {
    if (codes.isEmpty) return;

    final paint = Paint()
      ..color = Colors.greenAccent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 3.0;

    final fillPaint = Paint()
      ..color = Colors.greenAccent.withOpacity(0.2)
      ..style = PaintingStyle.fill;

    // Calculate BoxFit.cover mapping
    final double scale =
        (size.width / previewWidth > size.height / previewHeight)
        ? size.width / previewWidth
        : size.height / previewHeight;

    final double scaledWidth = previewWidth * scale;
    final double scaledHeight = previewHeight * scale;
    final double dx = (size.width - scaledWidth) / 2;
    final double dy = (size.height - scaledHeight) / 2;

    for (final code in codes) {
      if (code.frame != null) {
        final rect = Rect.fromLTWH(
          dx + (code.frame!.x * scaledWidth),
          dy + (code.frame!.y * scaledHeight),
          code.frame!.width * scaledWidth,
          code.frame!.height * scaledHeight,
        );

        canvas.drawRect(rect, fillPaint);
        canvas.drawRect(rect, paint);

        if (code.value != null) {
          final tp = TextPainter(
            text: TextSpan(
              text: code.value,
              style: const TextStyle(
                color: Colors.greenAccent,
                fontSize: 14,
                fontWeight: FontWeight.bold,
                backgroundColor: Colors.black87,
              ),
            ),
            textDirection: TextDirection.ltr,
          );
          tp.layout();
          // Draw text slightly offset from the top of the box
          tp.paint(canvas, Offset(rect.left, rect.top - 20));
        }
      }
    }
  }

  @override
  bool shouldRepaint(covariant ScannerOverlayPainter oldDelegate) {
    return oldDelegate.codes != codes ||
        oldDelegate.previewWidth != previewWidth ||
        oldDelegate.previewHeight != previewHeight;
  }
}
