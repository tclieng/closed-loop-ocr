// test/ocr/ocr_extractor_test.dart
//
// Verifies the consensus -> ExtractionTrace -> DecisionPolicy chain with
// synthetic engine results (no device needed).

import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:closed_loop_ocr/ocr/ocr_engine.dart';
import 'package:closed_loop_ocr/ocr/ocr_types.dart';
import 'package:closed_loop_ocr/ocr/consensus.dart';
import 'package:closed_loop_ocr/ocr/ocr_extractor.dart';
import 'package:closed_loop_ocr/policy/decision_policy.dart';
import 'package:closed_loop_ocr/policy/extraction_trace.dart';

/// Minimal engine double: returns canned lines, optionally records calls, and
/// can be made to throw if (e.g.) it must not be invoked.
class _MockEngine extends OcrEngine {
  final String _id;
  final List<OcrLine> lines;
  final bool throwsOnDetect;
  int detectCalls = 0;
  _MockEngine(this._id, this.lines, {this.throwsOnDetect = false});

  @override
  String get id => _id;
  @override
  bool get isAvailable => true;
  @override
  Future<OcrResult> detect(Uint8List imageBytes) async {
    detectCalls++;
    if (throwsOnDetect) throw StateError('$id must not be invoked');
    return OcrResult(id, lines);
  }
}

void main() {
  test('OcrExtractor -> policy: 3/3 agreement (critical) -> GREEN', () {
    final extractor =
        OcrExtractor(consensus: ConsensusOcr(primary: []), defaultRisk: FieldRisk.critical);
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
        OcrExtractor(consensus: ConsensusOcr(primary: []), defaultRisk: FieldRisk.critical);
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
        OcrExtractor(consensus: ConsensusOcr(primary: []), defaultRisk: FieldRisk.high);
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

  group('selective Paddle (detailed) tie-breaker', () {
    test('primary fully agree -> detailed NOT invoked', () async {
      final ml = _MockEngine('mlkit', [OcrLine('TOTAL 12.00')]);
      final tess = _MockEngine('tesseract', [OcrLine('TOTAL 12.00')]);
      final paddle =
          _MockEngine('paddle', [OcrLine('TOTAL 12.00')], throwsOnDetect: true);
      final consensus =
          ConsensusOcr(primary: [ml, tess], detailed: [paddle]);
      final results =
          await consensus.runRaw(Uint8List.fromList([1, 2, 3]));
      expect(paddle.detectCalls, 0); // Paddle never ran
      expect(results.length, 2); // only mlkit + tesseract
      expect(results.map((r) => r.engineId).toList(),
          ['mlkit', 'tesseract']);
    });

    test('primary disagree -> detailed invoked (whole-line engine is ref)',
        () async {
      // mlkit (most lines) is the reference skeleton. Its TOTAL line pairs
      // with paddle's identical reading (agree 2/3); tesseract's DATE line is
      // dissimilar (sim 0.33 < 0.40) so it stays a separate single-engine
      // row -> the primaries genuinely disagree -> Paddle runs as the
      // tie-breaker. No false agreement is manufactured.
      final ml = _MockEngine('mlkit',
          [OcrLine('TOTAL 12.00'), OcrLine('OTHER')]);
      final tess = _MockEngine('tesseract', [OcrLine('DATE 01/09/2026')]);
      final paddle = _MockEngine('paddle', [OcrLine('TOTAL 12.00')]);
      final consensus =
          ConsensusOcr(primary: [ml, tess], detailed: [paddle]);
      final results =
          await consensus.runRaw(Uint8List.fromList([1, 2, 3]));
      expect(paddle.detectCalls, 1); // Paddle ran as tie-breaker
      expect(results.length, 3);
      final lines = ConsensusOcr.align(results);
      // 2/3 majority resolves the TOTAL line to the correct reading.
      final total = lines.firstWhere((l) => l.text == 'TOTAL 12.00');
      expect(total.agreement, 2);
      expect(total.total, 3);
      // The dissimilar DATE line stays a separate single-engine row.
      final dateRow = lines.firstWhere((l) => l.text == 'DATE 01/09/2026');
      expect(dateRow.agreement, 1);
      expect(dateRow.perEngine.keys, contains('tesseract'));
    });
  });
}
