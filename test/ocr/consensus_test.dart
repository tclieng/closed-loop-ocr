// test/ocr/consensus_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:closed_loop_ocr/ocr/ocr_types.dart';
import 'package:closed_loop_ocr/ocr/consensus.dart';

void main() {
  test('align: 3/3 agreement -> majority text, agreement=3', () {
    final results = [
      OcrResult('mlkit', [OcrLine('TOTAL 100.00', confidence: 0.96)]),
      OcrResult('tesseract', [OcrLine('TOTAL 100.00', confidence: 0.94)]),
      OcrResult('paddle', [OcrLine('TOTAL 100.00', confidence: 0.97)]),
    ];
    final lines = ConsensusOcr.align(results);
    expect(lines.length, 1);
    expect(lines[0].text, 'TOTAL 100.00');
    expect(lines[0].agreement, 3);
    expect(lines[0].total, 3);
    expect(lines[0].perEngine['paddle'], 'TOTAL 100.00');
  });

  test('align: 2/3 majority wins; all 3 still matched to same line', () {
    final results = [
      OcrResult('mlkit', [OcrLine('100.00', confidence: 0.90)]),
      OcrResult('tesseract', [OcrLine('100.00', confidence: 0.88)]),
      OcrResult('paddle', [OcrLine('100.60', confidence: 0.70)]),
    ];
    final lines = ConsensusOcr.align(results);
    expect(lines.length, 1);
    expect(lines[0].text, '100.00'); // majority
    expect(lines[0].agreement, 3); // all engines matched this reference line
    expect(lines[0].perEngine['paddle'], '100.60'); // raw preserved
  });

  test('align: 1 vs 2 -> majority is the pair', () {
    final results = [
      OcrResult('mlkit', [OcrLine('100.00', confidence: 0.85)]),
      OcrResult('tesseract', [OcrLine('200.00', confidence: 0.65)]),
      OcrResult('paddle', [OcrLine('200.00', confidence: 0.62)]),
    ];
    final lines = ConsensusOcr.align(results);
    expect(lines.length, 1);
    expect(lines[0].text, '200.00');
    expect(lines[0].agreement, 3);
  });

  test('align: reading-order without bboxes', () {
    final results = [
      OcrResult('mlkit', [OcrLine('A'), OcrLine('B'), OcrLine('C')]),
      OcrResult('tesseract', [OcrLine('A'), OcrLine('B'), OcrLine('C')]),
    ];
    final lines = ConsensusOcr.align(results);
    expect(lines.map((l) => l.text).toList(), ['A', 'B', 'C']);
  });

  test('align: empty -> empty', () {
    expect(ConsensusOcr.align(const []), isEmpty);
  });

  test('textSimilarity sanity', () {
    expect(textSimilarity('100.00', '100.00'), 1.0);
    expect(textSimilarity('TOTAL 100', 'total 100'), 1.0); // normalized equal
    expect(textSimilarity('abc', 'xyz'), lessThan(0.5));
  });
}
