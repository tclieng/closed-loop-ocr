import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:path_provider/path_provider.dart';
import '../models/receipt_template.dart';

/// Service for managing supplier receipt templates (CRUD).
class TemplateService {
  static final TemplateService _instance = TemplateService._();
  factory TemplateService() => _instance;
  TemplateService._();

  List<ReceiptTemplate> _templates = [];

  List<ReceiptTemplate> get templates => List.unmodifiable(_templates);

  Future<String> get _storagePath async {
    final appDir = await getApplicationDocumentsDirectory();
    final dir = Directory('${appDir.path}/templates');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir.path;
  }

  /// Load all saved templates from storage.
  Future<void> loadTemplates() async {
    final path = await _storagePath;
    final indexFile = File('$path/index.json');
    if (await indexFile.exists()) {
      final content = await indexFile.readAsString();
      final ids = List<String>.from(jsonDecode(content));
      _templates = [];
      for (final id in ids) {
        final tplFile = File('$path/$id.json');
        if (await tplFile.exists()) {
          final tpl = ReceiptTemplate.fromJsonString(
              await tplFile.readAsString());
          _templates.add(tpl);
        }
      }
    }
  }

  /// Save a template to persistent storage.
  Future<void> saveTemplate(ReceiptTemplate template) async {
    final path = await _storagePath;
    final tplFile = File('$path/${template.id}.json');
    await tplFile.writeAsString(template.toJsonString());

    // Update index
    if (!_templates.any((t) => t.id == template.id)) {
      _templates.add(template);
    } else {
      final idx = _templates.indexWhere((t) => t.id == template.id);
      _templates[idx] = template;
    }
    await _saveIndex(path);
  }

  /// Delete a template by ID.
  Future<void> deleteTemplate(String id) async {
    final path = await _storagePath;
    final tplFile = File('$path/$id.json');
    if (await tplFile.exists()) await tplFile.delete();
    _templates.removeWhere((t) => t.id == id);
    await _saveIndex(path);
  }

  /// Find a matching template by supplier name or header text.
  ReceiptTemplate? findTemplateBySupplier(String supplierName) {
    final name = supplierName.toLowerCase();
    for (final tpl in _templates) {
      if (tpl.supplierName.toLowerCase().contains(name)) return tpl;
      if (tpl.anchorA != null &&
          tpl.anchorA!.expectedText.toLowerCase().contains(name)) return tpl;
    }
    return null;
  }

  /// Find the best-matching template for a receipt by its detected supplier-name
  /// text (OCR of the receipt header). Uses token overlap + (best-effort)
  /// Levenshtein similarity against each template's `supplierName` and anchor A
  /// expected text. Returns the best template if its score meets [threshold].
  ReceiptTemplate? findBestTemplateByHeader(String headerText,
      {double threshold = 0.5}) {
    final text = headerText.toLowerCase();
    if (text.trim().isEmpty) return null;

    ReceiptTemplate? best;
    double bestScore = 0;
    String bestScoreDetail = '';
    for (final tpl in _templates) {
      if (!tpl.isComplete) continue;
      final name = tpl.supplierName.toLowerCase();
      final anchor = tpl.anchorA?.expectedText.toLowerCase() ?? '';
      final scoreName = _fuzzyScore(text, name);
      final scoreAnchor =
          anchor.isNotEmpty ? _fuzzyScore(text, anchor) : 0.0;
      final score = scoreName >= scoreAnchor ? scoreName : scoreAnchor;
      final detail = scoreName >= scoreAnchor
          ? 'name=$scoreName (text="$text" vs name="$name")'
          : 'anchor=$scoreAnchor (text="$text" vs anchor="$anchor")';
      print('[TEMPLATE_SCORING] Template "${tpl.supplierName}": $detail');
      if (score > bestScore) {
        bestScore = score;
        best = tpl;
        bestScoreDetail = detail;
      }
    }
    if (best != null) {
      print('[TEMPLATE_SCORING] Best match: "${best.supplierName}" score=$bestScore $bestScoreDetail >= threshold $threshold? ${bestScore >= threshold}');
    }
    // Reject matches that rely only on generic tokens (sdn, bhd, sdn bhd, etc.)
    // These are common across many Malaysian company names and cause false positives.
    if (best != null && bestScore >= threshold) {
      final genericTokens = {'sdn', 'bhd', 'sdn bhd', 's/b', 'sendirian', 'berhad'};
      final textTokens = text.split(RegExp(r'\s+')).where((t) => t.length >= 2).toSet();
      final nameTokens = best.supplierName.toLowerCase().split(RegExp(r'\s+')).where((t) => t.length >= 2).toSet();
      final nonGenericText = textTokens.difference(genericTokens);
      final nonGenericName = nameTokens.difference(genericTokens);
      final nonGenericOverlap = nonGenericText.intersection(nonGenericName).length;
      final maxNonGeneric = nonGenericText.length > nonGenericName.length ? nonGenericText.length : nonGenericName.length;
      final nonGenericScore = maxNonGeneric > 0 ? nonGenericOverlap / maxNonGeneric : 0.0;
      print('[TEMPLATE_SCORING] Non-generic overlap: $nonGenericOverlap / $maxNonGeneric = $nonGenericScore');
      if (nonGenericScore < 0.3) {
        print('[TEMPLATE_SCORING] REJECTED — match relies only on generic tokens (sdn/bhd/etc)');
        return null;
      }
    }
    return bestScore >= threshold ? best : null;
  }

  /// Combined fuzzy score in [0,1]: substring / containment first, then token
  /// overlap (normalized by the smaller token set) with partial-token matching.
  double _fuzzyScore(String text, String target) {
    if (target.isEmpty || text.isEmpty) return 0;
    final tt = text.replaceAll(RegExp(r'\s+'), ' ').trim();
    final tg = target.replaceAll(RegExp(r'\s+'), ' ').trim();
    if (tt.isEmpty || tg.isEmpty) return 0;
    if (tg.contains(tt) || tt.contains(tg)) return 1.0;
    final ttc = tt.replaceAll(' ', '');
    final tgc = tg.replaceAll(' ', '');
    if (tgc.contains(ttc) || ttc.contains(tgc)) return 1.0;

    final textTokens = tt.split(' ').where((t) => t.length >= 2).toSet();
    final targetTokens = tg.split(' ').where((t) => t.length >= 2).toList();
    if (textTokens.isEmpty || targetTokens.isEmpty) return 0;

    int overlap = 0;
    for (final x in textTokens) {
      final hit = targetTokens.any((y) =>
          y == x || y.startsWith(x) || x.startsWith(y) || _levenshtein(x, y) <= 1);
      if (hit) overlap++;
    }
    return overlap / min(textTokens.length, targetTokens.length);
  }

  /// Public wrapper for _fuzzyScore — computes similarity between two strings
  /// using the same token-overlap algorithm. Returns 0..1.
  double similarityScore(String text, String target) =>
      _fuzzyScore(text, target);


  int _levenshtein(String a, String b) {
    if (a.isEmpty) return b.length;
    if (b.isEmpty) return a.length;
    final matrix =
        List.generate(a.length + 1, (_) => List.filled(b.length + 1, 0));
    for (int i = 0; i <= a.length; i++) matrix[i][0] = i;
    for (int j = 0; j <= b.length; j++) matrix[0][j] = j;
    for (int i = 1; i <= a.length; i++) {
      for (int j = 1; j <= b.length; j++) {
        final cost = a[i - 1] == b[j - 1] ? 0 : 1;
        matrix[i][j] = [
          matrix[i - 1][j] + 1,
          matrix[i][j - 1] + 1,
          matrix[i - 1][j - 1] + cost
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return matrix[a.length][b.length];
  }

  /// Get a template by ID.
  ReceiptTemplate? getTemplate(String id) {
    try {
      return _templates.firstWhere((t) => t.id == id);
    } catch (_) {
      return null;
    }
  }

  int get templateCount => _templates.length;

  Future<void> _saveIndex(String path) async {
    final indexFile = File('$path/index.json');
    await indexFile.writeAsString(
        jsonEncode(_templates.map((t) => t.id).toList()));
  }

  /// Copy a master template image to app storage.
  Future<String?> saveMasterImage(String templateId, File sourceImage) async {
    final path = await _storagePath;
    final destDir = Directory('$path/images');
    if (!await destDir.exists()) await destDir.create(recursive: true);
    final destFile = File('${destDir.path}/${templateId}_master.jpg');
    await sourceImage.copy(destFile.path);
    return destFile.path;
  }
}
