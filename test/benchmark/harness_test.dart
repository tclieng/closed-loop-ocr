// test/benchmark/harness_test.dart
//
// End-to-end test of the benchmark harness against a synthetic dataset.
// Validates the harness mechanics AND the central invariant:
//   auto-accept accuracy == 1.0
// i.e. every receipt the policy auto-accepts has all financial fields
// correct. This is the "100% accuracy" guarantee made measurable.
//
// Run with:
//   flutter test test/benchmark/harness_test.dart

import 'package:flutter_test/flutter_test.dart';
import 'package:closed_loop_ocr/benchmark/dataset.dart';
import 'package:closed_loop_ocr/benchmark/extractor.dart';
import 'package:closed_loop_ocr/benchmark/runner.dart';
import 'package:closed_loop_ocr/benchmark/report.dart';
import 'package:closed_loop_ocr/policy/decision_policy.dart';
import 'package:closed_loop_ocr/policy/extraction_trace.dart';

void main() {
  test('benchmark harness: 100% guarantee + valid distribution', () async {
    final policy = DecisionPolicy(1, const DecisionPolicyConfig());
    final mock = MockExtractor(cleanRate: 0.7, goodRate: 0.6, partialRate: 0.25, seed: 42);
    final runner = BenchmarkRunner(policy: policy, extractor: mock.extract);
    final metrics = await runner.run(_syntheticDataset());

    // Print the report for visibility (shows up in `flutter test` output).
    // ignore: avoid_print
    print(formatReport(metrics));

    // --- Mechanics ---
    expect(metrics.totalReceipts, _syntheticDataset().receipts.length);
    expect(metrics.greenCount + metrics.yellowCount + metrics.redCount,
        metrics.totalReceipts);
    expect(metrics.fieldMetrics, isNotEmpty);
    expect(metrics.engineAppearances['mlkit'], greaterThan(0));
    expect(metrics.engineAppearances['tesseract'], greaterThan(0));
    expect(metrics.engineAppearances['paddle'], greaterThan(0));

    // --- The 100% guarantee ---
    // The mock only ever auto-accepts (GREEN) when ALL engines agree on
    // expected; and (YELLOW) high fields only when 2/3 agree on expected
    // (correct consensus). Therefore every auto-accepted receipt has all
    // critical+high fields correct -> autoAcceptAccuracy == 1.0.
    expect(metrics.autoAcceptAccuracy, 1.0,
        reason: 'Auto-accepted receipts must be 100% correct.');
    expect(metrics.autoAcceptTotal, greaterThan(0),
        reason: 'Need at least one auto-accepted receipt to verify the guarantee.');
  });
}

BenchmarkDataset _syntheticDataset() => BenchmarkDataset('synthetic_v1', [
      // ATAS FROZEN
      LabeledReceipt(
        id: 'r1',
        supplier: 'ATAS FROZEN MARKETING',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier,
              'INV-2026-0001'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '2026-08-15'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '1234.56'),
          FieldLabel('tax', FieldRisk.critical, FieldType.numeric, '74.07'),
        ],
      ),
      // ST ROSYAM
      LabeledReceipt(
        id: 'r2',
        supplier: 'ST ROSYAM',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier, 'SR-9981'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '15/08/2026'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '500.00'),
        ],
      ),
      // ATAS FROZEN
      LabeledReceipt(
        id: 'r3',
        supplier: 'ATAS FROZEN MARKETING',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier,
              'INV-2026-0002'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '2026-08-16'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '8900.00'),
          FieldLabel('tax', FieldRisk.critical, FieldType.numeric, '534.00'),
        ],
      ),
      // SYNERGY
      LabeledReceipt(
        id: 'r4',
        supplier: 'SYNERGY WORLDWIDE LOGISTICS',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier, 'SYN-445'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '2026-07-30'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '7000.00'),
        ],
      ),
      // LEE CHOON THAI
      LabeledReceipt(
        id: 'r5',
        supplier: 'LEE CHOON THAI',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier, 'LCT-22'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '17/08/2026'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '2300.00'),
        ],
      ),
      // LIM HENG LEONG
      LabeledReceipt(
        id: 'r6',
        supplier: 'LIM HENG LEONG',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier, 'LHL-22'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '17/08/2026'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '2300.00'),
        ],
      ),
      // ATAS FROZEN
      LabeledReceipt(
        id: 'r7',
        supplier: 'ATAS FROZEN MARKETING',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier,
              'INV-2026-0003'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '2026-08-18'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '1500.50'),
          FieldLabel('tax', FieldRisk.critical, FieldType.numeric, '90.03'),
        ],
      ),
      // ST ROSYAM
      LabeledReceipt(
        id: 'r8',
        supplier: 'ST ROSYAM',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier, 'SR-9982'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '18/08/2026'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '320.00'),
        ],
      ),
      // SYNERGY
      LabeledReceipt(
        id: 'r9',
        supplier: 'SYNERGY WORLDWIDE LOGISTICS',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier, 'SYN-446'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '2026-08-01'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '4500.00'),
        ],
      ),
      // ATAS FROZEN
      LabeledReceipt(
        id: 'r10',
        supplier: 'ATAS FROZEN MARKETING',
        fields: [
          FieldLabel('invoice_no', FieldRisk.high, FieldType.identifier,
              'INV-2026-0004'),
          FieldLabel('date', FieldRisk.high, FieldType.date, '2026-08-20'),
          FieldLabel('total', FieldRisk.critical, FieldType.numeric, '2100.00'),
        ],
      ),
    ]);
