// lib/ocr/tesseract_engine.dart
//
// Tesseract engine adapter. Wraps v36 OcrService. Tesseract via the Flutter
// plugin returns full-page text (no per-line bboxes), so lines carry no bbox
// or per-line confidence; the consensus aligner falls back to reading-order
// matching, and OcrExtractor boosts confidence when Tesseract's text agrees
// with the majority.

import 'dart:typed_data';

import '../services/ocr_service.dart';
import 'ocr_engine.dart';
import 'ocr_types.dart';

class TesseractEngine extends OcrEngine {
  @override
  String get id => 'tesseract';

  @override
  bool get isAvailable => true;

  @override
  Future<OcrResult> detect(Uint8List imageBytes) async {
    final file = await ocrTempFile(imageBytes);
    final text = await OcrService().recognizeFullTesseract(file);
    final lines = text
        .split('\n')
        .map((s) => s.trim())
        .where((s) => s.isNotEmpty)
        .map((s) => OcrLine(s))
        .toList();
    return OcrResult(id, lines);
  }
}
