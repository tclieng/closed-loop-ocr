import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:image/image.dart' as img;

/// Image preprocessing service for receipt enhancement and correction.
///
/// IMPORTANT: This is now a minimal, safe pipeline. Previous versions
/// ran aggressive auto-cropping, deskew, grayscale and contrast that
/// destroyed receipt content. We now only resize very large images and
/// otherwise pass the bytes through unchanged so the user sees exactly
/// what was captured — and so anchor ROI coords line up with text.
class ImageProcessor {
  // ── Main Processing Pipeline ──

  /// Run the (minimal) correction pipeline on a receipt image.
  static Future<Uint8List> processReceipt(Uint8List imageBytes) async {
    img.Image? image = img.decodeImage(imageBytes);
    if (image == null) throw Exception('Failed to decode image');

    // Only resize if the image is unreasonably large (keep memory low).
    // Do NOT auto-crop white borders, do NOT deskew, do NOT grayscale,
    // do NOT enhance contrast — all of those destroy receipts and break
    // anchor ROI positioning.
    const maxWidth = 1600;
    if (image.width > maxWidth) {
      image = img.copyResize(image, width: maxWidth);
    }

    return Uint8List.fromList(img.encodeJpg(image, quality: 92));
  }

  /// Run the (minimal) pipeline and save to file.
  static Future<File> processAndSave(File sourceFile) async {
    final bytes = await sourceFile.readAsBytes();
    final processed = await processReceipt(bytes);
    final dir = sourceFile.parent;
    final processedFile = File(
        '${dir.path}/${_processedName(sourceFile.uri.pathSegments.last)}');
    return processedFile.writeAsBytes(processed);
  }

  // ── Helpers retained for compatibility but no longer called ──

  // ignore: unused_element
  static img.Image _autoCropWhiteBorders(img.Image src) => src;

  // ignore: unused_element
  static img.Image _deskew(img.Image src) => src;

  // ignore: unused_element
  static double _estimateSkewAngle(img.Image gray) => 0.0;

  // ignore: unused_element
  static img.Image _denoise(img.Image src) => src;

  // ignore: unused_element
  static img.Image _enhance(img.Image src) => src;

  // ignore: unused_element
  static img.Image _normalize(img.Image src) => src;

  static String _processedName(String original) {
    final dot = original.lastIndexOf('.');
    if (dot == -1) return 'proc_$original';
    return '${original.substring(0, dot)}_proc${original.substring(dot)}';
  }

  // Avoid unused import warning for dart:math.
  // ignore: unused_field
  static final double _kPi = pi;
}