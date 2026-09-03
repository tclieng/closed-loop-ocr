// lib/verify_runner.dart
//
// Shared Closed Loop verification runner.
//
// Runs the real on-device pipeline (consensus -> DecisionPolicy) on receipt
// images and produces a serialisable verdict report. Used by:
//   - the interactive Verify screen (lib/screens/verify_screen.dart)
//   - the headless auto-verify dev hook (lib/screens/home_screen.dart), which
//     triggers it via a flag file and writes the report to disk for off-device
//     analysis (audit export).

import 'dart:convert';
import 'dart:io';

import '../ocr/consensus.dart';
import '../ocr/mlkit_engine.dart';
import '../ocr/tesseract_engine.dart';
import '../ocr/ocr_extractor.dart';
import '../ocr/ocr_types.dart';
import '../policy/decision_policy.dart';
import '../policy/extraction_trace.dart';
import 'services/sd_card_service.dart';

/// Serialisable per-field verdict.
class FieldVerify {
  final String? text;
  final String status;
  final int agree;
  final int total;
  final double conf;
  final List<Map<String, dynamic>> engines;
  const FieldVerify({
    required this.text,
    required this.status,
    required this.agree,
    required this.total,
    required this.conf,
    required this.engines,
  });
  Map<String, dynamic> toJson() => {
        'text': text,
        'status': status,
        'agree': agree,
        'total': total,
        'conf': conf,
        'engines': engines,
      };
}

class ReceiptVerifyResult {
  final String file;
  final String overall;
  final int green;
  final int yellow;
  final int red;
  final List<FieldVerify> fields;
  ReceiptVerifyResult({
    required this.file,
    required this.overall,
    required this.green,
    required this.yellow,
    required this.red,
    required this.fields,
  });
  Map<String, dynamic> toJson() => {
        'file': file,
        'overall': overall,
        'green': green,
        'yellow': yellow,
        'red': red,
        'fields': fields.map((f) => f.toJson()).toList(),
      };
}

/// Runs the Closed Loop pipeline on receipt images.
class VerifyRunner {
  final ConsensusOcr consensus;
  final OcrExtractor extractor;

  VerifyRunner()
      : consensus = ConsensusOcr(
          primary: [MlKitEngine(), TesseractEngine()],
        ),
        extractor = OcrExtractor(
          consensus: ConsensusOcr(
            primary: [MlKitEngine(), TesseractEngine()],
          ),
        );

  Future<ReceiptVerifyResult> verifyFile(File file) async {
    final bytes = await file.readAsBytes();
    final ocrResults = await consensus.runRaw(bytes);
    final trace = extractor.fromResults(
      ocrResults,
      receiptId: file.uri.pathSegments.last,
      supplier: '?',
      classifyRisk: _riskForLine,
      matchedTemplateId: 'demo',
      templateMatchScore: 0.9,
      supplierConf: 0.9,
      quality: 0.9,
    );
    final decision =
        DecisionPolicy(1, const DecisionPolicyConfig()).decide(trace);

    final fields = <FieldVerify>[];
    for (int i = 0; i < decision.fields.length; i++) {
      final fd = decision.fields[i];
      final fe = trace.fields[i];
      fields.add(FieldVerify(
        text: fd.consensusText,
        status: fd.status.name,
        agree: fd.enginesAgreed,
        total: fd.enginesTotal,
        conf: double.parse(fd.confidenceAvg.toStringAsFixed(3)),
        engines: fe.engineResults
            .map((e) => {
                  'engine': e.engine,
                  'text': e.text,
                  'conf': double.parse(e.confidence.toStringAsFixed(3)),
                })
            .toList(),
      ));
    }
    final g =
        decision.fields.where((f) => f.status == FieldStatus.green).length;
    final y =
        decision.fields.where((f) => f.status == FieldStatus.yellow).length;
    final r = decision.fields.where((f) => f.status == FieldStatus.red).length;
    return ReceiptVerifyResult(
      file: file.uri.pathSegments.last,
      overall: decision.overall.name,
      green: g,
      yellow: y,
      red: r,
      fields: fields,
    );
  }

  Future<List<ReceiptVerifyResult>> verifyAll(List<File> files) async {
    final out = <ReceiptVerifyResult>[];
    for (final f in files) {
      try {
        out.add(await verifyFile(f));
      } catch (e) {
        print('CLO verify error on ${f.path}: $e');
      }
    }
    return out;
  }

  /// Per-line risk classification: money/amount lines are HIGH so that a
  /// two-engine disagreement on them surfaces as RED (high needs 2-of-2
  /// agreement); everything else stays MEDIUM (1-of-2 is enough).
  static FieldRisk _riskForLine(String text) {
    final t = normalizeText(text);
    if (t.isEmpty) return FieldRisk.medium;
    final bareAmount = RegExp(
            r'^(rm|myr|usd|\$)?\d{1,6}([.,]\d{1,2})?$')
        .hasMatch(t);
    final moneyKw = RegExp(
            r'(total|subtotal|sub|ttl|bayar|jumlah|amount|cash|change|balance|bal|due|grand|harga)')
            .hasMatch(t) &&
        t.contains(RegExp(r'\d'));
    return (bareAmount || moneyKw) ? FieldRisk.high : FieldRisk.medium;
  }

  /// Headless run for the auto-verify dev hook: verify all captures, write a
  /// JSON report next to the captures, and return the report path.
  static Future<String> runAutoVerify() async {
    final sd = SdCardService();
    final base = await sd.getBasePath();
    final caps = await sd.listCaptures();
    final runner = VerifyRunner();

    // Dev diagnostic: if a .clo_dumpraw flag file sits in the base dir,
    // dump the RAW per-engine line output (text + bbox) for the first few
    // captures so alignment geometry can be inspected off-device.
    if (await File('$base/.clo_dumpraw').exists()) {
      await _dumpRawLines(runner, caps, '$base/clo_raw_lines.json');
    }

    final results = await runner.verifyAll(caps);
    final report = {
      'generatedAt': DateTime.now().toIso8601String(),
      'receiptCount': results.length,
      'receipts': results.map((r) => r.toJson()).toList(),
    };
    final outPath = '$base/clo_verify_report.json';
    await File(outPath)
        .writeAsString(const JsonEncoder.withIndent('  ').convert(report));
    final greens = results.where((r) => r.overall == 'green').length;
    final yellows = results.where((r) => r.overall == 'yellow').length;
    final reds = results.where((r) => r.overall == 'red').length;
    print('CLO_AUTOVERIFY done: ${results.length} receipts -> $outPath '
        '[G=$greens Y=$yellows R=$reds]');
    return outPath;
  }

  /// Serialize raw per-engine OCR lines (text + bbox when available) for the
  /// first few captures. Dev-only diagnostic.
  static Future<void> _dumpRawLines(
      VerifyRunner runner, List<File> caps, String outPath) async {
    final out = <Map<String, dynamic>>[];
    for (final f in caps.take(3)) {
      final bytes = await f.readAsBytes();
      final results = await runner.consensus.runRaw(bytes);
      out.add({
        'file': f.uri.pathSegments.last,
        'results': results.map((r) => {
              'engine': r.engineId,
              'lines': r.lines
                  .map((l) => {
                        'text': l.text,
                        'conf': l.confidence,
                        'bbox': l.bbox == null
                            ? null
                            : {
                                'left': l.bbox!.left,
                                'top': l.bbox!.top,
                                'right': l.bbox!.right,
                                'bottom': l.bbox!.bottom,
                              },
                      })
                  .toList(),
            }).toList(),
      });
    }
    await File(outPath).writeAsString(
        const JsonEncoder.withIndent('  ').convert({'raw': out}));
    print('CLO_RAWLINES dumped -> $outPath');
  }
}
