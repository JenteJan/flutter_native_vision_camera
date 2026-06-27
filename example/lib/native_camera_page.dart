import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';
import 'detailed_photo_viewer.dart';
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';

class NativeCameraPage extends StatefulWidget {
  const NativeCameraPage({super.key});

  @override
  State<NativeCameraPage> createState() => _NativeCameraPageState();
}

class _NativeCameraPageState extends State<NativeCameraPage>
    with WidgetsBindingObserver {
  final CameraController _controller = CameraController();

  List<CameraDevice> _devices = [];
  CameraDevice? _currentDevice;
  CameraDeviceFormat? _currentFormat;
  bool _isInitialized = false;
  String? _error;

  double _zoom = 1.0;
  String? _lastMediaPath;
  bool _isVideo = false;

  // FPS Meter
  double _fps = 0;
  int _frameCount = 0;
  DateTime? _lastFpsUpdate;

  @override
  void initState() {
    super.initState();
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
    try {
      final camStatus = await CameraPermissions.requestCameraPermission();
      if (camStatus != PermissionStatus.granted) {
        if (mounted) {
          setState(() => _error = "Camera permission denied.");
        }
        return;
      }

      final devices = await CameraDevices.getAvailableCameraDevices();
      if (devices.isEmpty) {
        if (mounted) {
          setState(
            () => _error =
                "No camera devices found. (If on simulator, check settings)",
          );
        }
        return;
      }

      _devices = devices;
      _currentDevice =
          CameraDevices.getCameraDevice(devices, CameraPosition.back) ??
          devices.first;

      await _startCamera();
    } catch (e) {
      if (mounted) {
        setState(() => _error = "Initialization failed: $e");
      }
    }
  }

  Future<void> _startCamera() async {
    if (_currentDevice == null) return;
    setState(() => _isInitialized = false);

    try {
      if (_currentFormat == null) {
        final formats = List.of(_currentDevice!.formats);
        formats.sort((a, b) {
          bool is1080pVideo(CameraDeviceFormat f) =>
              (f.videoWidth == 1920 && f.videoHeight == 1080);
          final a1080V = is1080pVideo(a);
          final b1080V = is1080pVideo(b);
          if (a1080V && !b1080V) return -1;
          if (b1080V && !a1080V) return 1;
          return (b.photoWidth * b.photoHeight).compareTo(
            a.photoWidth * a.photoHeight,
          );
        });
        _currentFormat = formats.isNotEmpty ? formats.first : null;
      }

      await _controller.initialize(
        _currentDevice!,
        format: _currentFormat,
        enablePhoto: true,
        enableVideo: true,
        // One flag drives BOTH the preview and the saved image: true = selfie
        // mirror, false = save what the camera actually sees.
        mirror: true,
      );

      // Start FPS counter via frame processor
      await _controller.setFrameProcessor((frame) {
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

      await _controller.setActive(true);

      _zoom = _currentDevice!.neutralZoom;
      setState(() => _isInitialized = true);
    } catch (e) {
      debugPrint("Start error: $e");
    }
  }

  Future<void> _capture() async {
    try {
      if (_isVideo) {
        if (_controller.value == CameraState.recording) {
          await _controller.stopRecording();
          // Path is already in _lastMediaPath from startRecording
        } else {
          final tempDir = await getTemporaryDirectory();
          final path =
              '${tempDir.path}/${DateTime.now().millisecondsSinceEpoch}.mp4';
          await _controller.startRecording(path);
          _lastMediaPath = path;
        }
      } else {
        final photo = await _controller.takePhoto();
        setState(() => _lastMediaPath = photo.path);
      }
    } catch (e) {
      debugPrint("Capture error: $e");
    }
  }

  Widget _buildTopControls() {
    return Positioned(
      top: 48,
      left: 16,
      right: 16,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          IconButton(
            icon: Icon(
              _controller.torch == 'on' ? Icons.flash_on : Icons.flash_off,
              color: Colors.white,
            ),
            onPressed: () {
              final newMode = _controller.torch == 'on' ? 'off' : 'on';
              _controller.setTorch(newMode);
              setState(() {});
            },
          ),
          Text(
            _currentDevice?.position.toString().split('.').last.toUpperCase() ??
                "CAMERA",
            style: const TextStyle(
              color: Colors.white,
              fontWeight: FontWeight.bold,
              letterSpacing: 2,
            ),
          ),
          const SizedBox(width: 48), // Balance for flash icon
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_error != null) {
      return Scaffold(
        backgroundColor: Colors.black,
        body: Center(
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const Icon(
                  Icons.error_outline,
                  color: Colors.redAccent,
                  size: 64,
                ),
                const SizedBox(height: 16),
                Text(
                  _error!,
                  textAlign: TextAlign.center,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
                const SizedBox(height: 32),
                ElevatedButton(
                  onPressed: () {
                    setState(() => _error = null);
                    _initialize();
                  },
                  child: const Text("Retry"),
                ),
              ],
            ),
          ),
        ),
      );
    }
    return ValueListenableBuilder<CameraState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        return Scaffold(
          backgroundColor: Colors.black,
          body: Stack(
            children: [
              if (_isInitialized)
                // CameraPreview self-orients via controller.previewRotation —
                // no AspectRatio/RotatedBox compensation needed here.
                Positioned.fill(
                  child: CameraPreview(
                    controller: _controller,
                    // Fit the whole frame inside the view (letterboxed) so the
                    // full image is visible instead of cropped to fill.
                    resizeMode: ResizeMode.contain,
                    onTapToFocus: true,
                  ),
                )
              else
                const Center(child: CircularProgressIndicator()),

              _buildTopControls(),
              _buildFPSCounter(),
              _buildBottomControls(state),
              _buildZoomSlider(),
            ],
          ),
        );
      },
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

  Widget _buildZoomSlider() {
    if (_currentDevice == null || !_isInitialized) return const SizedBox();
    return Positioned(
      right: 16,
      top: 100,
      bottom: 150,
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          RotatedBox(
            quarterTurns: 3,
            child: SizedBox(
              width: 150,
              child: Slider(
                activeColor: Colors.white,
                inactiveColor: Colors.white24,
                value: _zoom,
                min: _currentDevice!.minZoom,
                max: _currentDevice!.maxZoom.clamp(
                  _currentDevice!.minZoom,
                  10.0,
                ),
                onChanged: (v) {
                  _controller.setZoom(v);
                  setState(() => _zoom = v);
                },
              ),
            ),
          ),
          const SizedBox(height: 10),
          Text(
            "${_zoom.toStringAsFixed(1)}x",
            style: const TextStyle(color: Colors.white, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildBottomControls(CameraState state) {
    final isRecording = state == CameraState.recording;
    return Positioned(
      bottom: 40,
      left: 0,
      right: 0,
      child: Column(
        children: [
          // Mode Switcher
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildModeButton("PHOTO", !_isVideo),
              const SizedBox(width: 40),
              _buildModeButton("VIDEO", _isVideo),
            ],
          ),
          const SizedBox(height: 30),
          // Main controls
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceEvenly,
            children: [
              // Thumbnail
              _buildThumbnail(),

              // Shutter
              GestureDetector(
                onTap: _capture,
                child: Container(
                  width: 80,
                  height: 80,
                  padding: const EdgeInsets.all(4),
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    border: Border.all(color: Colors.white, width: 4),
                  ),
                  child: Container(
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: isRecording ? Colors.red : Colors.white,
                    ),
                    child: isRecording
                        ? const Icon(Icons.stop, color: Colors.white)
                        : null,
                  ),
                ),
              ),

              // Switch Camera
              IconButton(
                onPressed: _switchCamera,
                iconSize: 32,
                icon: const Icon(Icons.flip_camera_ios, color: Colors.white),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildModeButton(String label, bool active) {
    return GestureDetector(
      onTap: () {
        if (active) return;
        setState(() => _isVideo = label == "VIDEO");
      },
      child: Column(
        children: [
          Text(
            label,
            style: TextStyle(
              color: active ? Colors.amber : Colors.white60,
              fontWeight: FontWeight.bold,
              fontSize: 14,
            ),
          ),
          if (active)
            Container(
              margin: const EdgeInsets.only(top: 4),
              height: 4,
              width: 4,
              decoration: const BoxDecoration(
                color: Colors.amber,
                shape: BoxShape.circle,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildThumbnail() {
    return GestureDetector(
      onTap: () async {
        if (_lastMediaPath != null) {
          if (_controller.value == CameraState.recording) {
            await _controller.stopRecording();
          }
          await _controller.setActive(false);
          if (mounted) {
            await Navigator.push(
              context,
              MaterialPageRoute(
                builder: (_) => DetailedPhotoViewer(path: _lastMediaPath!),
              ),
            );
            if (mounted) {
              await _controller.setActive(true);
              setState(() {});
            }
          }
        }
      },
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          color: Colors.white10,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: Colors.white24, width: 1),
          image:
              _lastMediaPath != null &&
                  !_lastMediaPath!.toLowerCase().endsWith('.mp4')
              ? DecorationImage(
                  image: FileImage(File(_lastMediaPath!)),
                  fit: BoxFit.cover,
                )
              : null,
        ),
        child:
            _lastMediaPath != null &&
                _lastMediaPath!.toLowerCase().endsWith('.mp4')
            ? const Icon(Icons.videocam, color: Colors.white)
            : (_lastMediaPath == null
                  ? const Icon(Icons.photo, color: Colors.white24)
                  : null),
      ),
    );
  }

  Future<void> _switchCamera() async {
    if (_devices.isEmpty) return;
    final currentIdx = _devices.indexOf(_currentDevice!);
    final nextIdx = (currentIdx + 1) % _devices.length;
    setState(() {
      _currentDevice = _devices[nextIdx];
      _currentFormat = null;
    });
    await _startCamera();
  }
}
