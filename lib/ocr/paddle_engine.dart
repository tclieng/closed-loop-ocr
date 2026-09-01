// lib/ocr/paddle_engine.dart
//
// PaddleOCR (PP-OCRv4) on-device engine via ONNX Runtime.
//
// This is the "detailed" OCR channel. It runs detection + recognition
// fully on-device (no server). Models are NOT bundled in git — place:
//   assets/models/ppocr_det.onnx   (PP-OCRv4 detection)
//   assets/models/ppocr_rec.onnx   (PP-OCRv4 recognition)
//   assets/models/ppocr_keys.txt   (vocab, one token per line)
// then call `PaddleOcrEngine.init()` once at app startup.
//
// Detection post-processing uses a threshold + connected-component (flood
// fill) to produce axis-aligned boxes (curved-text polygon expansion is
// simplified). Recognition uses CTC greedy decoding.
//
// NOTE: this engine compiles and degrades gracefully without models; the
// numerical pipeline requires on-device validation with real PP-OCRv4 assets.

import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/services.dart' show rootBundle;
import 'package:image/image.dart' as img;
import 'package:onnxruntime/onnxruntime.dart';
import 'ocr_engine.dart';
import 'ocr_types.dart';

class PaddleOcrEngine extends OcrEngine {
  static OrtSession? _detSession;
  static OrtSession? _recSession;
  static List<String> _keys = [];
  static bool _ready = false;

  @override
  String get id => 'paddle';

  @override
  bool get isAvailable => _ready;

  /// Load PP-OCRv4 ONNX models from assets/models/. Returns false (and stays
  /// unavailable) if the assets are missing — the consensus simply runs with
  /// the other two engines.
  static Future<bool> init() async {
    try {
      final detBytes =
          (await rootBundle.load('assets/models/ppocr_det.onnx'))
              .buffer
              .asUint8List();
      final recBytes =
          (await rootBundle.load('assets/models/ppocr_rec.onnx'))
              .buffer
              .asUint8List();
      final keyStr =
          await rootBundle.loadString('assets/models/ppocr_keys.txt');
      _keys = keyStr
          .split('\n')
          .map((s) => s.trim())
          .where((s) => s.isNotEmpty)
          .toList();

      OrtEnv.instance.init();
      _detSession = OrtSession.fromBuffer(detBytes, OrtSessionOptions());
      _recSession = OrtSession.fromBuffer(recBytes, OrtSessionOptions());
      _ready = true;
      return true;
    } catch (e) {
      _ready = false;
      return false;
    }
  }

  @override
  Future<OcrResult> detect(Uint8List imageBytes) async {
    if (!_ready) return OcrResult(id, const []);
    try {
      final image = img.decodeImage(imageBytes);
      if (image == null) return OcrResult(id, const []);
      final boxes = await _detect(image);
      final lines = <OcrLine>[];
      for (final box in boxes) {
        final rec = _recognize(image, box);
        if (rec.text.isNotEmpty) lines.add(rec);
      }
      return OcrResult(id, lines);
    } catch (e) {
      return OcrResult(id, const []);
    }
  }

  // ── Detection ──

  Future<List<OcrBBox>> _detect(img.Image image) async {
    const maxSide = 960;
    final scale = maxSide / max(image.width, image.height);
    final w = (image.width * scale).round();
    final h = (image.height * scale).round();
    final inW = ((w + 31) ~/ 32) * 32;
    final inH = ((h + 31) ~/ 32) * 32;

    final resized = img.copyResize(image, width: inW, height: inH);
    final input = _chwNormalized(resized, inW, inH);

    final outFlat = _run(_detSession!, input, [1, 3, inH, inW]);
    final ow = inW ~/ 4;
    final oh = inH ~/ 4;

    const thresh = 0.3;
    final mask = Uint8List(oh * ow);
    for (int i = 0; i < oh * ow; i++) {
      mask[i] = outFlat[i] >= thresh ? 1 : 0;
    }

    final visited = Uint8List(oh * ow);
    final boxes = <OcrBBox>[];
    for (int i = 0; i < oh * ow; i++) {
      if (mask[i] == 0 || visited[i] == 1) continue;
      int minX = ow, minY = oh, maxX = 0, maxY = 0;
      final stack = <int>[i];
      visited[i] = 1;
      while (stack.isNotEmpty) {
        final cur = stack.removeLast();
        final cx = cur % ow;
        final cy = cur ~/ ow;
        if (cx < minX) minX = cx;
        if (cy < minY) minY = cy;
        if (cx > maxX) maxX = cx;
        if (cy > maxY) maxY = cy;
        for (final d in const [
          [-1, 0],
          [1, 0],
          [0, -1],
          [0, 1],
        ]) {
          final nx = cx + d[0];
          final ny = cy + d[1];
          if (nx < 0 || ny < 0 || nx >= ow || ny >= oh) continue;
          final ni = ny * ow + nx;
          if (mask[ni] == 1 && visited[ni] == 0) {
            visited[ni] = 1;
            stack.add(ni);
          }
        }
      }
      final bw = maxX - minX + 1;
      final bh = maxY - minY + 1;
      if (bw < 4 || bh < 4) continue;
      if (bw / bh > 50 || bh / bw > 50) continue;
      boxes.add(OcrBBox(
        (minX * 4 * image.width / inW).toDouble(),
        (minY * 4 * image.height / inH).toDouble(),
        ((maxX + 1) * 4 * image.width / inW).toDouble(),
        ((maxY + 1) * 4 * image.height / inH).toDouble(),
      ));
    }

    boxes.sort((a, b) => (a.centerY - b.centerY).abs() < 5
        ? a.centerX.compareTo(b.centerX)
        : a.centerY.compareTo(b.centerY));
    return boxes;
  }

  // ── Recognition ──

  OcrLine _recognize(img.Image image, OcrBBox box) {
    final x0 = box.left.round().clamp(0, image.width - 1);
    final y0 = box.top.round().clamp(0, image.height - 1);
    final x1 = box.right.round().clamp(0, image.width);
    final y1 = box.bottom.round().clamp(0, image.height);
    final cw = (x1 - x0).clamp(1, image.width);
    final ch = (y1 - y0).clamp(1, image.height);
    final crop = img.copyCrop(image, x: x0, y: y0, width: cw, height: ch);

    const recH = 48;
    final recW =
        (crop.width * recH / crop.height).round().clamp(8, 4096);
    final r = img.copyResize(crop, width: recW, height: recH);
    final input = _chwNormalized(r, recW, recH);

    final outFlat = _run(_recSession!, input, [1, 3, recH, recW]);
    final c = _keys.length + 1; // +1 blank at index 0
    final t = outFlat.length ~/ c;

    final decoded = <int>[];
    double confSum = 0;
    int confCount = 0;
    int prev = -1;
    for (int i = 0; i < t; i++) {
      int bestIdx = 0;
      double bestVal = double.negativeInfinity;
      for (int k = 0; k < c; k++) {
        final v = outFlat[i * c + k];
        if (v > bestVal) {
          bestVal = v;
          bestIdx = k;
        }
      }
      double sumExp = 0;
      for (int k = 0; k < c; k++) {
        sumExp += exp(outFlat[i * c + k] - bestVal);
      }
      final prob = 1 / sumExp;
      if (bestIdx != 0 && bestIdx != prev) {
        decoded.add(bestIdx - 1); // shift past blank
        confSum += prob;
        confCount++;
      }
      prev = bestIdx;
    }

    final text =
        decoded.map((i) => i < _keys.length ? _keys[i] : '').join('');
    final conf = confCount == 0 ? 0.0 : confSum / confCount;
    return OcrLine(text, bbox: box, confidence: conf);
  }

  // ── Helpers ──

  Float32List _chwNormalized(img.Image im, int w, int h) {
    const mean = [0.485, 0.456, 0.406];
    const std = [0.229, 0.224, 0.225];
    final out = Float32List(1 * 3 * h * w);
    for (int y = 0; y < h; y++) {
      for (int x = 0; x < w; x++) {
        final p = im.getPixel(x, y);
        for (int c = 0; c < 3; c++) {
          final v = c == 0 ? p.r : (c == 1 ? p.g : p.b);
          out[c * h * w + y * w + x] = (v / 255.0 - mean[c]) / std[c];
        }
      }
    }
    return out;
  }

  Float32List _run(OrtSession session, Float32List input, List<int> shape) {
    final inputName = session.inputNames.first;
    final tensor = OrtValueTensor.createTensorWithDataList(input, shape);
    final runOptions = OrtRunOptions();
    final outputs = session.run(runOptions, {inputName: tensor});
    final first = outputs.first;
    if (first == null) throw Exception('null onnx output tensor');
    final data = first.value;
    if (data == null) throw Exception('null onnx output value');
    if (data is Float32List) return data;
    if (data is List) {
      final flat = Float32List(data.length);
      for (int i = 0; i < data.length; i++) {
        flat[i] = (data[i] as num).toDouble();
      }
      return flat;
    }
    throw Exception('unexpected onnx output type: ${data.runtimeType}');
  }
}
