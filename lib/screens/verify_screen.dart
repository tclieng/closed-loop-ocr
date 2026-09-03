// lib/screens/verify_screen.dart
//
// "Closed Loop Verify" — runs the new multi-engine consensus + DecisionPolicy
// on captured receipts and shows the GREEN / YELLOW / RED verdict per line.
//
// This is the on-device test surface for the Accuracy Contract: it does NOT
// write anything to the database; it only surfaces what the pipeline decided,
// so you can eyeball whether the consensus + policy behave correctly on your
// own receipts before any persistence is wired in.

import 'dart:io';

import 'package:flutter/material.dart';

import '../ocr/consensus.dart';
import '../ocr/mlkit_engine.dart';
import '../ocr/tesseract_engine.dart';
import '../ocr/ocr_extractor.dart';
import '../policy/decision_policy.dart';
import '../policy/extraction_trace.dart';
import '../services/sd_card_service.dart';

class VerifyScreen extends StatefulWidget {
  const VerifyScreen({super.key});

  @override
  State<VerifyScreen> createState() => _VerifyScreenState();
}

class _VerifyResult {
  final ExtractionTrace trace;
  final ReceiptDecision decision;
  _VerifyResult({required this.trace, required this.decision});
}

class _VerifyScreenState extends State<VerifyScreen> {
  final SdCardService _sdCard = SdCardService();
  final ConsensusOcr _consensus = ConsensusOcr(
    // Two-engine setup: ML Kit + Tesseract (both on-device, English/Malay).
    primary: [MlKitEngine(), TesseractEngine()],
  );
  late final OcrExtractor _extractor = OcrExtractor(consensus: _consensus);

  List<File> _captures = [];
  final Map<String, _VerifyResult> _results = {};
  bool _busy = false;
  String _status = 'Ready';

  @override
  void initState() {
    super.initState();
    _loadCaptures();
  }

  Future<void> _loadCaptures() async {
    final caps = await _sdCard.listCaptures();
    setState(() => _captures = caps);
  }

  Future<_VerifyResult> _verifyFile(File file) async {
    final bytes = await file.readAsBytes();
    final ocrResults = await _consensus.runRaw(bytes);
    // Each detected line becomes one field. We use 'medium' risk for the demo
    // (1-of-N consensus) so most clean lines are GREEN and only genuine
    // disagreements drop to YELLOW/RED — the safety net. A demo template id
    // is supplied so the overall verdict reflects field consensus, not the
    // (not-yet-wired) supplier/template gates.
    final trace = _extractor.fromResults(
      ocrResults,
      receiptId: file.uri.pathSegments.last,
      supplier: '?',
      risk: FieldRisk.medium,
      matchedTemplateId: 'demo',
      templateMatchScore: 0.9,
      supplierConf: 0.9,
      quality: 0.9,
    );
    final decision =
        DecisionPolicy(1, const DecisionPolicyConfig()).decide(trace);
    return _VerifyResult(trace: trace, decision: decision);
  }

  Future<void> _verifyAll() async {
    if (_captures.isEmpty) {
      setState(() => _status = 'No captures. Capture receipts first.');
      return;
    }
    setState(() {
      _busy = true;
      _status = 'Verifying 0/${_captures.length}...';
    });
    int done = 0;
    for (final f in _captures) {
      try {
        _results[f.uri.pathSegments.last] = await _verifyFile(f);
      } catch (e) {
        debugPrint('verify error: $e');
      }
      done++;
      if (mounted) {
        setState(() => _status = 'Verifying $done/${_captures.length}...');
      }
    }
    if (mounted) {
      setState(() {
        _busy = false;
        _status =
            'Done: ${_results.length}/${_captures.length} verified';
      });
    }
  }

  Color _statusColor(FieldStatus s) => s == FieldStatus.green
      ? Colors.green
      : s == FieldStatus.yellow
          ? Colors.amber
          : Colors.red;

  Color _overallColor(ReceiptStatus s) => s == ReceiptStatus.green
      ? Colors.green
      : s == ReceiptStatus.yellow
          ? Colors.amber
          : Colors.red;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Closed Loop Verify'),
        backgroundColor: const Color(0xFF1ABC9C),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          Container(
            padding: const EdgeInsets.all(12),
            color: const Color(0xFF0B1F3A),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(_status,
                          style: const TextStyle(color: Colors.white)),
                    ),
                    ElevatedButton.icon(
                      onPressed: _busy ? null : _verifyAll,
                      icon: _busy
                          ? const SizedBox(
                              width: 14,
                              height: 14,
                              child: CircularProgressIndicator(
                                  strokeWidth: 2, color: Colors.white))
                          : const Icon(Icons.verified, size: 16),
                      label: Text(_busy ? 'Working...' : 'Verify All'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFF1ABC9C),
                        foregroundColor: Colors.white,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'GREEN = auto-accept • YELLOW = auto-accept (soft) • RED = needs human verification',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ],
            ),
          ),
          Expanded(
            child: _captures.isEmpty
                ? const Center(
                    child: Text(
                        'No captures yet.\nGo to Capture to add receipts.'),
                  )
                : ListView.builder(
                    itemCount: _captures.length,
                    itemBuilder: (context, i) {
                      final f = _captures[i];
                      final name = f.uri.pathSegments.last;
                      final res = _results[name];
                      if (res == null) {
                        return Card(
                          margin: const EdgeInsets.symmetric(
                              horizontal: 8, vertical: 4),
                          child: ListTile(
                            title: Text(name,
                                style: const TextStyle(fontSize: 13)),
                            subtitle: const Text('Not verified'),
                            trailing: TextButton(
                              onPressed: _busy
                                  ? null
                                  : () async {
                                      setState(() => _busy = true);
                                      try {
                                        _results[name] =
                                            await _verifyFile(f);
                                      } catch (e) {
                                        debugPrint('$e');
                                      }
                                      if (mounted) {
                                        setState(() => _busy = false);
                                      }
                                    },
                              child: const Text('Verify'),
                            ),
                          ),
                        );
                      }
                      return _buildResultCard(name, res);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildResultCard(String name, _VerifyResult res) {
    final d = res.decision;
    final color = _overallColor(d.overall);
    final g = d.fields.where((f) => f.status == FieldStatus.green).length;
    final y = d.fields.where((f) => f.status == FieldStatus.yellow).length;
    final r = d.fields.where((f) => f.status == FieldStatus.red).length;
    return Card(
      margin: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      child: ExpansionTile(
        leading: CircleAvatar(
          backgroundColor: color,
          child: Text(d.overall.name[0].toUpperCase(),
              style: const TextStyle(
                  color: Colors.white, fontWeight: FontWeight.bold)),
        ),
        title: Text(name, style: const TextStyle(fontSize: 13)),
        subtitle: Text(
          '${d.fields.length} fields  •  $g G  $y Y  $r R',
          style: const TextStyle(fontSize: 12, color: Colors.grey),
        ),
        children: [
          for (int i = 0; i < d.fields.length; i++)
            _buildFieldTile(res.trace.fields[i], d.fields[i]),
        ],
      ),
    );
  }

  Widget _buildFieldTile(FieldExtraction fe, FieldDecision fd) {
    final color = _statusColor(fd.status);
    return ListTile(
      leading: Icon(Icons.circle, color: color, size: 12),
      title: Text(fd.consensusText ?? '(empty)',
          style: const TextStyle(fontSize: 13)),
      subtitle: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            '${fd.status.name.toUpperCase()} • agree ${fd.enginesAgreed}/${fd.enginesTotal} • conf ${fd.confidenceAvg.toStringAsFixed(2)}',
            style: const TextStyle(fontSize: 11, color: Colors.grey),
          ),
          const SizedBox(height: 2),
          for (final e in fe.engineResults)
            Text(
              '  ${e.engine}: ${e.text} (${(e.confidence * 100).round()}%)',
              style: const TextStyle(fontSize: 11, color: Colors.black87),
            ),
        ],
      ),
      isThreeLine: true,
    );
  }
}
