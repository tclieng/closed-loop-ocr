// lib/ocr/consensus.dart
//
// Multi-OCR consensus: align each engine's line output (by reading order,
// with optional bbox proximity as a tiebreak) and vote a canonical text per
// line. The result feeds the DecisionPolicy through OcrExtractor.

import 'dart:typed_data';

import 'ocr_engine.dart';
import 'ocr_types.dart';

class ConsensusOcr {
  final List<OcrEngine> engines;
  /// Minimum normalized-text similarity for two lines to be considered the
  /// same logical line across engines.
  final double textThresh;
  const ConsensusOcr(this.engines, {this.textThresh = 0.78});

  /// Run all available engines on one image and align their outputs.
  Future<List<ConsensusLine>> run(Uint8List imageBytes) async {
    final results = await runRaw(imageBytes);
    return align(results, textThresh);
  }

  /// Run all available engines; return the raw per-engine results (no
  /// alignment). Used by OcrExtractor.extract.
  Future<List<OcrResult>> runRaw(Uint8List imageBytes) async {
    final ready = engines.where((e) => e.isAvailable).toList();
    if (ready.isEmpty) return const [];
    return Future.wait(ready.map((e) => e.detect(imageBytes)));
  }

  /// Pure alignment over already-collected engine results (no image needed).
  static List<ConsensusLine> align(List<OcrResult> results,
      [double textThresh = 0.78]) {
    if (results.isEmpty) return const [];

    // Reference = the engine that produced the most lines.
    final sorted = [...results]
      ..sort((a, b) => b.lines.length.compareTo(a.lines.length));
    final ref = sorted.first;
    final others = sorted.skip(1).toList();
    final used = {for (final o in others) o.engineId: <int>{}};

    final out = <ConsensusLine>[];
    for (int i = 0; i < ref.lines.length; i++) {
      final refLine = ref.lines[i];
      final perEngine = <String, String>{ref.engineId: refLine.text};
      final perEngineConf = <String, double>{
        ref.engineId: refLine.confidence ?? 0.5,
      };

      for (final o in others) {
        int? bestIdx;
        double bestScore = -1;
        for (int j = 0; j < o.lines.length; j++) {
          if (used[o.engineId]!.contains(j)) continue;
          final sim = textSimilarity(refLine.text, o.lines[j].text);
          if (sim < textThresh) continue;
          double score = sim;
          if (refLine.bbox != null && o.lines[j].bbox != null) {
            // small tiebreak toward vertically-close lines
            score -=
                (o.lines[j].bbox!.centerY - refLine.bbox!.centerY).abs() / 2000.0;
          }
          if (score > bestScore) {
            bestScore = score;
            bestIdx = j;
          }
        }
        if (bestIdx != null) {
          used[o.engineId]!.add(bestIdx);
          perEngine[o.engineId] = o.lines[bestIdx].text;
          perEngineConf[o.engineId] = o.lines[bestIdx].confidence ?? 0.5;
        }
      }

      out.add(ConsensusLine(
        text: _majorityText(perEngine.values.toList()),
        bbox: refLine.bbox,
        confidence: perEngineConf.values.reduce((a, b) => a + b) /
            perEngineConf.length,
        agreement: perEngine.length,
        total: results.length,
        perEngine: perEngine,
        perEngineConf: perEngineConf,
      ));
    }
    return out;
  }

  /// Pick the most frequent normalized text; ties -> longest original.
  static String _majorityText(List<String> texts) {
    final counts = <String, int>{};
    final rep = <String, String>{};
    for (final t in texts) {
      final n = normalizeText(t);
      counts[n] = (counts[n] ?? 0) + 1;
      rep.putIfAbsent(n, () => t);
    }
    String best = texts.first;
    int bestC = 0;
    for (final e in counts.entries) {
      final t = rep[e.key]!;
      if (e.value > bestC || (e.value == bestC && t.length > best.length)) {
        best = t;
        bestC = e.value;
      }
    }
    return best;
  }
}
