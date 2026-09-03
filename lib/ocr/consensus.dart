// lib/ocr/consensus.dart
//
// Multi-OCR consensus: align each engine's line output into a single set of
// logical rows and vote a canonical text per row. The result feeds the
// DecisionPolicy through OcrExtractor.
//
// Alignment strategy:
//   - Engines that expose bounding boxes (ML Kit, PaddleOCR) are clustered
//     into physical rows by vertical proximity, so fragmented readings of the
//     same receipt line ("AURA BERAS IMPORT" + "10KG") are rejoined.
//   - Engines without geometry (Tesseract full-page text) are aligned to the
//     reference rows with a monotonic (order-preserving) dynamic-programming
//     match on normalized text similarity. The match threshold is deliberately
//     LOW: we want the SAME physical row to be paired even when engines read
//     it differently (e.g. "TOTAL 578.43" vs "TOTAL 455.40") — that is exactly
//     the disagreement the decision policy must surface as YELLOW/RED.
//
// `agreement` on ConsensusLine = number of engines whose reading matches the
// canonical text (TRUE agreement), NOT the number of engines that merely
// contributed a line. This is what lets runRaw escalate to the detailed
// (Paddle) engine when the primaries genuinely disagree.
//
// Selective invocation: `primary` engines always run. The (slower, heavier)
// `detailed` engines — e.g. PaddleOCR on-device — run ONLY when the primary
// engines disagree or one misses a line. This keeps latency/RAM low on
// modest devices (e.g. 8 GB phones) while still lifting accuracy on hard
// receipts.

import 'dart:math' as math;
import 'dart:typed_data';

import 'ocr_engine.dart';
import 'ocr_types.dart';

/// A clustered physical row from one engine.
class _Row {
  final String text;
  final OcrBBox? bbox;
  final double centerY;
  final double conf;
  const _Row(this.text, this.bbox, this.centerY, this.conf);
}

class ConsensusOcr {
  /// Engines that always run (cheap, fast on-device).
  final List<OcrEngine> primary;
  /// Tie-breaker engines, run only when `primary` disagree.
  final List<OcrEngine> detailed;
  /// Minimum normalized-text similarity for two readings to be aligned to the
  /// same logical row. Deliberately below 0.5: pairing same-row readings even
  /// when engines disagree (e.g. "TOTAL 578.43" vs "TOTAL 455.40" ~0.5) is the
  /// safe direction (surfaces as YELLOW/RED), whereas failing to pair hides
  /// the disagreement behind false GREENs. But high enough (>=0.40) that
  /// dissimilar lines ("TOTAL 12.00" vs "DATE 01/09/2026" = 0.33) do not
  /// false-pair. Containment (same-row short-vs-long readings) is boosted to
  /// 0.95 separately.
  final double matchThresh;
  const ConsensusOcr({
    required this.primary,
    this.detailed = const [],
    this.matchThresh = 0.40,
  });

  /// Run primary engines; invoke detailed only if they disagree or a primary
  /// misses a line. Returns the raw per-engine results actually produced
  /// (for OcrExtractor.fromResults).
  Future<List<OcrResult>> runRaw(Uint8List imageBytes) async {
    final primaryReady = primary.where((e) => e.isAvailable).toList();
    if (primaryReady.isEmpty) return const [];
    final primaryResults =
        await Future.wait(primaryReady.map((e) => e.detect(imageBytes)));
    final primaryAligned = align(primaryResults, matchThresh);
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
    return align(results, matchThresh);
  }

  /// True when at least one line shows true primary-engine disagreement or a
  /// primary engine missing that line — i.e. a detailed engine would help.
  static bool _needsDetailed(List<ConsensusLine> lines, int primaryCount) {
    for (final l in lines) {
      if (l.total < primaryCount) return true; // a primary engine produced nothing
      if (l.agreement < l.total) return true; // engines disagree on canonical text
    }
    return false;
  }

  /// Pure alignment over already-collected engine results (no image needed).
  ///
  /// Strategy:
  ///   1. Reference = the whole-line engine when one is present (an engine
  ///      whose lines carry no bboxes, e.g. Tesseract psm=3): its lines are
  ///      clean physical lines, so they make the best skeleton. Otherwise
  ///      fall back to the engine with the most lines.
  ///   2. Cluster bbox'd lines (ML Kit) into physical rows by proximity.
  ///   3. Align every other engine to the reference rows with monotonic DP on
  ///      containment-aware text similarity (threshold `matchThresh`).
  ///   4. Emit one ConsensusLine per reference row + unmatched lines from the
  ///      other engines (data preservation).
  static List<ConsensusLine> align(List<OcrResult> results,
      [double matchThresh = 0.40]) {
    if (results.isEmpty) return const [];
    if (results.length == 1) {
      final r = results.first;
      return [
        for (final l in r.lines)
          ConsensusLine(
            text: l.text,
            bbox: l.bbox,
            confidence: l.confidence ?? 0.5,
            agreement: 1,
            total: 1,
            perEngine: {r.engineId: l.text},
            perEngineConf: {r.engineId: l.confidence ?? 0.5},
          )
      ];
    }

    // Prefer a whole-line engine (no bboxes) as the reference skeleton;
    // fall back to the engine with the most lines.
    final sorted = [...results]
      ..sort((a, b) => b.lines.length.compareTo(a.lines.length));
    OcrResult? wholeLine;
    for (final r in sorted) {
      if (r.lines.isNotEmpty && r.lines.every((l) => l.bbox == null)) {
        wholeLine = r;
        break;
      }
    }
    final refEngine = wholeLine ?? sorted.first;
    final others = [
      for (final r in results)
        if (r.engineId != refEngine.engineId) r
    ];

    final refRows = _toRows(refEngine.lines);
    final refTexts = [for (final r in refRows) r.text];

    // Align every other engine to the reference rows.
    final othersRows = <String, List<_Row>>{};
    final othersMatch = <String, List<int?>>{}; // engineId -> refIdx -> seqIdx
    final used = <String, Set<int>>{};
    for (final o in others) {
      final oRows = _toRows(o.lines);
      othersRows[o.engineId] = oRows;
      final oTexts = [for (final r in oRows) r.text];
      final m = _alignSequences(refTexts, oTexts, matchThresh);
      othersMatch[o.engineId] = m;
      used[o.engineId] = {for (final j in m) if (j != null) j};
    }

    final out = <ConsensusLine>[];
    for (int i = 0; i < refRows.length; i++) {
      final perEngine = <String, String>{refEngine.engineId: refRows[i].text};
      final perEngineConf = <String, double>{
        refEngine.engineId: refRows[i].conf,
      };
      for (final o in others) {
        final j = othersMatch[o.engineId]![i];
        if (j != null) {
          perEngine[o.engineId] = othersRows[o.engineId]![j].text;
          perEngineConf[o.engineId] = othersRows[o.engineId]![j].conf;
        }
      }
      final canonical = _majorityText(
          perEngine.values.toList(), prefer: refRows[i].text);
      final agreement = perEngine.values
          .where((t) => normalizeText(t) == normalizeText(canonical))
          .length;
      out.add(ConsensusLine(
        text: canonical,
        bbox: refRows[i].bbox,
        confidence:
            perEngineConf.values.reduce((a, b) => a + b) / perEngineConf.length,
        agreement: agreement,
        total: results.length,
        perEngine: perEngine,
        perEngineConf: perEngineConf,
      ));
    }

    // Unmatched lines from the other engines (preserve their data).
    for (final o in others) {
      final oRows = othersRows[o.engineId]!;
      for (int j = 0; j < oRows.length; j++) {
        if (used[o.engineId]!.contains(j)) continue;
        final r = oRows[j];
        out.add(ConsensusLine(
          text: r.text,
          bbox: r.bbox,
          confidence: r.conf,
          agreement: 1,
          total: results.length,
          perEngine: {o.engineId: r.text},
          perEngineConf: {o.engineId: r.conf},
        ));
      }
    }
    return out;
  }

  /// Build ordered rows from an engine's lines. Bbox'd lines are clustered
  /// into physical rows by centerY proximity with a per-line ADAPTIVE
  /// tolerance (fragments of the same receipt line rejoin; adjacent lines
  /// stay apart). Overlap-based merging is wrong for ML Kit's padded bboxes:
  /// on dense thermal receipts its boxes overlap vertically, so overlap
  /// merges whole pages into one row. Lines without bboxes stay as-is in
  /// reading order.
  static List<_Row> _toRows(List<OcrLine> lines) {
    final withB = [for (final l in lines) if (l.bbox != null) l];
    if (withB.isEmpty) {
      return [
        for (int i = 0; i < lines.length; i++)
          _Row(lines[i].text, null, i.toDouble(), lines[i].confidence ?? 0.5)
      ];
    }
    final sorted = [...withB]
      ..sort((a, b) {
        final c = a.bbox!.centerY.compareTo(b.bbox!.centerY);
        return c != 0 ? c : a.bbox!.centerX.compareTo(b.bbox!.centerX);
      });

    final rows = <_Row>[];
    var cur = <OcrLine>[];
    double? anchorY;
    double? rowH;
    for (final l in sorted) {
      final h = l.bbox!.height;
      final gap = anchorY == null ? 0.0 : (l.bbox!.centerY - anchorY);
      final tol = _proxTol(h, rowH, gap);
      if (tol == 0 || anchorY == null || gap > tol) {
        if (cur.isNotEmpty) rows.add(_mergeRow(cur));
        cur = [l];
        anchorY = l.bbox!.centerY;
        rowH = h;
      } else {
        cur.add(l);
        rowH = rowH == null ? h : (rowH + h) / 2;
      }
    }
    if (cur.isNotEmpty) rows.add(_mergeRow(cur));
    return rows;
  }

  /// Adaptive proximity tolerance for ML Kit bbox rows. Strategy:
  /// - Base = 0.4× the minimum of the two line heights (prevents tall bboxes
  ///   from inflating the threshold and swallowing adjacent logical rows).
  /// - Absolute cap of 20 px (on these receipts line pitch ≈ 50-80 px; a gap
  ///   larger than 20 px between same-line fragments is rare).
  /// - Additionally, if the centerY gap exceeds 1.8× the current line's
  ///   height, always start a new row regardless of tolerance.
  static double _proxTol(double h, double? rowH, double centerYGap) {
    // Pitch guard: adjacent rows are always >1 line apart.
    if (centerYGap > 1.8 * h) return 0;
    final base = (rowH == null ? h : math.min(h, rowH)) * 0.4;
    if (base < 1.5) return 1.5;
    if (base > 20.0) return 20.0;
    return base;
  }

  /// Merge fragments of one row: order by X, join text, union bbox.
  static _Row _mergeRow(List<OcrLine> frags) {
    final sorted = [...frags]
      ..sort((a, b) => a.bbox!.centerX.compareTo(b.bbox!.centerX));
    final text = sorted.map((l) => l.text.trim()).where((s) => s.isNotEmpty).join(' ');
    double left = double.infinity,
        top = double.infinity,
        right = double.negativeInfinity,
        bottom = double.negativeInfinity;
    double cy = 0, conf = 0;
    for (final l in sorted) {
      final b = l.bbox!;
      left = left < b.left ? left : b.left;
      top = top < b.top ? top : b.top;
      right = right > b.right ? right : b.right;
      bottom = bottom > b.bottom ? bottom : b.bottom;
      cy += b.centerY;
      conf += l.confidence ?? 0.5;
    }
    final n = sorted.length;
    return _Row(
      text,
      OcrBBox(left, top, right, bottom),
      cy / n,
      conf / n,
    );
  }

  /// Similarity used by the alignment DP: text similarity, boosted to a near-
  /// match when one reading is CONTAINED in the other (handles engines whose
  /// "lines" span several physical lines: a single-line reading still pairs
  /// with the multi-line row instead of being lost). The containment boost is
  /// guarded so tiny fragments (e.g. "Total") do not pair with long rows.
  static double _alignSim(String a, String b) {
    final base = textSimilarity(a, b);
    final na = normalizeText(a), nb = normalizeText(b);
    final short = na.length <= nb.length ? na : nb;
    final long = na.length <= nb.length ? nb : na;
    if (short.length >= 4 &&
        short.length / long.length >= 0.30 &&
        long.contains(short)) {
      return base > 0.95 ? base : 0.95;
    }
    return base;
  }

  /// Monotonic (order-preserving) alignment of `seq` to `ref` maximizing the
  /// sum of text similarities of matched pairs. Returns refIdx -> seqIdx (or
  /// null when the row is unmatched). Pairs with similarity below `thresh`
  /// are never matched — they stay separate (safer than a false merge).
  static List<int?> _alignSequences(
      List<String> ref, List<String> seq, double thresh) {
    final n = ref.length, m = seq.length;
    if (n == 0 || m == 0) return List<int?>.filled(n, null);
    final dp = List.generate(n + 1, (_) => List<double>.filled(m + 1, 0.0));
    for (int i = 1; i <= n; i++) {
      for (int j = 1; j <= m; j++) {
        var best = dp[i - 1][j] > dp[i][j - 1] ? dp[i - 1][j] : dp[i][j - 1];
        final s = _alignSim(ref[i - 1], seq[j - 1]);
        if (s >= thresh) {
          final cand = dp[i - 1][j - 1] + s;
          if (cand > best) best = cand;
        }
        dp[i][j] = best;
      }
    }
    final res = List<int?>.filled(n, null);
    int i = n, j = m;
    while (i > 0 && j > 0) {
      final s = _alignSim(ref[i - 1], seq[j - 1]);
      if (s >= thresh && (dp[i][j] - (dp[i - 1][j - 1] + s)).abs() < 1e-9) {
        res[i - 1] = j - 1;
        i--;
        j--;
      } else if ((dp[i][j] - dp[i - 1][j]).abs() < 1e-9) {
        i--;
      } else {
        j--;
      }
    }
    return res;
  }

  /// Pick the most frequent normalized text; ties -> the text closest to
  /// `prefer` (the reference engine's reading), then longest original.
  static String _majorityText(List<String> texts, {String? prefer}) {
    final counts = <String, int>{};
    final rep = <String, String>{};
    final pref = prefer == null ? null : normalizeText(prefer);
    for (final t in texts) {
      final n = normalizeText(t);
      counts[n] = (counts[n] ?? 0) + 1;
      rep.putIfAbsent(n, () => t);
    }
    String best = texts.first;
    int bestC = 0;
    for (final e in counts.entries) {
      final t = rep[e.key]!;
      if (e.value > bestC) {
        best = t;
        bestC = e.value;
      } else if (e.value == bestC) {
        final curPref = normalizeText(best) == pref;
        final newPref = e.key == pref;
        if (newPref && !curPref) {
          best = t;
        } else if (newPref == curPref && t.length > best.length) {
          best = t;
        }
      }
    }
    return best;
  }
}
