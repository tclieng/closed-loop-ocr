// lib/policy/decision_policy.dart
//
// The GREEN / YELLOW / RED decision engine.
// Versioned — every decision records which policy version made it.
//
// This is the heart of the "100% accuracy" guarantee:
//   - No financial record is written without a decision.
//   - RED means "human must verify before this is persisted."
//   - The policy is deterministic given the trace + config, so we can
//     reproduce and audit any past decision.

import 'extraction_trace.dart';

class DecisionPolicyConfig {
  // --- Consensus (k-of-n engines must agree) and confidence thresholds
  //     per field risk class. ---
  final int criticalMinAgree; // e.g., 3
  final int highMinAgree; // e.g., 2
  final int mediumMinAgree; // e.g., 1
  final double criticalMinConf;
  final double highMinConf;
  final double mediumMinConf;
  final double lowMinConf;

  // --- Global gates (a single failure here forces RED). ---
  final double minSupplierConfidence;
  final double minTemplateMatchScore;
  final double minImageQuality;
  final bool duplicateIsRed;

  const DecisionPolicyConfig({
    this.criticalMinAgree = 3,
    this.highMinAgree = 2,
    this.mediumMinAgree = 1,
    this.criticalMinConf = 0.95,
    this.highMinConf = 0.90,
    this.mediumMinConf = 0.80,
    this.lowMinConf = 0.60,
    this.minSupplierConfidence = 0.60,
    this.minTemplateMatchScore = 0.55,
    this.minImageQuality = 0.40,
    this.duplicateIsRed = true,
  });
}

class DecisionPolicy {
  final int version;
  final DecisionPolicyConfig cfg;
  const DecisionPolicy(this.version, this.cfg);

  /// Normalize text for consensus matching.
  /// NOTE: numeric-aware normalization (commas, decimals) is a planned
  /// refinement; for v1 we use whitespace + case folding.
  String _norm(String s) =>
      s.trim().toLowerCase().replaceAll(RegExp(r'\s+'), ' ');

  /// Decide the status of a single field.
  FieldDecision decideField(FieldExtraction fe) {
    final results = fe.engineResults;
    final total = results.length;
    if (total == 0) {
      return FieldDecision(
        fieldKey: fe.fieldKey,
        status: FieldStatus.red,
        consensusText: null,
        confidenceAvg: 0,
        enginesAgreed: 0,
        enginesTotal: 0,
        rulesPassed: const [],
        rulesFailed: const ['no_engine_results'],
        rationale: 'No engine produced a result for this field.',
      );
    }

    // Group by normalized text; pick the largest group (tie -> higher mean conf).
    final groups = <String, List<EngineFieldResult>>{};
    for (final r in results) {
      groups.putIfAbsent(_norm(r.text), () => []).add(r);
    }
    String? bestText;
    int bestCount = 0;
    double bestConf = -1;
    for (final g in groups.entries) {
      final c = g.value.length;
      final mc = g.value.map((r) => r.confidence).reduce((a, b) => a + b) /
          c;
      if (c > bestCount || (c == bestCount && mc > bestConf)) {
        bestCount = c;
        bestConf = mc;
        bestText = g.value.first.text;
      }
    }
    final avgConf = results.map((r) => r.confidence).reduce((a, b) => a + b) /
        total;

    // Per-risk thresholds.
    int minAgree;
    double minConf;
    switch (fe.risk) {
      case FieldRisk.critical:
        minAgree = cfg.criticalMinAgree;
        minConf = cfg.criticalMinConf;
        break;
      case FieldRisk.high:
        minAgree = cfg.highMinAgree;
        minConf = cfg.highMinConf;
        break;
      case FieldRisk.medium:
        minAgree = cfg.mediumMinAgree;
        minConf = cfg.mediumMinConf;
        break;
      case FieldRisk.low:
        minAgree = 1;
        minConf = cfg.lowMinConf;
        break;
    }

    final passed = <String>[];
    final failed = <String>[];
    if (bestCount >= minAgree) {
      passed.add('consensus >= $minAgree');
    } else {
      failed.add('consensus $bestCount/$minAgree');
    }
    if (avgConf >= minConf) {
      passed.add('conf >= ${minConf.toStringAsFixed(2)}');
    } else {
      failed.add(
          'conf ${avgConf.toStringAsFixed(2)} < ${minConf.toStringAsFixed(2)}');
    }

    FieldStatus status;
    if (failed.isEmpty) {
      status = FieldStatus.green;
    } else if (bestCount >= 1 && avgConf >= (minConf - 0.10)) {
      // soft pass: got at least one engine, conf within 10pts of threshold
      status = FieldStatus.yellow;
    } else {
      status = FieldStatus.red;
    }

    final rationale =
        'risk=${fe.risk.name}, agree=$bestCount/$total, '
        'conf=${avgConf.toStringAsFixed(3)}, consensus="$bestText"';
    return FieldDecision(
      fieldKey: fe.fieldKey,
      status: status,
      consensusText: bestText,
      confidenceAvg: avgConf,
      enginesAgreed: bestCount,
      enginesTotal: total,
      rulesPassed: passed,
      rulesFailed: failed,
      rationale: rationale,
    );
  }

  /// Decide the overall receipt status.
  ReceiptDecision decide(ExtractionTrace trace) {
    // --- Global gates (any failure -> RED). ---
    if (trace.duplicateDetected && cfg.duplicateIsRed) {
      return _red(trace, 'Duplicate receipt detected -> RED.');
    }
    if (trace.supplierConfidence < cfg.minSupplierConfidence) {
      return _red(
        trace,
        'Supplier confidence ${trace.supplierConfidence.toStringAsFixed(2)} '
        '< ${cfg.minSupplierConfidence} -> RED.',
      );
    }
    if (trace.matchedTemplateId == null ||
        trace.templateMatchScore < cfg.minTemplateMatchScore) {
      return _red(
        trace,
        'No/weak template match '
        '(${trace.templateMatchScore.toStringAsFixed(2)} < '
        '${cfg.minTemplateMatchScore}) -> RED.',
      );
    }
    if (trace.imageQualityScore < cfg.minImageQuality) {
      return _red(
        trace,
        'Image quality ${trace.imageQualityScore.toStringAsFixed(2)} '
        '< ${cfg.minImageQuality} -> RED.',
      );
    }

    // Critical/high validation failures -> RED.
    for (final v in trace.validations) {
      if (!v.passed && v.targetField != null) {
        FieldRisk? risk;
        for (final f in trace.fields) {
          if (f.fieldKey == v.targetField) {
            risk = f.risk;
            break;
          }
        }
        if (risk == FieldRisk.critical || risk == FieldRisk.high) {
          return _red(
            trace,
            'Critical validation failed: ${v.rule} on ${v.targetField} '
            '(${v.message ?? ''}) -> RED.',
          );
        }
      }
    }

    // --- Per-field decisions. ---
    final fieldDecisions = <FieldDecision>[];
    for (final f in trace.fields) {
      fieldDecisions.add(decideField(f));
    }

    // Overall = worst field status.
    final anyRed =
        fieldDecisions.any((d) => d.status == FieldStatus.red);
    final anyYellow =
        fieldDecisions.any((d) => d.status == FieldStatus.yellow);
    final overall = anyRed
        ? ReceiptStatus.red
        : (anyYellow ? ReceiptStatus.yellow : ReceiptStatus.green);

    final rationale =
        'supplier=${trace.supplierGuess}(${trace.supplierConfidence.toStringAsFixed(2)}), '
        'tpl=${trace.matchedTemplateId}@v${trace.matchedTemplateVersion}'
        '(${trace.templateMatchScore.toStringAsFixed(2)}), '
        'imgq=${trace.imageQualityScore.toStringAsFixed(2)}, '
        'fields=${fieldDecisions.length} '
        '[G=${fieldDecisions.where((d) => d.status == FieldStatus.green).length} '
        'Y=${fieldDecisions.where((d) => d.status == FieldStatus.yellow).length} '
        'R=${fieldDecisions.where((d) => d.status == FieldStatus.red).length}]';

    return ReceiptDecision(
      receiptId: trace.receiptId,
      policyVersion: version,
      overall: overall,
      fields: fieldDecisions,
      rationale: rationale,
      decidedAt: DateTime.now(),
    );
  }

  ReceiptDecision _red(ExtractionTrace t, String why) {
    // Always include per-field decisions, even on global RED, so downstream
    // tools (benchmark, audit) can report per-field status uniformly.
    final fieldDecisions = t.fields.map(decideField).toList();
    return ReceiptDecision(
      receiptId: t.receiptId,
      policyVersion: version,
      overall: ReceiptStatus.red,
      fields: fieldDecisions,
      rationale: why,
      decidedAt: DateTime.now(),
    );
  }
}
