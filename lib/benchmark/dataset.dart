// lib/benchmark/dataset.dart
//
// Labeled dataset + field-type-aware comparison.
// Pure Dart, no Flutter / DB deps.

import 'package:intl/intl.dart';

import '../policy/extraction_trace.dart';

enum FieldType { string, numeric, date, identifier }

class FieldLabel {
  final String fieldKey;
  final FieldRisk risk;
  final FieldType type;
  final String expected;
  const FieldLabel(this.fieldKey, this.risk, this.type, this.expected);
}

class LabeledReceipt {
  final String id;
  final String? imageUri;
  final String? supplier;
  final List<FieldLabel> fields;
  const LabeledReceipt({
    required this.id,
    this.imageUri,
    this.supplier,
    this.fields = const [],
  });
}

class BenchmarkDataset {
  final String name;
  final List<LabeledReceipt> receipts;
  const BenchmarkDataset(this.name, this.receipts);
}

/// Field-type-aware equality. `got` is the policy's consensus_text (nullable).
bool fieldMatches(String? got, FieldLabel label) {
  if (got == null) return label.expected.trim().isEmpty;
  switch (label.type) {
    case FieldType.string:
      return _norm(got) == _norm(label.expected);
    case FieldType.identifier:
      final a = _norm(got).replaceAll(RegExp(r'[^a-z0-9]'), '');
      final b = _norm(label.expected).replaceAll(RegExp(r'[^a-z0-9]'), '');
      return a == b;
    case FieldType.numeric:
      final a = _parseNum(got);
      final b = _parseNum(label.expected);
      if (a == null || b == null) return false;
      final tol = b.abs() * 0.005 + 0.01; // 0.5% + 0.01 absolute
      return (a - b).abs() <= tol;
    case FieldType.date:
      final a = _parseDate(got);
      final b = _parseDate(label.expected);
      if (a == null || b == null) return false;
      return a.year == b.year && a.month == b.month && a.day == b.day;
  }
}

String _norm(String s) =>
    s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

double? _parseNum(String s) {
  final cleaned = s.replaceAll(',', '').replaceAll(RegExp(r'[^\d.\-]'), '');
  return double.tryParse(cleaned);
}

DateTime? _parseDate(String s) {
  final t = s.trim();
  for (final f in const [
    'yyyy-MM-dd',
    'dd/MM/yyyy',
    'dd-MM-yyyy',
    'dd MMM yyyy',
    'MM/dd/yyyy',
  ]) {
    try {
      return DateFormat(f).parseStrict(t);
    } catch (_) {
      // try next format
    }
  }
  return DateTime.tryParse(t);
}
