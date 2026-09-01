import 'dart:io';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:image_picker/image_picker.dart';
import 'package:image/image.dart' as img;
import '../services/template_service.dart';
import '../services/image_processor.dart';
import '../services/ocr_service.dart';
import '../models/receipt_template.dart';
import '../models/anchor_point.dart';
import '../models/field_roi.dart';

/// New Template Wizard �ö 4 Steps
/// Step 1: Capture Master Receipt
/// Step 2: Draw 5 Boxes (BLACK, RED, BLUE, YELLOW, GREEN)
class NewTemplateWizard extends StatefulWidget {
  const NewTemplateWizard({super.key});

  @override
  State<NewTemplateWizard> createState() => _NewTemplateWizardState();
}

class _NewTemplateWizardState extends State<NewTemplateWizard> {
  final TemplateService _templateService = TemplateService();
  final ImagePicker _picker = ImagePicker();

  // Wizard state
  int _currentStep = 0;
  late ReceiptTemplate _template;
  File? _masterImage;
  img.Image? _processedImage;
  Uint8List? _cachedJpg; // re-encoded JPEG cache to avoid encode-on-every-rebuild

  // Five boxes state (Step 2) - NEW: BLACK box for Supplier Name
  Rect _blackBox = Rect.zero;  // BLACK: Supplier Name (manual, not OCR)
  Rect _redBox = Rect.zero;    // RED: Invoice Number
  Rect _blueBox = Rect.zero;   // BLUE: Invoice Date
  Rect _yellowBox = Rect.zero; // YELLOW: Items (ROI Fields)
  Rect _greenBox = Rect.zero;  // GREEN: Grand Total
  String _supplierFromBlackBox = ''; // Supplier name entered by user

  String _supplierName = '';
  
  // Processing state
  bool _isProcessing = false;

  @override
  void initState() {
    super.initState();
    final id = 'TPL_${DateTime.now().millisecondsSinceEpoch}';
    _template = ReceiptTemplate(id: id, supplierName: '');
  }

  // ─ Navigation ─

  void _nextStep() {
    if (_currentStep < 2) setState(() => _currentStep++);
  }

  void _prevStep() {
    if (_currentStep > 0) setState(() => _currentStep--);
  }

  bool get _canProceed {
    switch (_currentStep) {
      case 0: return _masterImage != null;
      case 1: return _blackBox != Rect.zero && _redBox != Rect.zero &&
                    _blueBox != Rect.zero && _yellowBox != Rect.zero &&
                    _greenBox != Rect.zero;
      case 2: return _canSave; // All boxes set, lines defined, name entered
      default: return false;
    }
  }


  bool get _canSave =>
      _masterImage != null &&
      _blackBox != Rect.zero &&
      _redBox != Rect.zero &&
      _blueBox != Rect.zero &&
      _yellowBox != Rect.zero &&
      _greenBox != Rect.zero &&
      
      _supplierFromBlackBox.trim().isNotEmpty;

  // ─ Step 1: Capture Master Receipt ─

  Future<void> _captureMaster() async {
    final photo = await _picker.pickImage(
      source: ImageSource.camera,
      maxWidth: 2048,
      maxHeight: 2048,
      imageQuality: 90,
    );
    if (photo == null) return;

    final bytes = await File(photo.path).readAsBytes();
    final processedBytes = await ImageProcessor.processReceipt(bytes);

    _masterImage = File(photo.path.replaceAll('.jpg', '_master.jpg'));
    await _masterImage!.writeAsBytes(processedBytes);
    _processedImage = img.decodeImage(processedBytes);
    _cachedJpg = processedBytes;

    if (_processedImage != null) {
      _template.masterWidth = _processedImage!.width.toDouble();
      _template.masterHeight = _processedImage!.height.toDouble();
      _initializeBoxes();
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
    _cachedJpg = processedBytes;

    if (_processedImage != null) {
      _template.masterWidth = _processedImage!.width.toDouble();
      _template.masterHeight = _processedImage!.height.toDouble();
      _initializeBoxes();
    }
    setState(() {});
  }

  void _initializeBoxes() {
    if (_processedImage == null) return;

    final w = _processedImage!.width.toDouble();
    final h = _processedImage!.height.toDouble();

    // Initialize 5 boxes in top-to-bottom sequence
    // BLACK: Supplier Name (topmost, manual entry - not OCR)
    _blackBox = Rect.fromLTWH(w * 0.10, h * 0.02, w * 0.80, h * 0.06);
    // RED: Invoice Number (was Company name)
    _redBox = Rect.fromLTWH(w * 0.10, h * 0.10, w * 0.80, h * 0.06);
    // BLUE: Invoice Date
    _blueBox = Rect.fromLTWH(w * 0.10, h * 0.18, w * 0.80, h * 0.05);
    // YELLOW: Items (middle)
    _yellowBox = Rect.fromLTWH(w * 0.08, h * 0.30, w * 0.84, h * 0.40);
    // GREEN: Grand Total (bottom)
    _greenBox = Rect.fromLTWH(w * 0.30, h * 0.82, w * 0.50, h * 0.07);
  }

  void _rotateMaster(int degrees) {
    if (_processedImage == null) return;
    setState(() {
      _processedImage = img.copyRotate(_processedImage!, angle: degrees);
      final bytes = img.encodeJpg(_processedImage!, quality: 92);
      _masterImage?.writeAsBytes(bytes);
      _cachedJpg = bytes;
      _template.masterWidth = _processedImage!.width.toDouble();
      _template.masterHeight = _processedImage!.height.toDouble();

      // Reinitialize boxes for new dimensions
      _initializeBoxes();
    });
  }

  // ─ Step 2: Draw 5 Boxes (BLACK, RED, BLUE, YELLOW, GREEN) ─

  Future<void> _openFiveBoxEditor() async {
    if (_processedImage == null) return;

    final result = await Navigator.of(context).push<_FiveBoxResult>(
      MaterialPageRoute(
        fullscreenDialog: true,
        builder: (_) => _FiveBoxEditorScreen(
          image: _processedImage!,
          initialBlack: _blackBox,
          initialRed: _redBox,
          initialBlue: _blueBox,
          initialYellow: _yellowBox,
          initialGreen: _greenBox,
        ),
      ),
    );

    if (result == null) return;

    setState(() {
      _blackBox = result.black;
      _redBox = result.red;
      _blueBox = result.blue;
      _yellowBox = result.yellow;
      _greenBox = result.green;
      // Supplier name will be set after OCR in _performBlackBoxOCR

      // Update template anchors
      // BLACK box: Supplier Name (manual, stored in template.supplierName directly)
      // We don't create an AnchorPoint for black - it's just for visual positioning reference

      _template.anchorA = AnchorPoint(
        id: 'anchor_a',
        label: 'Invoice Number',
        type: 'header_a',
        roi: _redBox,
        expectedText: '',
        position: (_redBox.top + _redBox.bottom) / 2 / _template.masterHeight,
      );

      _template.anchorB = AnchorPoint(
        id: 'anchor_b',
        label: 'Invoice Date',
        type: 'header_b',
        roi: _blueBox,
        expectedText: '',
        position: (_blueBox.top + _blueBox.bottom) / 2 / _template.masterHeight,
      );

      _template.anchorC = AnchorPoint(
        id: 'anchor_c',
        label: 'Grand Total',
        type: 'footer_c',
        roi: _greenBox,
        expectedText: '',
        position: (_greenBox.top + _greenBox.bottom) / 2 / _template.masterHeight,
      );

      // BLACK box - Supplier Name anchor (stored but not used for OCR)
      _template.anchorBlack = AnchorPoint(
        id: 'black_${DateTime.now().millisecondsSinceEpoch}',
        label: 'BLACK - Supplier Name',
        type: 'black',
        roi: _blackBox,
        expectedText: _supplierFromBlackBox,
        position: (_blackBox.top + _blackBox.bottom) / 2 / _template.masterHeight,
      );

      _template.yellowBoxConfig = YellowBoxConfig(
        id: 'yellow_${DateTime.now().millisecondsSinceEpoch}',
        roi: _yellowBox,
        columns: [],
      );
      
          // Confirm supplier name from BLACK box
    });
    
    // Perform OCR on BLACK box to get supplier name
    await _performBlackBoxOCR();
  }
  
  // OCR the BLACK box to extract supplier name
  Future<void> _performBlackBoxOCR() async {
    if (_processedImage == null || _blackBox == Rect.zero) return;
    
    setState(() => _isProcessing = true);
    
    try {
      // Crop the BLACK box region
      final cropped = img.copyCrop(
        _processedImage!,
        x: _blackBox.left.toInt(),
        y: _blackBox.top.toInt(),
        width: _blackBox.width.toInt(),
        height: _blackBox.height.toInt(),
      );
      
      // Save cropped image to temp file for OCR
      final tempDir = Directory.systemTemp;
      final tempFile = File('${tempDir.path}/black_box_ocr_${DateTime.now().millisecondsSinceEpoch}.jpg');
      await tempFile.writeAsBytes(img.encodeJpg(cropped, quality: 95));
      
      // Use OCR service to read text
      final ocrService = OcrService();
      final text = await ocrService.recognizeText(tempFile);
      
      // Clean up temp file
      try {
        if (await tempFile.exists()) await tempFile.delete();
      } catch (_) {}
      
      setState(() {
        _supplierFromBlackBox = text.trim();
        _isProcessing = false;
      });
      
      // Show the OCR result to user for confirmation
      if (mounted) {
        _showSupplierConfirmationDialog(_supplierFromBlackBox);
      }
    } catch (e) {
      setState(() => _isProcessing = false);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('OCR failed: $e')),
        );
      }
    }
  }
  
  // Show dialog to confirm/edit OCR result
  void _showSupplierConfirmationDialog(String ocrResult) {
    final controller = TextEditingController(text: ocrResult);
    
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (ctx) => AlertDialog(
        title: const Text('Confirm Supplier Name'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('OCR detected from BLACK box:'),
            const SizedBox(height: 8),
            TextField(
              controller: controller,
              decoration: const InputDecoration(
                labelText: 'Supplier Name',
                border: OutlineInputBorder(),
                helperText: 'Edit if OCR is incorrect',
              ),
              maxLines: 2,
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () {
              setState(() => _supplierFromBlackBox = controller.text.trim());
              Navigator.of(ctx).pop();
            },
            child: const Text('Confirm'),
          ),
        ],
      ),
    );
  }

  // ─ Step 3: Save Template ─

  void _showSaveDialog() {
    // Use supplier name from BLACK box if available, otherwise empty
    final nameController = TextEditingController(text: _supplierFromBlackBox);

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Save Template'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('Supplier name (from BLACK box):'),
            const SizedBox(height: 8),
            TextField(
              controller: nameController,
              decoration: const InputDecoration(
                hintText: 'e.g. ST ROSYAM MART SDN BHD',
                border: OutlineInputBorder(),
                helperText: 'Edit if needed - this is the template identifier',
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              final name = nameController.text.trim();
              if (name.isEmpty) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(content: Text('Please enter supplier name')),
                );
                return;
              }

              Navigator.of(ctx).pop();
              await _saveTemplate(name);
            },
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Future<void> _saveTemplate(String supplierName) async {
    
    _template.supplierName = supplierName;
    _template.updatedAt = DateTime.now();
    
    // Save master image
    if (_masterImage != null) {
      final imagePath = await _templateService.saveMasterImage(_template.id, _masterImage!);
      _template.masterImagePath = imagePath;
    }

    // Save template JSON
    await _templateService.saveTemplate(_template);
    
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text('Template "$supplierName" saved successfully!'),
          backgroundColor: Colors.green,
        ),
      );
      Navigator.of(context).pop(true);
    }
  }

  // ─ Build UI ─

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text('New Template ${_currentStep + 1}/3'),
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
      ),
      body: Column(
        children: [
          // Progress indicator
          LinearProgressIndicator(
            value: (_currentStep + 1) / 3,
            backgroundColor: Colors.grey[300],
            valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFFFF6B35)),
          ),
          
          // Step content
          Expanded(
            child: IndexedStack(
              index: _currentStep,
              children: [
                _buildStep1(),
                _buildStep2(),
                _buildSaveStep(),
              ],
            ),
          ),
          
          // Navigation buttons
          _buildNavigation(),
        ],
      ),
    );
  }

  Widget _buildStep1() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 1: Capture Master Receipt',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFFFF6B35)),
          ),
          const SizedBox(height: 12),
          Text(
            'Take a clear, well-lit photo of a sample receipt from this supplier.\n'
            'This will be used as the master template.',
            style: TextStyle(fontSize: 14, color: Colors.grey[600]),
          ),
          const SizedBox(height: 24),
          
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
                    padding: const EdgeInsets.symmetric(vertical: 16),
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
                    padding: const EdgeInsets.symmetric(vertical: 16),
                  ),
                ),
              ),
            ],
          ),

          if (_processedImage != null) ...[
            const SizedBox(height: 20),
            LayoutBuilder(
              builder: (context, constraints) {
                final imgW = _processedImage!.width.toDouble();
                final imgH = _processedImage!.height.toDouble();
                final maxH = 400.0;
                final h = (constraints.maxWidth * imgH / imgW).clamp(200.0, maxH);
                return Container(
                  width: double.infinity,
                  height: h,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: Colors.grey[300]!),
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(12),
                    child: Image.memory(
                      _cachedJpg!,
                      fit: BoxFit.contain,
                      gaplessPlayback: true,
                    ),
                  ),
                );
              },
            ),
            const SizedBox(height: 12),
            Row(
              mainAxisAlignment: MainAxisAlignment.center,
              children: [
                TextButton.icon(
                  onPressed: () => _rotateMaster(-90),
                  icon: const Icon(Icons.rotate_left),
                  label: const Text('Rotate Left'),
                ),
                const SizedBox(width: 16),
                TextButton.icon(
                  onPressed: () => _rotateMaster(90),
                  icon: const Icon(Icons.rotate_right),
                  label: const Text('Rotate Right'),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildStep2() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 2: Draw 5 Boxes',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFFFF6B35)),
          ),
          const SizedBox(height: 12),
          Text(
            'Create 5 boxes on the receipt image. They must NOT overlap and should be arranged from top to bottom:\n\n'
            'Γ¼¢ BLACK: Supplier Name (MANUAL - type the name, not OCR)\n'
            '≡ƒö┤ RED: Invoice Number\n'
            '≡ƒö╡ BLUE: Invoice Date\n'
            '≡ƒƒí YELLOW: Purchase Items (ROI Fields)\n'
            '≡ƒƒó GREEN: Grand Total',
            style: TextStyle(fontSize: 14, color: Colors.grey[700]),
          ),
          const SizedBox(height: 24),
          
          // Preview with boxes
          if (_processedImage != null) ...[
            Container(
              width: double.infinity,
              height: 450,
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(12),
                border: Border.all(color: Colors.grey[300]!),
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: _buildBoxPreview(),
              ),
            ),
            const SizedBox(height: 16),
          ],
          
          Center(
            child: ElevatedButton.icon(
              onPressed: _openFiveBoxEditor,
              icon: const Icon(Icons.edit),
              label: const Text('Open 5-Box Editor'),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B35),
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBoxPreview() {
    if (_processedImage == null) return const SizedBox();

    return LayoutBuilder(
      builder: (context, constraints) {
        final imgW = _processedImage!.width.toDouble();
        final imgH = _processedImage!.height.toDouble();
        final maxW = constraints.maxWidth;
        final maxH = constraints.maxHeight;
        if (imgW == 0 || imgH == 0) return const SizedBox();

        // BoxFit.contain math
        final scaleW = maxW / imgW;
        final scaleH = maxH / imgH;
        final scale = scaleW < scaleH ? scaleW : scaleH;
        final displayedW = imgW * scale;
        final displayedH = imgH * scale;
        final offsetX = (maxW - displayedW) / 2;
        final offsetY = (maxH - displayedH) / 2;

        return Stack(
          children: [
            // Image (filled to displayed rect so coords match)
            Positioned(
              left: offsetX,
              top: offsetY,
              width: displayedW,
              height: displayedH,
              child: Image.memory(
                _cachedJpg!,
                fit: BoxFit.fill,
                gaplessPlayback: true,
              ),
            ),

            // BLACK Box (Supplier Name - topmost)
            if (_blackBox != Rect.zero)
              Positioned(
                left: offsetX + _blackBox.left * scale,
                top: offsetY + _blackBox.top * scale,
                width: _blackBox.width * scale,
                height: _blackBox.height * scale,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.black, width: 2),
                    color: Colors.black.withOpacity(0.1),
                  ),
                  child: const Center(
                    child: Text('BLACK\n(Supplier)', style: TextStyle(fontSize: 12, color: Colors.black, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  ),
                ),
              ),

            // RED Box (Invoice Number)
            if (_redBox != Rect.zero)
              Positioned(
                left: offsetX + _redBox.left * scale,
                top: offsetY + _redBox.top * scale,
                width: _redBox.width * scale,
                height: _redBox.height * scale,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.red, width: 2),
                    color: Colors.red.withOpacity(0.1),
                  ),
                  child: const Center(
                    child: Text('RED\n(Invoice#)', style: TextStyle(fontSize: 12, color: Colors.red, fontWeight: FontWeight.bold), textAlign: TextAlign.center),
                  ),
                ),
              ),

            // BLUE Box
            if (_blueBox != Rect.zero)
              Positioned(
                left: offsetX + _blueBox.left * scale,
                top: offsetY + _blueBox.top * scale,
                width: _blueBox.width * scale,
                height: _blueBox.height * scale,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.blue, width: 2),
                    color: Colors.blue.withOpacity(0.1),
                  ),
                  child: const Center(
                    child: Text('BLUE', style: TextStyle(fontSize: 14, color: Colors.blue, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),

            // YELLOW Box
            if (_yellowBox != Rect.zero)
              Positioned(
                left: offsetX + _yellowBox.left * scale,
                top: offsetY + _yellowBox.top * scale,
                width: _yellowBox.width * scale,
                height: _yellowBox.height * scale,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.yellow[700]!, width: 2),
                    color: Colors.yellow.withOpacity(0.1),
                  ),
                  child: const Center(
                    child: Text('YELLOW', style: TextStyle(fontSize: 14, color: Colors.brown, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),

            // GREEN Box
            if (_greenBox != Rect.zero)
              Positioned(
                left: offsetX + _greenBox.left * scale,
                top: offsetY + _greenBox.top * scale,
                width: _greenBox.width * scale,
                height: _greenBox.height * scale,
                child: Container(
                  decoration: BoxDecoration(
                    border: Border.all(color: Colors.green, width: 2),
                    color: Colors.green.withOpacity(0.1),
                  ),
                  child: const Center(
                    child: Text('GREEN', style: TextStyle(fontSize: 14, color: Colors.green, fontWeight: FontWeight.bold)),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }



  Widget _buildSaveStep() {
    return SingleChildScrollView(
      padding: const EdgeInsets.all(20),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'Step 3: Save Template',
            style: TextStyle(fontSize: 20, fontWeight: FontWeight.bold, color: Color(0xFFFF6B35)),
          ),
          const SizedBox(height: 24),
          
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Template Summary',
                    style: TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
                  ),
                  const Divider(),
                  const SizedBox(height: 8),
                  _buildSummaryRow('BLACK Box (Supplier)', _blackBox != Rect.zero ? 'SET' : 'NOT SET'),
                  _buildSummaryRow('Supplier Name (OCR)', _supplierFromBlackBox.isNotEmpty ? _supplierFromBlackBox : 'NOT SET'),
                  const SizedBox(height: 8),
                  _buildSummaryRow('RED Box (Invoice #)', _redBox != Rect.zero ? 'SET' : 'NOT SET'),
                  _buildSummaryRow('BLUE Box (Date)', _blueBox != Rect.zero ? 'SET' : 'NOT SET'),
                  _buildSummaryRow('YELLOW Box (Items)', _yellowBox != Rect.zero ? 'SET' : 'NOT SET'),
                  _buildSummaryRow('GREEN Box (Total)', _greenBox != Rect.zero ? 'SET' : 'NOT SET'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 24),
          
          SizedBox(
            width: double.infinity,
            child: ElevatedButton.icon(
              onPressed: _showSaveDialog,
              icon: const Icon(Icons.save),
              label: const Text('Save Template'),
              style: ElevatedButton.styleFrom(
                backgroundColor: _canSave ? Colors.green : Colors.grey,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(vertical: 16),
                textStyle: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
              ),
            ),
          ),
          if (!_canSave)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                'WARNING: Complete all steps: capture image, draw 5 boxes, confirm supplier name',
                style: TextStyle(fontSize: 12, color: Colors.orange[800]),
                textAlign: TextAlign.center,
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildSummaryRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(label),
          Text(value, style: const TextStyle(fontWeight: FontWeight.bold)),
        ],
      ),
    );
  }

  Widget _buildNavigation() {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        boxShadow: [
          BoxShadow(
            color: Colors.grey.withOpacity(0.2),
            blurRadius: 4,
            offset: const Offset(0, -2),
          ),
        ],
      ),
      child: Row(
        children: [
          if (_currentStep > 0)
            OutlinedButton(
              onPressed: _prevStep,
              child: const Text('�É Back'),
            ),
          const Spacer(),
          if (_currentStep < 2)
            ElevatedButton(
              onPressed: _canProceed ? _nextStep : null,
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(0xFFFF6B35),
                foregroundColor: Colors.white,
              ),
              child: const Text('Next �Æ'),
            ),
        ],
      ),
    );
  }
}

// ─ Helper Classes ─

class _FiveBoxResult {
  final Rect black;   // Supplier Name position (OCR will read from here)
  final Rect red;     // Invoice Number
  final Rect blue;    // Invoice Date
  final Rect yellow;  // Items
  final Rect green;   // Grand Total

  _FiveBoxResult({
    required this.black,
    required this.red,
    required this.blue,
    required this.yellow,
    required this.green,
  });
}

// ─ Five Box Editor Screen ─

class _FiveBoxEditorScreen extends StatefulWidget {
  final img.Image image;
  final Rect initialBlack;
  final Rect initialRed;
  final Rect initialBlue;
  final Rect initialYellow;
  final Rect initialGreen;

  const _FiveBoxEditorScreen({
    required this.image,
    required this.initialBlack,
    required this.initialRed,
    required this.initialBlue,
    required this.initialYellow,
    required this.initialGreen,
  });

  @override
  State<_FiveBoxEditorScreen> createState() => _FiveBoxEditorScreenState();
}

class _FiveBoxEditorScreenState extends State<_FiveBoxEditorScreen> {
  late Rect _black;   // Supplier Name (OCR)
  late Rect _red;     // Invoice Number
  late Rect _blue;    // Invoice Date
  late Rect _yellow;  // Items
  late Rect _green;   // Grand Total
  String? _selectedBox;
  final _invoiceController = TextEditingController();  // For RED box
  late final Uint8List _cachedJpg; // encoded once, reused every frame

  @override
  void initState() {
    super.initState();
    _black = widget.initialBlack;
    _red = widget.initialRed;
    _blue = widget.initialBlue;
    _yellow = widget.initialYellow;
    _green = widget.initialGreen;
    _cachedJpg = img.encodeJpg(widget.image, quality: 85);
  }

  @override
  void dispose() {
    _invoiceController.dispose();
    super.dispose();
  }

  // Helper: get the actual displayed image rect given a Stack's box constraints
  // Returns the rect (in widget coords) where the image is drawn (with BoxFit.contain)
  Rect _getDisplayedImageRect(double maxW, double maxH) {
    final imgW = widget.image.width.toDouble();
    final imgH = widget.image.height.toDouble();
    if (imgW == 0 || imgH == 0) return Rect.fromLTWH(0, 0, maxW, maxH);

    final scaleW = maxW / imgW;
    final scaleH = maxH / imgH;
    final scale = scaleW < scaleH ? scaleW : scaleH;

    final displayedW = imgW * scale;
    final displayedH = imgH * scale;
    final offsetX = (maxW - displayedW) / 2;
    final offsetY = (maxH - displayedH) / 2;

    return Rect.fromLTWH(offsetX, offsetY, displayedW, displayedH);
  }

  // Convert image pixel coords to widget coords using displayed image rect
  Rect _imgToWidget(Rect imgRect, Rect displayedImgRect) {
    final imgW = widget.image.width.toDouble();
    final imgH = widget.image.height.toDouble();
    if (imgW == 0 || imgH == 0) return displayedImgRect;

    final scaleX = displayedImgRect.width / imgW;
    final scaleY = displayedImgRect.height / imgH;

    return Rect.fromLTWH(
      displayedImgRect.left + imgRect.left * scaleX,
      displayedImgRect.top + imgRect.top * scaleY,
      imgRect.width * scaleX,
      imgRect.height * scaleY,
    );
  }

  // Convert widget coords to image pixel coords
  Rect _widgetToImg(Rect widgetRect, Rect displayedImgRect) {
    final imgW = widget.image.width.toDouble();
    final imgH = widget.image.height.toDouble();
    if (imgW == 0 || imgH == 0) return widgetRect;

    final scaleX = imgW / displayedImgRect.width;
    final scaleY = imgH / displayedImgRect.height;

    return Rect.fromLTWH(
      (widgetRect.left - displayedImgRect.left) * scaleX,
      (widgetRect.top - displayedImgRect.top) * scaleY,
      widgetRect.width * scaleX,
      widgetRect.height * scaleY,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: const Text('Draw 4 Boxes'),
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
        actions: [
          TextButton(
            onPressed: _save,
            child: const Text('Done', style: TextStyle(color: Colors.white)),
          ),
        ],
      ),
      body: Column(
        children: [
          // Editor (instructions removed to maximize image area for box positioning)
          Expanded(
            child: LayoutBuilder(
              builder: (context, constraints) {
                final displayedImg = _getDisplayedImageRect(
                  constraints.maxWidth,
                  constraints.maxHeight,
                );
                return GestureDetector(
                  onTapDown: (details) => _onTapDown(details.localPosition, displayedImg),
                  child: Stack(
                    children: [
                      // Background fill (for tap-outside detection)
                      Positioned.fill(
                        child: Container(color: Colors.black),
                      ),
                      // Image (clipped to displayed rect)
                      Positioned(
                        left: displayedImg.left,
                        top: displayedImg.top,
                        width: displayedImg.width,
                        height: displayedImg.height,
                        child: Image.memory(
                          _cachedJpg,
                          fit: BoxFit.fill,
                          gaplessPlayback: true,
                        ),
                      ),
                      // 5 Boxes: BLACK (Supplier), RED (Invoice#), BLUE (Date), YELLOW (Items), GREEN (Total)
                      _buildBox('black', _black, displayedImg, Colors.black),
                      _buildBox('red', _red, displayedImg, Colors.red),
                      _buildBox('blue', _blue, displayedImg, Colors.blue),
                      _buildBox('yellow', _yellow, displayedImg, Colors.yellow[700]!),
                      _buildBox('green', _green, displayedImg, Colors.green),
                    ],
                  ),
                );
              },
            ),
          ),

          // BLACK box info (OCR will read supplier name from this box)
          if (_selectedBox == 'black')
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text(
                    'Γ¼¢ BLACK Box - Supplier Name',
                    style: TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    'Position this box over the company name on the receipt. OCR will read the text inside this box when you tap "Done".',
                    style: TextStyle(color: Colors.grey[700], fontSize: 13),
                  ),
                  const SizedBox(height: 8),
                  Container(
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: Colors.grey[100],
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: Colors.grey[300]!),
                    ),
                    child: const Row(
                      children: [
                        Icon(Icons.info_outline, size: 16, color: Colors.blue),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Make sure the company name is clearly visible inside the BLACK box',
                            style: TextStyle(fontSize: 12),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),

          // RED box text input (Invoice Number pattern)
          if (_selectedBox == 'red')
            Container(
              padding: const EdgeInsets.all(12),
              color: Colors.white,
              child: TextField(
                controller: _invoiceController,
                decoration: const InputDecoration(
                  labelText: 'Invoice Number (optional pattern)',
                  hintText: 'e.g. INV-2024-001',
                  border: OutlineInputBorder(),
                  helperText: 'Optional: helps OCR identify invoice numbers',
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _buildBox(String id, Rect imgRect, Rect displayedImg, Color color) {
    if (imgRect == Rect.zero) return const SizedBox();

    final widgetRect = _imgToWidget(imgRect, displayedImg);
    final isSelected = _selectedBox == id;

    // 20px transparent grab margin �ö big hit area without changing visible box
    const double kGrabMargin = 20;

    return Positioned(
      left: widgetRect.left - kGrabMargin,
      top: widgetRect.top - kGrabMargin,
      width: widgetRect.width + kGrabMargin * 2,
      height: widgetRect.height + kGrabMargin * 2,
      child: Stack(
        clipBehavior: Clip.none, // IMPORTANT: lets handles extend outside the box
        children: [
          // Move + select hit area (entire grab ring)
          // Use translucent so handles (drawn later in Stack) win the hit-test
          Positioned.fill(
            child: GestureDetector(
              behavior: HitTestBehavior.opaque, // opaque so it absorbs body touches
              onTap: () { print('[TAP] $id'); _selectBox(id); },
              onPanStart: (_) { print('[PAN_START] $id'); _selectBox(id); },
              onPanUpdate: (details) { print('[PAN_UPDATE] $id delta=${details.delta}'); _moveBox(id, details.delta, displayedImg); },
            ),
          ),
          // Visible box body (centered inside grab ring)
          // NO GestureDetector here �ö the outer grab ring handles tap/pan for
          // the whole area. Having an inner GestureDetector consumed the touch
          // before the outer move detector could start a pan gesture.
          Positioned(
            left: kGrabMargin,
            top: kGrabMargin,
            width: widgetRect.width,
            height: widgetRect.height,
            child: Container(
              decoration: BoxDecoration(
                border: Border.all(
                  color: isSelected ? color : color.withOpacity(0.7),
                  width: isSelected ? 3 : 2,
                ),
                color: color.withOpacity(isSelected ? 0.20 : 0.15),
              ),
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  // Label
                  Positioned(
                    left: 4,
                    top: 2,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: color,
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        id.toUpperCase(),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
          // Resize handles �ö placed in OUTER Stack so they aren't clipped
          // by the visible box's Container decoration. Use IgnorePointer on
          // the move detector so handle hit-testing wins; handles are drawn
          // last so they appear on top.
          // Offset (kGrabMargin - 28, kGrabMargin - 28) = (-8, -8) places
          // the handle's 56├ù56 box so its center sits exactly on the corner.
          Positioned(
            left: -8,
            top: -8,
            child: _buildHandle(color, 'tl', id, displayedImg),
          ),
          Positioned(
            right: -8,
            top: -8,
            child: _buildHandle(color, 'tr', id, displayedImg),
          ),
          Positioned(
            left: -8,
            bottom: -8,
            child: _buildHandle(color, 'bl', id, displayedImg),
          ),
          Positioned(
            right: -8,
            bottom: -8,
            child: _buildHandle(color, 'br', id, displayedImg),
          ),
        ],
      ),
    );
  }

  Widget _buildHandle(Color color, String corner, String boxId, Rect displayedImg) {
    // Outer 56x56 transparent hit area for easy grabbing, inner 36x36 visible circle
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onPanStart: (_) { print('[RESIZE_START] $boxId corner=$corner'); _selectBox(boxId); },
      onPanUpdate: (details) { print('[RESIZE_UPDATE] $boxId corner=$corner delta=${details.delta}'); _resizeBox(boxId, corner, details.delta, displayedImg); },
      child: Container(
        width: 56,
        height: 56,
        color: Colors.transparent,
        child: Center(
          child: Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 2.5),
              boxShadow: [
                BoxShadow(
                  color: Colors.black.withOpacity(0.45),
                  blurRadius: 4,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              corner == 'tl' ? Icons.north_west
                  : corner == 'tr' ? Icons.north_east
                  : corner == 'bl' ? Icons.south_west
                  : Icons.south_east,
              color: Colors.white,
              size: 18,
            ),
          ),
        ),
      ),
    );
  }

  void _onTapDown(Offset position, Rect displayedImg) {
    // Check which box was tapped (in widget coords) - priority: black > red > blue > yellow > green
    if (_containsPointWidget(_black, position, displayedImg)) {
      _selectBox('black');
    } else if (_containsPointWidget(_red, position, displayedImg)) {
      _selectBox('red');
    } else if (_containsPointWidget(_blue, position, displayedImg)) {
      _selectBox('blue');
    } else if (_containsPointWidget(_yellow, position, displayedImg)) {
      _selectBox('yellow');
    } else if (_containsPointWidget(_green, position, displayedImg)) {
      _selectBox('green');
    } else {
      setState(() => _selectedBox = null);
    }
  }

  bool _containsPointWidget(Rect imgRect, Offset point, Rect displayedImg) {
    if (imgRect == Rect.zero) return false;
    final w = _imgToWidget(imgRect, displayedImg);
    return point.dx >= w.left &&
        point.dx <= w.right &&
        point.dy >= w.top &&
        point.dy <= w.bottom;
  }

  void _selectBox(String id) {
    setState(() => _selectedBox = id);
  }

  void _moveBox(String id, Offset delta, Rect displayedImg) {
    setState(() {
      switch (id) {
        case 'black':
          _black = _shiftImgRect(_black, delta, displayedImg);
          break;
        case 'red':
          _red = _shiftImgRect(_red, delta, displayedImg);
          break;
        case 'blue':
          _blue = _shiftImgRect(_blue, delta, displayedImg);
          break;
        case 'yellow':
          _yellow = _shiftImgRect(_yellow, delta, displayedImg);
          break;
        case 'green':
          _green = _shiftImgRect(_green, delta, displayedImg);
          break;
      }
    });
  }

  void _resizeBox(String id, String corner, Offset delta, Rect displayedImg) {
    setState(() {
      final scaleX = widget.image.width / displayedImg.width;
      final scaleY = widget.image.height / displayedImg.height;
      final dx = delta.dx * scaleX;
      final dy = delta.dy * scaleY;
      Rect current;
      switch (id) {
        case 'black': current = _black; break;
        case 'red': current = _red; break;
        case 'blue': current = _blue; break;
        case 'yellow': current = _yellow; break;
        case 'green': current = _green; break;
        default: return;
      }

      double newLeft = current.left;
      double newTop = current.top;
      double newRight = current.right;
      double newBottom = current.bottom;

      if (corner.contains('l')) {
        newLeft = (newLeft + dx).clamp(0.0, current.right - 30);
      }
      if (corner.contains('r')) {
        newRight = (newRight + dx).clamp(current.left + 30, widget.image.width.toDouble());
      }
      if (corner.contains('t')) {
        newTop = (newTop + dy).clamp(0.0, current.bottom - 20);
      }
      if (corner.contains('b')) {
        newBottom = (newBottom + dy).clamp(current.top + 20, widget.image.height.toDouble());
      }

      final updated = Rect.fromLTRB(newLeft, newTop, newRight, newBottom);

      switch (id) {
        case 'red': _red = updated; break;
        case 'blue': _blue = updated; break;
        case 'yellow': _yellow = updated; break;
        case 'green': _green = updated; break;
      }
    });
  }

  Rect _shiftImgRect(Rect rect, Offset delta, Rect displayedImg) {
    final scaleX = widget.image.width / displayedImg.width;
    final scaleY = widget.image.height / displayedImg.height;
    final imgDx = delta.dx * scaleX;
    final imgDy = delta.dy * scaleY;
    final imgW = widget.image.width.toDouble();
    final imgH = widget.image.height.toDouble();

    final newLeft = (rect.left + imgDx).clamp(0.0, imgW - 30);
    final newTop = (rect.top + imgDy).clamp(0.0, imgH - 20);
    final newRight = newLeft + rect.width;
    final newBottom = newTop + rect.height;

    return Rect.fromLTRB(newLeft, newTop, newRight, newBottom);
  }

  void _save() {
    Navigator.of(context).pop(_FiveBoxResult(
      black: _black,
      red: _red,
      blue: _blue,
      yellow: _yellow,
      green: _green,
    ));
  }
}

// ─ Column Editor Screen ─

