import 'dart:io';
import 'package:flutter/material.dart';
import 'package:video_player/video_player.dart';

class DetailedPhotoViewer extends StatefulWidget {
  final String path;

  const DetailedPhotoViewer({super.key, required this.path});

  @override
  State<DetailedPhotoViewer> createState() => _DetailedPhotoViewerState();
}

class _DetailedPhotoViewerState extends State<DetailedPhotoViewer>
    with WidgetsBindingObserver {
  VideoPlayerController? _videoController;
  bool _isInitialized = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    if (widget.path.toLowerCase().endsWith('.mp4')) {
      _videoController = VideoPlayerController.file(File(widget.path))
        ..initialize().then((_) {
          if (!mounted) return;
          setState(() {
            _isInitialized = true;
          });
          _videoController?.play();
          _videoController?.setLooping(true);
        });
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _videoController?.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_videoController == null || !_isInitialized) return;

    if (state == AppLifecycleState.inactive ||
        state == AppLifecycleState.paused) {
      _videoController?.pause();
    } else if (state == AppLifecycleState.resumed) {
      if (mounted) {
        _videoController?.play();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final isVideo = widget.path.toLowerCase().endsWith('.mp4');

    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        title: Text(isVideo ? 'Video Viewer' : 'Photo Viewer'),
        backgroundColor: Colors.black,
        foregroundColor: Colors.white,
      ),
      body: Center(child: isVideo ? _buildVideoPlayer() : _buildImageViewer()),
      floatingActionButton: isVideo && _isInitialized
          ? FloatingActionButton(
              onPressed: () {
                setState(() {
                  _videoController!.value.isPlaying
                      ? _videoController!.pause()
                      : _videoController!.play();
                });
              },
              child: Icon(
                _videoController!.value.isPlaying
                    ? Icons.pause
                    : Icons.play_arrow,
              ),
            )
          : null,
    );
  }

  Widget _buildImageViewer() {
    return InteractiveViewer(
      minScale: 0.1,
      maxScale: 5.0,
      child: Image.file(
        File(widget.path),
        fit: BoxFit.contain,
        errorBuilder: (context, error, stackTrace) {
          return Center(
            child: Text(
              'Error loading image:\n$error',
              textAlign: TextAlign.center,
              style: const TextStyle(color: Colors.red),
            ),
          );
        },
      ),
    );
  }

  Widget _buildVideoPlayer() {
    if (!_isInitialized) {
      return const Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          CircularProgressIndicator(color: Colors.white),
          SizedBox(height: 20),
          Text('Initializing video...', style: TextStyle(color: Colors.white)),
        ],
      );
    }

    return AspectRatio(
      aspectRatio: _videoController!.value.aspectRatio,
      child: VideoPlayer(_videoController!),
    );
  }
}
