import 'dart:io';
import 'package:flutter/material.dart';
import '../services/template_service.dart';
import '../models/receipt_template.dart';
import 'template_view_screen.dart';
import 'new_template_wizard.dart';

/// Master Template Files screen - lists all created templates for viewing only.
class MasterTemplatesScreen extends StatefulWidget {
  const MasterTemplatesScreen({super.key});

  @override
  State<MasterTemplatesScreen> createState() => _MasterTemplatesScreenState();
}

class _MasterTemplatesScreenState extends State<MasterTemplatesScreen> {
  final TemplateService _templateService = TemplateService();
  List<ReceiptTemplate> _templates = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadTemplates();
  }

  Future<void> _loadTemplates() async {
    await _templateService.loadTemplates();
    setState(() {
      _templates = _templateService.templates;
      _loading = false;
    });
  }

  String _formatDate(DateTime dt) {
    return '${dt.day.toString().padLeft(2, '0')}/${dt.month.toString().padLeft(2, '0')}/${dt.year}';
  }

  void _onTemplateTap(ReceiptTemplate template) {
    Navigator.of(context).push(
      MaterialPageRoute(
        builder: (_) => TemplateViewScreen(template: template),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFFFFF8F5),
      appBar: AppBar(
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
        elevation: 0,
        title: const Text(
          'Master Template Files',
          style: TextStyle(fontWeight: FontWeight.bold),
        ),
        centerTitle: true,
        leading: IconButton(
          icon: const Icon(Icons.arrow_back_ios),
          onPressed: () => Navigator.of(context).pop(),
        ),
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator(color: Color(0xFFFF6B35)))
          : _templates.isEmpty
              ? _buildEmptyState()
              : _buildTemplateList(),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _createNewTemplate,
        backgroundColor: const Color(0xFFFF6B35),
        foregroundColor: Colors.white,
        icon: const Icon(Icons.add),
        label: const Text('New Template'),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          Icon(
            Icons.folder_open_outlined,
            size: 64,
            color: Colors.grey[400],
          ),
          const SizedBox(height: 16),
          Text(
            'No templates yet',
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w600,
              color: Colors.grey[600],
            ),
          ),
          const SizedBox(height: 8),
          Text(
            'Create templates using the New Template wizard',
            style: TextStyle(
              fontSize: 14,
              color: Colors.grey[500],
            ),
          ),
          const SizedBox(height: 24),
          ElevatedButton.icon(
            onPressed: _createNewTemplate,
            icon: const Icon(Icons.add),
            label: const Text('Create Template'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFFF6B35),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTemplateList() {
    return RefreshIndicator(
      onRefresh: _loadTemplates,
      color: const Color(0xFFFF6B35),
      child: ListView.builder(
        padding: const EdgeInsets.all(16),
        itemCount: _templates.length,
        itemBuilder: (context, index) {
          final template = _templates[index];
          return _buildTemplateCard(template);
        },
      ),
    );
  }

  Widget _buildTemplateCard(ReceiptTemplate template) {
    final bool hasMasterImage = template.masterImagePath != null &&
        File(template.masterImagePath!).existsSync();

    return Card(
      margin: const EdgeInsets.only(bottom: 12),
      elevation: 2,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      child: InkWell(
        onTap: () => _onTemplateTap(template),
        borderRadius: BorderRadius.circular(12),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Row(
            children: [
              // Thumbnail or placeholder
              Container(
                width: 72,
                height: 72,
                decoration: BoxDecoration(
                  color: const Color(0xFFFFF0EB),
                  borderRadius: BorderRadius.circular(8),
                  image: hasMasterImage
                      ? DecorationImage(
                          image: FileImage(File(template.masterImagePath!)),
                          fit: BoxFit.cover,
                        )
                      : null,
                ),
                child: !hasMasterImage
                    ? const Icon(
                        Icons.receipt_long,
                        color: Color(0xFFFF6B35),
                        size: 32,
                      )
                    : null,
              ),
              const SizedBox(width: 16),
              // Template info
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      template.supplierName.isNotEmpty
                          ? template.supplierName
                          : 'Unnamed Template',
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF333333),
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Version ${template.templateVersion}',
                      style: TextStyle(
                        fontSize: 13,
                        color: Colors.grey[600],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Row(
                      children: [
                        _buildStatusChip(
                          'A',
                          template.anchorA != null,
                          const Color(0xFFE53935),
                        ),
                        const SizedBox(width: 6),
                        _buildStatusChip(
                          'B',
                          template.anchorB != null,
                          const Color(0xFF1976D2),
                        ),
                        const SizedBox(width: 6),
                        _buildStatusChip(
                          'C',
                          template.anchorC != null,
                          const Color(0xFF388E3C),
                        ),
                        const SizedBox(width: 6),
                        _buildStatusChip(
                          'YELLOW',
                          template.yellowBoxConfig != null,
                          const Color(0xFFFFC400),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              // Delete button
              IconButton(
                icon: Icon(
                  Icons.delete_outline,
                  color: Colors.red[400],
                ),
                onPressed: () => _confirmDelete(template),
                tooltip: 'Delete template',
              ),
              // Arrow indicator
              const Icon(
                Icons.chevron_right,
                color: Colors.grey,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildStatusChip(String label, bool active, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: active ? color.withOpacity(0.15) : Colors.grey[200],
        borderRadius: BorderRadius.circular(4),
        border: Border.all(
          color: active ? color.withOpacity(0.5) : Colors.grey[300]!,
          width: 1,
        ),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.bold,
          color: active ? color : Colors.grey[500],
        ),
      ),
    );
  }

  void _confirmDelete(ReceiptTemplate template) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('Delete Template?'),
        content: Text(
          'Are you sure you want to delete "${template.supplierName}"?\n'
          'This cannot be undone.',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel'),
          ),
          TextButton(
            onPressed: () async {
              Navigator.pop(ctx);
              await _templateService.deleteTemplate(template.id);
              _loadTemplates();
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(
                    content: Text('"${template.supplierName}" deleted'),
                    backgroundColor: Colors.red[400],
                  ),
                );
              }
            },
            child: const Text('Delete', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _createNewTemplate() async {
    final result = await Navigator.push(
      context,
      MaterialPageRoute(builder: (_) => const NewTemplateWizard()),
    );
    if (result == true) {
      // Template was saved, refresh list
      _loadTemplates();
    }
  }
}
