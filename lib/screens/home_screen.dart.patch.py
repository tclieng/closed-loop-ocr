# Patch home_screen.dart: restore conditional supplier override (v17 fix)
# and raise threshold to 0.5

import re, sys

with open(sys.argv[1], 'r', encoding='utf-8') as f:
    content = f.read()

# Fix 1: Lower threshold from 0.4 to 0.5
content = content.replace(
    "                threshold: 0.4);",
    "                threshold: 0.5);"
)

# Fix 2: Add supplier similarity check before unconditional override
# Replace the unconditional override with a conditional one
old_block = """            // Use matched template's supplier name for Excel export
            // Only override if template matched — keep per-receipt supplier otherwise
            if (matchedTemplate.supplierName.isNotEmpty) {
              data.supplier = matchedTemplate.supplierName;
              print('[TEMPLATE_MATCH] Receipt $i: Final supplier set to template name="${data.supplier}"');
            }"""

new_block = """            // Use matched template's supplier name for Excel export
            // CONDITIONAL FIX (v17): Only override if the template's supplier name
            // actually resembles the detected text — NOT just from generic tokens like
            // "sdn bhd". E.g. "atas frozen marketing sdn bhd" scored 0.4 vs ST ROSYAM
            // only because of shared "sdn bhd" — that should NOT override.
            final tplLower = matchedTemplate.supplierName.toLowerCase();
            final detLower = detectedSupplier.toLowerCase();
            final supplierSim = _templateService._fuzzyScore(detLower, tplLower);
            print('[TEMPLATE_MATCH] Receipt $i: Supplier similarity score=$supplierSim');
            if (matchedTemplate.supplierName.isNotEmpty && supplierSim >= 0.5) {
              data.supplier = matchedTemplate.supplierName;
              print('[TEMPLATE_MATCH] Receipt $i: Final supplier set to template name="${data.supplier}"');
            } else {
              print('[TEMPLATE_MATCH] Receipt $i: Skipped override — template supplier may be wrong (similarity=$supplierSim < 0.5)');
            }"""

if old_block not in content:
    print("ERROR: Could not find old block to replace")
    sys.exit(1)

content = content.replace(old_block, new_block)

with open(sys.argv[1], 'w', encoding='utf-8') as f:
    f.write(content)

print("Patched successfully")
