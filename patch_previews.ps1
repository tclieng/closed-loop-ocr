$file = 'C:\Users\MK-User\.qclaw\workspace\intelliocr-scanner\lib\screens\template_editor_screen.dart'
$content = Get-Content $file -Raw

$old1 = "// Master image preview with anchor overlays`n          _buildAnchorOverlayPreview(`n            showAnchors: const ['A', 'B'],`n            onAnchorChanged: _updateAnchorInMemory,`n            onAnchorLongPress: (id) {`n              if (id == 'a') _setAnchorA();`n              if (id == 'b') _setAnchorB();`n            },`n          ),"
$new1 = "// Master image preview with anchor overlays`n          _buildAnchorOverlayPreview(`n            showAnchors: const ['A', 'B'],`n            onAnchorChanged: _updateAnchorInMemory,`n            onAnchorLongPress: (id) {`n              if (id == 'a') _setAnchorA();`n              if (id == 'b') _setAnchorB();`n            },`n            onTapOpenEditor: () => _openFullscreenAnchorEditor(['A', 'B']),`n          ),"

$old2 = "// Master image preview with Anchor A/B overlays`n          _buildAnchorOverlayPreview(`n            showAnchors: const ['A', 'B'],`n            onAnchorChanged: _updateAnchorInMemory,`n            onAnchorLongPress: (id) {`n              if (id == 'a') _setAnchorA();`n              if (id == 'b') _setAnchorB();`n            },`n          ),"
$new2 = "// Master image preview with Anchor A/B overlays`n          _buildAnchorOverlayPreview(`n            showAnchors: const ['A', 'B'],`n            onAnchorChanged: _updateAnchorInMemory,`n            onAnchorLongPress: (id) {`n              if (id == 'a') _setAnchorA();`n              if (id == 'b') _setAnchorB();`n            },`n            onTapOpenEditor: () => _openFullscreenAnchorEditor(['A', 'B']),`n          ),"

$content = $content.Replace($old1, $new1)
$content = $content.Replace($old2, $new2)

Set-Content -Path $file -Value $content -NoNewline
Write-Host "Done. Replacements made:"
Write-Host "  old1: $($content.Substring(0,0)) (check grep)"