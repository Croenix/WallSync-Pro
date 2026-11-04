import 'package:flutter/material.dart';
import '../models/desktop_studio_template.dart';
import '../services/desktop_studio_service.dart';

/// Local category-based dock and taskbar template gallery browser.
/// Allows instant filtering, searching, visual inspection, one-click desktop application,
/// duplication, and direct navigation into WallSync Desktop Studio.
class TemplateGalleryView extends StatefulWidget {
  final ValueChanged<DesktopStudioTemplate>? onEditInStudio;
  final VoidCallback? onCreateNew;

  const TemplateGalleryView({super.key, this.onEditInStudio, this.onCreateNew});

  @override
  State<TemplateGalleryView> createState() => _TemplateGalleryViewState();
}

class _TemplateGalleryViewState extends State<TemplateGalleryView> {
  final DesktopStudioService _studioService = DesktopStudioService();
  final TextEditingController _searchController = TextEditingController();

  String _selectedCategory = 'Taskbar';
  String _searchQuery = '';

  static const List<String> _categories = [
    'All',
    'Modern',
    'Minimal',
    'Productivity',
    'Taskbar',
    'Gaming',
    'Compact',
    'Custom',
  ];

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
    _searchController.dispose();
    super.dispose();
  }

  void _onServiceChanged() {
    if (mounted) setState(() {});
  }

  List<DesktopStudioTemplate> get _filteredTemplates {
    return _studioService.allTemplates.where((template) {
      // Category filter
      if (_selectedCategory == 'Custom') {
        if (template.isBuiltIn) return false;
      } else if (_selectedCategory != 'All') {
        if (template.category.toLowerCase() !=
            _selectedCategory.toLowerCase()) {
          return false;
        }
      }

      // Search query filter
      if (_searchQuery.isNotEmpty) {
        final query = _searchQuery.toLowerCase();
        final nameMatches = template.name.toLowerCase().contains(query);
        final descMatches = template.description.toLowerCase().contains(query);
        final tagMatches = template.tags.any(
          (t) => t.toLowerCase().contains(query),
        );
        final authorMatches = template.author.toLowerCase().contains(query);
        if (!nameMatches && !descMatches && !tagMatches && !authorMatches) {
          return false;
        }
      }

      return true;
    }).toList();
  }

  Future<void> _applyTemplate(DesktopStudioTemplate template) async {
    await _studioService.applyTemplateById(template.id);
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Row(
            children: [
              const Icon(
                Icons.check_circle_rounded,
                color: Color(0xFF10B981),
                size: 18,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  'Applied "${template.name}" directly to your desktop!',
                ),
              ),
            ],
          ),
          duration: const Duration(seconds: 2),
        ),
      );
    }
  }

  Future<void> _duplicateTemplate(DesktopStudioTemplate template) async {
    final copy = await _studioService.duplicateTemplate(template.id);
    if (copy != null && mounted) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Duplicated into "${copy.name}"')));
    }
  }

  Future<void> _deleteTemplate(DesktopStudioTemplate template) async {
    final confirm = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF131824),
        title: const Text(
          'Delete Template',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Are you sure you want to permanently delete "${template.name}"?',
          style: const TextStyle(color: Colors.white70),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white60),
            ),
          ),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Delete'),
          ),
        ],
      ),
    );

    if (confirm == true) {
      await _studioService.deleteTemplate(template.id);
    }
  }

  Future<void> _exportTemplate(DesktopStudioTemplate template) async {
    try {
      final path = await _studioService.exportTemplate(template);
      if (mounted) {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('Exported template to: $path')));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Export failed: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final templates = _filteredTemplates;
    final appliedId = _studioService.appliedTemplateId;

    return Scaffold(
      backgroundColor: const Color(0xFF07090F),
      body: Column(
        children: [
          // Header Bar
          _buildHeaderBar(),

          // Category Chips & Search Bar
          _buildFilterControls(),

          // Template Cards Grid
          Expanded(
            child: templates.isEmpty
                ? _buildEmptyState()
                : GridView.builder(
                    padding: const EdgeInsets.all(24),
                    gridDelegate:
                        const SliverGridDelegateWithMaxCrossAxisExtent(
                          maxCrossAxisExtent: 440,
                          mainAxisExtent: 280,
                          crossAxisSpacing: 18,
                          mainAxisSpacing: 18,
                        ),
                    itemCount: templates.length,
                    itemBuilder: (context, index) {
                      final item = templates[index];
                      final isApplied = item.id == appliedId;
                      return _buildTemplateCard(item, isApplied);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildHeaderBar() {
    final title = Row(
      children: [
        Container(
          padding: const EdgeInsets.all(8),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
            ),
            borderRadius: BorderRadius.circular(10),
          ),
          child: const Icon(
            Icons.grid_view_rounded,
            size: 20,
            color: Color(0xFF070B14),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Template Gallery',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 18,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: 0.5,
                ),
              ),
              Text(
                'Curated desktop dock & taskbar templates designed for Windows 10 & 11',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
            ],
          ),
        ),
      ],
    );
    final createButton = widget.onCreateNew == null
        ? null
        : FilledButton.icon(
            icon: const Icon(Icons.add_rounded, size: 16),
            label: const Text(
              'Create New in Studio',
              style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700),
            ),
            style: FilledButton.styleFrom(
              backgroundColor: const Color(0xFF38BDF8),
              foregroundColor: const Color(0xFF070B14),
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: widget.onCreateNew,
          );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 16),
      decoration: BoxDecoration(
        color: const Color(0xFF0E121A),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1.0,
          ),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          if (constraints.maxWidth < 600) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                title,
                if (createButton != null) ...[
                  const SizedBox(height: 10),
                  Align(alignment: Alignment.centerRight, child: createButton),
                ],
              ],
            );
          }

          return Row(
            children: [
              Expanded(child: title),
              if (createButton != null) ...[
                const SizedBox(width: 12),
                createButton,
              ],
            ],
          );
        },
      ),
    );
  }

  Widget _buildFilterControls() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF0B0E17),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 760;
          final categoryFilters = SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: Row(
              children: _categories.map((cat) {
                final isSelected = _selectedCategory == cat;
                return Padding(
                  padding: const EdgeInsets.only(right: 6),
                  child: ChoiceChip(
                    label: Text(cat),
                    selected: isSelected,
                    selectedColor: const Color(0xFF38BDF8),
                    backgroundColor: const Color(0xFF141824),
                    side: BorderSide(
                      color: isSelected
                          ? const Color(0xFF38BDF8)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                    labelStyle: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected
                          ? FontWeight.w700
                          : FontWeight.w500,
                      color: isSelected
                          ? const Color(0xFF070B14)
                          : Colors.white70,
                    ),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 4,
                    ),
                    onSelected: (_) => setState(() => _selectedCategory = cat),
                  ),
                );
              }).toList(),
            ),
          );
          final taskbarShortcut = ActionChip(
            avatar: const Icon(
              Icons.window_rounded,
              size: 14,
              color: Color(0xFF070B14),
            ),
            label: const Text(
              'Taskbar',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.w700),
            ),
            backgroundColor: const Color(0xFF38BDF8),
            labelStyle: const TextStyle(color: Color(0xFF070B14)),
            onPressed: () => setState(() => _selectedCategory = 'Taskbar'),
          );
          final searchField = SizedBox(
            width: compact ? double.infinity : 240,
            height: 34,
            child: TextField(
              controller: _searchController,
              style: const TextStyle(fontSize: 12, color: Colors.white),
              decoration: InputDecoration(
                hintText: 'Search templates...',
                hintStyle: TextStyle(
                  fontSize: 11,
                  color: Colors.white.withValues(alpha: 0.35),
                ),
                prefixIcon: const Icon(
                  Icons.search_rounded,
                  size: 16,
                  color: Colors.white54,
                ),
                suffixIcon: _searchQuery.isNotEmpty
                    ? IconButton(
                        icon: const Icon(
                          Icons.clear_rounded,
                          size: 14,
                          color: Colors.white54,
                        ),
                        onPressed: () {
                          _searchController.clear();
                          setState(() => _searchQuery = '');
                        },
                      )
                    : null,
                filled: true,
                fillColor: const Color(0xFF131824),
                contentPadding: const EdgeInsets.symmetric(vertical: 0),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                enabledBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: BorderSide(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                focusedBorder: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(8),
                  borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                ),
              ),
              onChanged: (val) => setState(() => _searchQuery = val.trim()),
            ),
          );

          if (compact) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Row(
                  children: [
                    taskbarShortcut,
                    const SizedBox(width: 8),
                    Expanded(child: categoryFilters),
                  ],
                ),
                const SizedBox(height: 8),
                searchField,
              ],
            );
          }

          return Row(
            children: [
              Padding(
                padding: const EdgeInsets.only(right: 8),
                child: taskbarShortcut,
              ),
              Expanded(child: categoryFilters),
              const SizedBox(width: 16),
              searchField,
            ],
          );
        },
      ),
    );
  }

  Widget _buildTemplateCard(DesktopStudioTemplate template, bool isApplied) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0F1420),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isApplied
              ? const Color(0xFF10B981)
              : Colors.white.withValues(alpha: 0.08),
          width: isApplied ? 1.5 : 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 14,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Visual Dock Simulation Thumbnail
          Expanded(
            child: Container(
              margin: const EdgeInsets.all(8),
              decoration: BoxDecoration(
                color: const Color(0xFF090C14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
              ),
              child: Stack(
                children: [
                  // Dock Preview Placement
                  Center(child: _buildMiniDockPreview(template)),

                  // Top Badges
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: template.isBuiltIn
                                ? const Color(
                                    0xFF38BDF8,
                                  ).withValues(alpha: 0.15)
                                : const Color(
                                    0xFFA855F7,
                                  ).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(4),
                            border: Border.all(
                              color: template.isBuiltIn
                                  ? const Color(
                                      0xFF38BDF8,
                                    ).withValues(alpha: 0.35)
                                  : const Color(
                                      0xFFA855F7,
                                    ).withValues(alpha: 0.35),
                            ),
                          ),
                          child: Text(
                            template.isBuiltIn ? 'BUILT-IN' : 'CUSTOM',
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w800,
                              color: template.isBuiltIn
                                  ? const Color(0xFF38BDF8)
                                  : const Color(0xFFA855F7),
                              letterSpacing: 0.6,
                            ),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.06),
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            template.category,
                            style: TextStyle(
                              fontSize: 8,
                              fontWeight: FontWeight.w600,
                              color: Colors.white.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),

                  if (isApplied)
                    Positioned(
                      top: 8,
                      right: 8,
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 7,
                          vertical: 3,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF10B981),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              Icons.check_rounded,
                              size: 10,
                              color: Color(0xFF070B14),
                            ),
                            SizedBox(width: 3),
                            Text(
                              'APPLIED',
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                                color: Color(0xFF070B14),
                                letterSpacing: 0.5,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),

          // Card Details & Actions
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Text(
                        template.name,
                        style: const TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: Colors.white,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      '${template.elements.length} items',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  template.description.isNotEmpty
                      ? template.description
                      : 'WallSync customized desktop bar configuration.',
                  style: TextStyle(
                    fontSize: 10.5,
                    color: Colors.white.withValues(alpha: 0.5),
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
                const SizedBox(height: 8),

                // Action Buttons
                Row(
                  children: [
                    // Apply Button
                    Expanded(
                      child: FilledButton.icon(
                        icon: Icon(
                          isApplied
                              ? Icons.check_circle_rounded
                              : Icons.desktop_windows_rounded,
                          size: 13,
                        ),
                        label: Text(
                          isApplied ? 'Applied' : 'Apply',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        style: FilledButton.styleFrom(
                          backgroundColor: isApplied
                              ? const Color(0xFF10B981)
                              : const Color(0xFF38BDF8),
                          foregroundColor: const Color(0xFF070B14),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          minimumSize: const Size(0, 28),
                        ),
                        onPressed: () => _applyTemplate(template),
                      ),
                    ),
                    const SizedBox(width: 6),

                    // Edit in Studio
                    if (widget.onEditInStudio != null)
                      OutlinedButton.icon(
                        icon: const Icon(Icons.edit_rounded, size: 12),
                        label: const Text(
                          'Edit',
                          style: TextStyle(fontSize: 11),
                        ),
                        style: OutlinedButton.styleFrom(
                          foregroundColor: Colors.white70,
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.15),
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 6,
                          ),
                          minimumSize: const Size(0, 28),
                        ),
                        onPressed: () {
                          _studioService.selectTemplate(template);
                          widget.onEditInStudio!(template);
                        },
                      ),

                    // More Menu (Duplicate, Export, Delete)
                    PopupMenuButton<String>(
                      icon: const Icon(
                        Icons.more_vert_rounded,
                        size: 16,
                        color: Colors.white54,
                      ),
                      color: const Color(0xFF141926),
                      tooltip: 'Options',
                      itemBuilder: (ctx) => [
                        const PopupMenuItem(
                          value: 'duplicate',
                          child: Row(
                            children: [
                              Icon(
                                Icons.copy_rounded,
                                size: 14,
                                color: Colors.white70,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Duplicate',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const PopupMenuItem(
                          value: 'export',
                          child: Row(
                            children: [
                              Icon(
                                Icons.file_download_outlined,
                                size: 14,
                                color: Colors.white70,
                              ),
                              SizedBox(width: 8),
                              Text(
                                'Export .wstemplate',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: Colors.white,
                                ),
                              ),
                            ],
                          ),
                        ),
                        if (!template.isBuiltIn)
                          const PopupMenuItem(
                            value: 'delete',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.delete_outline_rounded,
                                  size: 14,
                                  color: Colors.redAccent,
                                ),
                                SizedBox(width: 8),
                                Text(
                                  'Delete',
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: Colors.redAccent,
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      onSelected: (action) {
                        switch (action) {
                          case 'duplicate':
                            _duplicateTemplate(template);
                            break;
                          case 'export':
                            _exportTemplate(template);
                            break;
                          case 'delete':
                            _deleteTemplate(template);
                            break;
                        }
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildMiniDockPreview(DesktopStudioTemplate template) {
    final appearance = template.appearance;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: Color(appearance.backgroundColor),
        borderRadius: BorderRadius.circular(appearance.borderRadius * 0.5),
        border: Border.all(color: Color(appearance.borderColor), width: 1.0),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: template.elements.take(7).map((e) {
          if (e.type == DockElementType.separator) {
            return Container(
              width: 1,
              height: 12,
              margin: const EdgeInsets.symmetric(horizontal: 3),
              color: Colors.white24,
            );
          }
          if (e.type == DockElementType.spacer) {
            return const SizedBox(width: 8);
          }
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 2.5),
            child: Icon(
              DockElementType.getIcon(e.type),
              size: 13,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.search_off_rounded,
            size: 48,
            color: Colors.white.withValues(alpha: 0.25),
          ),
          const SizedBox(height: 12),
          const Text(
            'No templates found matching your search',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w600,
              color: Colors.white70,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Try selecting another category or clearing the search query.',
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.4),
            ),
          ),
        ],
      ),
    );
  }
}
