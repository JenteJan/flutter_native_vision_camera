import 'package:flutter/material.dart';
import 'package:flutter_native_vision_camera/flutter_native_vision_camera.dart';
import 'native_camera_page.dart';
import 'standard_camera_page.dart';
import 'code_scanner_page.dart';
import 'object_detector_page.dart';

import 'package:flutter/services.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  SystemChrome.setPreferredOrientations([DeviceOrientation.portraitUp]);
  initializeVisionCamera();

  // Showcase the C++ Standard Plugin Interface
  initializeNativeExamplePlugin();

  runApp(
    const MaterialApp(home: HomePage(), debugShowCheckedModeBanner: false),
  );
}

class HomePage extends StatefulWidget {
  const HomePage({super.key});

  @override
  State<HomePage> createState() => _HomePageState();
}

class _HomePageState extends State<HomePage> {
  @override
  void initState() {
    super.initState();
    _requestPermissions();
  }

  Future<void> _requestPermissions() async {
    await CameraPermissions.requestCameraPermission();
    await CameraPermissions.requestMicrophonePermission();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.grey[50],
      appBar: AppBar(
        title: const Text(
          'Vision Camera',
          style: TextStyle(fontWeight: FontWeight.bold, color: Colors.black),
        ),
        backgroundColor: Colors.white,
        elevation: 0,
        centerTitle: true,
      ),
      body: Padding(
        padding: const EdgeInsets.all(24.0),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Spacer(),
            _buildFeatureCard(
              context,
              title: 'Native Vision Camera',
              subtitle: 'FFI frame processor + live pixel read',
              icon: Icons.camera_enhance,
              color: Colors.blue,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const NativeCameraPage()),
                );
              },
            ),
            const SizedBox(height: 16),
            _buildFeatureCard(
              context,
              title: 'Barcode / QR Scanner',
              subtitle: 'MLKit on Android · Vision on iOS',
              icon: Icons.qr_code_scanner,
              color: Colors.green,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const CodeScannerPage()),
                );
              },
            ),
            const SizedBox(height: 16),
            _buildFeatureCard(
              context,
              title: 'Object Detector',
              subtitle: 'Frame processor → EfficientDet (90 classes) + boxes',
              icon: Icons.center_focus_strong,
              color: Colors.deepPurple,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const ObjectDetectorPage()),
                );
              },
            ),
            const SizedBox(height: 16),
            _buildFeatureCard(
              context,
              title: 'Standard Camera',
              subtitle: 'Official Flutter camera package',
              icon: Icons.camera,
              color: Colors.grey,
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (_) => const StandardCameraPage()),
                );
              },
            ),
            const Spacer(),
            const Text(
              'Compare the performance and latency between the native vision implementation and the standard camera package.',
              textAlign: TextAlign.center,
              style: TextStyle(color: Colors.grey, fontSize: 12),
            ),
            const SizedBox(height: 24),
          ],
        ),
      ),
    );
  }

  Widget _buildFeatureCard(
    BuildContext context, {
    required String title,
    required String subtitle,
    required IconData icon,
    required Color color,
    required VoidCallback onTap,
  }) {
    return Card(
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16)),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(16),
        child: Padding(
          padding: const EdgeInsets.all(20.0),
          child: Row(
            children: [
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: color.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(icon, color: color, size: 32),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: const TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      subtitle,
                      style: TextStyle(color: Colors.grey[600], fontSize: 13),
                    ),
                  ],
                ),
              ),
              const Icon(Icons.chevron_right, color: Colors.grey),
            ],
          ),
        ),
      ),
    );
  }
}
