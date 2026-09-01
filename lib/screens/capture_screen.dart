import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:permission_handler/permission_handler.dart';
import '../services/sd_card_service.dart';
import '../services/image_processor.dart';

class CaptureScreen extends StatefulWidget {
  const CaptureScreen({super.key});

  @override
  State<CaptureScreen> createState() => _CaptureScreenState();
}

class _CaptureScreenState extends State<CaptureScreen> {
  final ImagePicker _picker = ImagePicker();
  final SdCardService _sdCard = SdCardService();
  String _status = '';
  int _savedCount = 0;

  @override
  void initState() {
    super.initState();
    _initPermissions();
  }

  Future<void> _initPermissions() async {
    final camera = await Permission.camera.request();
    await Permission.storage.request();
    if (!camera.isGranted) {
      setState(() => _status = 'Camera permission required');
    }
  }

  Future<void> _takePhoto() async {
    try {
      final photo = await _picker.pickImage(
        source: ImageSource.camera,
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (photo != null) {
        setState(() => _status = 'Processing image...');

        // Step 1: Preprocess the image (edge detection, perspective, etc.)
        final bytes = await File(photo.path).readAsBytes();
        Uint8List processedBytes;
        try {
          processedBytes = await ImageProcessor.processReceipt(bytes);
        } catch (_) {
          processedBytes = bytes; // keep original if preprocessing fails
        }

        // Save processed image to temp then copy
        final tempFile = File(photo.path.replaceAll('.jpg', '_proc.jpg'));
        await tempFile.writeAsBytes(processedBytes);

        // Step 2: Save to captures folder
        await _sdCard.saveCapture(tempFile);
        if (await tempFile.exists()) await tempFile.delete();

        setState(() {
          _savedCount++;
          _status = '✅ Saved to IntelliOCR/Captures/';
        });
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _pickFromGallery() async {
    try {
      final images = await _picker.pickMultiImage(
        maxWidth: 2048,
        maxHeight: 2048,
        imageQuality: 85,
      );
      if (images.isEmpty) return;
      setState(() => _status = 'Processing ${images.length} image(s)...');

      int saved = 0;
      for (final image in images) {
        try {
          final bytes = await File(image.path).readAsBytes();
          Uint8List processedBytes;
          try {
            processedBytes = await ImageProcessor.processReceipt(bytes);
          } catch (_) {
            processedBytes = bytes; // keep original if preprocessing fails
          }

          final tempFile = File(image.path.replaceAll('.jpg', '_proc.jpg'));
          await tempFile.writeAsBytes(processedBytes);

          await _sdCard.saveCapture(tempFile);
          if (await tempFile.exists()) await tempFile.delete();
          saved++;
        } catch (e) {
          // Continue with the rest of the batch instead of aborting everything.
          print('Gallery image skipped (error): $e');
        }
      }

      if (saved > 0) {
        setState(() {
          _savedCount += saved;
          _status = '✅ Saved $saved image(s) to IntelliOCR/Captures/';
        });
      } else {
        setState(() => _status = 'Error: could not process selected images');
      }
    } catch (e) {
      setState(() => _status = 'Error: $e');
    }
  }

  Future<void> _showSdCardPath() async {
    final path = await _sdCard.getCapturesPath();
    if (mounted) {
      showDialog(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('Captures Folder'),
          content: Text(path),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('OK'),
            ),
          ],
        ),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFF6B35),
      appBar: AppBar(
        title: const Text('Capture Receipt'),
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF6B35), Color(0xFFE85D2C)],
          ),
        ),
        child: SafeArea(
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                const SizedBox(height: 20),
                Icon(Icons.camera_alt, size: 64, color: Colors.white.withOpacity(0.9)),
                const SizedBox(height: 12),
                Text(
                  'Receipts saved: $_savedCount',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.w500,
                  ),
                ),
                const SizedBox(height: 32),

                // Take Photo button
                SizedBox(
                  width: double.infinity,
                  child: ElevatedButton.icon(
                    onPressed: _takePhoto,
                    icon: const Icon(Icons.camera_alt, size: 24),
                    label: const Text('Take Photo', style: TextStyle(fontSize: 16)),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFFB347),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                      elevation: 4,
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Choose from Gallery
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    onPressed: _pickFromGallery,
                    icon: const Icon(Icons.photo_library, size: 20),
                    label: const Text('Choose from Gallery', style: TextStyle(fontSize: 15)),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.white,
                      side: BorderSide(color: Colors.white.withOpacity(0.5)),
                      padding: const EdgeInsets.symmetric(vertical: 14),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(16),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 16),

                // Show SD Card Path
                TextButton(
                  onPressed: _showSdCardPath,
                  child: Text(
                    '📁 Show Captures Folder',
                    style: TextStyle(color: Colors.white.withOpacity(0.7)),
                  ),
                ),

                const SizedBox(height: 16),

                // Status
                if (_status.isNotEmpty)
                  Container(
                    width: double.infinity,
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.15),
                      borderRadius: BorderRadius.circular(12),
                    ),
                    child: Text(
                      _status,
                      style: TextStyle(
                        color: _status.startsWith('✅') ? Colors.green[200] : Colors.orange[200],
                        fontSize: 13,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
