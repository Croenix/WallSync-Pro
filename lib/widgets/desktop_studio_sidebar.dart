import 'dart:convert';
import 'package:flutter/material.dart';
import '../models/desktop_studio_template.dart';

/// Comprehensive customization sidebar and inspector for WallSync Desktop Studio.
/// Features Layout, Appearance, Components palette, Animation Engine controls,
/// and Developer Mode with in-app JSON schema editor and validator.
class DesktopStudioSidebar extends StatefulWidget {
  final DesktopStudioTemplate template;
  final String? selectedElementId;
  final ValueChanged<String?> onSelectElement;
  final ValueChanged<DesktopStudioTemplate> onUpdateTemplate;

  const DesktopStudioSidebar({
    super.key,
    required this.template,
    required this.selectedElementId,
    required this.onSelectElement,
    required this.onUpdateTemplate,
  });

  @override
  State<DesktopStudioSidebar> createState() => _DesktopStudioSidebarState();
}

class _DesktopStudioSidebarState extends State<DesktopStudioSidebar>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;
  final TextEditingController _jsonController = TextEditingController();
  final TextEditingController _elementLabelController = TextEditingController();
  final TextEditingController _elementTargetController = TextEditingController();
  String? _editingElementId;
  String? _jsonValidationError;
  bool _isJsonValid = true;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(length: 5, vsync: this);
    _jsonController.text = widget.template.toFormattedJson();
    _syncElementControllers();
  }

  @override
  void didUpdateWidget(covariant DesktopStudioSidebar oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.template != oldWidget.template) {
      if (_tabController.index != 4) {
        // Only refresh JSON if not actively typing in Developer mode
        _jsonController.text = widget.template.toFormattedJson();
      }
    }
    _syncElementControllers();
  }

  @override
  void dispose() {
    _tabController.dispose();
    _jsonController.dispose();
    _elementLabelController.dispose();
    _elementTargetController.dispose();
    super.dispose();
  }

  DockItemElement? _selectedElement() {
    for (final element in widget.template.elements) {
      if (element.id == widget.selectedElementId) return element;
    }
    return null;
  }

  void _syncElementControllers() {
    final element = _selectedElement();
    if (element?.id != _editingElementId) {
      _editingElementId = element?.id;
      _elementLabelController.text = element?.label ?? '';
      _elementTargetController.text = element?.actionPayload ?? '';
      return;
    }
    if (element != null) {
      if (_elementLabelController.text != element.label) {
        _elementLabelController.text = element.label;
      }
      if (_elementTargetController.text != element.actionPayload) {
        _elementTargetController.text = element.actionPayload;
      }
    }
  }

  void _updateSelectedElement({
    String? label,
    String? actionType,
    String? actionPayload,
  }) {
    final elements = List<DockItemElement>.from(widget.template.elements);
    final index = elements.indexWhere(
      (element) => element.id == widget.selectedElementId,
    );
    if (index < 0) return;
    elements[index] = elements[index].copyWith(
      label: label,
      actionType: actionType,
      actionPayload: actionPayload,
    );
    _update(widget.template.copyWith(elements: elements));
  }

  void _update(DesktopStudioTemplate newTemplate) {
    widget.onUpdateTemplate(newTemplate);
    _jsonController.text = newTemplate.toFormattedJson();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 380,
      decoration: BoxDecoration(
        color: const Color(0xFF0F131C),
        border: Border(
          left: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1.0,
          ),
        ),
      ),
      child: Column(
        children: [
          // Inspector Header & Tabs
          Container(
            height: 48,
            decoration: BoxDecoration(
              color: const Color(0xFF131824),
              border: Border(
                bottom: BorderSide(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
            ),
            child: TabBar(
              controller: _tabController,
              isScrollable: true,
              tabAlignment: TabAlignment.start,
              labelPadding: const EdgeInsets.symmetric(horizontal: 14),
              indicatorColor: const Color(0xFF38BDF8),
              indicatorWeight: 2.5,
              labelColor: const Color(0xFF38BDF8),
              unselectedLabelColor: Colors.white60,
              labelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
              ),
              unselectedLabelStyle: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
              tabs: const [
                Tab(icon: Icon(Icons.tune_rounded, size: 16), text: 'Layout'),
                Tab(icon: Icon(Icons.palette_rounded, size: 16), text: 'Appearance'),
                Tab(icon: Icon(Icons.view_quilt_rounded, size: 16), text: 'Components'),
                Tab(icon: Icon(Icons.animation_rounded, size: 16), text: 'Animation'),
                Tab(icon: Icon(Icons.code_rounded, size: 16), text: 'Developer'),
              ],
            ),
          ),

          // Tab View Panes
          Expanded(
            child: TabBarView(
              controller: _tabController,
              children: [
                _buildLayoutPane(),
                _buildAppearancePane(),
                _buildComponentsPane(),
                _buildAnimationPane(),
                _buildDeveloperPane(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ===========================================================================
  // 1. LAYOUT PANE
  // ===========================================================================
  Widget _buildLayoutPane() {
    final layout = widget.template.layout;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader('Dock Edge Placement'),
        const SizedBox(height: 8),
        _buildSegmentedGroup<DockPosition>(
          currentValue: layout.position,
          items: const [
            MapEntry(DockPosition.bottom, 'Bottom'),
            MapEntry(DockPosition.top, 'Top'),
            MapEntry(DockPosition.left, 'Left'),
            MapEntry(DockPosition.right, 'Right'),
          ],
          onSelect: (pos) => _update(
            widget.template.copyWith(layout: layout.copyWith(position: pos)),
          ),
        ),
        const SizedBox(height: 18),

        _buildSectionHeader('Alignment'),
        const SizedBox(height: 8),
        _buildSegmentedGroup<DockAlignment>(
          currentValue: layout.alignment,
          items: const [
            MapEntry(DockAlignment.start, 'Start'),
            MapEntry(DockAlignment.center, 'Center'),
            MapEntry(DockAlignment.end, 'End'),
          ],
          onSelect: (align) => _update(
            widget.template.copyWith(layout: layout.copyWith(alignment: align)),
          ),
        ),
        const SizedBox(height: 18),

        _buildSectionHeader('Sizing & Thickness'),
        _buildSliderRow(
          title: 'Thickness (Bar Height)',
          value: layout.thickness,
          min: 36.0,
          max: 84.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(layout: layout.copyWith(thickness: val)),
          ),
        ),
        _buildSwitchRow(
          title: 'Auto-Size to Content',
          subtitle: 'Fit width proportionally to active icons',
          value: layout.autoSize,
          onChanged: (val) => _update(
            widget.template.copyWith(layout: layout.copyWith(autoSize: val)),
          ),
        ),
        if (!layout.autoSize) ...[
          _buildSliderRow(
            title: 'Custom Length',
            value: layout.length ?? 600.0,
            min: 240.0,
            max: 1400.0,
            unit: 'px',
            onChanged: (val) => _update(
              widget.template.copyWith(layout: layout.copyWith(length: val)),
            ),
          ),
        ],
        const SizedBox(height: 14),

        _buildSectionHeader('Screen Offsets & Spacing'),
        _buildSliderRow(
          title: 'Screen Edge Distance',
          value: layout.edgeOffset,
          min: 0.0,
          max: 48.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(layout: layout.copyWith(edgeOffset: val)),
          ),
        ),
        _buildSliderRow(
          title: 'Item Spacing',
          value: layout.itemSpacing,
          min: 2.0,
          max: 24.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(layout: layout.copyWith(itemSpacing: val)),
          ),
        ),
        _buildSliderRow(
          title: 'Horizontal Padding',
          value: layout.paddingHorizontal,
          min: 4.0,
          max: 36.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(layout: layout.copyWith(paddingHorizontal: val)),
          ),
        ),
        _buildSliderRow(
          title: 'Vertical Padding',
          value: layout.paddingVertical,
          min: 2.0,
          max: 20.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(layout: layout.copyWith(paddingVertical: val)),
          ),
        ),
        const SizedBox(height: 14),

        _buildSectionHeader('Multi-Monitor Targeting'),
        _buildSegmentedGroup<String>(
          currentValue: layout.multiMonitorTarget,
          items: const [
            MapEntry('primary', 'Primary Display'),
            MapEntry('all', 'All Monitors'),
          ],
          onSelect: (target) => _update(
            widget.template.copyWith(layout: layout.copyWith(multiMonitorTarget: target)),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 2. APPEARANCE PANE
  // ===========================================================================
  Widget _buildAppearancePane() {
    final appearance = widget.template.appearance;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader('Background Material'),
        const SizedBox(height: 8),
        _buildSegmentedGroup<DockBackgroundStyle>(
          currentValue: appearance.style,
          items: const [
            MapEntry(DockBackgroundStyle.acrylic, 'Acrylic'),
            MapEntry(DockBackgroundStyle.glass, 'Glass'),
            MapEntry(DockBackgroundStyle.mica, 'Mica'),
            MapEntry(DockBackgroundStyle.solid, 'Solid'),
            MapEntry(DockBackgroundStyle.gradient, 'Gradient'),
          ],
          onSelect: (style) => _update(
            widget.template.copyWith(appearance: appearance.copyWith(style: style)),
          ),
        ),
        const SizedBox(height: 18),

        _buildSectionHeader('Colors & Opacity'),
        _buildColorTile(
          title: 'Background Base Tint',
          color: Color(appearance.backgroundColor),
          onColorChanged: (c) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(backgroundColor: c.toARGB32()),
            ),
          ),
        ),
        _buildColorTile(
          title: 'Active Indicator Accent',
          color: Color(appearance.activeIndicatorColor),
          onColorChanged: (c) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(activeIndicatorColor: c.toARGB32()),
            ),
          ),
        ),
        const SizedBox(height: 14),

        _buildSectionHeader('Acrylic Blur & Transparency'),
        _buildSliderRow(
          title: 'Backdrop Blur Intensity',
          value: appearance.blurIntensity,
          min: 0.0,
          max: 60.0,
          unit: 'σ',
          onChanged: (val) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(blurIntensity: val),
            ),
          ),
        ),
        const SizedBox(height: 14),

        _buildSectionHeader('Borders & Radius'),
        _buildSliderRow(
          title: 'Corner Radius',
          value: appearance.borderRadius,
          min: 0.0,
          max: 36.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(borderRadius: val),
            ),
          ),
        ),
        _buildSliderRow(
          title: 'Border Width',
          value: appearance.borderWidth,
          min: 0.0,
          max: 3.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(borderWidth: val),
            ),
          ),
        ),
        _buildColorTile(
          title: 'Border Color',
          color: Color(appearance.borderColor),
          onColorChanged: (c) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(borderColor: c.toARGB32()),
            ),
          ),
        ),
        const SizedBox(height: 14),

        _buildSectionHeader('Shadow & Elevation'),
        _buildSliderRow(
          title: 'Shadow Blur',
          value: appearance.shadowBlur,
          min: 0.0,
          max: 48.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(shadowBlur: val),
            ),
          ),
        ),
        _buildSliderRow(
          title: 'Icon Size',
          value: appearance.iconSize,
          min: 16.0,
          max: 36.0,
          unit: 'px',
          onChanged: (val) => _update(
            widget.template.copyWith(
              appearance: appearance.copyWith(iconSize: val),
            ),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 3. COMPONENTS PANE
  // ===========================================================================
  Widget _buildComponentsPane() {
    final elements = widget.template.elements;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader('Active Elements in Dock (${elements.length})'),
        const SizedBox(height: 6),
        Text(
          'Reorder, inspect, or remove components from the dock.',
          style: TextStyle(fontSize: 11, color: Colors.white.withValues(alpha: 0.5)),
        ),
        const SizedBox(height: 12),

        ReorderableListView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          itemCount: elements.length,
          // ignore: deprecated_member_use
          onReorder: (oldIndex, newIndex) {
            final list = List<DockItemElement>.from(elements);
            if (oldIndex < newIndex) newIndex -= 1;
            final item = list.removeAt(oldIndex);
            list.insert(newIndex, item);
            _update(widget.template.copyWith(elements: list));
          },
          itemBuilder: (context, index) {
            final elem = elements[index];
            final isSelected = widget.selectedElementId == elem.id;

            return Container(
              key: ValueKey(elem.id),
              margin: const EdgeInsets.only(bottom: 6),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.12)
                    : const Color(0xFF161B26),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: isSelected
                      ? const Color(0xFF38BDF8)
                      : Colors.white.withValues(alpha: 0.08),
                  width: isSelected ? 1.5 : 1.0,
                ),
              ),
              child: Material(
                type: MaterialType.transparency,
                child: ListTile(
                  dense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 0),
                  leading: Icon(
                    DockElementType.getIcon(elem.type),
                    size: 18,
                    color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
                  ),
                  title: Text(
                    elem.label.isNotEmpty ? elem.label : DockElementType.getDisplayName(elem.type),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? Colors.white : Colors.white.withValues(alpha: 0.85),
                    ),
                  ),
                  subtitle: Text(
                    elem.type,
                    style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.4)),
                  ),
                  trailing: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        color: Colors.redAccent.withValues(alpha: 0.7),
                        onPressed: () {
                          final list = List<DockItemElement>.from(elements)..removeAt(index);
                          _update(widget.template.copyWith(elements: list));
                          if (widget.selectedElementId == elem.id) {
                            widget.onSelectElement(null);
                          }
                        },
                        tooltip: 'Remove',
                      ),
                      const Icon(Icons.drag_indicator_rounded, size: 18, color: Colors.white24),
                    ],
                  ),
                  onTap: () => widget.onSelectElement(elem.id),
                ),
              ),
            );
          },
        ),

        if (_selectedElement() case final selected?) ...[
          const SizedBox(height: 18),
          _buildSectionHeader('Selected Element'),
          const SizedBox(height: 10),
          TextField(
            controller: _elementLabelController,
            style: const TextStyle(color: Colors.white, fontSize: 12),
            decoration: _textFieldDecoration('Display name'),
            onChanged: (value) => _updateSelectedElement(label: value),
          ),
          if (selected.type == DockElementType.pinnedApp ||
              selected.type == DockElementType.customAction) ...[
            const SizedBox(height: 10),
            DropdownButtonFormField<String>(
              initialValue: [
                'app',
                'url',
                'dashboard',
                'default',
              ].contains(selected.actionType)
                  ? selected.actionType
                  : 'default',
              decoration: _textFieldDecoration('Click action'),
              dropdownColor: const Color(0xFF161C28),
              style: const TextStyle(color: Colors.white, fontSize: 12),
              items: const [
                DropdownMenuItem(value: 'app', child: Text('Open app or file')),
                DropdownMenuItem(value: 'url', child: Text('Open website')),
                DropdownMenuItem(value: 'dashboard', child: Text('Open WallSync')),
                DropdownMenuItem(value: 'default', child: Text('No action')),
              ],
              onChanged: (value) {
                if (value != null) {
                  _updateSelectedElement(actionType: value);
                }
              },
            ),
            if (selected.actionType == 'app' ||
                selected.actionType == 'url') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _elementTargetController,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: _textFieldDecoration(
                  selected.actionType == 'url'
                      ? 'Website URL'
                      : 'App command, path, or file',
                ),
                onChanged: (value) =>
                    _updateSelectedElement(actionPayload: value),
              ),
              const SizedBox(height: 6),
              Text(
                selected.actionType == 'url'
                    ? 'The website opens in your default Windows browser.'
                    : 'Examples: wt, code, C:\\Apps\\MyApp.exe',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.45),
                ),
              ),
            ],
            if (selected.actionType == 'dashboard') ...[
              const SizedBox(height: 10),
              TextField(
                controller: _elementTargetController,
                style: const TextStyle(color: Colors.white, fontSize: 12),
                decoration: _textFieldDecoration(
                  'Dashboard tab (e.g. desktop_studio)',
                ),
                onChanged: (value) =>
                    _updateSelectedElement(actionPayload: value),
              ),
            ],
          ],
        ],

        const SizedBox(height: 20),
        _buildSectionHeader('Add New Element'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: DockElementType.allTypes.map((type) {
            return ActionChip(
              avatar: Icon(DockElementType.getIcon(type), size: 14, color: const Color(0xFF38BDF8)),
              label: Text(
                DockElementType.getDisplayName(type),
                style: const TextStyle(fontSize: 11, color: Colors.white),
              ),
              backgroundColor: const Color(0xFF161C28),
              side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              onPressed: () {
                final newElem = DockItemElement(
                  id: '${type}_${DateTime.now().millisecondsSinceEpoch}',
                  type: type,
                  label: DockElementType.getDisplayName(type),
                  actionType: type == DockElementType.appLauncher
                      ? 'dashboard'
                      : type == DockElementType.pinnedApp ||
                            type == DockElementType.customAction
                      ? 'app'
                      : 'default',
                );
                final list = List<DockItemElement>.from(elements)..add(newElem);
                _update(widget.template.copyWith(elements: list));
              },
            );
          }).toList(),
        ),
      ],
    );
  }

  InputDecoration _textFieldDecoration(String label) {
    return InputDecoration(
      labelText: label,
      labelStyle: const TextStyle(color: Colors.white54, fontSize: 11),
      filled: true,
      fillColor: const Color(0xFF161C28),
      contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
      border: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
      enabledBorder: OutlineInputBorder(
        borderRadius: BorderRadius.circular(8),
        borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.12)),
      ),
    );
  }

  // ===========================================================================
  // 4. ANIMATION PANE
  // ===========================================================================
  Widget _buildAnimationPane() {
    final anim = widget.template.animation;

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        _buildSectionHeader('Fisheye Magnification Engine'),
        _buildSwitchRow(
          title: 'Hover Magnification',
          subtitle: 'Smooth wave scaling on cursor approach',
          value: anim.enableHoverScale,
          onChanged: (val) => _update(
            widget.template.copyWith(animation: anim.copyWith(enableHoverScale: val)),
          ),
        ),
        if (anim.enableHoverScale) ...[
          _buildSliderRow(
            title: 'Max Magnification Scale',
            value: anim.hoverScaleFactor,
            min: 1.1,
            max: 2.2,
            unit: 'x',
            onChanged: (val) => _update(
              widget.template.copyWith(animation: anim.copyWith(hoverScaleFactor: val)),
            ),
          ),
          _buildSliderRow(
            title: 'Hover Wave Distance',
            value: anim.hoverDistance,
            min: 40.0,
            max: 140.0,
            unit: 'px',
            onChanged: (val) => _update(
              widget.template.copyWith(animation: anim.copyWith(hoverDistance: val)),
            ),
          ),
          _buildSliderRow(
            title: 'Hover Vertical Lift',
            value: anim.hoverLift,
            min: 0.0,
            max: 16.0,
            unit: 'px',
            onChanged: (val) => _update(
              widget.template.copyWith(animation: anim.copyWith(hoverLift: val)),
            ),
          ),
        ],
        const SizedBox(height: 16),

        _buildSectionHeader('Interactive Reactions'),
        _buildSwitchRow(
          title: 'Click Bounce Effect',
          subtitle: 'Springy bounce animation when launching an application',
          value: anim.enableIconBounce,
          onChanged: (val) => _update(
            widget.template.copyWith(animation: anim.copyWith(enableIconBounce: val)),
          ),
        ),
        _buildSwitchRow(
          title: 'Running Indicator Pulse',
          subtitle: 'Active app glowing pulse beneath running tasks',
          value: anim.enableRunningPulse,
          onChanged: (val) => _update(
            widget.template.copyWith(animation: anim.copyWith(enableRunningPulse: val)),
          ),
        ),
        const SizedBox(height: 16),

        _buildSectionHeader('Timing & Dynamics'),
        _buildSliderRow(
          title: 'Animation Duration',
          value: anim.animationDurationMs.toDouble(),
          min: 80.0,
          max: 360.0,
          unit: 'ms',
          onChanged: (val) => _update(
            widget.template.copyWith(
              animation: anim.copyWith(animationDurationMs: val.toInt()),
            ),
          ),
        ),
        _buildSegmentedGroup<String>(
          currentValue: anim.curveName,
          items: const [
            MapEntry('easeOutCubic', 'Cubic'),
            MapEntry('easeOutBack', 'Back (Springy)'),
            MapEntry('easeOutQuad', 'Quad'),
          ],
          onSelect: (curve) => _update(
            widget.template.copyWith(animation: anim.copyWith(curveName: curve)),
          ),
        ),
        const SizedBox(height: 16),

        _buildSectionHeader('Desktop Edge Auto-Hide'),
        _buildSwitchRow(
          title: 'Enable Auto-Hide',
          subtitle: 'Slide dock away when cursor moves away',
          value: anim.enableAutoHide,
          onChanged: (val) => _update(
            widget.template.copyWith(animation: anim.copyWith(enableAutoHide: val)),
          ),
        ),
        if (anim.enableAutoHide) ...[
          _buildSliderRow(
            title: 'Auto-Hide Delay',
            value: anim.autoHideDelayMs.toDouble(),
            min: 300.0,
            max: 3000.0,
            unit: 'ms',
            onChanged: (val) => _update(
              widget.template.copyWith(
                animation: anim.copyWith(autoHideDelayMs: val.toInt()),
              ),
            ),
          ),
        ],
        const SizedBox(height: 16),

        _buildSectionHeader('Accessibility & Performance'),
        _buildSwitchRow(
          title: 'Reduced Motion Mode',
          subtitle: 'Disable fisheye magnification for battery conservation',
          value: anim.reducedMotion,
          onChanged: (val) => _update(
            widget.template.copyWith(animation: anim.copyWith(reducedMotion: val)),
          ),
        ),
      ],
    );
  }

  // ===========================================================================
  // 5. DEVELOPER PANE (IN-APP JSON SCHEMA EDITOR)
  // ===========================================================================
  Widget _buildDeveloperPane() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Column(
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildSectionHeader('Live Schema Editor'),
              Row(
                children: [
                  OutlinedButton.icon(
                    icon: const Icon(Icons.format_align_left_rounded, size: 14),
                    label: const Text('Format', style: TextStyle(fontSize: 11)),
                    style: OutlinedButton.styleFrom(
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                      side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                    ),
                    onPressed: () {
                      try {
                        final decoded = jsonDecode(_jsonController.text) as Map<String, dynamic>;
                        _jsonController.text = const JsonEncoder.withIndent('  ').convert(decoded);
                      } catch (_) {}
                    },
                  ),
                  const SizedBox(width: 6),
                  FilledButton.icon(
                    icon: const Icon(Icons.check_circle_outline_rounded, size: 14),
                    label: const Text('Apply JSON', style: TextStyle(fontSize: 11)),
                    style: FilledButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8),
                      foregroundColor: const Color(0xFF070B14),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    ),
                    onPressed: _validateAndApplyJson,
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),

          // Schema validation banner
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: _isJsonValid
                  ? const Color(0xFF10B981).withValues(alpha: 0.12)
                  : const Color(0xFFEF4444).withValues(alpha: 0.12),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(
                color: _isJsonValid
                  ? const Color(0xFF10B981).withValues(alpha: 0.3)
                  : const Color(0xFFEF4444).withValues(alpha: 0.4),
              ),
            ),
            child: Row(
              children: [
                Icon(
                  _isJsonValid ? Icons.check_circle_rounded : Icons.error_outline_rounded,
                  size: 16,
                  color: _isJsonValid ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    _isJsonValid
                        ? 'Schema Valid: wallsync.dock.template.v1'
                        : (_jsonValidationError ?? 'Invalid JSON schema'),
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: _isJsonValid ? const Color(0xFF10B981) : const Color(0xFFEF4444),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 12),

          // Code editor area
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF0B0E14),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: Colors.white.withValues(alpha: 0.08),
                ),
              ),
              child: TextField(
                controller: _jsonController,
                maxLines: null,
                expands: true,
                style: const TextStyle(
                  fontFamily: 'Consolas',
                  fontSize: 11,
                  color: Color(0xFFE2E8F0),
                  height: 1.4,
                ),
                decoration: const InputDecoration(
                  contentPadding: EdgeInsets.all(12),
                  border: InputBorder.none,
                ),
                onChanged: (_) {
                  setState(() {
                    _isJsonValid = true;
                    _jsonValidationError = null;
                  });
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  void _validateAndApplyJson() {
    try {
      final decoded = jsonDecode(_jsonController.text);
      if (decoded is! Map<String, dynamic>) {
        setState(() {
          _isJsonValid = false;
          _jsonValidationError = 'JSON root must be an object.';
        });
        return;
      }

      final errors = DesktopStudioTemplate.validate(decoded);
      if (errors.isNotEmpty) {
        setState(() {
          _isJsonValid = false;
          _jsonValidationError = errors.first;
        });
        return;
      }

      final parsed = DesktopStudioTemplate.fromJson(decoded);
      setState(() {
        _isJsonValid = true;
        _jsonValidationError = null;
      });
      _update(parsed);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Template JSON applied successfully!'),
          duration: Duration(seconds: 2),
        ),
      );
    } catch (e) {
      setState(() {
        _isJsonValid = false;
        _jsonValidationError = 'JSON Parse Error: $e';
      });
    }
  }

  // ===========================================================================
  // REUSABLE UI BUILDER HELPERS
  // ===========================================================================
  Widget _buildSectionHeader(String title) {
    return Text(
      title.toUpperCase(),
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w800,
        letterSpacing: 1.0,
        color: const Color(0xFF38BDF8).withValues(alpha: 0.85),
      ),
    );
  }

  Widget _buildSliderRow({
    required String title,
    required double value,
    required double min,
    required double max,
    required String unit,
    required ValueChanged<double> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                title,
                style: const TextStyle(fontSize: 12, color: Colors.white70),
              ),
              Text(
                '${value.toStringAsFixed(value == value.roundToDouble() ? 0 : 1)} $unit',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF38BDF8),
                ),
              ),
            ],
          ),
          SliderTheme(
            data: SliderTheme.of(context).copyWith(
              trackHeight: 3.0,
              thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
              activeTrackColor: const Color(0xFF38BDF8),
              inactiveTrackColor: Colors.white.withValues(alpha: 0.1),
              thumbColor: const Color(0xFF38BDF8),
              overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
            ),
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              onChanged: onChanged,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSwitchRow({
    required String title,
    required String subtitle,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Colors.white),
                ),
                Text(
                  subtitle,
                  style: TextStyle(fontSize: 10, color: Colors.white.withValues(alpha: 0.45)),
                ),
              ],
            ),
          ),
          Switch(
            value: value,
            activeThumbColor: const Color(0xFF38BDF8),
            onChanged: onChanged,
          ),
        ],
      ),
    );
  }

  Widget _buildSegmentedGroup<T>({
    required T currentValue,
    required List<MapEntry<T, String>> items,
    required ValueChanged<T> onSelect,
  }) {
    return Container(
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: const Color(0xFF161B26),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
        ),
      ),
      child: Row(
        children: items.map((item) {
          final isSelected = item.key == currentValue;
          return Expanded(
            child: InkWell(
              onTap: () => onSelect(item.key),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 6),
                decoration: BoxDecoration(
                  color: isSelected ? const Color(0xFF38BDF8) : Colors.transparent,
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Center(
                  child: Text(
                    item.value,
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: isSelected ? FontWeight.w700 : FontWeight.w500,
                      color: isSelected ? const Color(0xFF070B14) : Colors.white70,
                    ),
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }

  Widget _buildColorTile({
    required String title,
    required Color color,
    required ValueChanged<Color> onColorChanged,
  }) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Text(
            title,
            style: const TextStyle(fontSize: 12, color: Colors.white70),
          ),
          InkWell(
            onTap: () {
              // Quick color cycle through clean-room WallSync palette
              final palette = [
                const Color(0xFF38BDF8),
                const Color(0xFF818CF8),
                const Color(0xFFEC4899),
                const Color(0xFF10B981),
                const Color(0xFFF59E0B),
                const Color(0xFF06B6D4),
                const Color(0xFF6366F1),
                const Color(0xDD12151E),
                const Color(0xF210131B),
                const Color(0xFFFFFFFF),
              ];
              final nextIndex = (palette.indexOf(color) + 1) % palette.length;
              onColorChanged(palette[nextIndex >= 0 ? nextIndex : 0]);
            },
            borderRadius: BorderRadius.circular(6),
            child: Container(
              width: 32,
              height: 22,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(6),
                border: Border.all(color: Colors.white38, width: 1.0),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
