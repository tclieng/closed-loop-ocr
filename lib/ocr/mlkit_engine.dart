// lib/ocr/mlkit_engine.dart
//
// ML Kit engine adapter. Wraps the existing v36 OcrService so it conforms to
// the OcrEngine interface. Provides per-line bounding boxes (used by the
// consensus aligner when other engines also expose bboxes).

import 'dart:typed_data';

import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import '../services/ocr_service.dart';
import 'ocr_engine.dart';
import 'ocr_types.dart';

class MlKitEngine extends OcrEngine {
  @override
  String get id => 'mlkit';

  @override
  bool get isAvailable => true; // ML Kit is always available on-device

  @override
  Future<OcrResult> detect(Uint8List imageBytes) async {
    final file = await ocrTempFile(imageBytes);
    final RecognizedText? recognized =
        await OcrService().recognizeDetailed(file);
    if (recognized == null) return OcrResult(id, const []);
    final lines = <OcrLine>[];
    for (final block in recognized.blocks) {
      for (final line in block.lines) {
        lines.add(OcrLine(
          line.text,
          bbox: OcrBBox.fromRect(line.boundingBox),
        ));
      }
    }
    return OcrResult(id, lines);
  }
}
