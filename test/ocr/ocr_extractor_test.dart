// test/ocr/ocr_extractor_test.dart
//
// Verifies the consensus -> ExtractionTrace -> DecisionPolicy chain with
// synthetic engine results (no device needed).

import 'package:flutter_test/flutter_test.dart';
import 'package:closed_loop_ocr/ocr/ocr_types.dart';
import 'package:closed_loop_ocr/ocr/consensus.dart';
import 'package:closed_loop_ocr/ocr/ocr_extractor.dart';
import 'package:closed_loop_ocr/policy/decision_policy.dart';
import 'package:closed_loop_ocr/policy/extraction_trace.dart';

void main() {
  test('OcrExtractor -> policy: 3/3 agreement (critical) -> GREEN', () {
    final extractor =
        OcrExtractor(ConsensusOcr([]), defaultRisk: FieldRisk.critical);
    final results = [
      OcrResult('mlkit', [OcrLine('100.00')]),
      OcrResult('tesseract', [OcrLine('100.00')]),
      OcrResult('paddle', [OcrLine('100.00')]),
    ];
    final trace = extractor.fromResults(results, receiptId: 'rx', supplier: 'X');
    final decision = DecisionPolicy(1, const DecisionPolicyConfig())
        .decide(trace);
    expect(decision.fields.length, 1);
    expect(decision.fields.first.status, FieldStatus.green);
    // All three engines should have contributed to the consensus.
    expect(decision.fields.first.enginesTotal, 3);
    expect(decision.fields.first.confidenceAvg, greaterThanOrEqualTo(0.9));
  });

  test('OcrExtractor -> policy: 2/3 on critical -> RED (needs 3/3)', () {
    final extractor =
        OcrExtractor(ConsensusOcr([]), defaultRisk: FieldRisk.critical);
    final results = [
      OcrResult('mlkit', [OcrLine('100.00')]),
      OcrResult('tesseract', [OcrLine('100.00')]),
      OcrResult('paddle', [OcrLine('100.60')]),
    ];
    final trace = extractor.fromResults(results, receiptId: 'rx', supplier: 'X');
    final decision = DecisionPolicy(1, const DecisionPolicyConfig())
        .decide(trace);
    expect(decision.fields.first.status, FieldStatus.red);
  });

  test('OcrExtractor -> policy: 2/3 on high -> GREEN/YELLOW (2-of-3 ok)', () {
    final extractor =
        OcrExtractor(ConsensusOcr([]), defaultRisk: FieldRisk.high);
    final results = [
      OcrResult('mlkit', [OcrLine('INV-1')]),
      OcrResult('tesseract', [OcrLine('INV-1')]),
      OcrResult('paddle', [OcrLine('INV-2')]),
    ];
    final trace = extractor.fromResults(results, receiptId: 'rx', supplier: 'X');
    final decision = DecisionPolicy(1, const DecisionPolicyConfig())
        .decide(trace);
    final st = decision.fields.first.status;
    expect(st == FieldStatus.green || st == FieldStatus.yellow, isTrue);
  });
}
