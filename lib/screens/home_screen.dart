import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../services/sd_card_service.dart';
import '../services/excel_service.dart';
import '../services/ocr_service.dart';
import '../services/template_service.dart';
import '../services/match_engine.dart';
import '../services/image_processor.dart';
import '../models/receipt_data.dart';
import '../models/receipt_template.dart';
import 'capture_screen.dart';
import 'template_list_screen.dart';
import 'master_templates_screen.dart';

class HomeScreen extends StatefulWidget {
  const HomeScreen({super.key});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final SdCardService _sdCard = SdCardService();
  final OcrService _ocr = OcrService();
  final ExcelService _excel = ExcelService();
  final TemplateService _templateService = TemplateService();
  final MatchEngine _matchEngine = MatchEngine();

  List<File> _captures = [];
  List<ReceiptData> _results = [];
  bool _processing = false;
  String _status = 'Ready';
  String _processedSupplier = '';
  int _processedCount = 0;
  ReceiptTemplate? _lastMatchedTemplate;
  int _totalCount = 0;

  @override
  void initState() {
    super.initState();
    _refreshCaptures();
    _templateService.loadTemplates();
  }

  Future<void> _refreshCaptures() async {
    final captures = await _sdCard.listCaptures();
    setState(() {
      _captures = captures;
      _totalCount = captures.length;
    });
  }

  void _showSnack(String msg) {
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(msg)));
    }
  }

  Future<void> _processReceipts() async {
    if (_captures.isEmpty) {
      _showSnack('No receipts to process. Capture some first!');
      return;
    }

    setState(() {
      _processing = true;
      _status = 'Processing...';
      _results = [];
    });

    for (int i = 0; i < _captures.length; i++) {
      setState(() => _status = 'Processing ${i + 1}/${_captures.length}...');
      try {
        final imageBytes = await _captures[i].readAsBytes();
        // Use original image for OCR, but apply gentle deskew to fix tilted receipts
        img.Image? src = img.decodeImage(imageBytes);
        if (src != null) {
          final angle = _estimateSkewAngle(src);
          if (angle.abs() > 1.5 && angle.abs() < 25) {
            src = img.copyRotate(src, angle: -angle, interpolation: img.Interpolation.linear);
          }
        }
        final tempDir = Directory.systemTemp;
        final originalFile = File('${tempDir.path}/orig_${_captures[i].uri.pathSegments.last}');
        await originalFile.writeAsBytes(img.encodeJpg(src ?? img.decodeImage(imageBytes)!, quality: 92));

        final w = src?.width.toDouble() ?? 1000;
        final h = src?.height.toDouble() ?? 1000;

        final rawText = await _ocr.recognizeText(originalFile);
        final rawPreview = rawText.substring(0, min(300, rawText.length)).replaceAll('\n', ' | ');
        print('[OCR_RAW][$i] $rawPreview');
        debugPrint('OCR_RAW[${i}]: ${rawText.substring(0, min(200, rawText.length))}...');
        final rawFname = _captures[i].uri.pathSegments.last;
        // Clean internal prefixes for display: CAP_{timestamp}_{basename}
        final cleanFname = rawFname
            .replaceAll(RegExp(r'^CAP_\d+_'), '')
            .replaceAll(RegExp(r'_scaled_\d+'), '')
            .replaceAll(RegExp(r'_proc$'), '')
            .replaceAll(RegExp(r'_scaled$'), '');
        final data = await _parseReceiptData(cleanFname, rawText);

        // FALLBACK: If OCR didn't detect a supplier name but a previous receipt
        // in this batch matched a template, reuse that template. Common when
        // a receipt's header is faded or partially out of frame.
        if (data.supplier.isEmpty && _lastMatchedTemplate != null) {
          print('[TEMPLATE_MATCH] Receipt $i: Empty OCR supplier, reusing last matched template="${_lastMatchedTemplate!.supplierName}"');
          data.supplier = _lastMatchedTemplate!.supplierName;
        }

        // ── Supplier-name-based template matching ──
        // OCR detects the supplier name from the receipt header, then we find
        // the best-matching template by supplier name (not by anchor text,
        // which changes per receipt and never matches).
        final detectedSupplier = data.supplier;
        print('[TEMPLATE_MATCH] Receipt $i: OCR detected supplier="$detectedSupplier"');
        ReceiptTemplate? matchedTemplate =
            _templateService.findBestTemplateByHeader(detectedSupplier,
                threshold: 0.5);

        if (matchedTemplate != null) {
          print('[TEMPLATE_MATCH] Receipt $i: Matched template="${matchedTemplate.supplierName}"');
          _lastMatchedTemplate = matchedTemplate;
          try {
            final enhanced = await _matchEngine.extractWithTemplate(
              matchedTemplate,
              originalFile,
              w,
              h,
              data.filename,
              supplierMatched: true,
            );
            // Overwrite with template-extracted data (more accurate)
            if (enhanced.supplier.isNotEmpty) data.supplier = enhanced.supplier;
            if (enhanced.number.isNotEmpty) data.number = enhanced.number;
            if (enhanced.date.isNotEmpty) data.date = enhanced.date;
            if (enhanced.amount > 0) data.amount = enhanced.amount;
            if (enhanced.time.isNotEmpty) data.time = enhanced.time;
            if (enhanced.paymentMethod.isNotEmpty) {
              data.paymentMethod = enhanced.paymentMethod;
            }
            if (enhanced.subtotal > 0) data.subtotal = enhanced.subtotal;
            if (enhanced.tax > 0) data.tax = enhanced.tax;
            if (enhanced.items.isNotEmpty) data.items = enhanced.items;
            data.confidence = enhanced.confidence;
            data.isValidated = enhanced.isValidated;
            // Use matched template's supplier name for Excel export
            // CONDITIONAL FIX (v17): Only override if the template's supplier name
            // actually resembles the detected text — NOT just from generic tokens like
            // "sdn bhd". E.g. "atas frozen marketing sdn bhd" scored 0.4 vs ST ROSYAM
            // only because of shared "sdn bhd" — that should NOT override.
            final tplLower = matchedTemplate.supplierName.toLowerCase();
            final detLower = detectedSupplier.toLowerCase();
            final supplierSim = _templateService.similarityScore(detLower, tplLower);
            print('[TEMPLATE_MATCH] Receipt $i: Supplier similarity score=$supplierSim');
            if (matchedTemplate.supplierName.isNotEmpty && supplierSim >= 0.5) {
              data.supplier = matchedTemplate.supplierName;
              print('[TEMPLATE_MATCH] Receipt $i: Final supplier set to template name="${data.supplier}"');
            } else {
              print('[TEMPLATE_MATCH] Receipt $i: Skipped override — template supplier may be wrong (similarity=$supplierSim < 0.5)');
            }
          } catch (e) {
            debugPrint('Template extraction error: $e');
          }
        } else {
          print('[TEMPLATE_MATCH] Receipt $i: No template matched for "$detectedSupplier"');
        }

        _results.add(data);
        try { if (await originalFile.exists()) await originalFile.delete(); } catch (_) {}
      } catch (e) {
        _results.add(ReceiptData(
          filename: _captures[i].uri.pathSegments.last
              .replaceAll(RegExp(r'^CAP_\d+_'), '')
              .replaceAll(RegExp(r'_scaled_\d+'), '')
              .replaceAll(RegExp(r'_proc$'), '')
              .replaceAll(RegExp(r'_scaled$'), ''),
          description: 'Error: $e',
        ));
      }
    }

    setState(() {
      _processing = false;
      _processedCount = _results.length;
      // Use the first result's supplier (which is the matched template name)
      _processedSupplier = _results.isNotEmpty ? _results.first.supplier : '';
      _lastMatchedTemplate = null; // reset for next batch
      _status = '${_results.length}/${_captures.length} processed';
    });
  }

  /// Estimate skew angle (in degrees) of a document by analyzing row projection.
  /// Returns a small angle if image is reasonably upright.
  double _estimateSkewAngle(img.Image src) {
    final w = src.width;
    final h = src.height;
    if (w < 100 || h < 100) return 0;
    // Downscale for speed: downscale so width = 400 max.
    final scale = (400 / w).clamp(0.15, 0.5);
    final small = img.copyResize(src, width: (w * scale).round(), height: (h * scale).round(), interpolation: img.Interpolation.linear);
    final sw = small.width;
    final sh = small.height;

    // Convert to grayscale threshold map of dark pixels
    final dark = Uint8List(sw * sh);
    int darkCount = 0;
    for (int y = 0; y < sh; y++) {
      for (int x = 0; x < sw; x++) {
        final p = small.getPixel(x, y);
        final r = (p.r * 255).toInt();
        final g = (p.g * 255).toInt();
        final b = (p.b * 255).toInt();
        final luminance = (r * 0.299 + g * 0.587 + b * 0.114).round();
        if (luminance < 120) {
          dark[y * sw + x] = 1;
          darkCount++;
        }
      }
    }
    if (darkCount < 50) return 0;

    // Search angles in range [-15, +15] degrees
    double bestVar = -1;
    double bestAngle = 0;
    for (double angle = -15; angle <= 15; angle += 0.5) {
      final rad = angle * pi / 180.0;
      final c = cos(rad);
      final s = sin(rad);
      // Compute horizontal projection of rotated points.
      // For each dark pixel (x, y), map to rotated x-axis coordinate: xr = x*cos + y*sin.
      // Bins of width 1 over [0, sw].
      final bins = List<int>.filled(sw, 0);
      int maxBin = 0;
      for (int y = 0; y < sh; y++) {
        for (int x = 0; x < sw; x++) {
          if (dark[y * sw + x] == 0) continue;
          // Center around image center
          final dx = x - sw / 2;
          final dy = y - sh / 2;
          final xr = (dx * c + dy * s + sw / 2).round();
          if (xr >= 0 && xr < sw) {
            bins[xr]++;
            if (bins[xr] > maxBin) maxBin = bins[xr];
          }
        }
      }
      // Variance of the projection (higher = more text-line-like)
      double mean = bins.reduce((a, b) => a + b) / bins.length;
      double varSum = 0;
      for (final b in bins) varSum += (b - mean) * (b - mean);
      final v = varSum / bins.length;
      if (v > bestVar) {
        bestVar = v;
        bestAngle = angle;
      }
    }
    return bestAngle;
  }

  Future<ReceiptData> _parseReceiptData(String filename, String rawText) async {
    final lines = rawText.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    final data = ReceiptData(filename: filename);
    if (lines.isEmpty) return data;

    final allText = rawText.toLowerCase();

    // Smart supplier detection: skip lines that look like receipt numbers/dates
    // HIGH-CONFIDENCE keywords: these are specific enough to avoid false positives
    final highConfidenceSuppliers = [
      'qq mee', 'mee stall', 'restoran', 'kopitiam',
      'majestic', 'majestik', 'ong tai', 'kk', 'sin', 'heng',
      'supermarket', 'mart', 'shop', 'store', 'bakeri', 'bakery',
      'tasty', 'poh', 'ayam', 'milo', 'noodle', 'noodles', 'food', 'restaurant',
      'atas frozen', 'top frozen', 'frozen', 'taste good', 'jms',
    ];
    // LOW-CONFIDENCE keywords: generic Malaysian company suffixes — only use if
    // the line also contains a high-confidence word OR matches a template name
    final genericSuffixes = ['sdn bhd', 'enterprise', 'sendirian', 'berhad', 's/b', 'limited', 'ltd'];

    String? detectedSupplier;
    final List<String> candidateLines = [];

    for (final line in lines.take(25)) {
      final lower = line.toLowerCase().trim();
      // Skip obvious non-supplier lines
      if (RegExp(r'^\d+$').hasMatch(line)) continue;
      if (RegExp(r'^\d{4}[-/.]\d{1,2}[-/.]\d{1,2}').hasMatch(line)) continue;
      if (RegExp(r'^\d{1,2}:\d{2}').hasMatch(line)) continue;
      if (RegExp(r'(?:jalan|jln|street|avenue|taman|kawasan|lot|no\.?|persiaran|blk|block)\b', caseSensitive: false).hasMatch(lower)) continue;
      if (RegExp(r'^\d{4,6}\s').hasMatch(line)) continue;
      if (lower.contains('receipt') && lower.length < 25) continue;
      if (lower.contains('invoice') && lower.length < 35) continue;
      if (RegExp(r'^[a-z]?\d{4,}', caseSensitive: false).hasMatch(line)) continue;
      if (RegExp(r'^\([\w\u00C0-\u024F]+\)', caseSensitive: false).hasMatch(line)) continue;
      if (line.length < 3) continue;
      if (RegExp(r'^[\d\s\-_.,:()]+$').hasMatch(line)) continue;
      // Skip lines with sub-branch/location identifiers in parentheses (e.g. "LE CAFE DE FLORA")
      if (RegExp(r'\([A-Z][A-Z\s]{4,}\)').hasMatch(line)) {
        print('[SUPPLIER] Skipped branch line: "$line"');
        continue;
      }
      // Skip lines with obvious mixed-case OCR garbage (e.g. "eaTNIAGA")
      int caseTransitions = 0;
      for (int i = 1; i < line.length; i++) {
        final a = line[i - 1];
        final b = line[i];
        final aUpper = a.codeUnitAt(0) >= 65 && a.codeUnitAt(0) <= 90;
        final bUpper = b.codeUnitAt(0) >= 65 && b.codeUnitAt(0) <= 90;
        final aLower = a.codeUnitAt(0) >= 97 && a.codeUnitAt(0) <= 122;
        final bLower = b.codeUnitAt(0) >= 97 && b.codeUnitAt(0) <= 122;
        if ((aUpper && bLower) || (aLower && bUpper)) caseTransitions++;
      }
      if (caseTransitions >= 3 && line.length >= 6) {
        print('[SUPPLIER] Skipped OCR-garbage (mixed case) line: "$line"');
        continue;
      }

      // Collect all candidate lines for later fuzzy matching against templates
      candidateLines.add(line.trim());

      // Priority 1: High-confidence keyword match
      for (final kw in highConfidenceSuppliers) {
        if (lower.contains(kw)) {
          detectedSupplier = line.trim();
          print('[SUPPLIER] High-confidence match: "$detectedSupplier" (keyword: $kw)');
          break;
        }
      }
      if (detectedSupplier != null) break;

      // Priority 2: Generic suffix ONLY if line also has a non-generic word (>3 chars, not in suffix list)
      bool hasGenericSuffix = false;
      for (final suffix in genericSuffixes) {
        if (lower.contains(suffix)) { hasGenericSuffix = true; break; }
      }
      if (hasGenericSuffix) {
        // Check if line has at least one "real" word (not a generic suffix/component)
        final words = lower.split(RegExp(r'[\s\(\)]+')).where((w) => w.length > 2).toList();
        final realWords = words.where((w) =>
          !genericSuffixes.any((s) => w.contains(s)) &&
          w != 'sdn' && w != 'bhd' && w != 's' && w != 'b' &&
          w != 'marketing' && w != 'enterprise' && w != 'sendirian' && w != 'berhad'
        ).toList();
        if (realWords.isNotEmpty) {
          detectedSupplier = line.trim();
          print('[SUPPLIER] Generic-suffix match: "$detectedSupplier" (real words: $realWords)');
          break;
        }
      }
    }

    // Priority 3: Fuzzy match against existing template names
    if (detectedSupplier == null && candidateLines.isNotEmpty) {
      final templates = _templateService.templates;
      if (templates.isNotEmpty) {
        String? bestMatch;
        double bestScore = 0;
        for (final candidate in candidateLines) {
          final candLower = candidate.toLowerCase();
          for (final tpl in templates) {
            final score = _templateService.similarityScore(candLower, tpl.supplierName.toLowerCase());
            print('[SUPPLIER] Fuzzy candidate: "$candidate" vs template "${tpl.supplierName}" = $score');
            if (score > bestScore && score >= 0.4) {
              bestScore = score;
              bestMatch = tpl.supplierName;
            }
          }
        }
        if (bestMatch != null) {
          detectedSupplier = bestMatch;
          print('[SUPPLIER] Fuzzy matched to template: "$detectedSupplier" (score=$bestScore)');
        }
      }
    }

    // Priority 4: Fallback to first candidate line (weaker)
    if (detectedSupplier == null && candidateLines.isNotEmpty) {
      detectedSupplier = candidateLines.first;
      print('[SUPPLIER] Fallback to first candidate: "$detectedSupplier"');
    }

    data.supplier = detectedSupplier ?? lines.first;
    print('[SUPPLIER] Final supplier: "${data.supplier}"');

    for (final line in lines) {
      final m = RegExp(r'(\d{4}[-/.]\d{1,2}[-/.]\d{1,2})').firstMatch(line);
      if (m != null) { data.date = m.group(1)!; break; }
    }

    for (final line in lines) {
      final m = RegExp(r'(\d{1,2}:\d{2}(:\d{2})?)').firstMatch(line);
      if (m != null) { data.time = m.group(1)!; break; }
    }

    for (final line in lines) {
      final m = RegExp(r'(?:Receipt|Invoice)[#\s:]*([\w/-]+)', caseSensitive: false).firstMatch(line);
      if (m != null) { data.number = m.group(1)!.trim(); break; }
    }

    double best = 0;
    // Priority 1: Look for Total/Amount/Payable with RM prefix
    for (final line in lines) {
      final lower = line.toLowerCase();
      if (lower.contains('total') || lower.contains('amount') || lower.contains('payable') || lower.contains('grand')) {
        final amt = RegExp(r'(?:rm\s*)?([\d,]+\.\d{2})', caseSensitive: false).firstMatch(line);
        if (amt != null) {
          final v = double.tryParse(amt.group(1)!.replaceAll(',', '')) ?? 0;
          if (v > best) best = v;
        }
      }
    }
    // Priority 2: Look for RM X.XX pattern anywhere
    if (best == 0) {
      for (final line in lines) {
        final rmMatch = RegExp(r'rm\s*([\d,]+\.\d{2})', caseSensitive: false).firstMatch(line);
        if (rmMatch != null) {
          final v = double.tryParse(rmMatch.group(1)!.replaceAll(',', '')) ?? 0;
          if (v > best) best = v;
        }
      }
    }
    // Priority 3: Largest decimal number > 1.0 (avoid small prices)
    if (best == 0) {
      for (final line in lines) {
        for (final m in RegExp(r'(\d+\.\d{2})').allMatches(line)) {
          final v = double.tryParse(m.group(1)!) ?? 0;
          if (v > 1.0 && v < 100000 && v > best) best = v;
        }
      }
    }
    data.amount = best;

    final all = rawText.toLowerCase();
    if (all.contains('cash')) data.paymentMethod = 'Cash';
    else if (all.contains('visa') || all.contains('master')) data.paymentMethod = 'Card';
    else if (all.contains('tng') || all.contains('ewallet')) data.paymentMethod = 'TNG eWallet';

    return data;
  }

  Future<void> _exportExcel() async {
    if (_results.isEmpty) return;
    try {
      final supplier = _processedSupplier.isNotEmpty ? _processedSupplier : 'Receipts';
      final filePath = await _excel.createExcel(_results, supplier);
      await _excel.shareViaGmail(filePath, supplier);
    } catch (e) {
      _showSnack('Export error: $e');
    }
  }

  Future<void> _deleteCaptures() async {
    for (final file in _captures) {
      await _sdCard.deleteFile(file.path);
    }
    _refreshCaptures();
    setState(() {
      _results = [];
      _processedCount = 0;
      _status = 'Cleared';
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFF6B35),
      appBar: AppBar(
        title: const Text('IntelliOCR',
            style: TextStyle(fontWeight: FontWeight.bold, color: Colors.white, fontSize: 22)),
        centerTitle: true,
        backgroundColor: const Color(0xFFFF6B35),
        elevation: 0,
      ),
      body: Container(
        decoration: const BoxDecoration(
          gradient: LinearGradient(
            begin: Alignment.topCenter,
            end: Alignment.bottomCenter,
            colors: [Color(0xFFFF6B35), Color(0xFFE85D2C)],
          ),
        ),
        child: SafeArea(
          child: Column(
            children: [
              _buildStatusBar(),
              Expanded(
                child: Container(
                  margin: const EdgeInsets.symmetric(horizontal: 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  clipBehavior: Clip.hardEdge,
                  child: Column(
                    children: [
                      _buildStepsRow(),
                      const Divider(height: 1),
                      Expanded(
                        child: _results.isEmpty ? _buildIdleContent() : _buildResultsContent(),
                      ),
                      _buildActionBar(),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      child: Row(
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(_status,
                    style: const TextStyle(color: Colors.white, fontSize: 14, fontWeight: FontWeight.w500)),
                const SizedBox(height: 4),
                Text('$_totalCount captures | $_processedCount processed',
                    style: TextStyle(color: Colors.white.withOpacity(0.8), fontSize: 12)),
              ],
            ),
          ),
          IconButton(
              icon: const Icon(Icons.refresh, color: Colors.white),
              onPressed: _processing ? null : _refreshCaptures),
        ],
      ),
    );
  }

  Widget _buildStepsRow() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        children: [
          _stepBadge(1, 'Capture', Icons.camera_alt),
          _stepConnector(_captures.isNotEmpty),
          _stepBadge(2, 'Process', Icons.auto_awesome),
          _stepConnector(_results.isNotEmpty),
          _stepBadge(3, 'Export', Icons.ios_share),
        ],
      ),
    );
  }

  Widget _stepBadge(int step, String label, IconData icon) {
    bool active = (step == 1 && _captures.isNotEmpty) ||
        (step == 2 && _results.isNotEmpty) ||
        (step == 3 && _results.isNotEmpty);
    return Expanded(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            width: 32, height: 32,
            decoration: BoxDecoration(
              color: active ? const Color(0xFFFF6B35) : Colors.grey[300],
              borderRadius: BorderRadius.circular(16),
            ),
            child: Icon(icon, size: 16, color: active ? Colors.white : Colors.grey[600]),
          ),
          const SizedBox(height: 2),
          Text(label, style: TextStyle(fontSize: 10, color: active ? const Color(0xFFFF6B35) : Colors.grey[500])),
        ],
      ),
    );
  }

  Widget _stepConnector(bool done) {
    return Container(
      width: 24, height: 2,
      margin: const EdgeInsets.only(bottom: 16),
      color: done ? const Color(0xFFFF6B35) : Colors.grey[300],
    );
  }

  Widget _buildIdleContent() {
    final hasCaptures = _captures.isNotEmpty;
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            hasCaptures ? Icons.inbox : Icons.receipt_long,
            size: 72,
            color: hasCaptures ? Colors.orange[400] : Colors.orange[200],
          ),
          const SizedBox(height: 16),
          Text(
            hasCaptures
                ? '${_captures.length} receipt${_captures.length == 1 ? '' : 's'} ready'
                : 'No receipts yet',
            style: TextStyle(
              fontSize: 18,
              color: Colors.grey[700],
              fontWeight: FontWeight.w500,
            ),
          ),
          const SizedBox(height: 8),
          Text(
            hasCaptures
                ? 'Tap Process to extract data\nor Capture to add more.'
                : 'Capture receipts, then Process\nto extract data.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 14, color: Colors.grey[500]),
          ),
        ],
      ),
    );
  }

  void _deleteResult(int index) {
    setState(() {
      _results.removeAt(index);
      _processedCount = _results.length;
    });
    _showSnack('Record deleted');
  }

  void _viewReceiptImage(int index) async {
    // Find the matching capture file
    final result = _results[index];
    File? sourceFile;
    try {
      final matches = _captures.where((c) => c.uri.pathSegments.last == result.filename);
      if (matches.isNotEmpty) sourceFile = matches.first;
    } catch (_) {}
    if (sourceFile == null) return;
    await showDialog(
      context: context,
      builder: (_) => Dialog(
        insetPadding: const EdgeInsets.all(8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            AppBar(
              leading: IconButton(
                icon: const Icon(Icons.close),
                onPressed: () => Navigator.pop(context),
              ),
              title: Text(result.filename, overflow: TextOverflow.ellipsis),
              backgroundColor: const Color(0xFFFF6B35),
              foregroundColor: Colors.white,
              elevation: 0,
            ),
            ConstrainedBox(
              constraints: BoxConstraints(
                maxHeight: MediaQuery.of(context).size.height * 0.7,
                maxWidth: MediaQuery.of(context).size.width,
              ),
              child: InteractiveViewer(
                child: Image.file(sourceFile!, fit: BoxFit.contain),
              ),
            ),
            Padding(
              padding: const EdgeInsets.all(12),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(child: Text('Supplier: ${result.supplier} | RM ${result.amount.toStringAsFixed(2)}', style: const TextStyle(fontSize: 13), overflow: TextOverflow.ellipsis)),
                  TextButton(onPressed: () { Navigator.pop(context); _deleteResult(index); }, child: const Text('Delete', style: TextStyle(color: Colors.red))),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildResultsContent() {
    return ListView.builder(
      padding: const EdgeInsets.all(12),
      itemCount: _results.length,
      itemBuilder: (context, index) {
        final r = _results[index];
        return Card(
          margin: const EdgeInsets.only(bottom: 8),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
          child: InkWell(
            onTap: () => _viewReceiptImage(index),
            borderRadius: BorderRadius.circular(12),
            child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(r.supplier.isNotEmpty ? r.supplier : r.filename,
                          style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                      decoration: BoxDecoration(
                        color: const Color(0xFFFF6B35).withOpacity(0.15),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Text('RM ${r.amount.toStringAsFixed(2)}',
                          style: const TextStyle(fontWeight: FontWeight.bold,
                              color: Color(0xFFFF6B35), fontSize: 13)),
                    ),
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () => _deleteResult(index),
                      child: Container(
                        padding: const EdgeInsets.all(4),
                        decoration: BoxDecoration(
                          color: Colors.red[50],
                          borderRadius: BorderRadius.circular(6),
                        ),
                        child: Icon(Icons.delete_outline, size: 16, color: Colors.red[400]),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text('${r.date} ${r.time}  |  #${r.number.isNotEmpty ? r.number : '-'}',
                    style: TextStyle(fontSize: 12, color: Colors.grey[600])),
                if (r.items.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  ...r.items.take(3).map((item) => Padding(
                    padding: const EdgeInsets.only(left: 8),
                    child: Text('  ${item.description} x${item.quantity}',
                        style: TextStyle(fontSize: 11, color: Colors.grey[700])),
                  )),
                ],
              ],
            ),
          ),
          ),
        );
      },
    );
  }

  Widget _buildActionBar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.grey[50],
        borderRadius: const BorderRadius.only(
          bottomLeft: Radius.circular(20),
          bottomRight: Radius.circular(20),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          // Pick button density to fit available width.
          // 4 visible buttons (Clear + Capture + Process + Templates) when narrow,
          // and Export button appears only when results exist.
          final showExport = _results.isNotEmpty;
          final bool compact = constraints.maxWidth < 420;

          Widget btn({
            required IconData icon,
            required String label,
            required VoidCallback? onPressed,
            required Color bg,
            required Color fg,
          }) {
            return ElevatedButton(
              onPressed: onPressed,
              style: ElevatedButton.styleFrom(
                backgroundColor: bg,
                foregroundColor: fg,
                shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10)),
                padding: EdgeInsets.symmetric(
                    horizontal: compact ? 6 : 10, vertical: 6),
                minimumSize: Size(0, 34),
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(icon, size: 14),
                  const SizedBox(width: 4),
                  Text(label, style: const TextStyle(fontSize: 11)),
                ],
              ),
            );
          }

          return SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (_captures.isNotEmpty)
                  IconButton(
                    icon: Icon(Icons.delete_outline,
                        color: Colors.grey[600], size: 20),
                    onPressed: _processing ? null : _deleteCaptures,
                    tooltip: 'Clear',
                    padding: EdgeInsets.zero,
                    visualDensity: VisualDensity.compact,
                    constraints: const BoxConstraints(
                        minWidth: 36, minHeight: 36),
                  ),
                if (_captures.isNotEmpty) const SizedBox(width: 4),
                btn(
                  icon: Icons.camera_alt,
                  label: 'Capture',
                  onPressed: () async {
                    await Navigator.push(
                      context,
                      MaterialPageRoute(
                          builder: (_) => const CaptureScreen()),
                    );
                    _refreshCaptures();
                  },
                  bg: Colors.grey[200]!,
                  fg: Colors.grey[800]!,
                ),
                const SizedBox(width: 4),
                btn(
                  icon: _processing ? Icons.refresh : Icons.auto_awesome,
                  label: _processing ? '...' : 'Process',
                  onPressed: _processing ? null : _processReceipts,
                  bg: const Color(0xFFFF6B35),
                  fg: Colors.white,
                ),
                if (showExport) ...[
                  const SizedBox(width: 4),
                  btn(
                    icon: Icons.ios_share,
                    label: 'Export',
                    onPressed: _exportExcel,
                    bg: const Color(0xFFE85D2C),
                    fg: Colors.white,
                  ),
                ],
                const SizedBox(width: 4),
                btn(
                  icon: Icons.folder_copy_outlined,
                  label: 'Templates',
                  onPressed: () => Navigator.push(
                    context,
                    MaterialPageRoute(
                        builder: (_) => const MasterTemplatesScreen()),
                  ),
                  bg: const Color(0xFF6B8EFF),
                  fg: Colors.white,
                ),
              ],
            ),
          );
        },
      ),
    );
  }
}
