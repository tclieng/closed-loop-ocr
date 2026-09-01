// lib/ocr/consensus.dart
//
// Multi-OCR consensus: align each engine's line output (by reading order,
// with optional bbox proximity as a tiebreak) and vote a canonical text per
// line. The result feeds the DecisionPolicy through OcrExtractor.
//
// Selective invocation: `primary` engines always run. The (slower, heavier)
// `detailed` engines — e.g. PaddleOCR on-device — run ONLY when the primary
// engines disagree or one misses a line. This keeps latency/RAM low on
// modest devices (e.g. 8 GB phones) while still lifting accuracy on hard
// receipts.

import 'dart:typed_data';

import 'ocr_engine.dart';
import 'ocr_types.dart';

class ConsensusOcr {
  /// Engines that always run (cheap, fast on-device).
  final List<OcrEngine> primary;
  /// Tie-breaker engines, run only when `primary` disagree.
  final List<OcrEngine> detailed;
  /// Minimum normalized-text similarity for two lines to be the same logical line.
  final double textThresh;
  const ConsensusOcr({
    required this.primary,
    this.detailed = const [],
    this.textThresh = 0.78,
  });

  /// Run primary engines; invoke detailed only if they disagree or a primary
  /// misses a line. Returns the raw per-engine results actually produced
  /// (for OcrExtractor.fromResults).
  Future<List<OcrResult>> runRaw(Uint8List imageBytes) async {
    final primaryReady = primary.where((e) => e.isAvailable).toList();
    if (primaryReady.isEmpty) return const [];
    final primaryResults =
        await Future.wait(primaryReady.map((e) => e.detect(imageBytes)));
    final primaryAligned = align(primaryResults, textThresh);
    if (!_needsDetailed(primaryAligned, primaryReady.length)) {
      return primaryResults;
    }
    final detailedReady = detailed.where((e) => e.isAvailable).toList();
    if (detailedReady.isEmpty) return primaryResults;
    final detailedResults =
        await Future.wait(detailedReady.map((e) => e.detect(imageBytes)));
    return [...primaryResults, ...detailedResults];
  }

  /// Run and align (consensus lines). Used by callers that want the merged view.
  Future<List<ConsensusLine>> run(Uint8List imageBytes) async {
    final results = await runRaw(imageBytes);
    return align(results, textThresh);
  }

  /// True when at least one line shows primary-engine disagreement or a
  /// primary engine missing that line — i.e. a detailed engine would help.
  static bool _needsDetailed(List<ConsensusLine> lines, int primaryCount) {
    for (final l in lines) {
      if (l.total < primaryCount) return true; // some primary engine missed this line
      if (l.agreement < l.total) return true; // engines disagree on canonical text
    }
    return false;
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
