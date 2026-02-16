import 'dart:io';
import 'package:camera/camera.dart' as official;
import 'package:flutter/material.dart';
import 'detailed_photo_viewer.dart';

class StandardCameraPage extends StatefulWidget {
  const StandardCameraPage({super.key});

  @override
  State<StandardCameraPage> createState() => _StandardCameraPageState();
}

class _StandardCameraPageState extends State<StandardCameraPage> {
  official.CameraController? _controller;
  List<official.CameraDescription>? _cameras;
  official.CameraDescription? _currentCamera;
  bool _isReady = false;

  // Controls
  double _minZoom = 1.0;
  double _maxZoom = 1.0;
  double _currentZoom = 1.0;
  double _exposureOffset = 0.0;
  official.FlashMode _flashMode = official.FlashMode.off;

  // Media
  official.XFile? _lastPhoto;

  // FPS Meter
  double _fps = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;

  @override
  void initState() {
    super.initState();
    _initCamera();
  }

  Future<void> _initCamera() async {
    try {
      _cameras = await official.availableCameras();
      if (_cameras != null && _cameras!.isNotEmpty) {
        _currentCamera = _cameras![0];
        await _onNewCameraSelected(_currentCamera!);
      }
    } catch (e) {
      debugPrint("Error initializing standard camera: $e");
    }
  }

  Future<void> _onNewCameraSelected(
    official.CameraDescription cameraDescription,
  ) async {
    if (_controller != null) {
      await _controller!.dispose();
    }

    final official.CameraController cameraController =
        official.CameraController(
          cameraDescription,
          official.ResolutionPreset.max,
          enableAudio: false,
        );
    _controller = cameraController;

    try {
      await cameraController.initialize();
      if (!mounted) {
        return;
      }

      // Start FPS stream
      cameraController.startImageStream((image) {
        _frameCount++;
        final now = DateTime.now();
        _lastFpsUpdate ??= now;

        if (now.difference(_lastFpsUpdate!).inMilliseconds >= 1000) {
          if (mounted) {
            setState(() {
              _fps =
                  _frameCount *
                  1000 /
                  now.difference(_lastFpsUpdate!).inMilliseconds;
              _frameCount = 0;
              _lastFpsUpdate = now;
            });
          }
        }
      });

      await Future.wait([
        cameraController
            .getMaxZoomLevel()
            .then((value) => _maxZoom = value)
            .catchError((_) => _maxZoom = 1.0),
        cameraController
            .getMinZoomLevel()
            .then((value) => _minZoom = value)
            .catchError((_) => _minZoom = 1.0),
      ]);

      setState(() {
        _isReady = true;
        _currentZoom = 1.0;
        _exposureOffset = 0.0;
        _flashMode = official.FlashMode.off;
      });
    } on official.CameraException catch (e) {
      _showError('Error: ${e.code}\n${e.description}');
    }
  }

  @override
  void dispose() {
    _controller?.dispose();
    super.dispose();
  }

  // --- Actions ---

  Future<void> _takePhoto() async {
    if (_controller == null || !_controller!.value.isInitialized) return;
    try {
      if (_controller!.value.isTakingPicture) return;
      final official.XFile photo = await _controller!.takePicture();
      setState(() => _lastPhoto = photo);
      if (mounted) _showSnackbar('Photo saved: ${photo.path}');
    } on official.CameraException catch (e) {
      _showError('Error taking picture: $e');
    }
  }

  Future<void> _setZoom(double zoom) async {
    if (_controller == null) return;
    try {
      await _controller!.setZoomLevel(zoom);
      setState(() => _currentZoom = zoom);
    } on official.CameraException catch (e) {
      debugPrint('Zoom failed: $e');
    }
  }

  Future<void> _setExposure(double value) async {
    if (_controller == null) return;
    try {
      await _controller!.setExposureOffset(value);
      setState(() => _exposureOffset = value);
    } on official.CameraException catch (e) {
      debugPrint('Exposure failed: $e');
    }
  }

  Future<void> _focus(
    TapDownDetails details,
    BoxConstraints constraints,
  ) async {
    if (_controller == null) return;
    final offset = Offset(
      details.localPosition.dx / constraints.maxWidth,
      details.localPosition.dy / constraints.maxHeight,
    );
    try {
      await _controller!.setFocusPoint(offset);
      await _controller!.setExposurePoint(offset);
      if (mounted)
        _showSnackbar(
          'Focused at ${offset.dx.toStringAsFixed(2)}, ${offset.dy.toStringAsFixed(2)}',
        );
    } on official.CameraException catch (e) {
      debugPrint('Focus failed: $e');
    }
  }

  Future<void> _toggleFlash() async {
    if (_controller == null) return;
    final newMode = _flashMode == official.FlashMode.off
        ? official.FlashMode.torch
        : official.FlashMode.off;
    try {
      await _controller!.setFlashMode(newMode);
      setState(() => _flashMode = newMode);
    } on official.CameraException catch (e) {
      debugPrint('Flash toggle failed: $e');
    }
  }

  Future<void> _switchCamera() async {
    if (_cameras == null || _cameras!.isEmpty) return;
    final cameraIndex = _cameras!.indexOf(_currentCamera!);
    final newCameraIndex = (cameraIndex + 1) % _cameras!.length;
    await _onNewCameraSelected(_cameras![newCameraIndex]);
    setState(() => _currentCamera = _cameras![newCameraIndex]);
  }

  // --- UI ---

  void _showError(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(message), backgroundColor: Colors.red),
    );
  }

  void _showSnackbar(String message) {
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        duration: const Duration(milliseconds: 500),
      ),
    );
  }

  Widget _buildFPSCounter() {
    return Positioned(
      top: 100,
      left: 16,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: Colors.black54,
          borderRadius: BorderRadius.circular(4),
        ),
        child: Text(
          "FPS: ${_fps.toStringAsFixed(1)}",
          style: const TextStyle(
            color: Colors.greenAccent,
            fontWeight: FontWeight.bold,
            fontSize: 12,
            fontFamily: "monospace",
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (!_isReady || _controller == null || !_controller!.value.isInitialized) {
      return const Scaffold(
        backgroundColor: Colors.black,
        body: Center(child: CircularProgressIndicator()),
      );
    }

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Stack(
          children: [
            // Preview
            Center(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return GestureDetector(
                    onTapDown: (details) => _focus(details, constraints),
                    child: official.CameraPreview(_controller!),
                  );
                },
              ),
            ),

            _buildFPSCounter(),

            // Top Bar
            Positioned(
              top: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black45,
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 8,
                ),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    IconButton(
                      icon: Icon(
                        _flashMode == official.FlashMode.torch
                            ? Icons.flash_on
                            : Icons.flash_off,
                        color: Colors.white,
                      ),
                      onPressed: _toggleFlash,
                    ),
                    Text(
                      'Standard Camera ${_currentCamera?.lensDirection.name.toUpperCase()}',
                      style: const TextStyle(color: Colors.white, fontSize: 12),
                    ),
                  ],
                ),
              ),
            ),

            // Side Controls
            Positioned(
              right: 16,
              top: 100,
              bottom: 150,
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  // Exposure
                  RotatedBox(
                    quarterTurns: 3,
                    child: SizedBox(
                      width: 150,
                      child: Slider(
                        value: _exposureOffset,
                        min:
                            -2.0, // Standard min/max often allow wider range, safe -2 to 2
                        max: 2.0,
                        activeColor: Colors.yellow,
                        inactiveColor: Colors.white24,
                        onChanged: _setExposure,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  const Icon(Icons.exposure, color: Colors.yellow, size: 20),
                  const SizedBox(height: 40),

                  // Zoom
                  RotatedBox(
                    quarterTurns: 3,
                    child: SizedBox(
                      width: 150,
                      child: Slider(
                        value: _currentZoom,
                        min: _minZoom,
                        max: _maxZoom.clamp(
                          _minZoom,
                          10.0,
                        ), // Cap at 10x for usability
                        activeColor: Colors.white,
                        inactiveColor: Colors.white24,
                        onChanged: _setZoom,
                      ),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${_currentZoom.toStringAsFixed(1)}x',
                    style: const TextStyle(color: Colors.white),
                  ),
                ],
              ),
            ),

            // Bottom Bar
            Positioned(
              bottom: 0,
              left: 0,
              right: 0,
              child: Container(
                color: Colors.black54,
                padding: const EdgeInsets.all(24),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.spaceEvenly,
                  children: [
                    // Last Photo
                    GestureDetector(
                      onTap: () {
                        if (_lastPhoto != null) {
                          Navigator.push(
                            context,
                            MaterialPageRoute(
                              builder: (_) =>
                                  DetailedPhotoViewer(path: _lastPhoto!.path),
                            ),
                          );
                        }
                      },
                      child: Container(
                        width: 50,
                        height: 50,
                        decoration: BoxDecoration(
                          color: Colors.grey[800],
                          borderRadius: BorderRadius.circular(8),
                          image: _lastPhoto != null
                              ? DecorationImage(
                                  image: FileImage(File(_lastPhoto!.path)),
                                  fit: BoxFit.contain,
                                )
                              : null,
                        ),
                        child: _lastPhoto == null
                            ? const Icon(
                                Icons.broken_image,
                                color: Colors.white,
                              )
                            : null,
                      ),
                    ),

                    // Shutter
                    GestureDetector(
                      onTap: _takePhoto,
                      child: Container(
                        width: 80,
                        height: 80,
                        decoration: BoxDecoration(
                          shape: BoxShape.circle,
                          border: Border.all(color: Colors.white, width: 4),
                          color: Colors.white,
                        ),
                      ),
                    ),

                    // Switch
                    IconButton(
                      icon: const Icon(
                        Icons.cameraswitch,
                        color: Colors.white,
                        size: 30,
                      ),
                      onPressed: _switchCamera,
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
