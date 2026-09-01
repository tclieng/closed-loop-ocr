// lib/benchmark/runner.dart
//
// Runs a BenchmarkDataset through (extractor -> DecisionPolicy) and
// accumulates BenchmarkMetrics.

import 'dataset.dart';
import 'extractor.dart';
import 'metrics.dart';
import '../policy/decision_policy.dart';
import '../policy/extraction_trace.dart';

class BenchmarkRunner {
  final DecisionPolicy policy;
  final ReceiptExtractor extractor;
  static const int _maxRedSamples = 5;

  BenchmarkRunner({required this.policy, required this.extractor});

  Future<BenchmarkMetrics> run(BenchmarkDataset ds) async {
    int green = 0, yellow = 0, red = 0;
    int autoAcceptCorrect = 0, autoAcceptTotal = 0;
    final fieldStats = <String, _FieldStat>{};
    final engineAppearances = <String, int>{};
    final redSamples = <String>[];

    for (final lr in ds.receipts) {
      final trace = await extractor(lr);
      final decision = policy.decide(trace);

      switch (decision.overall) {
        case ReceiptStatus.green:
          green++;
          break;
        case ReceiptStatus.yellow:
          yellow++;
          break;
        case ReceiptStatus.red:
        case ReceiptStatus.rejected:
          red++;
          break;
      }

      final fdByKey = {
        for (final fd in decision.fields) fd.fieldKey: fd,
      };
      final isAuto = decision.isGreen || decision.isYellow;
      bool allFinancialMatch = true;

      for (final lbl in lr.fields) {
        final fd = fdByKey[lbl.fieldKey];
        final got = fd?.consensusText;
        final ok = fieldMatches(got, lbl);

        final stat = fieldStats.putIfAbsent(
            lbl.fieldKey, () => _FieldStat(lbl.fieldKey));
        stat.total++;
        if (ok) stat.correct++;
        if (fd != null) {
          if (fd.status == FieldStatus.green) stat.green++;
          if (fd.status == FieldStatus.yellow) stat.yellow++;
          if (fd.status == FieldStatus.red) stat.red++;
        }
        if (!ok) {
          final key = '${got ?? "<null>"}→${lbl.expected}';
          stat.mismatches[key] = (stat.mismatches[key] ?? 0) + 1;
        }
        if (isAuto &&
            (lbl.risk == FieldRisk.critical || lbl.risk == FieldRisk.high) &&
            !ok) {
          allFinancialMatch = false;
        }
      }
      if (isAuto) {
        autoAcceptTotal++;
        if (allFinancialMatch) autoAcceptCorrect++;
      }

      for (final fe in trace.fields) {
        for (final er in fe.engineResults) {
          engineAppearances[er.engine] =
              (engineAppearances[er.engine] ?? 0) + 1;
        }
      }

      if (decision.overall == ReceiptStatus.red &&
          redSamples.length < _maxRedSamples) {
        redSamples.add(decision.rationale);
      }
    }

    return BenchmarkMetrics(
      dataset: ds.name,
      policyVersion: policy.version,
      totalReceipts: ds.receipts.length,
      greenCount: green,
      yellowCount: yellow,
      redCount: red,
      autoAcceptCorrect: autoAcceptCorrect,
      autoAcceptTotal: autoAcceptTotal,
      fieldMetrics: {
        for (final e in fieldStats.entries) e.key: e.value.toMetric(),
      },
      engineAppearances: engineAppearances,
      decisionSamples: redSamples,
    );
  }
}

class _FieldStat {
  final String fieldKey;
  int total = 0, correct = 0;
  int green = 0, yellow = 0, red = 0;
  final Map<String, int> mismatches = {};
  _FieldStat(this.fieldKey);
  FieldMetric toMetric() => FieldMetric(
        fieldKey: fieldKey,
        total: total,
        correct: correct,
        green: green,
        yellow: yellow,
        red: red,
        mismatches: mismatches,
      );
}
