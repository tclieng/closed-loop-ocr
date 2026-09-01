// lib/policy/extraction_trace.dart
//
// Data classes for the Decision Policy.
// Pure Dart, no Flutter / DB dependencies.
//
// Represents WHAT the 12 engines produced for a single receipt
// (`ExtractionTrace`) and WHAT the policy decided (`ReceiptDecision`).

/// Risk class of a field — drives the GREEN threshold.
enum FieldRisk { critical, high, medium, low }

/// Per-field decision.
enum FieldStatus { green, yellow, red }

/// Overall receipt decision.
enum ReceiptStatus { green, yellow, red, rejected }

class BoundingBox {
  final double x, y, w, h;
  const BoundingBox(this.x, this.y, this.w, this.h);
  Map<String, dynamic> toJson() =>
      {'x': x, 'y': y, 'w': w, 'h': h};
  factory BoundingBox.fromJson(Map<String, dynamic> j) => BoundingBox(
        (j['x'] as num).toDouble(),
        (j['y'] as num).toDouble(),
        (j['w'] as num).toDouble(),
        (j['h'] as num).toDouble(),
      );
}

/// One engine's output for one field.
class EngineFieldResult {
  final String engine; // 'mlkit' | 'tesseract' | 'paddle' | 'template_roi' | 'human'
  final String text;
  final double confidence; // 0..1
  final BoundingBox? bbox;
  const EngineFieldResult(this.engine, this.text, this.confidence,
      [this.bbox]);
  Map<String, dynamic> toJson() => {
        'engine': engine,
        'text': text,
        'confidence': confidence,
        if (bbox != null) 'bbox': bbox!.toJson(),
      };
}

/// All engine outputs for a single field — the consensus input.
class FieldExtraction {
  final String fieldKey;
  final FieldRisk risk;
  final List<EngineFieldResult> engineResults;
  const FieldExtraction(this.fieldKey, this.risk, this.engineResults);
}

/// A validation rule result (arithmetic, format, supplier match, etc.).
class ValidationResult {
  final String rule;
  final String? targetField;
  final bool passed;
  final String? message;
  const ValidationResult(this.rule, this.targetField, this.passed,
      [this.message]);
}

/// A datum/anchor detection.
class AnchorResult {
  final int index;
  final double detectedX, detectedY;
  final double templateX, templateY;
  final double score; // 0..1
  const AnchorResult(this.index, this.detectedX, this.detectedY,
      this.templateX, this.templateY, this.score);
}

/// The full extraction trace for a receipt — the input to decide().
class ExtractionTrace {
  final String receiptId;
  final String? supplierGuess;
  final double supplierConfidence; // 0..1
  final String? matchedTemplateId;
  final int? matchedTemplateVersion;
  final double templateMatchScore; // 0..1
  final double imageQualityScore; // 0..1
  final List<FieldExtraction> fields;
  final List<ValidationResult> validations;
  final List<AnchorResult> anchors;
  final bool duplicateDetected;
  const ExtractionTrace({
    required this.receiptId,
    this.supplierGuess,
    this.supplierConfidence = 0,
    this.matchedTemplateId,
    this.matchedTemplateVersion,
    this.templateMatchScore = 0,
    this.imageQualityScore = 1,
    this.fields = const [],
    this.validations = const [],
    this.anchors = const [],
    this.duplicateDetected = false,
  });
}

/// Policy verdict on a single field.
class FieldDecision {
  final String fieldKey;
  final FieldStatus status;
  final String? consensusText;
  final double confidenceAvg;
  final int enginesAgreed;
  final int enginesTotal;
  final List<String> rulesPassed;
  final List<String> rulesFailed;
  final String rationale;
  const FieldDecision({
    required this.fieldKey,
    required this.status,
    required this.consensusText,
    required this.confidenceAvg,
    required this.enginesAgreed,
    required this.enginesTotal,
    required this.rulesPassed,
    required this.rulesFailed,
    required this.rationale,
  });
  Map<String, dynamic> toJson() => {
        'field': fieldKey,
        'status': status.name,
        'consensus': consensusText,
        'conf': double.parse(confidenceAvg.toStringAsFixed(3)),
        'agree': '$enginesAgreed/$enginesTotal',
        'passed': rulesPassed,
        'failed': rulesFailed,
        'rationale': rationale,
      };
}

/// Policy verdict on a whole receipt.
class ReceiptDecision {
  final String receiptId;
  final int policyVersion;
  final ReceiptStatus overall;
  final List<FieldDecision> fields;
  final String rationale;
  final DateTime decidedAt;
  const ReceiptDecision({
    required this.receiptId,
    required this.policyVersion,
    required this.overall,
    required this.fields,
    required this.rationale,
    required this.decidedAt,
  });
  bool get isGreen => overall == ReceiptStatus.green;
  bool get isYellow => overall == ReceiptStatus.yellow;
  bool get isRed => overall == ReceiptStatus.red;
  bool get isRejected => overall == ReceiptStatus.rejected;
  bool get isAutoAcceptable => isGreen || isYellow;
  Map<String, dynamic> toJson() => {
        'receipt': receiptId,
        'policy_v': policyVersion,
        'overall': overall.name,
        'rationale': rationale,
        'decided_at': decidedAt.toIso8601String(),
        'fields': fields.map((f) => f.toJson()).toList(),
      };
}
