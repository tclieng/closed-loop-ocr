// lib/benchmark/extractor.dart
//
// Pluggable extractor interface + a MockExtractor that produces
// synthetic ExtractionTraces with controllable quality. The mock lets
// us validate the harness + policy end-to-end before any real OCR
// engine (PaddleOCR, etc.) is wired in; once it is, you swap the
// mock for the real extractor and the same harness measures it.

import 'dart:math';

import 'dataset.dart';
import '../policy/extraction_trace.dart';

typedef ReceiptExtractor = Future<ExtractionTrace> Function(LabeledReceipt);

class MockExtractor {
  /// P(receipt is fully clean: every field is 3/3 engines agree, high conf).
  final double cleanRate;
  /// Per-field P(good | not clean) -> 3/3 engines agree, high conf.
  final double goodRate;
  /// Per-field P(partial | not clean) -> 2/3 engines agree, 1 wrong.
  /// Remainder = 1/3 (only one engine correct, majority wrong).
  final double partialRate;
  final Random _rng;

  MockExtractor({
    this.cleanRate = 0.5,
    this.goodRate = 0.6,
    this.partialRate = 0.25,
    int? seed,
  }) : _rng = Random(seed);

  Future<ExtractionTrace> extract(LabeledReceipt r) async {
    final isClean = _rng.nextDouble() < cleanRate;
    final templateOk = _rng.nextDouble() > 0.05; // 5% template miss -> RED
    return ExtractionTrace(
      receiptId: r.id,
      supplierGuess: r.supplier,
      supplierConfidence: 0.7 + _rng.nextDouble() * 0.3,
      matchedTemplateId:
          templateOk ? 'tpl_${(r.supplier ?? "unknown").replaceAll(" ", "_")}' : null,
      matchedTemplateVersion: templateOk ? 1 : null,
      templateMatchScore:
          templateOk ? 0.7 + _rng.nextDouble() * 0.3 : 0.2,
      imageQualityScore: 0.4 + _rng.nextDouble() * 0.6,
      fields: r.fields
          .map((lbl) => isClean ? _allGood(lbl) : _synthField(lbl))
          .toList(),
      validations: const [],
      anchors: const [],
      duplicateDetected: false,
    );
  }

  FieldExtraction _allGood(FieldLabel lbl) => FieldExtraction(
        lbl.fieldKey,
        lbl.risk,
        [
          EngineFieldResult('mlkit', lbl.expected, 0.96),
          EngineFieldResult('tesseract', lbl.expected, 0.94),
          EngineFieldResult('paddle', lbl.expected, 0.97),
        ],
      );

  FieldExtraction _synthField(FieldLabel lbl) {
    final roll = _rng.nextDouble();
    final List<EngineFieldResult> results;
    if (roll < goodRate) {
      results = [
        EngineFieldResult('mlkit', lbl.expected, 0.96),
        EngineFieldResult('tesseract', lbl.expected, 0.94),
        EngineFieldResult('paddle', lbl.expected, 0.97),
      ];
    } else if (roll < goodRate + partialRate) {
      // 2/3 agree on expected, 1 gives a perturbed value.
      results = [
        EngineFieldResult('mlkit', lbl.expected, 0.90),
        EngineFieldResult('tesseract', lbl.expected, 0.88),
        EngineFieldResult('paddle', _perturb(lbl), 0.70),
      ];
    } else {
      // 1/3: only mlkit is correct, tesseract+paddle are wrong.
      results = [
        EngineFieldResult('mlkit', lbl.expected, 0.85),
        EngineFieldResult('tesseract', _perturb(lbl), 0.65),
        EngineFieldResult('paddle', _perturb(lbl), 0.62),
      ];
    }
    return FieldExtraction(lbl.fieldKey, lbl.risk, results);
  }

  String _perturb(FieldLabel lbl) {
    if (lbl.type == FieldType.numeric) {
      final n = _parseNum(lbl.expected);
      if (n == null) return '${lbl.expected}x';
      final perturbed =
          (n * (0.92 + _rng.nextDouble() * 0.16)).toStringAsFixed(2);
      return perturbed;
    }
    return '${lbl.expected}*';
  }

  double? _parseNum(String s) => double.tryParse(
      s.replaceAll(',', '').replaceAll(RegExp(r'[^\d.\-]'), ''));
}
