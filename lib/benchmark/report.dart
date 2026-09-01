// lib/benchmark/report.dart
//
// Human-readable report formatter for BenchmarkMetrics.

import 'metrics.dart';

String formatReport(BenchmarkMetrics m) {
  final b = StringBuffer();
  b.writeln('=== Benchmark: ${m.dataset} (policy v${m.policyVersion}) ===');
  b.writeln('Receipts: ${m.totalReceipts}');
  b.writeln('GREEN:   ${m.greenCount} (${pct(m.greenRate)})');
  b.writeln('YELLOW:  ${m.yellowCount} (${pct(m.yellowRate)})');
  b.writeln('RED:     ${m.redCount} (${pct(m.redRate)})');
  b.writeln(
      'Auto-accept accuracy: ${m.autoAcceptCorrect}/${m.autoAcceptTotal} '
      '(${pct(m.autoAcceptAccuracy)})');
  b.writeln('');
  b.writeln('Per-field (sorted by accuracy, worst first):');
  final sorted = m.fieldMetrics.values.toList()
    ..sort((a, b) => a.accuracy.compareTo(b.accuracy));
  for (final f in sorted) {
    final top = f.mismatches.entries
        .take(2)
        .map((e) => '"${e.key}"(${e.value})')
        .join(', ');
    b.writeln(
        '  ${f.fieldKey.padRight(20)} acc=${pct(f.accuracy).padLeft(6)} '
        '[G=${f.green} Y=${f.yellow} R=${f.red}]  top: $top');
  }
  b.writeln('');
  b.writeln('Engine appearances: ${m.engineAppearances}');
  if (m.decisionSamples.isNotEmpty) {
    b.writeln('');
    b.writeln('Sample RED rationales:');
    for (final s in m.decisionSamples) {
      b.writeln('  - $s');
    }
  }
  return b.toString();
}

String pct(double x) => '${(x * 100).toStringAsFixed(1)}%';
