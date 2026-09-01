import 'dart:io';
import 'package:path/path.dart' as p;
import 'package:path_provider/path_provider.dart';

/// Service for managing local image storage (SD card / internal storage).
class SdCardService {
  static final SdCardService _instance = SdCardService._();
  factory SdCardService() => _instance;
  SdCardService._();

  static const String _folderName = 'IntelliOCR';
  static const String _captureSubfolder = 'Captures';
  static const String _masterSubfolder = 'Masters';

  /// Get the base IntelliOCR photos directory.
  Future<String> getBasePath() async {
    // Try external storage first (SD card / shared pictures)
    try {
      // On Android 10+, use app-specific external storage
      final extDir = await getExternalStorageDirectory();
      if (extDir != null) {
        final dir = Directory('${extDir.path}/$_folderName');
        if (!await dir.exists()) await dir.create(recursive: true);
        return dir.path;
      }
    } catch (_) {}

    // Fallback to app documents directory
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/$_folderName');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Get the captures subfolder path.
  Future<String> getCapturesPath() async {
    final base = await getBasePath();
    final dir = Directory('$base/$_captureSubfolder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Get the master template images subfolder path.
  Future<String> getMastersPath() async {
    final base = await getBasePath();
    final dir = Directory('$base/$_masterSubfolder');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Save a captured image to the captures folder.
  Future<String> saveCapture(File sourceImage) async {
    final capturesPath = await getCapturesPath();
    final timestamp = DateTime.now().millisecondsSinceEpoch;
    final filename = 'CAP_${timestamp}_${p.basename(sourceImage.path)}';
    final dest = File('$capturesPath/$filename');
    await sourceImage.copy(dest.path);
    return dest.path;
  }

  /// Save a master receipt image for template creation.
  Future<String> saveMasterImage(File sourceImage, String supplierName) async {
    final mastersPath = await getMastersPath();
    final safeName = supplierName.replaceAll(RegExp(r'[^\w]'), '_');
    final filename = '${safeName}_master.jpg';
    final dest = File('$mastersPath/$filename');
    await sourceImage.copy(dest.path);
    return dest.path;
  }

  /// List all captured images, sorted by newest first.
  Future<List<File>> listCaptures() async {
    final path = await getCapturesPath();
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    final files = dir.listSync().whereType<File>().toList();
    files.sort((a, b) => b.lastModifiedSync().compareTo(a.lastModifiedSync()));
    return files;
  }

  /// List all master template images.
  Future<List<File>> listMasterImages() async {
    final path = await getMastersPath();
    final dir = Directory(path);
    if (!await dir.exists()) return [];
    return dir.listSync().whereType<File>().toList();
  }

  /// Delete a captured image.
  Future<void> deleteFile(String path) async {
    final file = File(path);
    if (await file.exists()) await file.delete();
  }

  /// Get the total number of captured images.
  Future<int> countCaptures() async {
    final files = await listCaptures();
    return files.length;
  }
}
