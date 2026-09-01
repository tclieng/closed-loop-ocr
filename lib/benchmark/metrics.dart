// lib/benchmark/metrics.dart
//
// Metrics produced by the benchmark runner.

class FieldMetric {
  final String fieldKey;
  final int total;
  final int correct;
  final int green;
  final int yellow;
  final int red;
  final Map<String, int> mismatches; // "got→expected" -> count
  const FieldMetric({
    required this.fieldKey,
    required this.total,
    required this.correct,
    required this.green,
    required this.yellow,
    required this.red,
    required this.mismatches,
  });
  double get accuracy => total == 0 ? 0 : correct / total;
  Map<String, dynamic> toJson() => {
        'field': fieldKey,
        'total': total,
        'correct': correct,
        'accuracy': double.parse(accuracy.toStringAsFixed(3)),
        'green': green,
        'yellow': yellow,
        'red': red,
        'top_mismatches': _topMismatches(3),
      };
  List<MapEntry<String, int>> _topMismatches(int n) {
    final e = mismatches.entries.toList()
      ..sort((a, b) => b.value.compareTo(a.value));
    return e.take(n).toList();
  }
}

class BenchmarkMetrics {
  final String dataset;
  final int policyVersion;
  final int totalReceipts;
  final int greenCount;
  final int yellowCount;
  final int redCount;
  /// Numerator: auto-accepted (G+Y) receipts whose financial fields
  /// (critical + high) are all correct.
  final int autoAcceptCorrect;
  /// Denominator: total auto-accepted (G+Y) receipts.
  final int autoAcceptTotal;
  final Map<String, FieldMetric> fieldMetrics;
  final Map<String, int> engineAppearances;
  final List<String> decisionSamples; // first N RED rationales
  const BenchmarkMetrics({
    required this.dataset,
    required this.policyVersion,
    required this.totalReceipts,
    required this.greenCount,
    required this.yellowCount,
    required this.redCount,
    required this.autoAcceptCorrect,
    required this.autoAcceptTotal,
    required this.fieldMetrics,
    required this.engineAppearances,
    required this.decisionSamples,
  });
  double get greenRate =>
      totalReceipts == 0 ? 0 : greenCount / totalReceipts;
  double get yellowRate =>
      totalReceipts == 0 ? 0 : yellowCount / totalReceipts;
  double get redRate => totalReceipts == 0 ? 0 : redCount / totalReceipts;
  /// The "100% accuracy" invariant on the auto-accept path.
  double get autoAcceptAccuracy =>
      autoAcceptTotal == 0 ? 0 : autoAcceptCorrect / autoAcceptTotal;
  Map<String, dynamic> toJson() => {
        'dataset': dataset,
        'policy_version': policyVersion,
        'total_receipts': totalReceipts,
        'green': greenCount,
        'yellow': yellowCount,
        'red': redCount,
        'green_rate': double.parse(greenRate.toStringAsFixed(3)),
        'yellow_rate': double.parse(yellowRate.toStringAsFixed(3)),
        'red_rate': double.parse(redRate.toStringAsFixed(3)),
        'auto_accept_total': autoAcceptTotal,
        'auto_accept_correct': autoAcceptCorrect,
        'auto_accept_accuracy':
            double.parse(autoAcceptAccuracy.toStringAsFixed(3)),
        'field_metrics':
            fieldMetrics.map((k, v) => MapEntry(k, v.toJson())),
        'engine_appearances': engineAppearances,
        'sample_red_decisions': decisionSamples,
      };
}
