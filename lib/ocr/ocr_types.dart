// lib/ocr/ocr_types.dart
//
// Engine-agnostic OCR data types + text-similarity helper.
// Device-agnostic (no Flutter/widget deps) so it runs under `flutter test`.

import 'dart:math';

/// Axis-aligned bounding box. `fromRect` converts a Flutter `ui.Rect`.
class OcrBBox {
  final double left, top, right, bottom;
  const OcrBBox(this.left, this.top, this.right, this.bottom);
  double get width => right - left;
  double get height => bottom - top;
  double get centerX => (left + right) / 2;
  double get centerY => (top + bottom) / 2;
  static OcrBBox fromRect(dynamic r) =>
      OcrBBox(r.left, r.top, r.right, r.bottom);
  double iou(OcrBBox o) {
    final ix = max(0.0, min(right, o.right) - max(left, o.left));
    final iy = max(0.0, min(bottom, o.bottom) - max(top, o.top));
    final inter = ix * iy;
    if (inter <= 0) return 0;
    final union = width * height + o.width * o.height - inter;
    return union <= 0 ? 0 : inter / union;
  }
}

/// One recognized text line from a single OCR engine.
class OcrLine {
  final String text;
  final OcrBBox? bbox;
  final double? confidence;
  const OcrLine(this.text, {this.bbox, this.confidence});
}

/// Full OCR output of one engine for one image.
class OcrResult {
  final String engineId;
  final List<OcrLine> lines;
  const OcrResult(this.engineId, this.lines);
}

/// A line after multi-engine consensus (alignment + majority vote).
class ConsensusLine {
  final String text; // majority-voted canonical text
  final OcrBBox? bbox;
  final double confidence; // mean of matched engines' confidence
  final int agreement; // # engines that contributed a line
  final int total; // # engines total
  final Map<String, String> perEngine; // engineId -> raw text it produced
  final Map<String, double> perEngineConf; // engineId -> confidence
  const ConsensusLine({
    required this.text,
    this.bbox,
    required this.confidence,
    required this.agreement,
    required this.total,
    required this.perEngine,
    required this.perEngineConf,
  });
}

/// Alphanumeric-normalized form for stable comparison.
String normalizeText(String s) =>
    s.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

int _lev(String a, String b) {
  final m = a.length, n = b.length;
  if (m == 0) return n;
  if (n == 0) return m;
  var prev = List<int>.generate(n + 1, (i) => i);
  var cur = List<int>.filled(n + 1, 0);
  for (int i = 1; i <= m; i++) {
    cur[0] = i;
    for (int j = 1; j <= n; j++) {
      final cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      cur[j] = min(min(prev[j] + 1, cur[j - 1] + 1), prev[j - 1] + cost);
    }
    final t = prev;
    prev = cur;
    cur = t;
  }
  return prev[n];
}

/// Normalized Levenshtein similarity in [0,1].
double textSimilarity(String a, String b) {
  if (a == b) return 1.0;
  final na = normalizeText(a), nb = normalizeText(b);
  if (na == nb) return 1.0;
  final maxLen = max(na.length, nb.length);
  if (maxLen == 0) return 1.0;
  return 1.0 - _lev(na, nb) / maxLen;
}
