// lib/ocr/ocr_engine.dart
//
// Pluggable OCR engine interface + a shared temp-file helper.

import 'dart:io';
import 'dart:typed_data';
import 'ocr_types.dart';

abstract class OcrEngine {
  /// Stable id used in consensus maps: 'mlkit' | 'tesseract' | 'paddle'.
  String get id;

  /// Whether this engine can run in the current environment.
  bool get isAvailable;

  /// Run OCR on raw image bytes, returning ordered lines.
  Future<OcrResult> detect(Uint8List imageBytes);
}

int _tmpCounter = 0;

/// Write bytes to a temp jpg so engines that only accept a File path can run.
Future<File> ocrTempFile(Uint8List bytes) async {
  final f = File(
      '${Directory.systemTemp.path}/clo_ocr_${++_tmpCounter}.jpg');
  await f.writeAsBytes(bytes);
  return f;
}
