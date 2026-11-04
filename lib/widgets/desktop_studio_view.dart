import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/desktop_studio_template.dart';
import '../services/desktop_studio_service.dart';
import 'desktop_studio_preview.dart';
import 'desktop_studio_sidebar.dart';

/// Full-screen visual workspace for WallSync Desktop Studio.
/// Provides a unified desktop virtualization environment with live preview,
/// dock layout editing, history management (undo/redo), and instant application.
class DesktopStudioView extends StatefulWidget {
  final VoidCallback? onOpenGallery;

  const DesktopStudioView({
    super.key,
    this.onOpenGallery,
  });

  @override
  State<DesktopStudioView> createState() => _DesktopStudioViewState();
}

class _DesktopStudioViewState extends State<DesktopStudioView> {
  final DesktopStudioService _studioService = DesktopStudioService();
  final FocusNode _keyboardFocusNode = FocusNode();

  bool _isLivePreviewMode = true;
  String? _selectedElementId;
  bool _isSaving = false;

  @override
  void initState() {
    super.initState();
    _studioService.addListener(_onServiceChanged);
    if (!_studioService.isInitialized) {
      _studioService.init();
    }
  }

  @override
  void dispose() {
    _studioService.removeListener(_onServiceChanged);
    _keyboardFocusNode.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent) return KeyEventResult.ignored;

    final isCtrlPressed = HardwareKeyboard.instance.isControlPressed;
    if (isCtrlPressed) {
      if (event.logicalKey == LogicalKeyboardKey.keyZ) {
        if (HardwareKeyboard.instance.isShiftPressed) {
          _studioService.redo();
        } else {
          _studioService.undo();
        }
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.keyY) {
        _studioService.redo();
        return KeyEventResult.handled;
      } else if (event.logicalKey == LogicalKeyboardKey.keyS) {
        _handleSave();
        return KeyEventResult.handled;
      }
    }
    return KeyEventResult.ignored;
  }

  Future<void> _handleSave() async {
    if (_isSaving) return;
    setState(() => _isSaving = true);
    try {
      await _studioService.saveCurrentTemplate();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Template saved successfully!'),
            duration: Duration(seconds: 2),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Save error: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  Future<void> _handleSaveAs() async {
    final textController = TextEditingController(
      text: '${_studioService.currentTemplate.name} Custom',
    );

    final newName = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131824),
        title: const Text(
          'Save As New Template',
          style: TextStyle(color: Colors.white, fontSize: 16, fontWeight: FontWeight.w700),
        ),
        content: TextField(
          controller: textController,
          autofocus: true,
          style: const TextStyle(color: Colors.white),
          decoration: InputDecoration(
            labelText: 'Template Name',
            labelStyle: const TextStyle(color: Colors.white60),
            filled: true,
            fillColor: const Color(0xFF1B2232),
            border: OutlineInputBorder(borderRadius: BorderRadius.circular(8)),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Cancel', style: TextStyle(color: Colors.white60)),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: const Color(0xFF38BDF8)),
            onPressed: () => Navigator.pop(ctx, textController.text.trim()),
            child: const Text('Save', style: TextStyle(color: Color(0xFF070B14))),
          ),
        ],
      ),
    );

    if (newName != null && newName.isNotEmpty) {
      await _studioService.saveAsNewTemplate(newName);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Created template "$newName"')),
        );
      }
    }
  }

  Future<void> _handleExport() async {
    try {
      final path = await _studioService.exportTemplate(_studioService.currentTemplate);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Exported template to: $path'),
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Export failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _handleImport() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['wstemplate', 'json'],
      );

      if (result.isNotEmpty && result.first.path != null) {
        final imported = await _studioService.importTemplateFromFile(result.first.path!);
        _studioService.selectTemplate(imported);
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('Imported template "${imported.name}" successfully!')),
          );
        }
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Import error: $e'), backgroundColor: Colors.redAccent),
        );
      }
    }
  }

  Future<void> _handleApplyToDesktop() async {
    setState(() => _isSaving = true);
    try {
      await _studioService.applyCurrentTemplateToDesktop();
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Color(0xFF10B981), size: 18),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    'Applied "${_studioService.currentTemplate.name}" to live Windows desktop dock!',
                  ),
                ),
              ],
            ),
            duration: const Duration(seconds: 3),
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Apply failed: $e'), backgroundColor: Colors.redAccent),
        );
      }
    } finally {
      if (mounted) setState(() => _isSaving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final currentTemplate = _studioService.currentTemplate;
    final isApplied = _studioService.appliedTemplateId == currentTemplate.id;
    final isDirty = _studioService.isDirty;

    return Focus(
      focusNode: _keyboardFocusNode,
      autofocus: true,
      onKeyEvent: _handleKeyEvent,
      child: Scaffold(
        backgroundColor: const Color(0xFF07090F),
        body: Column(
          children: [
            // Top Action Toolbar
            _buildTopToolbar(currentTemplate, isApplied, isDirty),

            // Main Studio Body: Center Preview Viewport + Right Customization Sidebar
            Expanded(
              child: Row(
                children: [
                  // Center Virtual Desktop Preview
                  Expanded(
                    child: Container(
                      color: const Color(0xFF07090F),
                      padding: const EdgeInsets.all(24),
                      child: Center(
                        child: DesktopStudioPreview(
                          template: currentTemplate,
                          isLivePreviewMode: _isLivePreviewMode,
                          selectedElementId: _selectedElementId,
                          onSelectElement: (id) => setState(() => _selectedElementId = id),
                          onUpdateTemplate: (updated) => _studioService.updateCurrentTemplate(updated),
                        ),
                      ),
                    ),
                  ),

                  // Right Customization Sidebar
                  DesktopStudioSidebar(
                    template: currentTemplate,
                    selectedElementId: _selectedElementId,
                    onSelectElement: (id) => setState(() => _selectedElementId = id),
                    onUpdateTemplate: (updated) => _studioService.updateCurrentTemplate(updated),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildTopToolbar(DesktopStudioTemplate template, bool isApplied, bool isDirty) {
    return Container(
      height: 56,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0F131C),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1.0,
          ),
        ),
      ),
      child: Row(
        children: [
          // Template Info & Name
          Icon(
            template.isBuiltIn ? Icons.verified_rounded : Icons.palette_rounded,
            size: 20,
            color: const Color(0xFF38BDF8),
          ),
          const SizedBox(width: 8),
          Column(
            mainAxisAlignment: MainAxisAlignment.center,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  Text(
                    template.name,
                    style: const TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(width: 8),
                  // Status Badge
                  _buildStatusBadge(isApplied: isApplied, isDirty: isDirty),
                ],
              ),
              Text(
                '${template.category} • v${template.version} • ${template.elements.length} elements',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ],
          ),
          const SizedBox(width: 20),

          // Presets Quick Dropdown
          Container(
            height: 32,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: const Color(0xFF161C28),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.1),
              ),
            ),
            child: DropdownButtonHideUnderline(
              child: DropdownButton<String>(
                value: template.id,
                dropdownColor: const Color(0xFF131824),
                icon: const Icon(Icons.keyboard_arrow_down_rounded, size: 16, color: Colors.white60),
                style: const TextStyle(fontSize: 12, color: Colors.white),
                items: _studioService.allTemplates.map((t) {
                  return DropdownMenuItem<String>(
                    value: t.id,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          t.isBuiltIn ? Icons.bookmark_rounded : Icons.person_rounded,
                          size: 13,
                          color: t.isBuiltIn ? const Color(0xFF38BDF8) : const Color(0xFFA855F7),
                        ),
                        const SizedBox(width: 6),
                        Text(t.name),
                      ],
                    ),
                  );
                }).toList(),
                onChanged: (id) {
                  if (id != null) _studioService.selectTemplateById(id);
                },
              ),
            ),
          ),

          const SizedBox(width: 14),

          // Undo & Redo buttons
          IconButton(
            icon: const Icon(Icons.undo_rounded, size: 18),
            color: _studioService.canUndo ? Colors.white70 : Colors.white24,
            tooltip: 'Undo (Ctrl+Z)',
            onPressed: _studioService.canUndo ? () => _studioService.undo() : null,
          ),
          IconButton(
            icon: const Icon(Icons.redo_rounded, size: 18),
            color: _studioService.canRedo ? Colors.white70 : Colors.white24,
            tooltip: 'Redo (Ctrl+Y)',
            onPressed: _studioService.canRedo ? () => _studioService.redo() : null,
          ),

          const SizedBox(width: 8),
          Container(
            height: 20,
            width: 1,
            color: Colors.white.withValues(alpha: 0.1),
          ),
          const SizedBox(width: 8),

          // Live Preview Mode Toggle
          InkWell(
            onTap: () => setState(() => _isLivePreviewMode = !_isLivePreviewMode),
            borderRadius: BorderRadius.circular(8),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              decoration: BoxDecoration(
                color: _isLivePreviewMode
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.15)
                    : const Color(0xFF161B26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _isLivePreviewMode
                      ? const Color(0xFF38BDF8).withValues(alpha: 0.5)
                      : Colors.white.withValues(alpha: 0.1),
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isLivePreviewMode ? Icons.play_arrow_rounded : Icons.edit_note_rounded,
                    size: 15,
                    color: _isLivePreviewMode ? const Color(0xFF38BDF8) : Colors.white60,
                  ),
                  const SizedBox(width: 5),
                  Text(
                    _isLivePreviewMode ? 'Live Preview' : 'Edit Mode',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: _isLivePreviewMode ? const Color(0xFF38BDF8) : Colors.white70,
                    ),
                  ),
                ],
              ),
            ),
          ),

          const Spacer(),

          // Template Gallery shortcut
          if (widget.onOpenGallery != null) ...[
            OutlinedButton.icon(
              icon: const Icon(Icons.grid_view_rounded, size: 14),
              label: const Text('Gallery', style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              ),
              onPressed: widget.onOpenGallery,
            ),
            const SizedBox(width: 8),
          ],

          // Import & Export
          IconButton(
            icon: const Icon(Icons.file_upload_outlined, size: 18),
            color: Colors.white70,
            tooltip: 'Import Template (.wstemplate)',
            onPressed: _handleImport,
          ),
          IconButton(
            icon: const Icon(Icons.file_download_outlined, size: 18),
            color: Colors.white70,
            tooltip: 'Export Template (.wstemplate)',
            onPressed: _handleExport,
          ),

          const SizedBox(width: 8),

          // Save & Save As
          OutlinedButton.icon(
            icon: const Icon(Icons.copy_rounded, size: 14),
            label: const Text('Save As', style: TextStyle(fontSize: 11)),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            ),
            onPressed: _handleSaveAs,
          ),
          const SizedBox(width: 8),

          if (isDirty)
            OutlinedButton.icon(
              icon: const Icon(Icons.save_rounded, size: 14),
              label: const Text('Save', style: TextStyle(fontSize: 11)),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFFF59E0B),
                side: const BorderSide(color: Color(0xFFF59E0B)),
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              ),
              onPressed: _handleSave,
            ),

          const SizedBox(width: 8),

          // Apply to Desktop Button
          FilledButton.icon(
            icon: Icon(
              isApplied ? Icons.check_circle_rounded : Icons.desktop_windows_rounded,
              size: 15,
            ),
            label: Text(
              isApplied ? 'CURRENTLY APPLIED' : 'Apply to Desktop',
              style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, letterSpacing: 0.4),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: isApplied ? const Color(0xFF10B981) : const Color(0xFF38BDF8),
              foregroundColor: const Color(0xFF070B14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
            ),
            onPressed: _handleApplyToDesktop,
          ),
        ],
      ),
    );
  }

  Widget _buildStatusBadge({required bool isApplied, required bool isDirty}) {
    Color bg;
    Color fg;
    String text;

    if (isApplied && !isDirty) {
      bg = const Color(0xFF10B981).withValues(alpha: 0.15);
      fg = const Color(0xFF10B981);
      text = 'CURRENTLY APPLIED';
    } else if (isDirty) {
      bg = const Color(0xFFF59E0B).withValues(alpha: 0.15);
      fg = const Color(0xFFF59E0B);
      text = 'UNSAVED EDITS';
    } else {
      bg = const Color(0xFF38BDF8).withValues(alpha: 0.15);
      fg = const Color(0xFF38BDF8);
      text = 'SAVED';
    }

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: fg.withValues(alpha: 0.4), width: 0.8),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 8.5,
          fontWeight: FontWeight.w800,
          color: fg,
          letterSpacing: 0.6,
        ),
      ),
    );
  }
}
