import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:image/image.dart' as img;
import '../models/receipt_template.dart';
import '../models/anchor_point.dart';
import '../models/field_roi.dart';
import '../services/template_service.dart';

/// Editable view screen: display a template's master image with
/// draggable/resizable boxes for Anchor A, B, C and Item Table.
/// Changes are saved back to the template JSON when "Save" is pressed.
class TemplateViewScreen extends StatefulWidget {
  final ReceiptTemplate template;

  const TemplateViewScreen({
    super.key,
    required this.template,
  });

  @override
  State<TemplateViewScreen> createState() => _TemplateViewScreenState();
}

class _TemplateViewScreenState extends State<TemplateViewScreen> {
  final TemplateService _templateService = TemplateService();

  Uint8List? _imageBytes;
  img.Image? _decodedImage;
  bool _loading = true;
  String? _error;

  // Editable rectangles (in image coordinate space, not display)
  Rect? _anchorARoi;
  Rect? _anchorBRoi;
  Rect? _anchorCRoi;
  Rect? _itemTableRoi;

  // Track if any changes were made
  bool _hasChanges = false;

  @override
  void initState() {
    super.initState();
    _initializeRois();
    _loadImage();
  }

  void _initializeRois() {
    final t = widget.template;
    if (t.anchorA != null) _anchorARoi = t.anchorA!.roi;
    if (t.anchorB != null) _anchorBRoi = t.anchorB!.roi;
    if (t.anchorC != null) _anchorCRoi = t.anchorC!.roi;
    // Prefer new yellowBoxConfig (current wizard); fall back to legacy itemTableConfig
    if (t.yellowBoxConfig != null) {
      _itemTableRoi = t.yellowBoxConfig!.roi;
    } else if (t.itemTableConfig != null) {
      _itemTableRoi = t.itemTableConfig!.tableRoi;
    }
  }

  Future<void> _loadImage() async {
    try {
      final path = widget.template.masterImagePath;
      if (path == null || !File(path).existsSync()) {
        setState(() {
          _error = 'Master image not found';
          _loading = false;
        });
        return;
      }

      final bytes = await File(path).readAsBytes();
      final decoded = img.decodeImage(bytes);

      setState(() {
        _imageBytes = bytes;
        _decodedImage = decoded;
        _loading = false;
      });
    } catch (e) {
      setState(() {
        _error = 'Failed to load image: $e';
        _loading = false;
      });
    }
  }

  void _markChanged() {
    if (!_hasChanges) {
      setState(() => _hasChanges = true);
    }
  }

  Future<void> _saveChanges() async {
    final t = widget.template;

    // Create mutable copies with updated rois
    if (t.anchorA != null && _anchorARoi != null) {
      t.anchorA = AnchorPoint(
        id: t.anchorA!.id,
        label: t.anchorA!.label,
        type: t.anchorA!.type,
        roi: _anchorARoi!,
        expectedText: t.anchorA!.expectedText,
        imageFingerprint: t.anchorA!.imageFingerprint,
        position: t.anchorA!.position,
        size: t.anchorA!.size,
        confidenceThreshold: t.anchorA!.confidenceThreshold,
      );
    }
    if (t.anchorB != null && _anchorBRoi != null) {
      t.anchorB = AnchorPoint(
        id: t.anchorB!.id,
        label: t.anchorB!.label,
        type: t.anchorB!.type,
        roi: _anchorBRoi!,
        expectedText: t.anchorB!.expectedText,
        imageFingerprint: t.anchorB!.imageFingerprint,
        position: t.anchorB!.position,
        size: t.anchorB!.size,
        confidenceThreshold: t.anchorB!.confidenceThreshold,
      );
    }
    if (t.anchorC != null && _anchorCRoi != null) {
      t.anchorC = AnchorPoint(
        id: t.anchorC!.id,
        label: t.anchorC!.label,
        type: t.anchorC!.type,
        roi: _anchorCRoi!,
        expectedText: t.anchorC!.expectedText,
        imageFingerprint: t.anchorC!.imageFingerprint,
        position: t.anchorC!.position,
        size: t.anchorC!.size,
        confidenceThreshold: t.anchorC!.confidenceThreshold,
      );
    }
    if (t.yellowBoxConfig != null && _itemTableRoi != null) {
      t.yellowBoxConfig = YellowBoxConfig(
        id: t.yellowBoxConfig!.id,
        roi: _itemTableRoi!,
        columns: t.yellowBoxConfig!.columns,
        detectRowsBySubtotal: t.yellowBoxConfig!.detectRowsBySubtotal,
      );
    } else if (t.itemTableConfig != null && _itemTableRoi != null) {
      t.itemTableConfig!.tableRoi = _itemTableRoi!;
    }

    await _templateService.saveTemplate(t);

    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Template saved successfully')),
      );
      setState(() => _hasChanges = false);
    }
  }

  void _updateRoi(String boxId, Rect newRoi) {
    setState(() {
      switch (boxId) {
        case 'A':
          _anchorARoi = newRoi;
          break;
        case 'B':
          _anchorBRoi = newRoi;
          break;
        case 'C':
          _anchorCRoi = newRoi;
          break;
        case 'T':
          _itemTableRoi = newRoi;
          break;
      }
      _hasChanges = true;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: Colors.black,
      appBar: AppBar(
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
        elevation: 0,
        title: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              widget.template.supplierName.isNotEmpty
                  ? widget.template.supplierName
                  : 'Template View',
              style: const TextStyle(
                fontWeight: FontWeight.bold,
                fontSize: 16,
              ),
            ),
            Text(
              'Version ${widget.template.templateVersion}${_hasChanges ? ' (modified)' : ''}',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.normal,
              ),
            ),
          ],
        ),
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.of(context).pop(_hasChanges),
        ),
        actions: [
          if (_hasChanges)
            TextButton.icon(
              icon: const Icon(Icons.save, color: Colors.white),
              label: const Text('Save',
                  style: TextStyle(
                      color: Colors.white, fontWeight: FontWeight.bold)),
              onPressed: _saveChanges,
            ),
        ],
      ),
      body: _loading
          ? const Center(
              child:
                  CircularProgressIndicator(color: Color(0xFFFF6B35)),
            )
          : _error != null
              ? Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Icon(Icons.error_outline,
                          size: 48, color: Colors.grey[600]),
                      const SizedBox(height: 16),
                      Text(
                        _error!,
                        style: TextStyle(color: Colors.grey[400]),
                      ),
                    ],
                  ),
                )
              : _buildImageWithOverlays(),
      bottomNavigationBar: _loading || _error != null
          ? null
          : Container(
              padding:
                  const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              color: Colors.grey[900],
              child: const Text(
                '👆 Drag box to move   ↘️ Drag corner to resize',
                textAlign: TextAlign.center,
                style: TextStyle(color: Colors.white70, fontSize: 12),
              ),
            ),
    );
  }

  Widget _buildImageWithOverlays() {
    return LayoutBuilder(
      builder: (context, constraints) {
        if (_decodedImage == null) return const SizedBox.shrink();

        final imgW = _decodedImage!.width.toDouble();
        final imgH = _decodedImage!.height.toDouble();

        // Calculate display size maintaining aspect ratio
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        final scale = (maxW / imgW).clamp(0.0, maxH / imgH);
        final dispW = imgW * scale;
        final dispH = imgH * scale;

        // Center the image
        final offsetX = (maxW - dispW) / 2;
        final offsetY = (maxH - dispH) / 2;

        return InteractiveViewer(
          boundaryMargin: const EdgeInsets.all(64),
          minScale: 0.5,
          maxScale: 4.0,
          child: SizedBox(
            width: maxW,
            height: maxH,
            child: Stack(
              children: [
                // Image
                Positioned(
                  left: offsetX,
                  top: offsetY,
                  width: dispW,
                  height: dispH,
                  child: Image.memory(_imageBytes!, fit: BoxFit.fill),
                ),
                // Anchor A (Red) - draggable
                if (_anchorARoi != null)
                  _buildDraggableBox(
                    boxId: 'A',
                    label: 'Anchor A',
                    imageRoi: _anchorARoi!,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    scale: scale,
                    imgW: imgW,
                    imgH: imgH,
                    color: const Color(0xFFE53935),
                  ),
                // Anchor B (Blue) - draggable
                if (_anchorBRoi != null)
                  _buildDraggableBox(
                    boxId: 'B',
                    label: 'Anchor B',
                    imageRoi: _anchorBRoi!,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    scale: scale,
                    imgW: imgW,
                    imgH: imgH,
                    color: const Color(0xFF1976D2),
                  ),
                // Anchor C (Green) - draggable
                if (_anchorCRoi != null)
                  _buildDraggableBox(
                    boxId: 'C',
                    label: 'Anchor C',
                    imageRoi: _anchorCRoi!,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    scale: scale,
                    imgW: imgW,
                    imgH: imgH,
                    color: const Color(0xFF388E3C),
                  ),
                // Item Table / YELLOW Box - draggable
                if (_itemTableRoi != null)
                  _buildDraggableBox(
                    boxId: 'T',
                    label: widget.template.yellowBoxConfig != null
                        ? 'Yellow Box'
                        : 'Item Table',
                    imageRoi: _itemTableRoi!,
                    offsetX: offsetX,
                    offsetY: offsetY,
                    scale: scale,
                    imgW: imgW,
                    imgH: imgH,
                    color: const Color(0xFFFFC400),
                  ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildDraggableBox({
    required String boxId,
    required String label,
    required Rect imageRoi,
    required double offsetX,
    required double offsetY,
    required double scale,
    required double imgW,
    required double imgH,
    required Color color,
  }) {
    final left = offsetX + imageRoi.left * scale;
    final top = offsetY + imageRoi.top * scale;
    final width = imageRoi.width * scale;
    final height = imageRoi.height * scale;

    return Positioned(
      left: left,
      top: top,
      width: width,
      height: height,
      child: _DraggableResizableBox(
        boxId: boxId,
        label: label,
        color: color,
        currentImageRoi: imageRoi,
        scale: scale,
        imgW: imgW,
        imgH: imgH,
        onRoiChanged: (newRoi) => _updateRoi(boxId, newRoi),
      ),
    );
  }
}

/// A widget that renders a colored box with:
/// - Drag-to-move (single finger anywhere on box)
/// - Drag corner handles to resize (4 corners)
/// - Color label badge
class _DraggableResizableBox extends StatefulWidget {
  final String boxId;
  final String label;
  final Color color;
  final Rect currentImageRoi;
  final double scale;
  final double imgW;
  final double imgH;
  final ValueChanged<Rect> onRoiChanged;

  const _DraggableResizableBox({
    required this.boxId,
    required this.label,
    required this.color,
    required this.currentImageRoi,
    required this.scale,
    required this.imgW,
    required this.imgH,
    required this.onRoiChanged,
  });

  @override
  State<_DraggableResizableBox> createState() =>
      _DraggableResizableBoxState();
}

class _DraggableResizableBoxState extends State<_DraggableResizableBox> {
  Offset? _dragStartImagePos;
  Rect? _dragStartImageRoi;
  String? _activeCorner; // 'TL', 'TR', 'BL', 'BR'
  static const double _minSize = 20.0; // min box size in image pixels
  static const double _handleSize = 28.0; // fat hit area in display px

  void _onMoveStart(DragStartDetails details) {
    final localPos = details.localPosition;
    // Convert display position back to image coords
    final imgX = localPos.dx / widget.scale;
    final imgY = localPos.dy / widget.scale;
    _dragStartImagePos = Offset(imgX, imgY);
    _dragStartImageRoi = widget.currentImageRoi;
    _activeCorner = null;
  }

  void _onMoveUpdate(DragUpdateDetails details) {
    if (_dragStartImagePos == null || _dragStartImageRoi == null) return;
    final localPos = details.localPosition;
    final imgX = localPos.dx / widget.scale;
    final imgY = localPos.dy / widget.scale;
    final dx = imgX - _dragStartImagePos!.dx;
    final dy = imgY - _dragStartImagePos!.dy;

    final newRoi = Rect.fromLTRB(
      (_dragStartImageRoi!.left + dx).clamp(0.0, widget.imgW - _minSize),
      (_dragStartImageRoi!.top + dy).clamp(0.0, widget.imgH - _minSize),
      (_dragStartImageRoi!.right + dx).clamp(_minSize, widget.imgW),
      (_dragStartImageRoi!.bottom + dy).clamp(_minSize, widget.imgH),
    );
    widget.onRoiChanged(newRoi);
  }

  void _onResizeStart(DragStartDetails details, String corner) {
    final localPos = details.localPosition;
    final imgX = localPos.dx / widget.scale;
    final imgY = localPos.dy / widget.scale;
    _dragStartImagePos = Offset(imgX, imgY);
    _dragStartImageRoi = widget.currentImageRoi;
    _activeCorner = corner;
  }

  void _onResizeUpdate(DragUpdateDetails details) {
    if (_dragStartImagePos == null ||
        _dragStartImageRoi == null ||
        _activeCorner == null) return;

    final localPos = details.localPosition;
    final imgX = localPos.dx / widget.scale;
    final imgY = localPos.dy / widget.scale;
    final dx = imgX - _dragStartImagePos!.dx;
    final dy = imgY - _dragStartImagePos!.dy;

    final orig = _dragStartImageRoi!;
    double newLeft = orig.left;
    double newTop = orig.top;
    double newRight = orig.right;
    double newBottom = orig.bottom;

    switch (_activeCorner) {
      case 'TL':
        newLeft = (orig.left + dx).clamp(0.0, orig.right - _minSize);
        newTop = (orig.top + dy).clamp(0.0, orig.bottom - _minSize);
        break;
      case 'TR':
        newRight = (orig.right + dx).clamp(orig.left + _minSize, widget.imgW);
        newTop = (orig.top + dy).clamp(0.0, orig.bottom - _minSize);
        break;
      case 'BL':
        newLeft = (orig.left + dx).clamp(0.0, orig.right - _minSize);
        newBottom =
            (orig.bottom + dy).clamp(orig.top + _minSize, widget.imgH);
        break;
      case 'BR':
        newRight = (orig.right + dx).clamp(orig.left + _minSize, widget.imgW);
        newBottom =
            (orig.bottom + dy).clamp(orig.top + _minSize, widget.imgH);
        break;
    }

    widget.onRoiChanged(
        Rect.fromLTRB(newLeft, newTop, newRight, newBottom));
  }

  void _onEnd(DragEndDetails details) {
    _dragStartImagePos = null;
    _dragStartImageRoi = null;
    _activeCorner = null;
  }

  @override
  Widget build(BuildContext context) {
    final w = widget.currentImageRoi.width * widget.scale;
    final h = widget.currentImageRoi.height * widget.scale;

    return SizedBox(
      width: w,
      height: h,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // Body - draggable
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque,
              onPanStart: _onMoveStart,
              onPanUpdate: _onMoveUpdate,
              onPanEnd: _onEnd,
              child: Container(
                decoration: BoxDecoration(
                  border: Border.all(color: widget.color, width: 2.5),
                  color: widget.color.withOpacity(0.10),
                ),
                child: Stack(
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                            horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: widget.color,
                          borderRadius: const BorderRadius.only(
                            bottomRight: Radius.circular(6),
                          ),
                        ),
                        child: Text(
                          widget.label,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          // Corner handles - resizable
          // Top-left
          _buildCorner('TL', Alignment.topLeft),
          // Top-right
          _buildCorner('TR', Alignment.topRight),
          // Bottom-left
          _buildCorner('BL', Alignment.bottomLeft),
          // Bottom-right
          _buildCorner('BR', Alignment.bottomRight),
        ],
      ),
    );
  }

  Widget _buildCorner(String corner, Alignment alignment) {
    return Align(
      alignment: alignment,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onPanStart: (d) => _onResizeStart(d, corner),
        onPanUpdate: _onResizeUpdate,
        onPanEnd: _onEnd,
        child: Container(
          width: _handleSize,
          height: _handleSize,
          color: Colors.transparent,
          child: Center(
            child: Container(
              width: 14,
              height: 14,
              decoration: BoxDecoration(
                color: widget.color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withOpacity(0.4),
                    blurRadius: 2,
                    offset: const Offset(0, 1),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}