import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/foundation.dart';
import '../models/receipt_template.dart';
import '../models/field_roi.dart';
import '../models/receipt_data.dart';
import '../services/ocr_service.dart';

/// Numeric cell detected inside an item row: its x-center and parsed value.
class _Dec {
  final double x;
  final double value;
  _Dec(this.x, this.value);
}

/// True when [t] consists only of digits, commas, dots and whitespace.
bool _isPureNumber(String t) => RegExp(r'^[\d.,\s]+$').hasMatch(t.trim());

/// Heuristic: does this line look like a column-header row
/// (e.g. "ITEM DESCRIPTION  QTY  PRICE  AMOUNT")?
bool _isHeaderLine(String low) {
  final headers = [
    'description', 'qty', 'price', 'amount', 'unit', 'item', 'code', 'hsn', 'part'
  ];
  int hits = 0;
  for (final h in headers) {
    if (low.contains(h)) hits++;
  }
  return hits >= 2;
}

/// Result of anchor matching on a captured receipt image.
class AnchorMatchResult {
  final bool matched;
  final double scaleX;
  final double scaleY;
  final double offsetX;
  final double offsetY;
  final String? matchedAnchorA;
  final String? matchedAnchorB;
  final String? matchedAnchorC;
  final double confidence;

  AnchorMatchResult({
    required this.matched,
    this.scaleX = 1.0,
    this.scaleY = 1.0,
    this.offsetX = 0.0,
    this.offsetY = 0.0,
    this.matchedAnchorA,
    this.matchedAnchorB,
    this.matchedAnchorC,
    this.confidence = 0.0,
  });

  ui.Rect mapRoi(ui.Rect templateRoi) {
    return ui.Rect.fromLTRB(
      templateRoi.left * scaleX + offsetX,
      templateRoi.top * scaleY + offsetY,
      templateRoi.right * scaleX + offsetX,
      templateRoi.bottom * scaleY + offsetY,
    );
  }
}

/// Lightweight OCR block with position info.
class OcrBlock {
  final String text;
  final double x, y, width, height;

  OcrBlock({
    required this.text,
    required this.x,
    required this.y,
    required this.width,
    required this.height,
  });

  double get centerX => x + width / 2;
  double get centerY => y + height / 2;
}

/// Engine for matching receipt templates using OCR-based anchor detection.
class MatchEngine {
  static final MatchEngine _instance = MatchEngine._();
  factory MatchEngine() => _instance;
  MatchEngine._();

  final OcrService _ocr = OcrService();

  // State for merged-description recovery (reset per receipt in _extractYellowBox)
  int _itemRowCount = 0;
  final Set<int> _usedPartIndices = {};

  // ── Block extraction ──

  Future<List<OcrBlock>> _getBlocks(File imageFile) async {
    final result = await _ocr.recognizeDetailed(imageFile);
    if (result == null) return [];

    final blocks = <OcrBlock>[];
    for (final block in result.blocks) {
      final lines = block.lines;
      final text = lines.map((l) => l.text).join(' ').trim();
      if (text.isEmpty) continue;

      double minX = double.infinity, minY = double.infinity;
      double maxX = 0, maxY = 0;
      for (final line in lines) {
        for (final element in line.elements) {
          final rect = element.boundingBox;
          if (rect != null) {
            if (rect.left < minX) minX = rect.left.toDouble();
            if (rect.top < minY) minY = rect.top.toDouble();
            if (rect.right > maxX) maxX = rect.right.toDouble();
            if (rect.bottom > maxY) maxY = rect.bottom.toDouble();
          }
        }
      }

      if (minX.isFinite && minY.isFinite) {
        blocks.add(OcrBlock(
          text: text,
          x: minX,
          y: minY,
          width: maxX - minX,
          height: maxY - minY,
        ));
      }
    }
    return blocks;
  }

  // ── Template matching ──

  Future<AnchorMatchResult> matchTemplate(
    ReceiptTemplate template,
    File capturedFile,
    double capturedWidth,
    double capturedHeight, {
    bool supplierMatched = false,
  }) async {
    final blocks = await _getBlocks(capturedFile);
    if (blocks.isEmpty) return AnchorMatchResult(matched: false);

    final allText = blocks.map((b) => b.text).join('\n').toLowerCase();

    String? matchedA;
    double? ax, ay;
    if (template.anchorA != null && template.anchorA!.expectedText.isNotEmpty) {
      final expA = template.anchorA!.expectedText;
      matchedA = _findBestMatch(expA.toLowerCase(), blocks, allText);
      if (matchedA != null) {
        final block = blocks.firstWhere(
          (b) => b.text.toLowerCase().contains(expA.toLowerCase()),
          orElse: () => blocks.first,
        );
        ax = block.x + block.width / 2;
        ay = block.y + block.height / 2;
      }
    }

    String? matchedB;
    double? bx, by;
    if (template.anchorB != null && template.anchorB!.expectedText.isNotEmpty) {
      final expB = template.anchorB!.expectedText;
      matchedB = _findBestMatch(expB.toLowerCase(), blocks, allText);
      if (matchedB != null) {
        final block = blocks.firstWhere(
          (b) => b.text.toLowerCase().contains(expB.toLowerCase()),
          orElse: () => blocks.first,
        );
        bx = block.x + block.width / 2;
        by = block.y + block.height / 2;
      }
    }

    String? matchedC;
    if (template.anchorC != null && template.anchorC!.expectedText.isNotEmpty) {
      final expC = template.anchorC!.expectedText;
      matchedC = _findBestMatch(expC.toLowerCase(), blocks, allText);
    }

    double scaleX = 1.0, scaleY = 1.0, offsetX = 0.0, offsetY = 0.0;
    final tW = template.masterWidth > 0 ? template.masterWidth : capturedWidth;
    final tH = template.masterHeight > 0 ? template.masterHeight : capturedHeight;
    scaleX = capturedWidth / tW;
    scaleY = capturedHeight / tH;

    if (!supplierMatched) {
      if (matchedA != null && ax != null && ay != null && template.anchorA != null) {
        final tA = template.anchorA!;
        offsetX = ax - tA.roi.left * scaleX;
        offsetY = ay - tA.roi.top * scaleY;
      } else if (matchedB != null && bx != null && by != null && template.anchorB != null) {
        final tB = template.anchorB!;
        offsetX = bx - tB.roi.left * scaleX;
        offsetY = by - tB.roi.top * scaleY;
      }
    }

    int matchedCount = [matchedA, matchedB, matchedC].where((m) => m != null).length;
    double confidence = matchedCount / 3.0;

    return AnchorMatchResult(
      matched: matchedA != null || matchedB != null,
      scaleX: scaleX,
      scaleY: scaleY,
      offsetX: offsetX,
      offsetY: offsetY,
      matchedAnchorA: matchedA,
      matchedAnchorB: matchedB,
      matchedAnchorC: matchedC,
      confidence: confidence,
    );
  }

  String? _findBestMatch(String expected, List<OcrBlock> blocks, String allText) {
    if (allText.contains(expected)) return expected;

    final keywords = expected.split(RegExp(r'\s+')).where((w) => w.length >= 3).toList();
    if (keywords.isNotEmpty) {
      final found = keywords.where((k) => allText.contains(k)).toList();
      if (found.length >= keywords.length * 0.6) {
        found.sort((a, b) => b.length.compareTo(a.length));
        return found.first;
      }
    }

    for (final block in blocks) {
      final bt = block.text.toLowerCase();
      if (_levenshteinSimilarity(bt, expected) > 0.7) return block.text;
      if (bt.startsWith(expected) || expected.startsWith(bt)) return block.text;
    }

    return null;
  }

  double _levenshteinSimilarity(String a, String b) {
    if (a.isEmpty || b.isEmpty) return 0;
    final dist = _levenshtein(a, b);
    final maxLen = a.length > b.length ? a.length : b.length;
    return 1.0 - dist / maxLen;
  }

  int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final matrix = List.generate(a.length + 1, (i) => List.filled(b.length + 1, 0));
    for (int i = 0; i <= a.length; i++) matrix[i][0] = i;
    for (int j = 0; j <= b.length; j++) matrix[0][j] = j;
    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        matrix[i][j] = [matrix[i - 1][j] + 1, matrix[i][j - 1] + 1, matrix[i - 1][j - 1] + cost]
            .reduce((a, b) => a < b ? a : b);
      }
    }
    return matrix[a.length][b.length];
  }

  // ── Main extraction ──

  Future<ReceiptData> extractWithTemplate(
    ReceiptTemplate template,
    File capturedFile,
    double capturedWidth,
    double capturedHeight,
    String filename, {
    bool supplierMatched = false,
  }) async {
    final result = await matchTemplate(
      template,
      capturedFile,
      capturedWidth,
      capturedHeight,
      supplierMatched: supplierMatched,
    );
    final data = ReceiptData(filename: filename);

    if (!result.matched && !supplierMatched) {
      data.description = 'Template not matched — low confidence';
      final rawText = await _ocr.recognizeText(capturedFile);
      _fillFromFullOcr(data, rawText);
      return data;
    }

    final blocks = await _getBlocks(capturedFile);
    final rawText = await _ocr.recognizeText(capturedFile);
    print('[ENGINE] Full-page OCR (${rawText.length} chars): ${rawText.substring(0, rawText.length > 300 ? 300 : rawText.length).replaceAll('\n', ' | ')}');

    // Find Anchor C position for item table bottom boundary
    double? anchorCY;
    if (result.matchedAnchorC != null) {
      final lower = result.matchedAnchorC!.toLowerCase();
      for (final b in blocks) {
        if (b.text.toLowerCase().contains(lower)) {
          anchorCY = b.y;
          break;
        }
      }
    }

    // Extract configured field ROIs (ROI Fields from template editor)
    // Force dual OCR (ML Kit + Tesseract) for all fields to maximize accuracy
    print('[FIELDS] Processing ${template.fields.length} field ROIs');
    for (final field in template.fields) {
      final mappedRoi = result.mapRoi(field.roi);
      print('[FIELDS] Field "${field.fieldName}" roi=${field.roi} mapped=${mappedRoi}');
      final croppedText = await _extractRoiText(capturedFile, mappedRoi, useDual: true);
      print('[FIELDS] Field "${field.fieldName}" extracted text: "$croppedText"');
      _populateField(data, field.fieldName, croppedText.trim(), blocks);
    }
    print('[FIELDS] Total blocks from full-page OCR: ${blocks.length}');

    // Extract TOTAL from GREEN box (anchorC) if defined — most reliable source
    if (template.anchorC != null && template.anchorC!.roi != ui.Rect.zero) {
      final greenRoi = result.mapRoi(template.anchorC!.roi);
      final greenText = await _extractRoiText(capturedFile, greenRoi, useDual: true);
      print('[GREEN] Raw OCR: "$greenText"');
      final gv = _extractGreenTotal(greenText);
      print('[GREEN] Parsed amount: $gv');
      if (gv > 0) data.amount = gv;
    }

    // Extract Invoice Number from RED box (anchorA) — per spec RED = Invoice Number
    if (template.anchorA != null && template.anchorA!.roi != ui.Rect.zero) {
      final redRoi = result.mapRoi(template.anchorA!.roi);
      final redText = await _extractRoiText(capturedFile, redRoi, useDual: true);
      final inv = _extractInvoiceNumber(redText);
      if (inv.isNotEmpty) {
        data.number = inv;
        print('[RED] Invoice number: "$inv" (from "$redText")');
      } else {
        print('[RED] No invoice number in RED box text: "$redText"');
      }
    }

    // Extract item rows from YELLOW box (new, column-based, subtotal-delimiter rows)
    if (template.yellowBoxConfig != null) {
      data.items = await _extractYellowBox(
        template.yellowBoxConfig!,
        result,
        capturedFile,
        blocks,
        anchorCY,
      );
    } else if (template.itemTableConfig != null) {
      // Legacy fallback for pre-yellowbox templates
      data.items = await _extractItemTable(
        template.itemTableConfig!,
        result,
        capturedFile,
        blocks,
        anchorCY,
      );
    }

    _fillFromFullOcr(data, rawText);

    data.confidence = result.confidence;
    data.isValidated = result.confidence >= 0.3;
    return data;
  }

  Future<String> _extractRoiText(File imageFile, ui.Rect roi, {bool useDual = false}) async {
    final clamped = ui.Rect.fromLTRB(
      roi.left.clamp(0.0, double.infinity),
      roi.top.clamp(0.0, double.infinity),
      roi.right.clamp(0.0, double.infinity),
      roi.bottom.clamp(0.0, double.infinity),
    );
    if (clamped.width < 5 || clamped.height < 5) return '';
    try {
      if (useDual) {
        final dualResult = await _ocr.recognizeRoiDual(imageFile, clamped);
        return dualResult.fusedText;
      }
      return await _ocr.recognizeRoi(imageFile, clamped);
    } catch (e) {
      return '';
    }
  }

  // ── Field population (FIXED: now handles ALL field types) ──

  void _populateField(ReceiptData data, String fieldName, String text, List<OcrBlock> blocks) {
    if (text.isEmpty) return;
    switch (fieldName) {
      // Predefined standard fields
      case 'store_name':
        if (data.supplier.isEmpty) data.supplier = text;
        break;
      case 'date':
        final dateMatch = RegExp(r'(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})').firstMatch(text);
        if (dateMatch != null) {
          final candidate = dateMatch.group(1)!;
          // Validate: year must be 20-30 (2-digit) or 2020-2030 (4-digit)
          final parts = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$').firstMatch(candidate);
          if (parts != null) {
            final yy = int.tryParse(parts.group(3)!) ?? 0;
            final validYear = yy < 100 ? (yy >= 20 && yy <= 30) : (yy >= 2020 && yy <= 2030);
            if (validYear) data.date = candidate;
          }
        }
        break;
      case 'time':
        final m = RegExp(r'(\d{1,2}:\d{2}(:\d{2})?)').firstMatch(text);
        if (m != null) data.time = m.group(1)!;
        break;
      case 'receipt_number':
        if (data.number.isEmpty) data.number = text;
        break;
      case 'invoice_number':
        if (data.number.isEmpty) {
          final inv = _extractInvoiceNumber(text);
          if (inv.isNotEmpty) data.number = inv;
        }
        break;
      case 'cashier':
        data.cashier = text;
        break;
      case 'terminal_id':
        data.terminalId = text;
        break;
      case 'currency':
        data.currency = text.length <= 5 ? text : 'RM';
        break;
      case 'tax':
        final v = _extractDecimal(text);
        if (v > 0) data.tax = v;
        break;
      case 'subtotal':
        final v = _extractDecimal(text);
        if (v > 0) data.subtotal = v;
        break;
      case 'total':
        final v = _extractDecimal(text);
        if (v > 0) data.amount = v;
        break;
      case 'payment_method':
        data.paymentMethod = text;
        break;
      case 'membership_number':
        data.membershipNumber = text;
        break;
      case 'service_charge':
        // Handled via custom fields
        data.customFields['service_charge'] = text;
        break;
      // ── Custom ROI fields (user-defined in template editor) ──
      case 'item_description':
        // Single-line ROI text: extract the product description text
        // Usually contains product name, remove trailing numbers/amounts
        final cleanText = _cleanItemDescription(text);
        if (cleanText.isNotEmpty) data.description = cleanText;
        break;
      case 'unit_price':
        final v = _extractDecimal(text);
        if (v > 0) {
          data.customFields['unit_price'] = v.toStringAsFixed(2);
        }
        break;
      case 'quantity':
        final qty = _extractInteger(text);
        if (qty > 0) data.customFields['quantity'] = qty.toString();
        break;
      case 'discount':
        final v = _extractDecimal(text);
        if (v > 0) {
          data.customFields['discount'] = v.toStringAsFixed(2);
        }
        break;
      case 'custom_field':
        // Generic custom field — skip (handled elsewhere)
        break;
    }
  }

  /// Clean item description text: remove trailing prices/quantities that OCR may include.
  String _cleanItemDescription(String text) {
    // Remove trailing numbers (prices, quantities) from description
    var cleaned = text
        .replaceAll(RegExp(r'\s*\d[\d.,]*\s*[xX×*]\s*\d+\s*'), ' ') // e.g. "32.50*1" anywhere
        .replaceAll(RegExp(r'\s*\d+[xX×*]\s*$'), '') // e.g. "2x" at end
        .replaceAll(RegExp(r'\s*[\d,]+\.\d{2}\s*$'), '') // e.g. " 12.50"
        .replaceAll(RegExp(r'\s*RM\s*[\d,]+\.?\d*\s*$', caseSensitive: false), '') // " RM 12.50"
        .replaceAll(RegExp(r'\s+/\s*[\d.,]+'), '') // e.g. "/ 10.49" trailing amount
        .replaceAll(RegExp(r'\b\d{8,}\b'), '') // Remove barcodes (8+ consecutive digits)
        .replaceAll(RegExp(r'\s{2,}'), ' ') // Collapse multiple spaces
        .trim();
    // Remove leading item codes: alphanumeric codes with 1-3 letters followed by
    // numbers/dashes at the very start of the description. Examples:
    // "0085S 1.000 UNIT"     -> remove "0085S"
    // "300-S0002 MYF 1of 1"  -> remove code prefix before product name
    // "s7LO679159832 FARMFRITES" -> remove hex-like prefix
    cleaned = cleaned.replaceFirst(
        RegExp(r'^[A-Za-z]?\d[A-Za-z0-9\-]{0,20}\s*'), '');
    // Remove leading hex-like codes: mix of letters+numbers with 4+ chars starting with letter
    cleaned = cleaned.replaceFirst(
        RegExp(r'^[A-Za-z][A-Za-z0-9\-]{3,20}\s*'), '');
    // If the whole thing is just a number, return empty
    if (RegExp(r'^[\d\s,.]+$').hasMatch(cleaned)) return '';
    return cleaned;
  }

  /// Extract integer from text (for quantity, etc.)
  int _extractInteger(String text) {
    final m = RegExp(r'\b(\d+)\b').firstMatch(text);
    if (m == null) return 0;
    return int.tryParse(m.group(1)!) ?? 0;
  }

  // ── YELLOW box extraction (column-based, subtotal-delimiter row detection) ──

  /// Extract item rows from the YELLOW box using user-defined columns.
  /// Rows are delimited by a decimal value in the `amount` column (the per-line
  /// subtotal). Description-only rows that precede an amount row are merged into
  /// it, which handles wrapped item names that spill onto a second line.
  Future<List<ItemRow>> _extractYellowBox(
    YellowBoxConfig cfg,
    AnchorMatchResult match,
    File imageFile,
    List<OcrBlock> blocks,
    double? anchorCY,
  ) async {
    final items = <ItemRow>[];
    // Reset merged-description recovery state
    _itemRowCount = 0;
    _usedPartIndices.clear();
    print('[YELLOW_EXTRACT] roi=${cfg.roi} columns=${cfg.columns.length} detectRowsBySubtotal=${cfg.detectRowsBySubtotal}');

    final mappedYellow = match.mapRoi(cfg.roi);
    final topY = mappedYellow.top;
    // Allow YELLOW box to extend below the GREEN anchor so item rows near the
    // GREEN box boundary are still captured. Use the maximum of the template
    // YELLOW bottom and the GREEN anchor position (plus a small margin), so we
    // never accidentally clip item lines that sit just below the anchor text.
    final bottomY = mappedYellow.bottom;
    final effectiveBottom = (anchorCY != null && anchorCY > bottomY)
        ? anchorCY + 30
        : bottomY;
    final leftX = mappedYellow.left;
    final rightX = mappedYellow.right;

    final tol = 8.0;
    final yellowBlocks = blocks.where((b) {
      final cy = b.centerY;
      final cx = b.centerX;
      return cy >= topY - tol &&
          cy <= effectiveBottom + tol &&
          cx >= leftX - tol &&
          cx <= rightX + tol;
    }).toList();

    if (yellowBlocks.isEmpty) {
      print('[YELLOW] No blocks inside YELLOW box from full-page OCR. Trying dual OCR on YELLOW ROI...');
      print('[YELLOW] Box: topY=$topY bottomY=$bottomY leftX=$leftX rightX=$rightX tol=$tol');
      print('[YELLOW] Total blocks available: ${blocks.length}');
      if (blocks.isNotEmpty) {
        print('[YELLOW] Sample blocks:');
        for (int i = 0; i < (blocks.length > 10 ? 10 : blocks.length); i++) {
          final b = blocks[i];
          print('  [$i] "${b.text}" @ (${b.x}, ${b.y}) center=(${b.centerX.toStringAsFixed(1)}, ${b.centerY.toStringAsFixed(1)})');
        }
      }
      // Fallback: dual OCR directly on YELLOW ROI, then parse lines
      final yellowRect = ui.Rect.fromLTRB(leftX, topY, rightX, bottomY);
      final yellowText = await _extractRoiText(imageFile, yellowRect, useDual: true);
      print('[YELLOW] Dual OCR on YELLOW ROI: "${yellowText.substring(0, yellowText.length > 500 ? 500 : yellowText.length).replaceAll('\n', ' | ')}"');
      if (yellowText.trim().isNotEmpty) {
        // Parse the OCR text into pseudo-blocks (one per line)
        final lines = yellowText.split('\n').where((l) => l.trim().isNotEmpty).toList();
        final pseudoBlocks = <OcrBlock>[];
        double lineY = topY;
        for (final line in lines) {
          pseudoBlocks.add(OcrBlock(
            text: line.trim(),
            x: leftX,
            y: lineY,
            width: rightX - leftX,
            height: 20,
          ));
          lineY += 25;
        }
        if (pseudoBlocks.isNotEmpty) {
          final pseudoRows = _groupBlocksIntoRows(pseudoBlocks);
          print('[YELLOW] Parsed ${pseudoBlocks.length} blocks into ${pseudoRows.length} rows from dual OCR');
          // Process these rows using the same logic below
          // (fall through to main extraction with pseudoBlocks as yellowBlocks)
          yellowBlocks.addAll(pseudoBlocks);
        }
      }
      if (yellowBlocks.isEmpty) return items;
    }

    print('[YELLOW] Found ${yellowBlocks.length} blocks inside YELLOW box');

    yellowBlocks.sort((a, b) {
      final dy = a.y - b.y;
      if (dy.abs() > 6) return dy.round();
      return a.x.compareTo(b.x);
    });

    final rawRows = _groupBlocksIntoRows(yellowBlocks);
    print('[YELLOW] Grouped into ${rawRows.length} rows');

    // ── Merge rows: product name rows (no prices) with their price rows ──
    // Receipt items often span 2 lines: line1=product name, line2=barcode+price.
    // The barcode creates a Y-gap that splits them. Merge a row with no prices
    // into the NEXT row (which should have the price).
    bool hasPriceLike(List<OcrBlock> r) {
      for (final b in r) {
        final t = b.text.trim();
        // price*qty pattern
        if (RegExp(r'\d[\d.,]*\s*[xX×*]\s*\d+').hasMatch(t)) return true;
        // Decimal amount (but not pure integer barcode)
        if (RegExp(r'\d+\.\d{2}').hasMatch(t)) return true;
      }
      return false;
    }
    // Check if row looks like a product name (has letters, no price patterns)
    bool looksLikeProductName(List<OcrBlock> r) {
      for (final b in r) {
        final t = b.text.trim();
        if (RegExp(r'[A-Za-z]{3,}').hasMatch(t) && !RegExp(r'\d[\d.,]*\s*[xX×*]').hasMatch(t)) {
          return true;
        }
      }
      return false;
    }

    final mergedRows = <List<OcrBlock>>[];
    for (int i = 0; i < rawRows.length; i++) {
      final row = rawRows[i];
      // Only merge if:
      // 1. Current row has no price indicators (product name only)
      // 2. Next row exists and has price indicators
      // 3. Next row does NOT look like another product name (would indicate wrong merge)
      if (!hasPriceLike(row) && i + 1 < rawRows.length &&
          hasPriceLike(rawRows[i + 1]) && !looksLikeProductName(rawRows[i + 1])) {
        // This row has no price indicators — merge into next row
        final merged = List<OcrBlock>.from(row)..addAll(rawRows[i + 1]);
        mergedRows.add(merged);
        i++; // Skip next row since we consumed it
      } else {
        mergedRows.add(row);
      }
    }
    print('[YELLOW] Merged into ${mergedRows.length} rows');

    // ── FIX for JMS / invoice-style receipts: split rows that were merged
    // because of small Y gaps between adjacent items. Strategy:
    // 1. For each merged row, count how many standalone decimal numbers it
    //    contains (e.g., qty + price + amount per item).
    // 2. If a row has >= 6 standalone decimals (>= 2 items), look for Y-gaps
    //    between blocks. The gap between items is typically larger than the
    //    gap within an item (e.g., between qty and price in same row).
    // 3. Use median inter-block Y-distance as the threshold. Any gap > 2x
    //    median indicates a new item line.
    final splitRows = <List<OcrBlock>>[];
    for (final row in mergedRows) {
      if (row.length < 6) {
        splitRows.add(row);
        continue;
      }
      // Sort by Y
      final sorted = List<OcrBlock>.from(row)..sort((a, b) => a.y.compareTo(b.y));
      // Print all blocks for debugging
      print('[YELLOW] Merged row blocks (${row.length}):');
      for (int bi = 0; bi < sorted.length; bi++) {
        final b = sorted[bi];
        print('  [$bi] "${b.text}" @ x=${b.x.toStringAsFixed(0)} y=${b.y.toStringAsFixed(0)} h=${b.height.toStringAsFixed(0)}');
      }
      // ── Strategy: find Y-clusters of similar-Y blocks. Each cluster
      // is a visual row in the original receipt. Use a tight Y tolerance
      // (block-height based) so adjacent item lines split cleanly.
      final avgH = sorted.fold<double>(0, (s, b) => s + b.height) / sorted.length;
      // Tight tolerance: ~60% of avg height (most OCR engines return blocks
      // with consistent Y per visual row).
      final tolerance = avgH * 0.6;
      final groups = <List<OcrBlock>>[];
      var currentGroup = <OcrBlock>[sorted.first];
      for (int i = 1; i < sorted.length; i++) {
        final prev = sorted[i - 1];
        final curr = sorted[i];
        final yDiff = (curr.y - prev.y).abs();
        if (yDiff > tolerance) {
          if (currentGroup.isNotEmpty) groups.add(currentGroup);
          currentGroup = [curr];
        } else {
          currentGroup.add(curr);
        }
      }
      if (currentGroup.isNotEmpty) groups.add(currentGroup);
      if (groups.length > 1) {
        for (final g in groups) {
          g.sort((a, b) => a.x.compareTo(b.x));
        }
        print('[YELLOW] Y-cluster split: ${row.length} blocks → ${groups.length} items (tolerance=${tolerance.toStringAsFixed(1)}, avgH=${avgH.toStringAsFixed(1)})');
        splitRows.addAll(groups);
      } else {
        // No Y-cluster split — try fallback: split by decimal count
        // Count standalone decimal blocks
        final numRe = RegExp(r'^\d[\d.,]*$');
        final decCount = row.where((b) => numRe.hasMatch(b.text.trim())).length;
        if (decCount >= 6) {
          // Likely multi-item: try a tighter Y threshold (30% avgH)
          final tightTol = avgH * 0.3;
          final tightGroups = <List<OcrBlock>>[];
          var tightCurrent = <OcrBlock>[sorted.first];
          for (int i = 1; i < sorted.length; i++) {
            final prev = sorted[i - 1];
            final curr = sorted[i];
            final yDiff = (curr.y - prev.y).abs();
            if (yDiff > tightTol) {
              if (tightCurrent.isNotEmpty) tightGroups.add(tightCurrent);
              tightCurrent = [curr];
            } else {
              tightCurrent.add(curr);
            }
          }
          if (tightCurrent.isNotEmpty) tightGroups.add(tightCurrent);
          if (tightGroups.length > 1) {
            for (final g in tightGroups) {
              g.sort((a, b) => a.x.compareTo(b.x));
            }
            print('[YELLOW] Tight Y-cluster split: ${row.length} blocks → ${tightGroups.length} items (tolerance=${tightTol.toStringAsFixed(1)}, decs=$decCount)');
            splitRows.addAll(tightGroups);
            continue;
          }
        }
        print('[YELLOW] No Y split: ${groups.length} group, avgH=${avgH.toStringAsFixed(1)}');
        splitRows.add(row);
      }
    }
    final finalRows = splitRows;
    print('[YELLOW] After Y-cluster split: ${finalRows.length} rows');

    // ── Column-independent row extraction ──
    // We no longer rely on a fixed "amount" column (which is fragile when the
    // YELLOW box has a right margin or amounts fall just inside its edge).
    // Instead, within each row the RIGHTMOST decimal is the line amount and the
    // SECOND-rightmost is the unit price. The leftmost non-numeric text is the
    // description. This naturally handles wrapped names, "price x qty" lines and
    // barcodes.
    String pendingDesc = '';
    final requireAmount = cfg.detectRowsBySubtotal;

    for (final row in finalRows) {
      // Collect all blocks in this row, sorted left-to-right
      final sortedRow = List<OcrBlock>.from(row)..sort((a, b) => a.x.compareTo(b.x));
      
      // First pass: identify all price*qty patterns and split row into sub-items
      // if multiple price*qty patterns are found (indicates merged item lines).
      // Handle OCR confusion: O→0, l→1, I→1, S→5, and negative prices (discounts)
      final pqPattern = RegExp(r'-?\d[\d.,OolI]*\s*[xX×*]\s*\d+');
      final pqIndices = <int>[];
      for (int bi = 0; bi < sortedRow.length; bi++) {
        final t = sortedRow[bi].text.trim();
        if (pqPattern.hasMatch(t)) {
          pqIndices.add(bi);
        }
      }
      
      // If multiple price*qty patterns found, split into sub-rows
      final subRows = <List<OcrBlock>>[];
      if (pqIndices.length >= 2) {
        print('[YELLOW] Row has ${pqIndices.length} price*qty patterns — splitting into sub-items');
        int startIdx = 0;
        for (int si = 0; si < pqIndices.length; si++) {
          // Sub-row: from startIdx to the next price*qty block (inclusive)
          // plus any blocks until the next price*qty or end
          int endIdx = (si < pqIndices.length - 1) ? pqIndices[si + 1] : sortedRow.length;
          subRows.add(sortedRow.sublist(startIdx, endIdx));
          startIdx = endIdx;
        }
      } else {
        subRows.add(sortedRow);
      }
      
      for (final subRow in subRows) {
        final decs = <_Dec>[]; // numeric cells in this row: (x, value)
        final descParts = <String>[];
        int pqQty = 0;
        double pqPrice = 0;

        print('[YELLOW] Sub-row has ${subRow.length} blocks: ${subRow.map((b) => '"${b.text}"').join(' ')}');

        for (final b in subRow) {
          final t = b.text.trim();
          if (t.isEmpty) continue;

          // "price x qty" pattern, e.g. "2.50x2" or "12.90 X 3" or "0.20*1"
          // Handle OCR confusion: O→0, l→1, I→1, and negative prices (discounts)
          final pq = RegExp(r'(-?\d[\d.,OolI]*)\s*[xX×*]\s*(\d+)').firstMatch(t);
          if (pq != null) {
            final pStr = pq.group(1)!.replaceAll(',', '').replaceAll('O', '0').replaceAll('o', '0').replaceAll('l', '1').replaceAll('I', '1');
            final p = double.tryParse(pStr);
            final q = int.tryParse(pq.group(2)!);
            if (p != null && p > 0) pqPrice = p;
            if (q != null && q > 0) pqQty = q;
            if (pqQty > 999) pqQty = 1; // guard against barcode-as-quantity (e.g. 201503)
            // FIX: If pqQty > 20, it's likely an OCR fragment. "12.90" split into
            // "12." and "90" → pqPattern matches "12." as price=12, and the "90"
            // text block is misread as qty=90. An impossible qty for a grocery item.
            // Reset to 1 so we fall through to the decs-based path instead.
            if (pqQty > 20) {
              print('[YELLOW] pqQty=$pqQty implausible — OCR likely split price, resetting qty to 1');
              pqQty = 1;
              pqPrice = 0; // also clear price so we use decs path
            }
            continue;
          }

          if (_isPureNumber(t)) {
            // Barcode / SKU (long digit run) — neither description nor amount.
            // True barcodes are 7+ digits (e.g. 021024008591014944). 4-6 digit
            // pure integers in a price area are almost always a decimal point
            // dropped by OCR ("2100" -> "21.00", "3818" -> "38.18") — common on
            // budget-mart receipts where unit prices are single/double digits.
            final digitCount = t.replaceAll(RegExp(r'\D'), '').length;
            if (digitCount >= 7) continue; // Skip true barcodes
            final v = _moneyCell(t);
            if (v > 0) decs.add(_Dec(b.centerX, v));
            continue;
          }

          // Parse UOM from "qty uom" patterns like "1.000 UNIT" or "1 KG"
          final uomMatch = RegExp(r'^(?:\d[\d.,]*\s+)?([A-Za-z]{2,6})$').firstMatch(t);
          if (uomMatch != null) {
            final possibleUom = uomMatch.group(1)!.toUpperCase();
            final uomRe = RegExp(r'\b(KG|KGM|G|GM|GR|GMS|L|LT|ML|LTR|PCS|PC|EA|EACH|UNIT|SET|PKT|PACKET|BTL|BOTTLE|CAN|BOX|DOZ|DRM|ROLL|SLICE|SQFT|M|CM|MM)\b', caseSensitive: false);
            if (uomRe.hasMatch(possibleUom)) {
              // Found a UOM token — store it in descParts temporarily so it
              // survives row merging, but don't treat it as a description.
              descParts.add(possibleUom);
              continue;
            }
          }

          // Plain text → description.
          descParts.add(t);
        }

        decs.sort((a, b) => a.x.compareTo(b.x));
        // Priority: if we found price*qty pattern, that's the most reliable source
        // for both unit price and amount. Only use decs (standalone decimal numbers)
        // when price*qty wasn't found.
        double amount;
        double unitPrice;
        int qty = pqQty > 0 ? pqQty : 1;
        if (pqPrice > 0) {
          unitPrice = pqPrice;
          amount = pqPrice * qty;
        } else {
          amount = decs.isNotEmpty ? decs.last.value : 0.0;
          unitPrice = (decs.length >= 2)
              ? decs[decs.length - 2].value
              : 0.0;
          // FIX: When amount < unitPrice the columns are swapped. This is physically
          // impossible for grocery (amount = qty * unitPrice, qty >= 1, so amount >= unitPrice).
          // On ATAS FROZEN receipts the YELLOW box captures: [qty, unitPrice] instead of
          // [unitPrice, amount] — e.g. CHICKEN CHOP shows decs=[24, 16.70] where 24 is the
          // qty (KG count) and 16.70 is the unit price, but the amount (400.80) is outside
          // the box ROI. When the larger value is a whole number 2-100 it is almost
          // certainly the qty column, not the amount. Derive amount = qty * unitPrice.
          //
          // GUARD: If amount is a very small number (e.g. 0.90 from OCR splitting "12.90"
          // into [12., 90]) it is a decimal FRAGMENT, not a valid unit price. Only swap
          // when amount is large enough to be a plausible real unit price (>= 1.00).
          // Also guard: only swap when the product of qty*unitPrice would be REASONABLE
          // (not more than 3x the original amount — a huge product means the swap is wrong).
          if (amount > 0 &&
              unitPrice > 0 &&
              amount < unitPrice &&
              unitPrice >= 2 &&
              unitPrice <= 100 &&
              unitPrice == unitPrice.roundToDouble() &&
              amount >= 1.0 &&                        // Guard: decimal fragment (e.g. 0.90)
              (unitPrice * amount) <= amount * 3.0) {  // Guard: product must be plausible
            // unitPrice is actually the qty; the original amount is the real unit price
            qty = unitPrice.round();
            final realUnitPrice = amount;
            amount = qty * realUnitPrice;
            unitPrice = realUnitPrice;
            print('[YELLOW] Fixed swap: qty=$qty unitPrice=$unitPrice amount=$amount');
          }
        }

        final descText = descParts.join(' ').trim();

        // Guard: "2000 UNIT" → qty=2000 skipped by _moneyCell (>=1000 digit run).
        // But "2000" in a UOM context is actually the qty (e.g. 2.000 kg).
        // If decs has only one value and it's large (>= 100), check if there's
        // a UOM token in descParts and treat it as the actual amount (qty=1).
        // This handles the case where "2.000 UNIT" was split into "2000 UNIT"
        // by OCR (2 → 2000 digit corruption).
        if (decs.length == 1 &&
            decs.first.value >= 100 &&
            descParts.any((p) => RegExp(r'\b(KG|KGM|G|GM|GR|GMS|L|LT|ML|LTR|PCS|PC|UNIT)\b', caseSensitive: false).hasMatch(p))) {
          print('[YELLOW] Large single dec ${decs.first.value} >= 100 in UOM context — treating as qty=1, unitPrice=0');
          qty = 1;
          amount = 0;
          decs.clear();
        }

        if (amount <= 0 && requireAmount) {
          // No amount on this row → treat as a description continuation (wrapped
          // name, barcode line, or column header). Buffer it for the next amount.
          final low = descText.toLowerCase();
          if (descText.isNotEmpty &&
              !_isNonItemText(low) &&
              !_isHeaderLine(low)) {
            pendingDesc =
                pendingDesc.isEmpty ? descText : '$pendingDesc $descText';
          }
          continue;
        }

        // Amount row — merge any buffered leading description lines.
        var finalDesc = descText;
        if (pendingDesc.isNotEmpty) {
          finalDesc = finalDesc.isEmpty ? pendingDesc : '$pendingDesc $finalDesc';
          pendingDesc = '';
        }

        // UOM extraction — do this BEFORE stripping UOM from descParts.
        // For JMS: "1.000 UNIT" gets split into ["1.000", "UNIT"] blocks.
        // Scan ALL row blocks (not just descParts) for UOM tokens so we don't
        // miss ones stripped by the "qty uom" block handler above.
        String uom = '';
        for (final b in row) {
          final uomRe = RegExp(r'\b(KG|KGM|G|GM|GR|GMS|L|LT|ML|LTR|PCS|PC|EA|EACH|UNIT|SET|PKT|PACKET|BTL|BOTTLE|CAN|BOX|DOZ|DRM|ROLL|SLICE|SQFT|M|CM|MM)\b', caseSensitive: false);
          final um = uomRe.firstMatch(b.text);
          if (um != null) {
            uom = um.group(1)!.toUpperCase();
            break;
          }
        }
        if (uom.isEmpty) {
          // Fall back: scan original descParts before UOM stripping
          for (final token in descParts) {
            final uomRe = RegExp(r'\b(KG|KGM|G|GM|GR|GMS|L|LT|ML|LTR|PCS|PC|EA|EACH|UNIT|SET|PKT|PACKET|BTL|BOTTLE|CAN|BOX|DOZ|DRM|ROLL|SLICE|SQFT|M|CM|MM)\b', caseSensitive: false);
            final um = uomRe.firstMatch(token);
            if (um != null) {
              uom = um.group(1)!.toUpperCase();
              break;
            }
          }
        }

        // Remove UOM tokens from description (they were captured separately above)
        final cleanedParts = descParts.where((p) {
          final uomRe = RegExp(r'\b(KG|KGM|G|GM|GR|GMS|L|LT|ML|LTR|PCS|PC|EA|EACH|UNIT|SET|PKT|PACKET|BTL|BOTTLE|CAN|BOX|DOZ|DRM|ROLL|SLICE|SQFT|M|CM|MM)\b', caseSensitive: false);
          return !uomRe.hasMatch(p);
        }).toList();
        finalDesc = _cleanItemDescription(cleanedParts.join(' ')).trim();

        // If description is missing or clearly non-item, try to recover it from
        // the merged description block. JMS receipts OCR-merge all 3 product names
        // into one block ("FARMFRITES...KGX6...WESTGOLD..."). Split by multi-pack
        // size markers (KGX, KGXS, LKGX) which are the separators between products.
        // Also handle cases where only some items are in the merged block.
        if (finalDesc.isEmpty || _isNonItemText(finalDesc.toLowerCase())) {
          final mergedText = row.map((b) => b.text).join(' ');
          // Split by multi-pack size markers — these reliably separate JMS products.
          // Approach: find each \d?L?KGX position, split at the preceding space.
          // Lookahead split doesn't work here (can't split before \d?L?KGX since
          // the space char fails the lookahead char-class), so use index scanning.
          final parts = <String>[];
          final pattern = RegExp(r'\d?L?KGX', caseSensitive: false);
          int prev = 0;
          for (final m in pattern.allMatches(mergedText)) {
            final spacePos = mergedText.lastIndexOf(' ', m.start - 1);
            final splitAt = (spacePos > prev) ? spacePos : m.start;
            final chunk = mergedText.substring(prev, splitAt).trim();
            if (chunk.length > 5) parts.add(chunk);
            prev = splitAt + 1;
          }
          final last = mergedText.substring(prev).trim();
          if (last.length > 5) parts.add(last);
          if (parts.length > 1) {
            // Pick part by item row index, preferring unused parts first
            int idx = _itemRowCount % parts.length;
            if (_usedPartIndices.isNotEmpty) {
              final remaining = <int>[];
              for (int i = 0; i < parts.length; i++) {
                if (!_usedPartIndices.contains(i)) remaining.add(i);
              }
              if (remaining.isNotEmpty) {
                remaining.sort((a, b) => ((a - idx).abs()).compareTo((b - idx).abs()));
                idx = remaining.first;
              }
            }
            _usedPartIndices.add(idx);
            final candDesc = _cleanItemDescription(parts[idx]);
            if (candDesc.isNotEmpty && !_isNonItemText(candDesc.toLowerCase())) {
              finalDesc = candDesc;
              print('[YELLOW] Desc recovered: idx=$idx parts=${parts.length} "$finalDesc"');
            }
          }
        }
        // Final filter: skip only if no valid description AND no amount
        if (finalDesc.isEmpty && amount <= 0) continue;

        // If amount is 0 but unitPrice > 0 (JMS "1.000 UNIT" + "65.000" row),
        // treat unitPrice as the actual amount with qty=1.
        if (amount <= 0 && unitPrice > 0) {
          print('[YELLOW] No amount but unitPrice=$unitPrice > 0 — using unitPrice as amount (qty=1)');
          amount = unitPrice;
          qty = 1;
        }

        final amt = amount > 0 ? amount : (unitPrice > 0 ? unitPrice * qty : 0.0);

      print('[YELLOW] Adding item: qty=$qty desc="$finalDesc" uom="$uom" unitPrice=$unitPrice amount=$amt');
      _itemRowCount++;
      items.add(ItemRow(
        quantity: qty,
        description: finalDesc,
        uom: uom,
        unitPrice: unitPrice,
        discount: 0,
        amount: amt,
        subtotal: amt,
      ));
    } // end for subRow
    } // end for rawRows

    return items;
  }

  // ── Item table extraction (improved for thermal receipts) ──

  Future<List<ItemRow>> _extractItemTable(
    ItemTableConfig config,
    AnchorMatchResult match,
    File imageFile,
    List<OcrBlock> blocks,
    double? anchorCY,
  ) async {
    final items = <ItemRow>[];

    // Map ROI regions
    final tableTop = match.mapRoi(config.tableRoi).top;
    // Use Anchor C Y position if found; otherwise use template table bottom
    final tableBottom = anchorCY != null
        ? anchorCY
        : match.mapRoi(config.tableRoi).bottom;

    // Filter blocks that fall within the table vertical range
    final tableBlocks = blocks
        .where((b) => b.y >= tableTop - 30 && b.y <= tableBottom + 30)
        .toList();

    // Sort blocks by vertical position first, then horizontal
    tableBlocks.sort((a, b) {
      final dy = a.y - b.y;
      if (dy.abs() > 20) return dy.round();
      return a.x.compareTo(b.x);
    });

    // Column boundary X positions (mapped from template to captured)
    final descLeft = match.mapRoi(config.descriptionColumn).left;
    final priceLeft = match.mapRoi(config.unitPriceColumn).left;
    final amountLeft = match.mapRoi(config.amountColumn).left;

    // Group blocks into rows using Y-coordinate clustering
    final rows = _groupBlocksIntoRows(tableBlocks);

    for (final rowBlocks in rows) {
      // Sort by X within each row
      rowBlocks.sort((a, b) => a.x.compareTo(b.x));

      String desc = '';
      int? qty;
      double? price;
      double? amount;

      for (final block in rowBlocks) {
        final cx = block.centerX;
        final text = block.text.trim();

        if (text.isEmpty) continue;

        // Skip separator lines and non-item text
        final lower = text.toLowerCase();
        if (_isNonItemText(lower)) continue;

        if (cx < descLeft) {
          // Left column: quantity
          final n = _extractInteger(text);
          if (n > 0 && qty == null) qty = n;
          // Also check for "price × qty" format like "12.50×2"
          final priceQty = RegExp(r'([\d,]+\.?\d*)\s*[xX×]\s*(\d+)').firstMatch(text);
          if (priceQty != null) {
            final p = double.tryParse(priceQty.group(1)!.replaceAll(',', ''));
            final q = int.tryParse(priceQty.group(2)!);
            if (p != null && p > 0 && price == null) price = p;
            if (q != null && q > 0 && qty == null) qty = q;
          }
        } else if (cx < priceLeft) {
          // Middle column: description
          if (desc.isNotEmpty) desc += ' ';
          desc += text;
        } else if (cx < amountLeft) {
          // Price column: unit price
          final v = _extractDecimal(text);
          if (v > 0 && price == null) price = v;
        } else {
          // Amount column: line total
          final v = _extractDecimal(text);
          if (v > 0 && amount == null) amount = v;
        }
      }

      desc = desc.trim();
      if (desc.isEmpty) continue;

      // Skip non-item rows
      final lower = desc.toLowerCase();
      if (_isNonItemText(lower)) continue;

      // Compute amount from price × qty if not extracted
      if (amount == null && price != null) {
        amount = price * (qty ?? 1);
      }

      items.add(ItemRow(
        quantity: qty ?? 1,
        description: desc,
        unitPrice: price ?? 0,
        amount: amount ?? price ?? 0,
      ));
    }

    return items;
  }

  /// Check if text should be excluded from item rows.
  bool _isNonItemText(String text) {
    if (text.isEmpty) return true;
    final nonItemKeywords = [
      'subtotal', 'total', 'tax', 'gst', 'sst', 'service charge',
      'payment', 'cash', 'change', 'card', 'visa', 'mastercard', 'tender', 'paid',
      'rounding', 'grand total', 'amount', 'payable', 'balance', 'saving', 'points',
      'total item', 'total qty', 'total saving', 'item count',
      'thank you', 'please', 'welcome', 'receipt', 'invoice',
      'copy', 'original', 'return', 'exchange',
    ];
    for (final kw in nonItemKeywords) {
      if (text.contains(kw)) return true;
    }
    // Skip if it's mostly numbers
    if (RegExp(r'^[\d\s,.xX×-]+$').hasMatch(text)) return true;
    // Skip barcodes (long sequences of numbers)
    if (RegExp(r'^\d{8,}$').hasMatch(text)) return true;
    return false;
  }

  /// Group OCR blocks into rows using adaptive Y clustering.
  List<List<OcrBlock>> _groupBlocksIntoRows(List<OcrBlock> blocks) {
    if (blocks.isEmpty) return [];

    final rows = <List<OcrBlock>>[];
    var currentRow = <OcrBlock>[blocks.first];

    for (int i = 1; i < blocks.length; i++) {
      final block = blocks[i];
      final lastBlock = currentRow.last;
      // Use adaptive threshold: 8% of average block height in the row
      final avgHeight = currentRow.fold<double>(0, (sum, b) => sum + b.height) / currentRow.length;
      // Tighter threshold to avoid merging adjacent item lines on dense receipts.
      // Old: avgHeight * 0.8 + 8 (too aggressive, merged separate items)
      // New: avgHeight * 0.5 + 4 (still tolerant of minor Y jitter within a line)
      final threshold = avgHeight * 0.5 + 4;

      if ((block.y - lastBlock.y).abs() <= threshold) {
        currentRow.add(block);
      } else {
        if (currentRow.isNotEmpty) rows.add(currentRow);
        currentRow = [block];
      }
    }
    if (currentRow.isNotEmpty) rows.add(currentRow);

    return rows;
  }

  // ── Full-page OCR fallback (Priority 3) ──

  void _fillFromFullOcr(ReceiptData data, String rawText) {
    final lines = rawText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();

    // ── Date ──
    // Validate existing date: must be DD/MM/YYYY or similar with valid ranges
    // Reject prices like "1/10.49" that happen to match date pattern
    bool isValidDate(String d) {
      final m = RegExp(r'^(\d{1,2})[-/.](\d{1,2})[-/.](\d{2,4})$').firstMatch(d);
      if (m == null) return false;
      final dd = int.tryParse(m.group(1)!);
      final mm = int.tryParse(m.group(2)!);
      final yy = int.tryParse(m.group(3)!);
      if (dd == null || mm == null || yy == null) return false;
      if (dd < 1 || dd > 31) return false;
      if (mm < 1 || mm > 12) return false;
      // Year must be reasonable: 2-digit (20-30) or 4-digit (2020-2030)
      if (yy < 100) {
        if (yy < 20 || yy > 30) return false;
      } else {
        if (yy < 2020 || yy > 2030) return false;
      }
      return true;
    }

    if (data.date.isEmpty || !isValidDate(data.date)) {
      // Clear invalid date and try full OCR
      data.date = '';
      for (final line in lines) {
        final m = RegExp(r'(\d{1,2}[-/.]\d{1,2}[-/.]\d{2,4})').firstMatch(line);
        if (m != null) {
          final candidate = m.group(1)!;
          if (isValidDate(candidate)) {
            data.date = candidate;
            break;
          }
        }
      }
    }

    // ── Time ──
    if (data.time.isEmpty) {
      for (final line in lines) {
        final m = RegExp(r'(\d{1,2}:\d{2})').firstMatch(line);
        if (m != null) { data.time = m.group(1)!; break; }
      }
    }

    // ── Receipt number ──
    if (data.number.isEmpty) {
      for (final line in lines) {
        final m = RegExp(r'(?:Receipt|Invoice|PV|Inv)[#\s:]*([\w/-]+)', caseSensitive: false).firstMatch(line);
        if (m != null) { data.number = m.group(1)!.trim(); break; }
      }
    }

    // ── Supplier name (if not already set) ──
    if (data.supplier.isEmpty && lines.isNotEmpty) {
      // Use first non-empty line as supplier if it looks like a name
      for (final line in lines.take(3)) {
        if (line.length >= 3 && !RegExp(r'^\d').hasMatch(line) &&
            !line.contains(RegExp(r'[\d]{6,}'))) {
          data.supplier = line;
          break;
        }
      }
    }

    // ── Payment method ──
    if (data.paymentMethod.isEmpty) {
      final all = rawText.toLowerCase();
      if (all.contains('cash')) data.paymentMethod = 'Cash';
      else if (all.contains('visa')) data.paymentMethod = 'Visa';
      else if (all.contains('mastercard')) data.paymentMethod = 'Mastercard';
      else if (all.contains('tng') || all.contains('touch')) data.paymentMethod = 'TNG eWallet';
      else if (all.contains('boost')) data.paymentMethod = 'Boost';
      else if (all.contains('grabpay')) data.paymentMethod = 'GrabPay';
      else if (all.contains('debit') || all.contains('credit')) data.paymentMethod = 'Card';
    }

    // ── GRAND TOTAL (GREEN BOX) and SUBTOTAL ──
    // GREEN BOX is the authoritative Grand Total. Subtotal is the raw sum of
    // item line amounts; the printed Grand Total may differ by a small
    // rounding adjustment (e.g. subtotal 652.01 -> grand total 652.00, or
    // 331.18 -> 331.20, or 372.47 -> 372.45). So subtotal and grand total
    // are related but NOT forced equal — the rounding difference is real and
    // expected on these receipts.
    final itemsSum = data.items.fold(0.0, (s, it) => s + it.amount);
    print('[TOTAL] Green box grand total=${data.amount}  item line sum=$itemsSum');

    if (data.amount == 0) {
      // GREEN box failed to capture anything — fall back to full-page OCR,
      // then to the sum of item line amounts as a last resort.
      print('[TOTAL] Green box empty — trying full OCR fallback');
      _extractTotalFromFullOcr(data, lines, rawText);
      if (data.amount == 0 && itemsSum > 0) {
        print('[TOTAL] Full OCR also empty — using item line sum $itemsSum');
        data.amount = itemsSum;
      }
    }

    // Subtotal = raw sum of item line amounts (unrounded).
    // Grand Total (data.amount) = GREEN BOX figure (already includes rounding).
    if (itemsSum > 0) {
      data.subtotal = itemsSum;
    } else if (data.amount > 0) {
      data.subtotal = data.amount; // no items extracted; best available
    }

    // ── Tax ──
    if (data.tax == 0) {
      for (final line in lines) {
        final lower = line.toLowerCase();
        if (lower.contains('tax') || lower.contains('gst') || lower.contains('sst')) {
          final v = _extractDecimal(line);
          if (v > 0) { data.tax = v; break; }
        }
      }
    }
  }

  /// Extract total amount using Priority 3 strategy (Strategy C2):
  /// Priority 1: Find "TOTAL RM X.XX" or "Total X.XX" near anchor C match
  /// Priority 2: Find "Grand Total" or "Amount Due" label
  /// Priority 3: Find largest decimal value > RM 1.0 in bottom 30% of receipt
  void _extractTotalFromFullOcr(ReceiptData data, List<String> lines, String rawText) {
    final allLines = lines.toList();

    // ── Priority 1: TOTAL label line ──
    for (final line in allLines) {
      final lower = line.toLowerCase();
      // Must be a "TOTAL" labeled line (not "Total Item", "Total Qty")
      if (lower.contains('total') && !lower.contains('item') && !lower.contains('qty') &&
          !lower.contains('saving') && !lower.contains('discount')) {
        final v = _extractDecimal(line, isGrandTotal: true);
        if (v > 1.0) { data.amount = v; return; }
      }
    }

    // ── Priority 2: Grand Total / Amount Due / Total Payable ──
    for (final line in allLines) {
      final lower = line.toLowerCase();
      if (lower.contains('grand') || lower.contains('amount') ||
          (lower.contains('total') && lower.contains('payable'))) {
        final v = _extractDecimal(line, isGrandTotal: true);
        if (v > 1.0) { data.amount = v; return; }
      }
    }

    // ── Priority 3: Bottom 30% scan — largest decimal > RM 1.0 ──
    final scanStartIdx = (allLines.length * 0.7).round();
    double best = 0;
    for (int i = scanStartIdx; i < allLines.length; i++) {
      final line = allLines[i];
      final lower = line.toLowerCase();
      // Skip lines that are clearly not the total
      if (lower.contains('cash') || lower.contains('change') ||
          lower.contains('card') || lower.contains('payment')) continue;
      // Skip lines with item counts or quantities
      if (RegExp(r'\d+\s*[xX×]\s*\d+').hasMatch(line)) continue;

      final v = _extractDecimal(line, isGrandTotal: true);
      if (v > 1.0 && v < 100000 && v > best) best = v;
    }

    if (best > 0) { data.amount = best; return; }

    // ── Priority 4: Full receipt scan (last resort) ──
    for (final line in allLines.reversed) {
      final lower = line.toLowerCase();
      if (lower.contains('cash') || lower.contains('change')) continue;
      final v = _extractDecimal(line, isGrandTotal: true);
      if (v > 1.0 && v < 100000) { data.amount = v; return; }
    }
  }

  // ── Decimal extraction (supports RM, comma separators, Malaysian format) ──

  /// Extract an invoice/receipt number from RED-box text.
  /// Handles "INV-12345", "Receipt No: AB123", "PV26-001", or any standalone
  /// alphanumeric code of length >= 4 (to avoid capturing stray words).
  String _extractInvoiceNumber(String text) {
    final t = text.trim();
    if (t.isEmpty) return '';
    // Pattern 1: Labeled invoice/receipt number
    final m = RegExp(
            r'(?:invoice|receipt|inv|no|pv|ref|doc|bill)[#\s:/-]*([A-Za-z0-9][A-Za-z0-9\-/]{3,})',
            caseSensitive: false)
        .firstMatch(t);
    if (m != null) return m.group(1)!.trim();
    // Pattern 2: Standalone alphanumeric code that contains at least 2 digits
    // (avoids matching pure-alpha words like "ceNn" or store names)
    final m2 = RegExp(r'\b([A-Za-z0-9][A-Za-z0-9\-/]{3,})\b').firstMatch(t);
    if (m2 != null) {
      final candidate = m2.group(1)!;
      final digitCount = candidate.replaceAll(RegExp(r'\D'), '').length;
      if (digitCount >= 2) return candidate.trim();
    }
    return '';
  }

  /// Convert a pure-number YELLOW price cell to a money value.
  /// Pure integers of 4-6 digits are treated as a dropped decimal point
  /// ("2100" -> 21.00). 7+ digit numbers are barcodes and return 0.
  double _moneyCell(String text) {
    final raw = text.replaceAll(',', '').replaceAll(' ', '').trim();
    if (raw.contains('.')) {
      return double.tryParse(raw) ?? 0;
    }
    if (raw.length >= 4 && raw.length <= 6) {
      final d = double.tryParse(
          '${raw.substring(0, raw.length - 2)}.${raw.substring(raw.length - 2)}');
      if (d != null && d > 0) return d;
    }
    return double.tryParse(raw) ?? 0;
  }

  /// Extract the grand-total figure from GREEN-box OCR text.
  /// Totals are usually labelled TOTAL/GRAND/AMOUNT DUE and sit at the bottom.
  /// Prefer the decimal that follows such a keyword; otherwise the last
  /// (bottom-most) decimal in the box — the GREEN box may also capture a
  /// neighbouring CASH/CHANGE line, so we must not blindly take the first number.
  double _extractGreenTotal(String text) {
    final patterns = [
      RegExp(r'grand\s*total', caseSensitive: false),
      RegExp(r'amount\s*due', caseSensitive: false),
      RegExp(r'amount\s*payable', caseSensitive: false),
      RegExp(r'balance\s*due', caseSensitive: false),
      RegExp(r'\bpayable\b', caseSensitive: false),
      RegExp(r'\btotal\b', caseSensitive: false),
    ];
    int bestEnd = -1;
    for (final p in patterns) {
      for (final m in p.allMatches(text.toLowerCase())) {
        if (m.end > bestEnd) bestEnd = m.end;
      }
    }
    if (bestEnd >= 0) {
      final after = text.substring(bestEnd);
      final v = _extractDecimal(after, isGrandTotal: true);
      if (v > 0) return v;
    }
    // No keyword: take the last (bottom-most) decimal in the box.
    final lines = text.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    double last = 0;
    for (final line in lines) {
      final v = _extractDecimal(line, isGrandTotal: true);
      if (v > 0) last = v;
    }
    return last;
  }

  double _extractDecimal(String text, {bool isGrandTotal = false}) {
    // Pattern 1: RM followed by optional spaces and number (with optional comma separators)
    // e.g. "RM 372.45", "RM372.45", "RM 1,234.56"
    var m = RegExp(r'RM\s*([\d,]+\.?\d{0,2})', caseSensitive: false).firstMatch(text);
    if (m != null) {
      final parsed = double.tryParse(m.group(1)!.replaceAll(',', ''));
      if (parsed != null && parsed > 0) return parsed;
    }

    // Pattern 2: Number followed by RM suffix
    // e.g. "372.45 RM"
    m = RegExp(r'([\d,]+\.\d{2})\s*RM', caseSensitive: false).firstMatch(text);
    if (m != null) {
      final parsed = double.tryParse(m.group(1)!.replaceAll(',', ''));
      if (parsed != null && parsed > 0) return parsed;
    }

    // Pattern 3: Plain decimal with comma separators
    // e.g. "1,234.56" or "372.45"
    m = RegExp(r'\b([\d,]+\.\d{2})\b').firstMatch(text);
    if (m != null) {
      final parsed = double.tryParse(m.group(1)!.replaceAll(',', ''));
      if (parsed != null && parsed > 0) return parsed;
    }

    // Pattern 4: Plain integer (no decimal point)
    // Only apply missing-decimal heuristic for grand total context
    m = RegExp(r'\b([\d,]+)\b').firstMatch(text);
    if (m != null) {
      var raw = m.group(1)!.replaceAll(',', '');
      final parsed = double.tryParse(raw);
      if (parsed != null && parsed > 0) {
        // Only for grand total: if number has no decimal and is 4-6 digits,
        // try inserting decimal 2 from right (e.g. "37245" → "372.45")
        // Skip barcodes (7+ digits) and very large numbers
        if (isGrandTotal && !raw.contains('.') && raw.length >= 4 && raw.length <= 6) {
          final withDecimal = double.tryParse('${raw.substring(0, raw.length - 2)}.${raw.substring(raw.length - 2)}');
          if (withDecimal != null && withDecimal > 0 && withDecimal < 100000) {
            return withDecimal;
          }
        }
        return parsed;
      }
    }

    return 0;
  }
}
