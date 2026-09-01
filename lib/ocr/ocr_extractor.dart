// lib/ocr/ocr_extractor.dart
//
// OcrExtractor bridges the multi-engine OCR consensus to the Accuracy
// Contract. It implements the benchmark's ReceiptExtractor typedef, so the
// same harness that runs on MockExtractor can run on real consensus output.
//
// Key design point: the CONSENSUS arbitrates confidence. An engine whose
// reading matches the majority canonical text is assigned a high confidence
// (>= 0.97); a diverging engine is marked low (0.5). This lets the
// DecisionPolicy trust agreement without depending on per-engine confidence
// (which ML Kit / Tesseract do not expose per line).

import 'dart:io';
import '../benchmark/dataset.dart';
import 'consensus.dart';
import 'ocr_types.dart';
import '../policy/extraction_trace.dart';

class OcrExtractor {
  final ConsensusOcr consensus;
  final FieldRisk defaultRisk;

  OcrExtractor(this.consensus, {this.defaultRisk = FieldRisk.low});

  /// Build an ExtractionTrace from pre-collected engine results (no image
  /// needed). Used by the benchmark harness and unit tests.
  ExtractionTrace fromResults(
    List<OcrResult> results, {
    String? receiptId,
    String? supplier,
    double? supplierConf,
    double? quality,
    FieldRisk? risk,
  }) {
    final lines = ConsensusOcr.align(results);
    final r = risk ?? defaultRisk;
    final fields = <FieldExtraction>[];

    for (int i = 0; i < lines.length; i++) {
      final ln = lines[i];
      final canonical = normalizeText(ln.text);
      final ers = <EngineFieldResult>[];
      ln.perEngine.forEach((engine, raw) {
        final agrees = normalizeText(raw) == canonical;
        final rawConf = ln.perEngineConf[engine] ?? 0.5;
        final conf = agrees ? (rawConf > 0.97 ? rawConf : 0.97) : 0.5;
        ers.add(EngineFieldResult(engine, raw, conf));
      });
      fields.add(FieldExtraction('L$i', r, ers));
    }

    return ExtractionTrace(
      receiptId: receiptId ?? 'unknown',
      supplierGuess: supplier,
      supplierConfidence: supplierConf ?? 0.8,
      matchedTemplateId: null,
      matchedTemplateVersion: null,
      templateMatchScore: 0.8,
      imageQualityScore: quality ?? 0.8,
      fields: fields,
      validations: const [],
      anchors: const [],
      duplicateDetected: false,
    );
  }

  /// Full path: load the receipt image, run every available engine, align,
  /// and produce the trace.
  Future<ExtractionTrace> extract(LabeledReceipt r) async {
    if (r.imageUri == null) {
      return fromResults(const [], receiptId: r.id, supplier: r.supplier);
    }
    final bytes = await File(r.imageUri!).readAsBytes();
    final results = await consensus.runRaw(bytes);
    return fromResults(results, receiptId: r.id, supplier: r.supplier);
  }
}
