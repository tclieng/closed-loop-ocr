/// Result of cross-validating two OCR engine outputs.
class CrossValidationResult {
  /// The fused/merged text after cross-validation.
  final String fusedText;

  /// Confidence score (0.0–1.0) representing agreement level.
  final double confidence;

  /// True if both engines substantially agreed on the output.
  final bool bothAgreed;

  /// Human-readable description of what happened during validation.
  final String description;

  const CrossValidationResult({
    required this.fusedText,
    required this.confidence,
    required this.bothAgreed,
    required this.description,
  });
}

/// Cross-validates text results from two independent OCR engines
/// (Google ML Kit and Tesseract) and produces a fused high-confidence result.
class CrossValidator {
  static final CrossValidator _instance = CrossValidator._();
  factory CrossValidator() => _instance;
  CrossValidator._();

  /// Threshold above which both engines are considered "in agreement".
  static const double _agreementThreshold = 0.75;

  /// Cross-validate two OCR text strings.
  ///
  /// Strategy:
  /// 1. **Exact match** → high confidence, use the result directly.
  /// 2. **High similarity** (>75%) → use the longer/more complete text.
  /// 3. **Moderate similarity** (>40%) → character-level fusion:
  ///    - Align character positions, prefer the more confident source
  ///      at each position where they differ.
  /// 4. **Low similarity** (<40%) → fall back to the result with more content;
  ///    mark as low confidence.
  CrossValidationResult validate(String textA, String textB) {
    final a = textA.trim();
    final b = textB.trim();

    // Handle empty inputs.
    if (a.isEmpty && b.isEmpty) {
      return const CrossValidationResult(
        fusedText: '',
        confidence: 0.0,
        bothAgreed: true,
        description: 'Both empty',
      );
    }
    if (a.isEmpty) {
      return CrossValidationResult(
        fusedText: b,
        confidence: 0.3,
        bothAgreed: false,
        description: 'Engine A empty, using Engine B',
      );
    }
    if (b.isEmpty) {
      return CrossValidationResult(
        fusedText: a,
        confidence: 0.3,
        bothAgreed: false,
        description: 'Engine B empty, using Engine A',
      );
    }

    final similarity = _normalizedSimilarity(a, b);

    // Strategy 1: Exact match
    if (a == b) {
      return CrossValidationResult(
        fusedText: a,
        confidence: 0.95,
        bothAgreed: true,
        description: 'Exact match',
      );
    }

    // Strategy 2: High similarity → pick the longer / more complete text.
    if (similarity >= _agreementThreshold) {
      final betterText = a.length >= b.length ? a : b;
      return CrossValidationResult(
        fusedText: betterText,
        confidence: similarity,
        bothAgreed: true,
        description:
            'High similarity (${(similarity * 100).toStringAsFixed(0)}%)',
      );
    }

    // Strategy 3: Moderate similarity → character-level fusion
    if (similarity >= 0.40) {
      final fused = _fuseTexts(a, b);
      final fusedSim = _normalizedSimilarity(fused, a);
      return CrossValidationResult(
        fusedText: fused,
        confidence: fusedSim.clamp(0.4, 0.8),
        bothAgreed: false,
        description:
            'Fused from partial match (${(similarity * 100).toStringAsFixed(0)}%)',
      );
    }

    // Strategy 4: Low similarity → prefer the longer result
    return CrossValidationResult(
      fusedText: a.length >= b.length ? a : b,
      confidence: 0.25,
      bothAgreed: false,
      description:
          'Low similarity (${(similarity * 100).toStringAsFixed(0)}%)',
    );
  }

  /// Compute normalized Levenshtein similarity (0.0–1.0).
  /// Handles whitespace normalization.
  double _normalizedSimilarity(String a, String b) {
    // Normalize whitespace
    final na = a.replaceAll(RegExp(r'\s+'), ' ').trim();
    final nb = b.replaceAll(RegExp(r'\s+'), ' ').trim();

    if (na.isEmpty && nb.isEmpty) return 1.0;
    if (na.isEmpty || nb.isEmpty) return 0.0;

    final dist = _levenshtein(na.toLowerCase(), nb.toLowerCase());
    final maxLen = na.length > nb.length ? na.length : nb.length;
    return maxLen > 0 ? 1.0 - (dist / maxLen) : 0.0;
  }

  /// Levenshtein edit distance between two strings.
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
          matrix[i - 1][j - 1] + cost,
        ].reduce((a, b) => a < b ? a : b);
      }
    }
    return matrix[a.length][b.length];
  }

  /// Fuse two moderately similar strings at the character level.
  ///
  /// Alignment algorithm:
  /// - Align both strings using edit operations.
  /// - At each position where they differ, prefer the character from
  ///   the engine that produced a more plausible result (based on
  ///   character frequency and common OCR confusions).
  String _fuseTexts(String a, String b) {
    // Character-level fusion using edit alignment
    final result = StringBuffer();
    int i = 0, j = 0;

    while (i < a.length || j < b.length) {
      if (i >= a.length) {
        result.write(b.substring(j));
        break;
      }
      if (j >= b.length) {
        result.write(a.substring(i));
        break;
      }

      if (a[i] == b[j]) {
        result.write(a[i]);
        i++;
        j++;
      } else if (i + 1 < a.length && a[i + 1] == b[j]) {
        // Insertion in A (extra char in A) → skip
        i++;
      } else if (j + 1 < b.length && a[i] == b[j + 1]) {
        // Insertion in B (extra char in B) → skip
        j++;
      } else {
        // Substitution: prefer the character that OCR more likely got right.
        // Rule of thumb: prefer alphanumeric over symbol, uppercase over
        // lowercase when the other is lowercase, and the longer word segment.
        if (_isPreferred(a[i], b[j])) {
          result.write(a[i]);
        } else {
          result.write(b[j]);
        }
        i++;
        j++;
      }
    }

    return result.toString().trim();
  }

  /// Heuristic: which character is more likely correct at a substitution site.
  bool _isPreferred(String charA, String charB) {
    if (charA == charB) return true;
    // Prefer alphanumeric over punctuation/symbol.
    final aAlpha = RegExp(r'[a-zA-Z0-9]').hasMatch(charA);
    final bAlpha = RegExp(r'[a-zA-Z0-9]').hasMatch(charB);
    if (aAlpha && !bAlpha) return true;
    if (!aAlpha && bAlpha) return false;
    // Prefer uppercase when the other is lowercase (OCR often drops case).
    if (charA.toUpperCase() == charB && charA != charB) return true;
    // Otherwise prefer character from longer text.
    return false;
  }
}
