# Patch template_service.dart: add minimum non-generic token overlap
# to prevent "sdn bhd" only matches

import re, sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    content = f.read()

# Find the findBestTemplateByHeader method and add minNonGenericOverlap check
old_block = """    if (best != null) {
      print('[TEMPLATE_SCORING] Best match: "${best.supplierName}" score=$bestScore $bestScoreDetail >= threshold $threshold? ${bestScore >= threshold}');
    }
    return bestScore >= threshold ? best : null;"""

new_block = """    if (best != null) {
      print('[TEMPLATE_SCORING] Best match: "${best.supplierName}" score=$bestScore $bestScoreDetail >= threshold $threshold? ${bestScore >= threshold}');
    }
    // Reject matches that rely only on generic tokens (sdn, bhd, sdn bhd, etc.)
    // These are common across many Malaysian company names and cause false positives.
    if (best != null && bestScore >= threshold) {
      final genericTokens = {'sdn', 'bhd', 'sdn bhd', 's/b', 'sendirian', 'berhad'};
      final textTokens = text.split(RegExp(r'\\s+')).where((t) => t.length >= 2).toSet();
      final nameTokens = best.supplierName.toLowerCase().split(RegExp(r'\\s+')).where((t) => t.length >= 2).toSet();
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
    return bestScore >= threshold ? best : null;"""

if old_block not in content:
    print("ERROR: Could not find old block")
    sys.exit(1)

content = content.replace(old_block, new_block)

with open(sys.argv[1], 'w', encoding='utf-8') as f:
    f.write(content)

print("Patched successfully")
