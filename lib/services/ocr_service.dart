import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:flutter_tesseract_ocr/flutter_tesseract_ocr.dart';
import 'package:image/image.dart' as img;
import 'cross_validator.dart';

/// OCR result from a single engine.
class SingleEngineResult {
  final String text;
  final String engine; // 'mlkit' | 'tesseract'

  const SingleEngineResult({required this.text, required this.engine});
}

/// Result after dual-engine cross-validation.
class DualOcrResult {
  /// The fused/validated text.
  final String fusedText;

  /// Cross-validation confidence (0.0–1.0).
  final double confidence;

  /// Whether both engines substantially agreed.
  final bool bothAgreed;

  /// Individual engine results for debugging.
  final SingleEngineResult mlkitResult;
  final SingleEngineResult tesseractResult;
  final String validationDescription;

  const DualOcrResult({
    required this.fusedText,
    required this.confidence,
    required this.bothAgreed,
    required this.mlkitResult,
    required this.tesseractResult,
    required this.validationDescription,
  });
}

/// OCR service wrapping Google ML Kit + Tesseract for on-device text recognition
/// with dual-engine cross-validation.
class OcrService {
  static final OcrService _instance = OcrService._();
  factory OcrService() => _instance;
  OcrService._();

  final TextRecognizer _recognizer =
      TextRecognizer(script: TextRecognitionScript.latin);
  final CrossValidator _validator = CrossValidator();

  // ── Single Engine: ML Kit ──

  /// Run OCR on a full image file using ML Kit. Returns raw recognized text.
  Future<String> recognizeText(File imageFile) async {
    try {
      final inputImage = InputImage.fromFile(imageFile);
      final result = await _recognizer.processImage(inputImage);
      return result.text;
    } catch (e) {
      return '';
    }
  }

  /// Run OCR on raw image bytes using ML Kit.
  Future<String> recognizeBytes(Uint8List bytes) async {
    final inputImage = InputImage.fromBytes(
      bytes: bytes,
      metadata: InputImageMetadata(
        size: ui.Size(0, 0),
        rotation: InputImageRotation.rotation0deg,
        format: InputImageFormat.yuv420,
        bytesPerRow: 0,
      ),
    );
    try {
      final result = await _recognizer.processImage(inputImage);
      return result.text;
    } catch (e) {
      return '';
    }
  }

  /// Run ML Kit OCR on a cropped ROI region.
  Future<String> recognizeRoi(File imageFile, ui.Rect roi) async {
    try {
      final croppedBytes = _cropImageBytes(imageFile, roi);
      if (croppedBytes == null || croppedBytes.length < 100) return '';

      final inputImage = InputImage.fromBytes(
        bytes: croppedBytes,
        metadata: InputImageMetadata(
          size: ui.Size(0, 0),
          rotation: InputImageRotation.rotation0deg,
          format: InputImageFormat.nv21,
          bytesPerRow: 0,
        ),
      );
      final result = await _recognizer.processImage(inputImage);
      return result.text;
    } catch (e) {
      return '';
    }
  }

  /// Run ML Kit with detailed blocks/line-level results for structured extraction.
  Future<RecognizedText?> recognizeDetailed(File imageFile) async {
    final inputImage = InputImage.fromFile(imageFile);
    try {
      return await _recognizer.processImage(inputImage);
    } catch (e) {
      return null;
    }
  }

  // ── Single Engine: Tesseract ──

  /// Run Tesseract OCR on a full image file.
  Future<String> recognizeTextTesseract(File imageFile) async {
    try {
      return await FlutterTesseractOcr.extractText(
        imageFile.path,
        language: 'eng',
        args: {
          'psm': '6', // Assume uniform block of text
          'preserve_interword_spaces': '1',
        },
      );
    } catch (e) {
      return '';
    }
  }

  /// Run Tesseract OCR on a cropped ROI region.
  Future<String> recognizeRoiTesseract(File imageFile, ui.Rect roi) async {
    try {
      final croppedBytes = _cropImageBytes(imageFile, roi);
      if (croppedBytes == null || croppedBytes.length < 100) return '';

      // Write cropped region to temp file for Tesseract
      final tempDir = Directory.systemTemp;
      final tempFile = File(
          '${tempDir.path}/tess_roi_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(croppedBytes);

      final result = await FlutterTesseractOcr.extractText(
        tempFile.path,
        language: 'eng',
        args: {
          'psm': '8', // Single word/line for ROI
          'preserve_interword_spaces': '0',
        },
      );

      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}

      return result;
    } catch (e) {
      return '';
    }
  }

  /// Run full page OCR with Tesseract only.
  Future<String> recognizeFullTesseract(File imageFile) async {
    try {
      return await FlutterTesseractOcr.extractText(
        imageFile.path,
        language: 'eng',
        args: {
          'psm': '3', // Fully automatic page segmentation
          'preserve_interword_spaces': '1',
        },
      );
    } catch (e) {
      return '';
    }
  }

  // ── Dual Engine (Cross-Validated) ──

  /// Run both ML Kit and Tesseract on a ROI and return cross-validated result.
  Future<DualOcrResult> recognizeRoiDual(File imageFile, ui.Rect roi) async {
    // Run both engines concurrently
    final results = await Future.wait([
      recognizeRoi(imageFile, roi),
      recognizeRoiTesseract(imageFile, roi),
    ]);

    final mlkitText = results[0];
    final tesseractText = results[1];

    final validation = _validator.validate(mlkitText, tesseractText);

    return DualOcrResult(
      fusedText: validation.fusedText,
      confidence: validation.confidence,
      bothAgreed: validation.bothAgreed,
      mlkitResult:
          SingleEngineResult(text: mlkitText, engine: 'mlkit'),
      tesseractResult:
          SingleEngineResult(text: tesseractText, engine: 'tesseract'),
      validationDescription: validation.description,
    );
  }

  /// Run both ML Kit and Tesseract on a full page and return cross-validated result.
  Future<DualOcrResult> recognizeFullDual(File imageFile) async {
    final results = await Future.wait([
      recognizeText(imageFile),
      recognizeTextTesseract(imageFile),
    ]);

    final mlkitText = results[0];
    final tesseractText = results[1];

    // For full-page OCR, cross-validate line by line for better granularity.
    final mlkitLines =
        mlkitText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final tesseractLines =
        tesseractText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    if (mlkitLines.isEmpty && tesseractLines.isEmpty) {
      return DualOcrResult(
        fusedText: '',
        confidence: 0.0,
        bothAgreed: true,
        mlkitResult: SingleEngineResult(text: '', engine: 'mlkit'),
        tesseractResult: SingleEngineResult(text: '', engine: 'tesseract'),
        validationDescription: 'Both empty',
      );
    }

    // If only one engine has results, use that.
    if (mlkitLines.isEmpty) {
      return DualOcrResult(
        fusedText: tesseractText,
        confidence: 0.4,
        bothAgreed: false,
        mlkitResult: SingleEngineResult(text: '', engine: 'mlkit'),
        tesseractResult:
            SingleEngineResult(text: tesseractText, engine: 'tesseract'),
        validationDescription: 'ML Kit empty, using Tesseract',
      );
    }
    if (tesseractLines.isEmpty) {
      return DualOcrResult(
        fusedText: mlkitText,
        confidence: 0.4,
        bothAgreed: false,
        mlkitResult: SingleEngineResult(text: mlkitText, engine: 'mlkit'),
        tesseractResult: SingleEngineResult(text: '', engine: 'tesseract'),
        validationDescription: 'Tesseract empty, using ML Kit',
      );
    }

    // Cross-validate line by line
    final fusedLines = <String>[];
    double totalConfidence = 0.0;
    int lineCount = 0;
    bool anyDisagreed = false;

    final maxLines =
        mlkitLines.length > tesseractLines.length ? mlkitLines.length : tesseractLines.length;
    for (int i = 0; i < maxLines; i++) {
      final lineA = i < mlkitLines.length ? mlkitLines[i] : '';
      final lineB = i < tesseractLines.length ? tesseractLines[i] : '';
      final lineResult = _validator.validate(lineA, lineB);
      fusedLines.add(lineResult.fusedText);
      totalConfidence += lineResult.confidence;
      lineCount++;
      if (!lineResult.bothAgreed) anyDisagreed = true;
    }

    final avgConfidence = lineCount > 0 ? totalConfidence / lineCount : 0.0;

    return DualOcrResult(
      fusedText: fusedLines.join('\n'),
      confidence: avgConfidence,
      bothAgreed: !anyDisagreed,
      mlkitResult:
          SingleEngineResult(text: mlkitText, engine: 'mlkit'),
      tesseractResult:
          SingleEngineResult(text: tesseractText, engine: 'tesseract'),
      validationDescription: anyDisagreed
          ? 'Line-by-line fused (avg conf ${(avgConfidence * 100).toStringAsFixed(0)}%)'
          : 'Both engines agreed ($maxLines lines)',
    );
  }

  // ── Helper: Crop image bytes ──

  /// Crop an image file to the specified ROI and return JPEG bytes.
  Uint8List? _cropImageBytes(File imageFile, ui.Rect roi) {
    try {
      final bytes = imageFile.readAsBytesSync();
      img.Image? image = img.decodeImage(bytes);
      if (image == null) return null;

      final clamped = ui.Rect.fromLTRB(
        roi.left.clamp(0.0, image.width.toDouble() - 1),
        roi.top.clamp(0.0, image.height.toDouble() - 1),
        roi.right.clamp(0.0, image.width.toDouble()),
        roi.bottom.clamp(0.0, image.height.toDouble()),
      );

      if (clamped.width < 5 || clamped.height < 5) return null;

      final cropped = img.copyCrop(
        image,
        x: clamped.left.round(),
        y: clamped.top.round(),
        width: clamped.width.round(),
        height: clamped.height.round(),
      );
      return Uint8List.fromList(img.encodeJpg(cropped, quality: 90));
    } catch (e) {
      return null;
    }
  }

  void dispose() {
    _recognizer.close();
  }
}
