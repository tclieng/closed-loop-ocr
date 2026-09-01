import 'package:flutter/material.dart';
import '../services/template_service.dart';
import '../models/receipt_template.dart';
import 'template_editor_screen.dart';

/// Screen showing all saved supplier templates (Setup entry point).
class TemplateListScreen extends StatefulWidget {
  const TemplateListScreen({super.key});

  @override
  State<TemplateListScreen> createState() => _TemplateListScreenState();
}

class _TemplateListScreenState extends State<TemplateListScreen> {
  final TemplateService _templateService = TemplateService();
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    await _templateService.loadTemplates();
    setState(() => _loading = false);
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFF6B35),
      appBar: AppBar(
        title: const Text(
          'Supplier Templates',
          style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
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
              // Info header
              Container(
                margin: const EdgeInsets.all(16),
                padding: const EdgeInsets.all(16),
                decoration: BoxDecoration(
                  color: Colors.white.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(16),
                ),
                child: Row(
                  children: [
                    const Icon(Icons.info_outline, color: Colors.white),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: const [
                          Text(
                            'Phase 1: Template Setup',
                            style: TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 14),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'Create receipt templates for each supplier. Define anchor points, ROIs, and item table layout.',
                            style: TextStyle(color: Colors.white70, fontSize: 11),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // Template count
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 16),
                child: Row(
                  children: [
                    Text(
                      '${_templateService.templateCount} templates saved',
                      style: const TextStyle(color: Colors.white70, fontSize: 13),
                    ),
                    const Spacer(),
                    // Create new template
                    ElevatedButton.icon(
                      onPressed: () => _openEditor(null),
                      icon: const Icon(Icons.add, size: 18),
                      label: const Text('New Template'),
                      style: ElevatedButton.styleFrom(
                        backgroundColor: const Color(0xFFFFB347),
                        foregroundColor: Colors.white,
                        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 8),

              // Template list
              Expanded(
                child: _loading
                    ? const Center(child: CircularProgressIndicator(color: Colors.white))
                    : _templateService.templateCount == 0
                        ? _buildEmptyState()
                        : ListView.builder(
                            padding: const EdgeInsets.symmetric(horizontal: 12),
                            itemCount: _templateService.templateCount,
                            itemBuilder: (context, index) {
                              final tpl = _templateService.templates[index];
                              return _buildTemplateCard(tpl);
                            },
                          ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(Icons.add_box_outlined, size: 72, color: Colors.white.withOpacity(0.5)),
          const SizedBox(height: 16),
          Text(
            'No templates yet',
            style: TextStyle(color: Colors.white.withOpacity(0.7), fontSize: 18),
          ),
          const SizedBox(height: 8),
          Text(
            'Tap "New Template" to create\na supplier receipt template',
            textAlign: TextAlign.center,
            style: TextStyle(color: Colors.white.withOpacity(0.5), fontSize: 14),
          ),
        ],
      ),
    );
  }

  Widget _buildTemplateCard(ReceiptTemplate tpl) {
    return Card(
      margin: const EdgeInsets.only(bottom: 8),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
      child: InkWell(
        borderRadius: BorderRadius.circular(14),
        onTap: () => _openEditor(tpl),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              // Status icon
              Container(
                width: 44,
                height: 44,
                decoration: BoxDecoration(
                  color: tpl.isComplete
                      ? const Color(0xFFFF6B35).withOpacity(0.15)
                      : Colors.orange[100],
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(
                  tpl.isComplete ? Icons.check_circle : Icons.edit_note,
                  color: tpl.isComplete ? const Color(0xFFFF6B35) : Colors.orange[700],
                  size: 24,
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      tpl.supplierName.isNotEmpty
                          ? tpl.supplierName
                          : (tpl.anchorA?.expectedText.isNotEmpty == true
                              ? tpl.anchorA!.expectedText
                              : 'Unnamed Template'),
                      style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 15),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      'v${tpl.templateVersion} | ${tpl.fields.length} fields${tpl.itemTableConfig != null ? ' | Table configured' : ''}',
                      style: TextStyle(fontSize: 12, color: Colors.grey[600]),
                    ),
                  ],
                ),
              ),
              // Anchor status
              Text(
                tpl.isComplete ? '3/3 Anchors' : '${[
                  if (tpl.anchorA != null) 'A',
                  if (tpl.anchorB != null) 'B',
                  if (tpl.anchorC != null) 'C',
                ].length}/3 Anchors',
                style: TextStyle(
                  fontSize: 11,
                  color: tpl.isComplete ? const Color(0xFFFF6B35) : Colors.orange[400],
                  fontWeight: FontWeight.w500,
                ),
              ),
              const SizedBox(width: 8),
              // Delete button
              IconButton(
                icon: Icon(Icons.delete_outline, color: Colors.red[400], size: 20),
                onPressed: () => _confirmDelete(tpl),
                padding: EdgeInsets.zero,
                constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
              ),
              const SizedBox(width: 4),
              Icon(Icons.chevron_right, color: Colors.grey[400]),
            ],
          ),
        ),
      ),
    );
  }

  void _openEditor(ReceiptTemplate? template) async {
    await Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => TemplateEditorScreen(existingTemplate: template),
      ),
    );
    _load(); // Refresh list
  }

  void _confirmDelete(ReceiptTemplate template) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Template?'),
        content: Text(
          'Are you sure you want to delete "${template.supplierName.isNotEmpty ? template.supplierName : 'Unnamed Template'}"?\n\nThis action cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Cancel'),
          ),
          ElevatedButton(
            onPressed: () async {
              await _templateService.deleteTemplate(template.id);
              if (mounted) {
                Navigator.of(ctx).pop();
                _load(); // Refresh list
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('Template deleted'),
                    backgroundColor: Colors.red,
                  ),
                );
              }
            },
            style: ElevatedButton.styleFrom(backgroundColor: Colors.red),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }
}
