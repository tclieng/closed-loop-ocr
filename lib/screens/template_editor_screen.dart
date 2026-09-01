import 'dart:io';
import 'package:flutter/material.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../services/template_service.dart';
import '../services/image_processor.dart';
import '../models/receipt_template.dart';
import '../models/anchor_point.dart';
import '../models/field_roi.dart';

/// Template Editor Wizard — Phase 1 Steps 1-6
/// Step 1: Capture / Import master receipt
/// Step 2: Set Anchor A & B (header anchors)
/// Step 3: Configure ROI fields
/// Step 4: Configure item table
/// Step 5: Set Anchor C (dynamic footer anchor)
/// Step 6: Save template
class TemplateEditorScreen extends StatefulWidget {
  final ReceiptTemplate? existingTemplate;

  const TemplateEditorScreen({super.key, this.existingTemplate});

  @override
  State<TemplateEditorScreen> createState() => _TemplateEditorScreenState();
}

class _TemplateEditorScreenState extends State<TemplateEditorScreen> {
  final TemplateService _templateService = TemplateService();
  final ImagePicker _picker = ImagePicker();

  // Wizard state
  int _currentStep = 0;
  late ReceiptTemplate _template;
  File? _masterImage;
  img.Image? _processedImage;

  // Field editor state
  final List<FieldROI> _tempFields = [];
  @pragma('vm:not-useless')
  String _selectedFieldType = 'store_name';

  // Item table config
  ItemTableConfig? _itemTableConfig;

  @override
  void initState() {
    super.initState();
    if (widget.existingTemplate != null) {
      _template = widget.existingTemplate!;
      _tempFields.addAll(_template.fields);
      _itemTableConfig = _template.itemTableConfig;
    } else {
      final id = 'TPL_${DateTime.now().millisecondsSinceEpoch}';
      _template = ReceiptTemplate(id: id, supplierName: '');
    }
  }

  // ── Step Navigation ──

  void _nextStep() {
    if (_currentStep < 5) setState(() => _currentStep++);
  }

  void _prevStep() {
    if (_currentStep > 0) setState(() => _currentStep--);
  }

  bool get _canProceed {
    switch (_currentStep) {
      case 0: return _masterImage != null;
      case 1: return _template.anchorA != null && _template.anchorB != null;
      case 2: return _itemTableConfig != null;     // Step 3 = Item Table
      case 3: return _tempFields.isNotEmpty;       // Step 4 = ROI Fields
      case 4: return _template.anchorC != null;
      case 5: return true;
      default: return false;
    }
  }

  // ── Step 1: Capture Master Receipt ──

  Future<void> _captureMaster() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 90,
    );
    if (photo == null) return;

    setState(() {});

    // Process the image
    final bytes = await File(photo.path).readAsBytes();
    final processedBytes = await ImageProcessor.processReceipt(bytes);

    _masterImage = File(photo.path.replaceAll('.jpg', '_master.jpg'));
    await _masterImage!.writeAsBytes(processedBytes);
    _processedImage = img.decodeImage(processedBytes);

    if (_processedImage != null) {
      _template.masterWidth = _processedImage!.width.toDouble();
      _template.masterHeight = _processedImage!.height.toDouble();
    }
    setState(() {});
  }

  Future<void> _pickMasterFromGallery() async {
    final image = await _picker.pickImage(source: ImageSource.gallery);
    if (image == null) return;

    final bytes = await File(image.path).readAsBytes();
    final processedBytes = await ImageProcessor.processReceipt(bytes);

    _masterImage = File(image.path.replaceAll('.jpg', '_master.jpg'));
    await _masterImage!.writeAsBytes(processedBytes);
    _processedImage = img.decodeImage(processedBytes);

    if (_processedImage != null) {
      _template.masterWidth = _processedImage!.width.toDouble();
      _template.masterHeight = _processedImage!.height.toDouble();
    }
    setState(() {});
  }

  // ── Step 1: Rotate Master ──

  void _rotateMaster(int degrees) {
    if (_processedImage == null) return;
    setState(() {
      _processedImage = img.copyRotate(_processedImage!, angle: degrees);
      // Persist rotated bytes so later reads match what user sees.
      final bytes = img.encodeJpg(_processedImage!, quality: 92);
      _masterImage?.writeAsBytes(bytes);
      _template.masterWidth = _processedImage!.width.toDouble();
      _template.masterHeight = _processedImage!.height.toDouble();
      // Clear any anchors that were drawn on the pre-rotation image
      // (their pixel coordinates would no longer be valid).
      if (degrees % 360 != 0) {
        _template.anchorA = null;
        _template.anchorB = null;
        _template.anchorC = null;
      }
    });
  }

  // ── Step 2: Set Header Anchors ──

  void _setAnchorA() {
    _showAnchorDialog(
      'Anchor A — Supplier Name',
      'Enter the supplier name as it appears on the receipt.\n'
      'This will also be used as the template name.',
      (roi, text) {
        setState(() {
          _template.anchorA = AnchorPoint(
            id: 'anchor_a',
            label: 'Supplier Logo/Name',
            type: 'header_a',
            roi: roi,
            expectedText: text,
            position: (roi.top + roi.bottom) / 2 / _processedImage!.height,
          );
          // Auto-set supplier name from Anchor A text (always update if text is not empty)
          if (text.isNotEmpty) {
            _template.supplierName = text;
          }
        });
      },
    );
  }

  void _setAnchorB() {
    _showAnchorDialog(
      'Anchor B — Tax Invoice / GST',
      'Select the ROI for "TAX INVOICE", "OFFICIAL RECEIPT",\nor GST Registration Number.',
      (roi, text) {
        setState(() {
          _template.anchorB = AnchorPoint(
            id: 'anchor_b',
            label: 'Tax Invoice / GST',
            type: 'header_b',
            roi: roi,
            expectedText: text,
            position: (roi.top + roi.bottom) / 2 / _processedImage!.height,
          );
        });
      },
    );
  }

  // ── Step 3: Add ROI Fields ──

  void _addField() {
    // Simple dialog to add a new field
    showDialog(
      context: context,
      builder: (ctx) => _FieldSelectorDialog(
        availableFields: FieldROI.availableFields,
        onSelected: (fieldName, label) {
          Navigator.of(ctx).pop();
          // Draw ROI on image for this field
          _showRoiDrawer(fieldName, label);
        },
      ),
    );
  }

  void _showRoiDrawer(String fieldName, String label) {
    if (_masterImage == null) return;

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Draw ROI for "$label"'),
        content: SizedBox(
          width: 300,
          height: 400,
          child: Column(
            children: [
              Expanded(
                child: Container(
                  color: Colors.grey[200],
                  child: Center(
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Icon(Icons.touch_app, size: 48, color: Colors.grey),
                        const SizedBox(height: 8),
                        Text(
                          'You will define the ROI on the\nmaster receipt image.\n\nROI will be stored for OCR.',
                          textAlign: TextAlign.center,
                          style: TextStyle(color: Colors.grey[600]),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              // Add a placeholder ROI (full image width, centered)
              final h = _processedImage?.height.toDouble() ?? 1000;
              final w = _processedImage?.width.toDouble() ?? 800;
              final roi = Rect.fromLTWH(w * 0.05, h * 0.3, w * 0.9, h * 0.06);
              final field = FieldROI(
                id: 'field_${DateTime.now().millisecondsSinceEpoch}',
                fieldName: fieldName,
                displayLabel: label,
                roi: roi,
                isRequired: fieldName == 'total' || fieldName == 'date',
                validationRule: fieldName == 'date'
                    ? 'date'
                    : fieldName == 'total' || fieldName == 'subtotal' || fieldName == 'tax'
                        ? 'numeric'
                        : fieldName == 'currency'
                            ? 'currency'
                            : 'text',
              );
              setState(() {
                _tempFields.add(field);
                _template.fields = List.from(_tempFields);
              });
              Navigator.of(ctx).pop();
            },
            child: const Text('Add (auto-ROI)'),
          ),
        ],
      ),
    );
  }

  void _removeField(int index) {
    setState(() {
      _tempFields.removeAt(index);
      _template.fields = List.from(_tempFields);
    });
  }

  // ── Step 3: Configure Item Table ──

  /// Open the full-screen editor for the yellow item-table ROI.
  ///
  /// Constraints from the user:
  ///  • Yellow area starts horizontally AFTER Anchor B (right of B).
  ///  • Yellow area ends horizontally just BEFORE Anchor C (left of C).
  ///  • User can drag/resize within those horizontal bounds.
  Future<void> _openFullscreenItemTableEditor() async {
    if (_processedImage == null) return;

    // Seed initial tableRoi: full width, vertical band between Anchor B.bottom and Anchor C.top.
    final imgW = _processedImage!.width.toDouble();
    final imgH = _processedImage!.height.toDouble();
    final bRoi = _template.anchorB?.roi;
    final cRoi = _template.anchorC?.roi;

    Rect initial;
    if (bRoi != null && cRoi != null && cRoi.top > bRoi.bottom) {
      // Fit vertically between B.bottom (4px gap) and C.top (4px gap).
      final top = bRoi.bottom + 4.0;
      final bottom = cRoi.top - 4.0;
      initial = Rect.fromLTRB(0.0, top, imgW, bottom);
    } else if (bRoi != null) {
      // Only B set: start just below B, 40% of image height, full width.
      initial = Rect.fromLTRB(
        0.0,
        bRoi.bottom + 4.0,
        imgW,
        (bRoi.bottom + 4.0 + imgH * 0.4).clamp(bRoi.bottom + 4.0, imgH).toDouble(),
      );
    } else if (cRoi != null) {
      // Only C set: end just above C, 40% height, full width.
      initial = Rect.fromLTRB(
        0.0,
        (cRoi.top - 4.0 - imgH * 0.4).clamp(0.0, cRoi.top - 4.0).toDouble(),
        imgW,
        cRoi.top - 4.0,
      );
    } else {
      // No anchors: fallback full-width middle band.
      initial = Rect.fromLTWH(0.0, imgH * 0.35, imgW, imgH * 0.4);
    }

    final updated = await Navigator.of(context).push<Rect>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenItemTableEditor(
          image: _processedImage!,
          initialRoi: initial,
          anchorB: _template.anchorB,
          anchorC: _template.anchorC,
        ),
      ),
    );

    if (updated == null) return;

    // Distribute the 5 column ROIs proportionally across the new table width.
    final tbl = updated;
    final colWidths = _distributeColumns(tbl.width);

    setState(() {
      _itemTableConfig = ItemTableConfig(
        id: 'table_${DateTime.now().millisecondsSinceEpoch}',
        tableRoi: tbl,
        quantityColumn: Rect.fromLTWH(tbl.left + _sum(colWidths, 0), tbl.top, colWidths[0], tbl.height),
        descriptionColumn: Rect.fromLTWH(tbl.left + _sum(colWidths, 1), tbl.top, colWidths[1], tbl.height),
        unitPriceColumn: Rect.fromLTWH(tbl.left + _sum(colWidths, 2), tbl.top, colWidths[2], tbl.height),
        discountColumn: Rect.fromLTWH(tbl.left + _sum(colWidths, 3), tbl.top, colWidths[3], tbl.height),
        amountColumn: Rect.fromLTWH(tbl.left + _sum(colWidths, 4), tbl.top, colWidths[4], tbl.height),
      );
      _template.itemTableConfig = _itemTableConfig;
    });
  }

  /// Distribute table width across [qty, desc, price, discount, amount]
  /// as proportional weights: 8%, 42%, 15%, 10%, 25% = 100%.
  List<double> _distributeColumns(double totalWidth) {
    const weights = [0.08, 0.42, 0.15, 0.10, 0.25];
    return weights.map((w) => totalWidth * w).toList();
  }

  double _sum(List<double> arr, int endInclusive) {
    double s = 0;
    for (var i = 0; i <= endInclusive; i++) {
      s += arr[i];
    }
    return s;
  }

  // ── Step 5: Set Footer Anchor (Anchor C) ──

  void _setAnchorC() {
    _showAnchorDialog(
      'Anchor C — Dynamic Footer',
      'Select the "TOTAL", "GRAND TOTAL", "BALANCE DUE",\nor "PAYMENT" area.\n'
          'This is a dynamic anchor positioned after the item table.',
      (roi, text) {
        setState(() {
          final h = _processedImage?.height.toDouble() ?? 1000;
          _template.anchorC = AnchorPoint(
            id: 'anchor_c',
            label: 'Total/Payment',
            type: 'footer_c',
            roi: roi,
            expectedText: text,
            position: (roi.top + roi.bottom) / 2 / h,
          );
        });
      },
    );
  }

  // ── In-memory anchor geometry edit (drag/resize) ──

  /// Updates an anchor's ROI (in image pixel coords) WITHOUT persisting to disk.
  /// The change takes effect immediately in the UI and is held in
  /// _template.{anchorA,anchorB,anchorC} until the user reaches Step 6 and
  /// presses Save. This avoids accidentally writing to JSON on every drag tick.
  void _updateAnchorInMemory(String anchorId, Rect newRoi) {
    final h = _processedImage?.height.toDouble() ?? 1000;
    final w = _processedImage?.width.toDouble() ?? 800;
    // Clamp to image bounds.
    final clamped = Rect.fromLTWH(
      newRoi.left.clamp(0.0, w - 1),
      newRoi.top.clamp(0.0, h - 1),
      newRoi.width.clamp(20.0, w),
      newRoi.height.clamp(10.0, h),
    );
    setState(() {
      switch (anchorId) {
        case 'a':
          final prev = _template.anchorA;
          if (prev == null) return;
          _template.anchorA = AnchorPoint(
            id: prev.id,
            label: prev.label,
            type: prev.type,
            roi: clamped,
            expectedText: prev.expectedText,
            imageFingerprint: prev.imageFingerprint,
            position: (clamped.top + clamped.bottom) / 2 / h,
            size: clamped.width * clamped.height,
            confidenceThreshold: prev.confidenceThreshold,
          );
          break;
        case 'b':
          final prev = _template.anchorB;
          if (prev == null) return;
          _template.anchorB = AnchorPoint(
            id: prev.id,
            label: prev.label,
            type: prev.type,
            roi: clamped,
            expectedText: prev.expectedText,
            imageFingerprint: prev.imageFingerprint,
            position: (clamped.top + clamped.bottom) / 2 / h,
            size: clamped.width * clamped.height,
            confidenceThreshold: prev.confidenceThreshold,
          );
          break;
        case 'c':
          final prev = _template.anchorC;
          if (prev == null) return;
          _template.anchorC = AnchorPoint(
            id: prev.id,
            label: prev.label,
            type: prev.type,
            roi: clamped,
            expectedText: prev.expectedText,
            imageFingerprint: prev.imageFingerprint,
            position: (clamped.top + clamped.bottom) / 2 / h,
            size: clamped.width * clamped.height,
            confidenceThreshold: prev.confidenceThreshold,
          );
          break;
      }
    });
  }

  // ── Common: Anchor ROI Dialog ──

  void _showAnchorDialog(
      String title, String description, void Function(Rect roi, String text) onSet) {
    final textController = TextEditingController();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text(title),
        content: SizedBox(
          width: 320,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(description, style: const TextStyle(fontSize: 13)),
                const SizedBox(height: 16),
                const Text('Expected text (OCR will verify this anchor):'),
                const SizedBox(height: 8),
                TextField(
                  decoration: const InputDecoration(
                    hintText: 'e.g. TASTY NAME',
                    border: OutlineInputBorder(),
                    contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                  ),
                  controller: textController,
                ),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              final h = _processedImage?.height.toDouble() ?? 1000;
              final w = _processedImage?.width.toDouble() ?? 800;
              // Auto-set ROI based on anchor type
              final isA = title.startsWith('Anchor A');
              final isB = title.startsWith('Anchor B');
              final roi = isA
                  ? Rect.fromLTWH(w * 0.10, h * 0.04, w * 0.80, h * 0.08)
                  : isB
                      ? Rect.fromLTWH(w * 0.10, h * 0.16, w * 0.80, h * 0.08)
                      : Rect.fromLTWH(w * 0.1, h * 0.8, w * 0.8, h * 0.06);
              onSet(roi, textController.text.trim());
              Navigator.of(ctx).pop();
            },
            child: const Text('Set Auto-ROI'),
          ),
        ],
      ),
    );
  }

  // ── Fullscreen Anchor Editor ──

  Future<void> _openFullscreenAnchorEditor(List<String> anchorIdsToShow) async {
    if (_processedImage == null) return;
    final colorMap = {
      'A': const Color(0xFFD32F2F),
      'B': const Color(0xFF1976D2),
      'C': const Color(0xFF388E3C),
    };
    final anchors = {
      for (final id in anchorIdsToShow)
        id: id == 'A'
            ? _template.anchorA
            : id == 'B'
                ? _template.anchorB
                : _template.anchorC,
    };
    await Navigator.of(context).push(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FullscreenAnchorEditor(
          image: _processedImage!,
          anchors: anchors,
          anchorIdsToShow: anchorIdsToShow,
          anchorColors: colorMap,
          onAnchorChanged: _updateAnchorInMemory,
        ),
      ),
    );
  }

  // ── Save Template (Step 6) ──

  Future<void> _saveTemplate() async {
    _template.fields = List.from(_tempFields);
    _template.itemTableConfig = _itemTableConfig;
    _template.updatedAt = DateTime.now();

    // Save master image
    if (_masterImage != null) {
      _template.masterImagePath =
          await _templateService.saveMasterImage(_template.id, _masterImage!);
    }

    await _templateService.saveTemplate(_template);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('✅ Template "${_template.supplierName}" saved!'),
          backgroundColor: Colors.green[700],
        ),
      );
      Navigator.of(context).pop(); // Return to template list
    }
  }

  // ── Build ──

  @override
  Widget build(BuildContext context) {
    final steps = [
      'Capture Master',
      'Header Anchors',
      'Item Table',     // Step 3: define item table columns (was Step 4)
      'ROI Fields',     // Step 4: define ROI Field area (was Step 3)
      'Footer Anchor',
      'Save',
    ];

    return Scaffold(
      backgroundColor: const Color(0xFFFF6B35),
      appBar: AppBar(
        title: Text(
          _template.supplierName.isNotEmpty
              ? _template.supplierName
              : 'New Template',
          style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18),
        ),
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
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
              // Step indicator
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                child: Row(
                  children: List.generate(steps.length, (i) {
                    final isActive = i == _currentStep;
                    final isDone = i < _currentStep;
                    return Expanded(
                      child: GestureDetector(
                        onTap: i <= _currentStep + 1 ? () => setState(() => _currentStep = i) : null,
                        child: Container(
                          margin: const EdgeInsets.symmetric(horizontal: 2),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Container(
                                width: 28,
                                height: 28,
                                decoration: BoxDecoration(
                                  color: isActive
                                      ? Colors.white
                                      : isDone
                                          ? Colors.green[400]
                                          : Colors.white.withOpacity(0.2),
                                  shape: BoxShape.circle,
                                ),
                                child: Center(
                                  child: isDone
                                      ? const Icon(Icons.check, size: 16, color: Colors.white)
                                      : Text(
                                          '${i + 1}',
                                          style: TextStyle(
                                            color: isActive
                                                ? const Color(0xFFFF6B35)
                                                : Colors.white,
                                            fontWeight: FontWeight.bold,
                                            fontSize: 12,
                                          ),
                                        ),
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                steps[i],
                                style: TextStyle(
                                  fontSize: 9,
                                  color: isActive ? Colors.white : Colors.white60,
                                  fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),
                    );
                  }),
                ),
              ),

              // Step content
              Expanded(
                child: Container(
                  margin: const EdgeInsets.fromLTRB(12, 0, 12, 12),
                  decoration: BoxDecoration(
                    color: Colors.white.withOpacity(0.95),
                    borderRadius: BorderRadius.circular(20),
                  ),
                  child: _buildStepContent(),
                ),
              ),

              // Navigation buttons
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
                child: Row(
                  children: [
                    if (_currentStep > 0)
                      OutlinedButton(
                        onPressed: _prevStep,
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white,
                          side: const BorderSide(color: Colors.white38),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                        child: const Text('← Back'),
                      ),
                    const Spacer(),
                    ElevatedButton(
                      onPressed: _currentStep == 5 ? _saveTemplate : (_canProceed ? _nextStep : null),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: _currentStep == 5
                            ? Colors.green[600]
                            : const Color(0xFFFFB347),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                      ),
                      child: Text(_currentStep == 5 ? '💾 Save Template' : 'Next →'),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStepContent() {
    switch (_currentStep) {
      case 0:
        return _buildStep1();
      case 1:
        return _buildStep2();
      case 2:
        return _buildStep4(); // swapped: Item Table
      case 3:
        return _buildStep3(); // swapped: ROI Fields
      case 4:
        return _buildStep5();
      case 5:
        return _buildStep6();
      default:
        return const SizedBox();
    }
  }

  // ── Step 1: Capture Master Receipt ──

  Widget _buildStep1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 1: Capture Master Receipt',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE85D2C)),
          ),
          const SizedBox(height: 8),
          Text(
            'Take a clear, well-lit photo of a sample receipt from this supplier.\n'
            'The system will auto-detect edges, correct perspective, and enhance the image.\n\n'
            '🛈 Supplier name will be extracted from Anchor A in Step 2.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 20),

          // Image capture buttons
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _captureMaster,
                  icon: const Icon(Icons.camera_alt),
                  label: const Text('Take Photo'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFF6B35),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: OutlinedButton.icon(
                  onPressed: _pickMasterFromGallery,
                  icon: const Icon(Icons.photo_library),
                  label: const Text('From Gallery'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6B35),
                    side: const BorderSide(color: Color(0xFFFF6B35)),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                  ),
                ),
              ),
            ],
          ),

          // Preview
          if (_processedImage != null) ...[
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                // Compute height based on image aspect ratio,
                // capped to keep the page scrollable.
                final imgW = _processedImage!.width.toDouble();
                final imgH = _processedImage!.height.toDouble();
                final maxH = 420.0;
                final maxW = constraints.maxWidth;
                final h = (maxW * imgH / imgW).clamp(180.0, maxH);
                return Container(
                  width: double.infinity,
                  height: h,
                  decoration: BoxDecoration(
                    color: Colors.grey[100],
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: const Color(0xFFFF6B35).withOpacity(0.3)),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: FittedBox(
                      fit: BoxFit.contain,
                      alignment: Alignment.topCenter,
                      child: Image.memory(
                        img.encodeJpg(_processedImage!, quality: 85),
                        fit: BoxFit.contain,
                      ),
                    ),
                  ),
                );
              },
            ),

            // Rotate controls
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                OutlinedButton.icon(
                  onPressed: () => _rotateMaster(-90),
                  icon: const Icon(Icons.rotate_left, size: 18),
                  label: const Text('Rotate Left'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6B35),
                    side: const BorderSide(color: Color(0xFFFF6B35)),
                  ),
                ),
                const SizedBox(width: 12),
                OutlinedButton.icon(
                  onPressed: () => _rotateMaster(90),
                  icon: const Icon(Icons.rotate_right, size: 18),
                  label: const Text('Rotate Right'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFFF6B35),
                    side: const BorderSide(color: Color(0xFFFF6B35)),
                  ),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  // ── Step 2: Header Anchors ──

  Widget _buildStep2() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 2: Create Header Anchors',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE85D2C)),
          ),
          const SizedBox(height: 8),
          Text(
            'Define two permanent anchor points in the fixed header section.\n'
            'These anchors are used for alignment & rotation correction on every receipt scan.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),

          // Master image preview with anchor overlays
          _buildAnchorOverlayPreview(
            showAnchors: const ['A', 'B'],
            onAnchorChanged: _updateAnchorInMemory,
            onAnchorLongPress: (id) {
              if (id == 'a') _setAnchorA();
              if (id == 'b') _setAnchorB();
            },
            onTapOpenEditor: () => _openFullscreenAnchorEditor(['A', 'B']),
          ),

          const SizedBox(height: 20),

          // Anchor A
          _anchorCard(
            'Anchor A',
            'Supplier Name (auto-fills template name)',
            _template.anchorA,
            Colors.red,
            _setAnchorA,
          ),
          const SizedBox(height: 12),

          // Anchor B
          _anchorCard(
            'Anchor B',
            'TAX INVOICE / GST Registration',
            _template.anchorB,
            Colors.red,
            _setAnchorB,
          ),
        ],
      ),
    );
  }

  /// Renders the master image with a tap-to-open fullscreen editor.
  ///
  /// The interactive drag/resize is now done in a fullscreen overlay
  /// (see [_FullscreenAnchorEditor]) so the boxes have plenty of room and
  /// large touch targets. This preview just shows static colored borders.
  Widget _buildAnchorOverlayPreview({
    required List<String> showAnchors,
    void Function(String anchorId, Rect newRoi)? onAnchorChanged,
    void Function(String anchorId)? onAnchorLongPress,
    VoidCallback? onTapOpenEditor,
  }) {
    if (_processedImage == null) return const SizedBox.shrink();
    final imgW = _processedImage!.width.toDouble();
    final imgH = _processedImage!.height.toDouble();
    final bytes = img.encodeJpg(_processedImage!, quality: 85);

    Widget borderOnly(AnchorPoint? a, Color color) {
      if (a == null) return const SizedBox.shrink();
      return LayoutBuilder(builder: (ctx, c) {
        final sw = c.maxWidth;
        final sh = sw * (imgH / imgW);
        final sx = sw / imgW;
        final sy = sh / imgH;
        return Positioned(
          left: a.roi.left * sx,
          top: a.roi.top * sy,
          width: a.roi.width * sx,
          height: a.roi.height * sy,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 2),
                borderRadius: BorderRadius.circular(2),
                color: color.withOpacity(0.06),
              ),
            ),
          ),
        );
      });
    }

    return LayoutBuilder(builder: (ctx, c) {
      final sw = c.maxWidth;
      final sh = sw * (imgH / imgW);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GestureDetector(
            onTap: onTapOpenEditor,
            child: Container(
              margin: const EdgeInsets.symmetric(vertical: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: const Color(0xFFFF6B35).withOpacity(0.5), width: 2),
                color: Colors.grey[100],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                children: [
                  Image.memory(bytes, fit: BoxFit.contain, width: sw, height: sh),
                  if (showAnchors.contains('A'))
                    borderOnly(_template.anchorA, const Color(0xFFD32F2F)),
                  if (showAnchors.contains('B'))
                    borderOnly(_template.anchorB, const Color(0xFF1976D2)),
                  if (showAnchors.contains('C'))
                    borderOnly(_template.anchorC, const Color(0xFF388E3C)),
                  // "Tap to edit" hint
                  Positioned(
                    right: 8,
                    top: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                      decoration: BoxDecoration(
                        color: Colors.black54,
                        borderRadius: BorderRadius.circular(20),
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(Icons.fullscreen, color: Colors.white, size: 14),
                          SizedBox(width: 4),
                          Text('Tap to edit', style: TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: onTapOpenEditor,
            icon: const Icon(Icons.tune),
            label: const Text('OPEN FULLSCREEN ANCHOR EDITOR'),
            style: OutlinedButton.styleFrom(
              foregroundColor: const Color(0xFFFF6B35),
              side: const BorderSide(color: Color(0xFFFF6B35), width: 1.5),
              padding: const EdgeInsets.symmetric(vertical: 12),
            ),
          ),
        ],
      );
    });
  }

  Widget _anchorCard(String title, String description, AnchorPoint? anchor, Color color, VoidCallback onSet) {
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12),
        side: anchor != null ? BorderSide(color: color, width: 2) : BorderSide.none,
      ),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Row(
          children: [
            Container(
              width: 40,
              height: 40,
              decoration: BoxDecoration(color: color.withOpacity(0.15), borderRadius: BorderRadius.circular(10)),
              child: Icon(
                anchor != null ? Icons.check_circle : Icons.anchor,
                color: anchor != null ? Colors.green : color,
                size: 22,
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(title, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 2),
                  Text(
                    anchor != null
                        ? 'Set (${anchor.roi.left.toStringAsFixed(0)}, ${anchor.roi.top.toStringAsFixed(0)})'
                        : description,
                    style: TextStyle(fontSize: 12, color: anchor != null ? Colors.green[700] : Colors.grey[600]),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ],
              ),
            ),
            TextButton(
              onPressed: onSet,
              child: Text(anchor != null ? 'Edit' : 'Set'),
            ),
          ],
        ),
      ),
    );
  }

  // ── Step 3: ROI Fields ──

  Widget _buildStep3() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 4: Configure OCR Fields (ROI)',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE85D2C)),
          ),
          const SizedBox(height: 8),
          Text(
            'Press "Add Field" to define each data field you want to extract.\n'
            'Draw the ROI on the receipt for each field.\n\n'
            'Red outlines = Anchor A/B positions from Step 2.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),

          // Master image preview with Anchor A/B overlays
          _buildAnchorOverlayPreview(
            showAnchors: const ['A', 'B'],
            onAnchorChanged: _updateAnchorInMemory,
            onAnchorLongPress: (id) {
              if (id == 'a') _setAnchorA();
              if (id == 'b') _setAnchorB();
            },
            onTapOpenEditor: () => _openFullscreenAnchorEditor(['A', 'B']),
          ),

          const SizedBox(height: 16),

          // Add field button
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _addField,
              icon: const Icon(Icons.add),
              label: const Text('Add Field'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B35),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              ),
            ),
          ),
          const SizedBox(height: 16),

          // Field list
          if (_tempFields.isEmpty)
            Center(
              child: Padding(
                padding: const EdgeInsets.all(32),
                child: Column(
                  children: [
                    Icon(Icons.touch_app, size: 48, color: Colors.grey[300]),
                    const SizedBox(height: 8),
                    Text('No fields configured yet', style: TextStyle(color: Colors.grey[500])),
                  ],
                ),
              ),
            )
          else
            ..._tempFields.asMap().entries.map((entry) {
              final i = entry.key;
              final f = entry.value;
              return Card(
                margin: const EdgeInsets.only(bottom: 8),
                child: ListTile(
                  leading: Container(
                    width: 32, height: 32,
                    decoration: BoxDecoration(
                      color: const Color(0xFFFF6B35).withOpacity(0.1),
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Center(child: Text('${i + 1}', style: const TextStyle(fontWeight: FontWeight.bold, color: Color(0xFFFF6B35)))),
                  ),
                  title: Text(f.displayLabel, style: const TextStyle(fontWeight: FontWeight.w500)),
                  subtitle: Text('${f.roi.width.toStringAsFixed(0)}x${f.roi.height.toStringAsFixed(0)} px | ${f.validationRule}'),
                  trailing: IconButton(
                    icon: const Icon(Icons.delete_outline, color: Colors.red),
                    onPressed: () => _removeField(i),
                  ),
                ),
              );
            }),
        ],
      ),
    );
  }

  // ── Step 4: Item Table ──

  Widget _buildStep4() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 3: Configure Item Table',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE85D2C)),
          ),
          const SizedBox(height: 8),
          Text(
            'Define the YELLOW area that covers the purchased-item rows.\n'
            'It starts horizontally AFTER Anchor B and ends just BEFORE Anchor C.\n'
            'Drag and resize the yellow box in full-screen mode.\n\n'
            'Blue/Green outlines below show Anchor B (right edge) and Anchor C (left edge).',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),

          // Master image preview with Anchor B + C overlays (yellow area is between them)
          _buildAnchorOverlayPreview(
            showAnchors: _template.anchorC != null ? const ['B', 'C'] : const ['B'],
            onAnchorChanged: _updateAnchorInMemory,
            onAnchorLongPress: (id) {
              if (id == 'b') _setAnchorB();
              if (id == 'c') _setAnchorC();
            },
            onTapOpenEditor: () => _openFullscreenAnchorEditor(
              _template.anchorC != null ? ['B', 'C'] : ['B'],
            ),
          ),

          const SizedBox(height: 16),

          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        _itemTableConfig != null ? Icons.check_circle : Icons.grid_view,
                        color: _itemTableConfig != null ? Colors.green : Colors.grey,
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _itemTableConfig != null ? 'Table configured' : 'Not configured',
                        style: TextStyle(
                          fontWeight: FontWeight.bold,
                          fontSize: 15,
                          color: _itemTableConfig != null ? Colors.green[700] : Colors.grey[700],
                        ),
                      ),
                    ],
                  ),
                  if (_itemTableConfig != null) ...[
                    const SizedBox(height: 12),
                    Text('Columns: Qty | Description | Unit Price | Discount | Amount'),
                    Text('ROI: ${_itemTableConfig!.tableRoi.width.toStringAsFixed(0)} x ${_itemTableConfig!.tableRoi.height.toStringAsFixed(0)} px'),
                    Text('Position: (${_itemTableConfig!.tableRoi.left.toInt()}, ${_itemTableConfig!.tableRoi.top.toInt()}) → (${_itemTableConfig!.tableRoi.right.toInt()}, ${_itemTableConfig!.tableRoi.bottom.toInt()})'),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                      onPressed: _openFullscreenItemTableEditor,
                      icon: const Icon(Icons.crop_din, size: 16),
                      label: const Text('Re-adjust Yellow Area'),
                    ),
                  ] else ...[
                    const SizedBox(height: 16),
                    SizedBox(
                      width: double.infinity,
                      child: ElevatedButton.icon(
                        onPressed: _openFullscreenItemTableEditor,
                        icon: const Icon(Icons.crop_din),
                        label: const Text('OPEN FULLSCREEN — Draw Yellow Area'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFFFF6B35),
                          foregroundColor: Colors.white,
                          padding: const EdgeInsets.symmetric(vertical: 12),
                          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                        ),
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Step 5: Footer Anchor ──

  Widget _buildStep5() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 5: Configure Dynamic Footer Anchor',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE85D2C)),
          ),
          const SizedBox(height: 8),
          Text(
            'Select a stable field that always appears after the item table.\n'
            'Recommended: TOTAL, SUBTOTAL, GRAND TOTAL, BALANCE DUE.\n\n'
            'This anchor is found dynamically after detecting the end of the item table.',
            style: TextStyle(fontSize: 13, color: Colors.grey[600]),
          ),
          const SizedBox(height: 12),

          // Master image preview with Anchor C overlay
          _buildAnchorOverlayPreview(
            showAnchors: const ['C'],
            onAnchorChanged: _updateAnchorInMemory,
            onAnchorLongPress: (id) {
              if (id == 'c') _setAnchorC();
            },
            onTapOpenEditor: () => _openFullscreenAnchorEditor(['C']),
          ),

          const SizedBox(height: 20),

          // Anchor C
          _anchorCard(
            'Anchor C (Dynamic)',
            'Total / Subtotal / Balance Due',
            _template.anchorC,
            Colors.red,
            _setAnchorC,
          ),
        ],
      ),
    );
  }

  // ── Step 6: Save ──

  Widget _buildStep6() {
    final checks = [
      _template.supplierName.isNotEmpty,
      _template.anchorA != null,
      _template.anchorB != null,
      _template.anchorC != null,
      _tempFields.isNotEmpty,
      _itemTableConfig != null,
      _masterImage != null,
    ];
    final labels = [
      'Supplier name set',
      'Anchor A (header logo/name)',
      'Anchor B (tax invoice/GST)',
      'Anchor C (footer total)',
      'ROI fields configured (${_tempFields.length})',
      'Item table configured',
      'Master receipt image captured',
    ];

    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 6: Save Template',
            style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold, color: Color(0xFFE85D2C)),
          ),
          const SizedBox(height: 16),

          Text(
            'Template: ${_template.supplierName}',
            style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w500),
          ),
          Text(
            'Version ${_template.templateVersion}',
            style: TextStyle(color: Colors.grey[600]),
          ),
          const SizedBox(height: 16),

          // Master image preview with all anchor overlays
          _buildAnchorOverlayPreview(
            showAnchors: const ['A', 'B', 'C'],
            onAnchorChanged: _updateAnchorInMemory,
            onAnchorLongPress: (id) {
              if (id == 'a') _setAnchorA();
              if (id == 'b') _setAnchorB();
              if (id == 'c') _setAnchorC();
            },
            onTapOpenEditor: () => _openFullscreenAnchorEditor(['A', 'B', 'C']),
          ),
          _buildAnchorOverlayPreview(showAnchors: const ['A', 'B', 'C']),

          const SizedBox(height: 20),

          // Checklist
          ...List.generate(checks.length, (i) {
            return Padding(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: Row(
                children: [
                  Icon(
                    checks[i] ? Icons.check_circle : Icons.radio_button_unchecked,
                    color: checks[i] ? Colors.green : Colors.grey[400],
                    size: 20,
                  ),
                  const SizedBox(width: 8),
                  Text(
                    labels[i],
                    style: TextStyle(
                      color: checks[i] ? Colors.black87 : Colors.grey[500],
                      fontSize: 13,
                    ),
                  ),
                ],
              ),
            );
          }),

          const SizedBox(height: 24),

          // Summary
          Card(
            shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('Template Summary', style: TextStyle(fontWeight: FontWeight.bold, fontSize: 14)),
                  const SizedBox(height: 8),
                  Text('${_tempFields.length} field(s) configured'),
                  Text('${_itemTableConfig != null ? "5" : "0"} item column(s) set'),
                  Text('3 anchor point(s): A (${_template.anchorA != null ? "✅" : "❌"}) B (${_template.anchorB != null ? "✅" : "❌"}) C (${_template.anchorC != null ? "✅" : "❌"})'),
                  const SizedBox(height: 8),
                  Text(
                    _template.isComplete ? '✅ All anchors set. Template ready!' : '⚠️ Some anchors missing, processing may be less accurate.',
                    style: TextStyle(
                      fontSize: 12,
                      color: _template.isComplete ? Colors.green[700] : Colors.orange[700],
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Dialog for selecting a field type to add.
class _FieldSelectorDialog extends StatelessWidget {
  final List<Map<String, String>> availableFields;
  final void Function(String fieldName, String label) onSelected;

  const _FieldSelectorDialog({
    required this.availableFields,
    required this.onSelected,
  });

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: const Text('Select Field Type'),
      content: SizedBox(
        width: 300,
        height: 400,
        child: ListView(
          children: availableFields.map((field) {
            return ListTile(
              leading: Icon(_fieldIcon(field['name']!), color: const Color(0xFFFF6B35)),
              title: Text(field['label']!),
              onTap: () => onSelected(field['name']!, field['label']!),
            );
          }).toList(),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Cancel'),
        ),
      ],
    );
  }

  IconData _fieldIcon(String name) {
    switch (name) {
      case 'store_name': return Icons.store;
      case 'date': return Icons.calendar_today;
      case 'time': return Icons.access_time;
      case 'receipt_number': return Icons.numbers;
      case 'cashier': return Icons.person;
      case 'terminal_id': return Icons.computer;
      case 'currency': return Icons.monetization_on;
      case 'item_table': return Icons.table_chart;
      case 'item_description': return Icons.description;
      case 'quantity': return Icons.format_list_numbered;
      case 'unit_price': return Icons.attach_money;
      case 'discount': return Icons.discount;
      case 'tax': return Icons.receipt_long;
      case 'service_charge': return Icons.room_service;
      case 'subtotal': return Icons.summarize;
      case 'total': return Icons.calculate;
      case 'payment_method': return Icons.payment;
      case 'membership_number': return Icons.card_membership;
      case 'custom_field': return Icons.add_circle_outline;
      default: return Icons.text_fields;
    }
  }
}

// ───────────────────────────────────────────────────────────────────────────
// Interactive Anchor Box — drag to move, drag a corner handle to resize.
// Long-press re-opens the text-entry dialog (handled by the parent).
// All geometry is converted between image-pixel coords (which the AnchorPoint
// stores) and the display coords (which the parent Stack uses) via scale
// factors derived from imageWidth / imageHeight.
// ───────────────────────────────────────────────────────────────────────────

// ═══════════════════════════════════════════════════════════════════════════
// FULLSCREEN ANCHOR EDITOR
// Opens as a modal route. Image takes the whole screen; touch targets are
// large (44px+), gesture arenas are scoped to each handle, and there is a
// clear MODE toggle (MOVE vs RESIZE) so the user always knows what each
// gesture does.
// ═══════════════════════════════════════════════════════════════════════════

enum _EditMode { move, resize }

class _FullscreenAnchorEditor extends StatefulWidget {
  final img.Image image;
  final Map<String, AnchorPoint?> anchors; // id -> AnchorPoint (mutable ref)
  final List<String> anchorIdsToShow; // e.g. ['A','B'] or ['C']
  final Map<String, Color> anchorColors; // 'A' -> red, 'B' -> blue, 'C' -> green
  final void Function(String anchorId, Rect newRoi) onAnchorChanged;

  const _FullscreenAnchorEditor({
    required this.image,
    required this.anchors,
    required this.anchorIdsToShow,
    required this.anchorColors,
    required this.onAnchorChanged,
  });

  @override
  State<_FullscreenAnchorEditor> createState() => _FullscreenAnchorEditorState();
}

class _FullscreenAnchorEditorState extends State<_FullscreenAnchorEditor> {
  // Local working copy of each anchor's ROI in image-pixel coords.
  late Map<String, Rect> _roi;
  // Which anchor the user is currently dragging (null = none).
  String? _activeAnchorId;
  // For RESIZE: which corner of the active anchor is being dragged.
  String? _activeCorner; // 'tl','tr','bl','br'
  _EditMode _mode = _EditMode.move;
  // Which anchor the user has selected for nudge/edit (null = none)
  String? _selectedForEdit;

  @override
  void initState() {
    super.initState();
    _roi = {
      for (final id in widget.anchorIdsToShow)
        id: widget.anchors[id]?.roi ?? Rect.zero,
    };
  }

  Rect _clamp(Rect r, double maxW, double maxH) {
    final left = r.left.clamp(0.0, maxW - 1).toDouble();
    final top = r.top.clamp(0.0, maxH - 1).toDouble();
    final right = r.right.clamp(left + 30, maxW).toDouble();
    final bottom = r.bottom.clamp(top + 20, maxH).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _commit(String id, Rect next) {
    final clamped = _clamp(next, widget.image.width.toDouble(), widget.image.height.toDouble());
    setState(() => _roi[id] = clamped);
    widget.onAnchorChanged(id.toLowerCase(), clamped);
  }

  @override
  Widget build(BuildContext context) {
    final imgW = widget.image.width.toDouble();
    final imgH = widget.image.height.toDouble();
    final bytes = img.encodeJpg(widget.image, quality: 90);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Colors.black87,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    'Anchor Editor',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  // Mode toggle
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        _modeButton('MOVE', Icons.open_with, _EditMode.move),
                        _modeButton('RESIZE', Icons.aspect_ratio, _EditMode.resize),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Mode hint banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: _mode == _EditMode.move ? Colors.blue[900] : Colors.orange[900],
              child: Text(
                _mode == _EditMode.move
                    ? 'MOVE mode: tap and drag any anchor box to reposition it'
                    : 'RESIZE mode: tap and drag any of the 4 corner circles to resize',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),

            // Image + anchors
            Expanded(
              child: LayoutBuilder(builder: (ctx, c) {
                // Fit image to available space (account for top bar 56 + banner 32).
                final maxW = c.maxWidth;
                final maxH = c.maxHeight;
                final fit = imgW / imgH;
                double dispW, dispH;
                if (maxW / fit <= maxH) {
                  dispW = maxW;
                  dispH = maxW / fit;
                } else {
                  dispH = maxH;
                  dispW = maxH * fit;
                }
                final offsetX = (maxW - dispW) / 2;
                final offsetY = (maxH - dispH) / 2;

                final sx = dispW / imgW;
                final sy = dispH / imgH;

                return GestureDetector(
                  // Tap empty area = no-op (don't intercept, let Image handle taps)
                  behavior: HitTestBehavior.translucent,
                  onTapUp: (_) {},
                  child: Container(
                    color: Colors.black,
                    child: Stack(
                      children: [
                        // Image
                        Positioned(
                          left: offsetX,
                          top: offsetY,
                          width: dispW,
                          height: dispH,
                          child: Image.memory(bytes, fit: BoxFit.fill),
                        ),
                        // Each anchor
                        for (final id in widget.anchorIdsToShow)
                          if (_roi[id] != null && _roi[id]!.width > 0)
                            _buildAnchorBox(id, _roi[id]!, offsetX, offsetY, sx, sy, widget.anchorColors[id] ?? Colors.red),
                      ],
                    ),
                  ),
                );
              }),
            ),

            // Bottom precise-input panel: tap an anchor chip to enter exact pixel mode
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Colors.black87,
              child: Row(
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Row(
                        children: widget.anchorIdsToShow.map((id) {
                          final color = widget.anchorColors[id] ?? Colors.red;
                          final r = _roi[id];
                          final isSelected = id == _selectedForEdit;
                          return Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: GestureDetector(
                              onTap: () => setState(() => _selectedForEdit = id),
                              child: Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                                decoration: BoxDecoration(
                                  color: isSelected ? color : Colors.white12,
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(color: color, width: 1.5),
                                ),
                                child: r == null || r.width == 0
                                    ? Text('Anchor $id', style: TextStyle(color: isSelected ? Colors.white : color, fontSize: 11, fontWeight: FontWeight.bold))
                                    : Text(
                                        '$id: (${r.left.toInt()},${r.top.toInt()}) ${r.width.toInt()}×${r.height.toInt()}',
                                        style: TextStyle(color: isSelected ? Colors.white : Colors.white, fontSize: 11, fontWeight: FontWeight.bold),
                                      ),
                              ),
                            ),
                          );
                        }).toList(),
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: () => _showPreciseInputDialog(),
                    style: TextButton.styleFrom(foregroundColor: const Color(0xFFFF6B35)),
                    child: const Text('EDIT PX', style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold)),
                  ),
                ],
              ),
            ),
            // Nudge row for the selected anchor
            if (_selectedForEdit != null && _roi[_selectedForEdit] != null && _roi[_selectedForEdit]!.width > 0)
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                color: Colors.black87,
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    _nudgeButton('←1', () => _nudge(-1, 0)),
                    _nudgeButton('←10', () => _nudge(-10, 0)),
                    _nudgeButton('↑1', () => _nudge(0, -1)),
                    _nudgeButton('↑10', () => _nudge(0, -10)),
                    const SizedBox(width: 8),
                    Text('Move selected', style: TextStyle(color: Colors.white54, fontSize: 10)),
                    const SizedBox(width: 8),
                    _nudgeButton('↓1', () => _nudge(0, 1)),
                    _nudgeButton('↓10', () => _nudge(0, 10)),
                    _nudgeButton('→1', () => _nudge(1, 0)),
                    _nudgeButton('→10', () => _nudge(10, 0)),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }

  // Nudge the selected anchor by (dx, dy) in image pixels.
  void _nudge(double dx, double dy) {
    final id = _selectedForEdit;
    if (id == null) return;
    final r = _roi[id];
    if (r == null) return;
    _commit(id, Rect.fromLTRB(r.left + dx, r.top + dy, r.right + dx, r.bottom + dy));
  }

  Widget _nudgeButton(String label, VoidCallback onTap) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: GestureDetector(
        onTap: onTap,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white12,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Text(label, style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.bold)),
        ),
      ),
    );
  }

  // Show a dialog to type exact pixel values for the selected anchor.
  Future<void> _showPreciseInputDialog() async {
    final id = _selectedForEdit;
    if (id == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Tap an anchor chip first to select it')),
      );
      return;
    }
    final r = _roi[id];
    if (r == null) return;
    final leftC = TextEditingController(text: r.left.toInt().toString());
    final topC = TextEditingController(text: r.top.toInt().toString());
    final wC = TextEditingController(text: r.width.toInt().toString());
    final hC = TextEditingController(text: r.height.toInt().toString());
    final imgW = widget.image.width;
    final imgH = widget.image.height;

    await showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Text('Anchor $id — exact pixels'),
        content: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text('Image: ${imgW.toInt()} × ${imgH.toInt()} px', style: const TextStyle(fontSize: 11, color: Colors.grey)),
              const SizedBox(height: 12),
              Row(
                children: [
                  Expanded(child: TextField(controller: leftC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Left'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: topC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Top'))),
                ],
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  Expanded(child: TextField(controller: wC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Width'))),
                  const SizedBox(width: 8),
                  Expanded(child: TextField(controller: hC, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Height'))),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Tip: 50-300 wide and 20-60 tall usually fits text perfectly.',
                style: TextStyle(fontSize: 11, color: Colors.grey[600]),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: const Color(0xFFFF6B35)),
            onPressed: () {
              final l = double.tryParse(leftC.text) ?? r.left;
              final t = double.tryParse(topC.text) ?? r.top;
              final w = double.tryParse(wC.text) ?? r.width;
              final h = double.tryParse(hC.text) ?? r.height;
              _commit(id, Rect.fromLTWH(l, t, w, h));
              Navigator.pop(ctx);
            },
            child: const Text('Apply', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
    );
  }

  Widget _modeButton(String label, IconData icon, _EditMode mode) {
    final selected = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
        decoration: BoxDecoration(
          color: selected ? Colors.white : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, color: selected ? Colors.black : Colors.white70, size: 14),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: selected ? Colors.black : Colors.white70, fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }

  Widget _buildAnchorBox(String id, Rect roiImg, double offsetX, double offsetY, double sx, double sy, Color color) {
    final left = offsetX + roiImg.left * sx;
    final top = offsetY + roiImg.top * sy;
    final width = roiImg.width * sx;
    final height = roiImg.height * sy;

    const handleSize = 44.0; // LARGE touch target for corner handles
    const hitPad = 28.0; // FATTEN the drag area beyond the visible border

    return Stack(
      children: [
        // INVISIBLE FAT HIT AREA — extends 28px past each edge so finger
        // taps near the border still grab the box. Always MOVE-grabbable,
        // regardless of mode (corners still own resize in RESIZE mode).
        Positioned(
          left: left - hitPad,
          top: top - hitPad,
          width: width + hitPad * 2,
          height: height + hitPad * 2,
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onPanStart: (_) => _activeAnchorId = id,
            onPanUpdate: (d) {
              if (_activeAnchorId != id) return;
              // ALWAYS move the box on drag — corners still claim RESIZE in
              // their own gesture arena.
              _commit(id, Rect.fromLTRB(
                roiImg.left + d.delta.dx / sx,
                roiImg.top + d.delta.dy / sy,
                roiImg.right + d.delta.dx / sx,
                roiImg.bottom + d.delta.dy / sy,
              ));
            },
            onPanEnd: (_) => _activeAnchorId = null,
            child: const SizedBox.expand(),
          ),
        ),

        // The visible colored box (no gestures — the fat hit area owns them)
        Positioned(
          left: left,
          top: top,
          width: width,
          height: height,
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(color: color, width: 3),
                borderRadius: BorderRadius.circular(2),
                color: color.withOpacity(0.15),
              ),
              child: Stack(
                children: [
                  Positioned(
                    left: 0, top: 0,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      color: color,
                      child: Text(
                        'Anchor $id',
                        style: const TextStyle(color: Colors.white, fontSize: 13, fontWeight: FontWeight.bold),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
        // Corner handles — only in RESIZE mode
        if (_mode == _EditMode.resize) ...[
          _buildCorner(id, 'tl', left, top, handleSize, color, roiImg, sx, sy, (dx, dy) {
            return Rect.fromLTRB(roiImg.left + dx, roiImg.top + dy, roiImg.right, roiImg.bottom);
          }),
          _buildCorner(id, 'tr', left + width - handleSize / 2, top, handleSize, color, roiImg, sx, sy, (dx, dy) {
            return Rect.fromLTRB(roiImg.left, roiImg.top + dy, roiImg.right + dx, roiImg.bottom);
          }),
          _buildCorner(id, 'bl', left, top + height - handleSize / 2, handleSize, color, roiImg, sx, sy, (dx, dy) {
            return Rect.fromLTRB(roiImg.left + dx, roiImg.top, roiImg.right, roiImg.bottom + dy);
          }),
          _buildCorner(id, 'br', left + width - handleSize / 2, top + height - handleSize / 2, handleSize, color, roiImg, sx, sy, (dx, dy) {
            return Rect.fromLTRB(roiImg.left, roiImg.top, roiImg.right + dx, roiImg.bottom + dy);
          }),
        ],
      ],
    );
  }

  Widget _buildCorner(
    String anchorId,
    String cornerId,
    double left,
    double top,
    double size,
    Color color,
    Rect roiImg,
    double sx,
    double sy,
    Rect Function(double dx, double dy) buildNext,
  ) {
    return Positioned(
      left: left - size / 2,
      top: top - size / 2,
      width: size,
      height: size,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {
          _activeAnchorId = anchorId;
          _activeCorner = cornerId;
        },
        onPanUpdate: (d) {
          if (_activeAnchorId != anchorId || _activeCorner != cornerId) return;
          final next = buildNext(d.delta.dx / sx, d.delta.dy / sy);
          _commit(anchorId, next);
        },
        onPanEnd: (_) {
          _activeAnchorId = null;
          _activeCorner = null;
        },
        child: Container(
          decoration: BoxDecoration(
            color: color,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
          ),
          child: const Center(
            child: Icon(Icons.open_in_full, color: Colors.white, size: 18),
          ),
        ),
      ),
    );
  }
}

// ── Full-screen Item-Table ROI Editor (yellow shaded area) ──
//
// Constraints (from user):
//  • Yellow area STARTS horizontally AFTER Anchor B (right edge of B)
//  • Yellow area ENDS horizontally just BEFORE Anchor C (left edge of C)
//  • User can MOVE and RESIZE the yellow box freely within those bounds.

class _FullscreenItemTableEditor extends StatefulWidget {
  final img.Image image;
  final Rect initialRoi;
  final AnchorPoint? anchorB;
  final AnchorPoint? anchorC;

  const _FullscreenItemTableEditor({
    required this.image,
    required this.initialRoi,
    this.anchorB,
    this.anchorC,
  });

  @override
  State<_FullscreenItemTableEditor> createState() => _FullscreenItemTableEditorState();
}

class _FullscreenItemTableEditorState extends State<_FullscreenItemTableEditor> {
  late Rect _roi;
  // VERTICAL constraints: yellow area sits between Anchor B (below header)
  // and Anchor C (above footer). Left/right edges are free across full width.
  late double _minTop;
  late double _maxBottom;
  String? _activeCorner;
  _EditMode _mode = _EditMode.move;

  double get _imgW => widget.image.width.toDouble();
  double get _imgH => widget.image.height.toDouble();

  @override
  void initState() {
    super.initState();
    final b = widget.anchorB?.roi;
    final c = widget.anchorC?.roi;
    // Yellow MUST start vertically AFTER B (top must be below B's bottom edge).
    _minTop = b != null ? b.bottom + 4.0 : 0.0;
    // Yellow MUST end vertically BEFORE C (bottom must be above C's top edge).
    _maxBottom = c != null ? c.top - 4.0 : _imgH;
    // Clamp the initial ROI from caller to our valid vertical band, full width.
    final r = widget.initialRoi;
    final left = 0.0;
    final right = _imgW;
    final top = r.top.clamp(_minTop, _maxBottom - 40).toDouble();
    final bottom = r.bottom.clamp(top + 40, _maxBottom).toDouble();
    _roi = Rect.fromLTRB(left, top, right, bottom);
  }

  Rect _clamp(Rect r) {
    // Left/right: always full image width (the whole row band).
    final left = 0.0;
    final right = _imgW;
    // Top/bottom: strictly between B and C vertical extents.
    final top = r.top.clamp(_minTop, _maxBottom - 40).toDouble();
    final bottom = r.bottom.clamp(top + 40, _maxBottom).toDouble();
    return Rect.fromLTRB(left, top, right, bottom);
  }

  void _commit(Rect next) {
    setState(() => _roi = _clamp(next));
  }

  @override
  Widget build(BuildContext context) {
    final imgW = _imgW;
    final imgH = _imgH;
    final bytes = img.encodeJpg(widget.image, quality: 90);

    return Scaffold(
      backgroundColor: Colors.black,
      body: SafeArea(
        child: Column(
          children: [
            // Top bar
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              color: Colors.black87,
              child: Row(
                children: [
                  IconButton(
                    icon: const Icon(Icons.close, color: Colors.white),
                    onPressed: () => Navigator.of(context).pop(),
                  ),
                  const Text(
                    'Item Table Area',
                    style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Spacer(),
                  Container(
                    decoration: BoxDecoration(
                      color: Colors.white12,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      children: [
                        _modeButton('MOVE', Icons.open_with, _EditMode.move),
                        _modeButton('RESIZE', Icons.aspect_ratio, _EditMode.resize),
                      ],
                    ),
                  ),
                ],
              ),
            ),

            // Mode hint banner
            Container(
              width: double.infinity,
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              color: _mode == _EditMode.move ? Colors.blue[900] : Colors.orange[900],
              child: Text(
                _mode == _EditMode.move
                    ? 'MOVE mode: drag the yellow box to reposition (stays between Anchor B and C)'
                    : 'RESIZE mode: drag any of the 4 corner circles to resize',
                style: const TextStyle(color: Colors.white, fontSize: 12, fontWeight: FontWeight.w500),
              ),
            ),

            // Image + yellow box + anchor outlines
            Expanded(
              child: LayoutBuilder(builder: (ctx, c) {
                final maxW = c.maxWidth;
                final maxH = c.maxHeight;
                final fit = imgW / imgH;
                double dispW, dispH;
                if (maxW / fit <= maxH) {
                  dispW = maxW;
                  dispH = maxW / fit;
                } else {
                  dispH = maxH;
                  dispW = maxH * fit;
                }
                final offsetX = (maxW - dispW) / 2;
                final offsetY = (maxH - dispH) / 2;
                final sx = dispW / imgW;
                final sy = dispH / imgH;

                final boxLeft = offsetX + _roi.left * sx;
                final boxTop = offsetY + _roi.top * sy;
                final boxW = _roi.width * sx;
                final boxH = _roi.height * sy;

                return Container(
                  color: Colors.black,
                  child: Stack(
                    clipBehavior: Clip.none,
                    children: [
                      // Image
                      Positioned(
                        left: offsetX,
                        top: offsetY,
                        width: dispW,
                        height: dispH,
                        child: Image.memory(bytes, fit: BoxFit.fill),
                      ),
                      // Anchor B outline (blue, reference only)
                      if (widget.anchorB != null)
                        Positioned(
                          left: offsetX + widget.anchorB!.roi.left * sx,
                          top: offsetY + widget.anchorB!.roi.top * sy,
                          width: widget.anchorB!.roi.width * sx,
                          height: widget.anchorB!.roi.height * sy,
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: const Color(0xFF1976D2), width: 2),
                                color: const Color(0xFF1976D2).withOpacity(0.06),
                              ),
                            ),
                          ),
                        ),
                      // Anchor C outline (green, reference only)
                      if (widget.anchorC != null)
                        Positioned(
                          left: offsetX + widget.anchorC!.roi.left * sx,
                          top: offsetY + widget.anchorC!.roi.top * sy,
                          width: widget.anchorC!.roi.width * sx,
                          height: widget.anchorC!.roi.height * sy,
                          child: IgnorePointer(
                            child: Container(
                              decoration: BoxDecoration(
                                border: Border.all(color: const Color(0xFF388E3C), width: 2),
                                color: const Color(0xFF388E3C).withOpacity(0.06),
                              ),
                            ),
                          ),
                        ),
                      // Yellow shaded area (draggable/resizable)
                      Positioned(
                        left: boxLeft,
                        top: boxTop,
                        width: boxW,
                        height: boxH,
                        child: _buildYellowBox(boxW, boxH, sx, sy),
                      ),
                    ],
                  ),
                );
              }),
            ),

            // Bottom status bar: pixel coords + Save
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              color: Colors.black87,
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      'Yellow: (${_roi.left.toInt()}, ${_roi.top.toInt()}) → '
                      '(${_roi.right.toInt()}, ${_roi.bottom.toInt()}) '
                      '${_roi.width.toInt()}×${_roi.height.toInt()}',
                      style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w500),
                    ),
                  ),
                  const SizedBox(width: 8),
                  ElevatedButton.icon(
                    onPressed: () => Navigator.of(context).pop(_roi),
                    icon: const Icon(Icons.save, size: 16),
                    label: const Text('SAVE'),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFFFF6B35),
                      foregroundColor: Colors.white,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildYellowBox(double boxW, double boxH, double sx, double sy) {
    const handleSize = 40.0;
    const color = Color(0xFFFFC400); // yellow

    if (_mode == _EditMode.move) {
      // Move mode: drag whole box body. Use GestureDetector + HitTestBehavior.opaque
      // so we WIN the gesture arena against any overlap.
      return GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) {},
        onPanUpdate: (d) {
          final dx = d.delta.dx / sx;
          final dy = d.delta.dy / sy;
          _commit(Rect.fromLTRB(
            _roi.left + dx,
            _roi.top + dy,
            _roi.right + dx,
            _roi.bottom + dy,
          ));
        },
        child: Container(
          decoration: BoxDecoration(
            color: color.withOpacity(0.22),
            border: Border.all(color: color, width: 3),
            borderRadius: BorderRadius.circular(3),
          ),
          child: const Center(
            child: Padding(
              padding: EdgeInsets.symmetric(horizontal: 24),
              child: Text(
                'ITEM TABLE AREA\n(drag to move)',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.black87, fontSize: 13, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ),
      );
    }

    // Resize mode: yellow fill + 4 corner handles positioned FULLY INSIDE the box
    // (so they can never be clipped by the parent Positioned clip-rect).
    final maxX = (boxW - handleSize).clamp(0.0, double.infinity).toDouble();
    final maxY = (boxH - handleSize).clamp(0.0, double.infinity).toDouble();
    return Stack(
      clipBehavior: Clip.none,
      children: [
        // Yellow fill (no gesture — corners handle resize; body move uses empty area).
        Positioned.fill(
          child: IgnorePointer(
            child: Container(
              decoration: BoxDecoration(
                color: color.withOpacity(0.18),
                border: Border.all(color: color, width: 2),
                borderRadius: BorderRadius.circular(3),
              ),
            ),
          ),
        ),
        // Move body via a transparent GestureDetector covering the box.
        Positioned.fill(
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onPanStart: (_) {},
            onPanUpdate: (d) {
              final dx = d.delta.dx / sx;
              final dy = d.delta.dy / sy;
              _commit(Rect.fromLTRB(
                _roi.left + dx,
                _roi.top + dy,
                _roi.right + dx,
                _roi.bottom + dy,
              ));
            },
          ),
        ),
        // Corner handles, positioned fully inside box.
        _yellowCorner('tl', x: 0,            y: 0,            handleSize: handleSize, sx: sx, sy: sy),
        _yellowCorner('tr', x: maxX,         y: 0,            handleSize: handleSize, sx: sx, sy: sy),
        _yellowCorner('bl', x: 0,            y: maxY,         handleSize: handleSize, sx: sx, sy: sy),
        _yellowCorner('br', x: maxX,         y: maxY,         handleSize: handleSize, sx: sx, sy: sy),
      ],
    );
  }

  Widget _yellowCorner(String cornerId, {
    required double x,
    required double y,
    required double handleSize,
    required double sx,
    required double sy,
  }) {
    return Positioned(
      left: x,
      top: y,
      width: handleSize,
      height: handleSize,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (_) => _activeCorner = cornerId,
        onPanUpdate: (d) {
          if (_activeCorner != cornerId) return;
          final dx = d.delta.dx / sx;
          final dy = d.delta.dy / sy;
          Rect next;
          switch (cornerId) {
            case 'tl':
              next = Rect.fromLTRB(_roi.left + dx, _roi.top + dy, _roi.right, _roi.bottom);
              break;
            case 'tr':
              next = Rect.fromLTRB(_roi.left, _roi.top + dy, _roi.right + dx, _roi.bottom);
              break;
            case 'bl':
              next = Rect.fromLTRB(_roi.left + dx, _roi.top, _roi.right, _roi.bottom + dy);
              break;
            case 'br':
            default:
              next = Rect.fromLTRB(_roi.left, _roi.top, _roi.right + dx, _roi.bottom + dy);
              break;
          }
          _commit(next);
        },
        onPanEnd: (_) => _activeCorner = null,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFFFFC400),
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const [BoxShadow(color: Colors.black54, blurRadius: 4)],
          ),
          child: const Center(
            child: Icon(Icons.open_in_full, color: Colors.white, size: 16),
          ),
        ),
      ),
    );
  }

  Widget _modeButton(String label, IconData icon, _EditMode mode) {
    final active = _mode == mode;
    return GestureDetector(
      onTap: () => setState(() => _mode = mode),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        decoration: BoxDecoration(
          color: active ? const Color(0xFFFF6B35) : Colors.transparent,
          borderRadius: BorderRadius.circular(6),
        ),
        child: Row(
          children: [
            Icon(icon, size: 14, color: active ? Colors.white : Colors.white70),
            const SizedBox(width: 4),
            Text(label, style: TextStyle(color: active ? Colors.white : Colors.white70, fontSize: 12, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}

