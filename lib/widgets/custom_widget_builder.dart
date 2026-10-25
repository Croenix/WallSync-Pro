import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:flutter/material.dart';
import '../services/media_session_service.dart';
import '../services/settings_service.dart';
import '../services/system_metrics_service.dart';
import '../services/system_connectivity_service.dart';
import 'custom_widget_renderer.dart';

/// Full-screen Two-Section Custom Widget Studio / Builder.
/// - Section 1 (Main Window): Large interactive Canvas with real-time live clock,
///   drag-and-drop element positioning, element selection, and floating property inspector.
/// - Section 2 (Side Panel): "Elements" Toolbox showcasing all building blocks from
///   all existing WallSync widgets (Hours, Minutes, Day, Date, CPU/RAM bars, Space bar,
///   Weather, Media pill, Fonts like Robik's Montserrat & Product Sans, Anurati, etc.).
class CustomWidgetBuilderView extends StatefulWidget {
  final WidgetSettings initialSettings;
  final ValueChanged<WidgetSettings> onSave;
  final VoidCallback onBack;
  final VoidCallback? onLaunchOverlay;
  final bool isOverlayRunning;
  final String? initialSelectedElementId;

  const CustomWidgetBuilderView({
    super.key,
    required this.initialSettings,
    required this.onSave,
    required this.onBack,
    this.onLaunchOverlay,
    this.isOverlayRunning = false,
    this.initialSelectedElementId,
    this.existingWidget,
  });

  final SavedCustomWidget? existingWidget;

  @override
  State<CustomWidgetBuilderView> createState() =>
      _CustomWidgetBuilderViewState();
}

class _CustomWidgetBuilderViewState extends State<CustomWidgetBuilderView> {
  late List<CustomWidgetElement> _elements;
  late double _canvasWidth;
  late double _canvasHeight;
  String? _selectedElementId;
  DateTime _now = DateTime.now();
  late Timer _clockTimer;
  SystemMetricsSnapshot _systemMetrics = const SystemMetricsSnapshot();
  MediaInfo _mediaInfo = MediaSessionService().current;
  Uint8List? _mediaThumbnailBytes;
  final ValueNotifier<int> _mediaPosition = ValueNotifier<int>(0);
  StreamSubscription<MediaInfo>? _mediaSubscription;
  StreamSubscription<SystemConnectivitySnapshot>? _connectivitySubscription;
  SystemConnectivitySnapshot _connectivity =
      SystemConnectivityService.instance.current;
  String _elementsCategory = 'All';
  String _searchQuery = '';
  String _canvasBgMode = 'glass_dark'; // 'glass_dark' | 'grid' | 'pure_dark'
  bool _hasUnsavedChanges = false;
  late String _widgetName;

  TextEditingController? _customTextController;
  String? _customTextControllerElementId;
  final FocusNode _customTextFocusNode = FocusNode();

  final List<String> _availableFonts = [
    'Montserrat',
    'Product Sans',
    'Anurati',
    'Moving Skate',
    'Segoe UI',
    'Consolas',
    'Impact',
    'Arial',
    'Georgia',
  ];

  final List<Color> _quickPalette = const [
    Color(0xFFFFFFFF),
    Color(0xFFF18734), // Robik Signature Orange
    Color(0xFF00FFCC), // Cyber Mint
    Color(0xFF00FF55), // Media Neon Green
    Color(0xFF38BDF8), // Sky Blue
    Color(0xFF00F0FF), // Electric Cyan
    Color(0xFFD946EF), // Neon Fuchsia
    Color(0xFFA855F7), // Neon Purple
    Color(0xFFFACC15), // Cyber Yellow
    Color(0xFFF43F5E), // Rose Red
    Color(0xFF94A3B8), // Muted Slate
    Color(0xFF1E293B), // Dark Slate
  ];

  @override
  void initState() {
    super.initState();
    if (widget.existingWidget != null) {
      _widgetName = widget.existingWidget!.name;
      _elements = widget.existingWidget!.elements
          .map((e) => e.copyWith())
          .toList();
      _canvasWidth = widget.existingWidget!.width;
      _canvasHeight = widget.existingWidget!.height;
    } else {
      _widgetName =
          'Custom Widget ${widget.initialSettings.savedCustomWidgets.length + 1}';
      _elements = widget.initialSettings.customElements
          .map((e) => e.copyWith())
          .toList();
      if (_elements.isEmpty) {
        _elements = CustomWidgetElement.defaultCustomLayout();
      }
      _canvasWidth = widget.initialSettings.width >= 300
          ? widget.initialSettings.width
          : 480.0;
      _canvasHeight = widget.initialSettings.height >= 140
          ? widget.initialSettings.height
          : 260.0;
    }
    if (_elements.any((e) => e.id == widget.initialSelectedElementId)) {
      _selectedElementId = widget.initialSelectedElementId;
    }

    if (_needsSystemMetrics) {
      _systemMetrics = SystemMetricsService.readSnapshot();
    }
    _syncMediaSessionService();
    _syncConnectivityService();
    _mediaInfo = MediaSessionService().current;
    _updateMediaThumbnail(_mediaInfo);
    _mediaPosition.value = _mediaInfo.position;
    _mediaSubscription = MediaSessionService().mediaStream.listen((info) {
      if (!mounted || !_needsMediaSession) return;
      final hasChanged =
          info.title != _mediaInfo.title ||
          info.artist != _mediaInfo.artist ||
          info.album != _mediaInfo.album ||
          info.status != _mediaInfo.status ||
          info.source != _mediaInfo.source ||
          info.sessionId != _mediaInfo.sessionId ||
          info.duration != _mediaInfo.duration;
      final artworkChanged = info.thumbnail != _mediaInfo.thumbnail;
      _mediaInfo = info;
      _mediaPosition.value = info.position;
      _updateMediaThumbnail(info);
      if (hasChanged || artworkChanged) setState(() {});
    });
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (mounted) {
        setState(() {
          _now = DateTime.now();
          if (_needsSystemMetrics && timer.tick % 15 == 0) {
            _systemMetrics = SystemMetricsService.readSnapshot();
          }
        });
      }
    });
  }

  bool get _needsSystemMetrics => _elements.any(
    (element) => element.type == 'space_bar' || element.type == 'battery_bar',
  );

  bool get _needsMediaSession =>
      _elements.any((element) => MediaElementType.contains(element.type));

  bool get _needsConnectivity => _elements.any(
    (element) =>
        element.type == 'wifi_icon' || element.type == 'bluetooth_icon',
  );

  void _syncConnectivityService() {
    final service = SystemConnectivityService.instance;
    if (_needsConnectivity && _connectivitySubscription == null) {
      _connectivity = service.current;
      _connectivitySubscription = service.stream.listen((snapshot) {
        if (!mounted || snapshot == _connectivity) return;
        setState(() => _connectivity = snapshot);
      });
      service.start(owner: 'custom-widget-editor');
    } else if (!_needsConnectivity && _connectivitySubscription != null) {
      _connectivitySubscription?.cancel();
      _connectivitySubscription = null;
      service.stop(owner: 'custom-widget-editor');
    }
  }

  void _syncMediaSessionService() {
    if (_needsMediaSession) {
      MediaSessionService().start(owner: 'custom-widget-editor');
      _mediaInfo = MediaSessionService().current;
      _mediaPosition.value = _mediaInfo.position;
      _updateMediaThumbnail(_mediaInfo);
    } else {
      MediaSessionService().stop(owner: 'custom-widget-editor');
    }
  }

  void _updateMediaThumbnail(MediaInfo info) {
    if (info.thumbnail.isEmpty) {
      _mediaThumbnailBytes = null;
      return;
    }
    try {
      _mediaThumbnailBytes = base64Decode(info.thumbnail);
    } on FormatException catch (error, stackTrace) {
      _mediaThumbnailBytes = null;
      logWarning(
        'CustomWidgetBuilder',
        'Media artwork was not valid base64: $error\n$stackTrace',
      );
    }
  }

  @override
  void dispose() {
    _clockTimer.cancel();
    _mediaSubscription?.cancel();
    _connectivitySubscription?.cancel();
    _mediaPosition.dispose();
    _customTextController?.dispose();
    _customTextFocusNode.dispose();
    MediaSessionService().stop(owner: 'custom-widget-editor');
    SystemConnectivityService.instance.stop(owner: 'custom-widget-editor');
    super.dispose();
  }

  CustomWidgetElement? get _selectedElement {
    if (_selectedElementId == null) return null;
    try {
      return _elements.firstWhere((e) => e.id == _selectedElementId);
    } catch (_) {
      return null;
    }
  }

  void _promptSaveDialog() {
    final nameCtrl = TextEditingController(text: _widgetName);
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF181C2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Row(
          children: [
            Icon(Icons.save_rounded, color: Color(0xFF43E97B), size: 20),
            SizedBox(width: 8),
            Text(
              'Save User-Designed Widget',
              style: TextStyle(
                color: Colors.white,
                fontSize: 16,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'Give your custom widget layout a memorable name to save it to your "User Designed Widgets" collection.',
              style: TextStyle(color: Colors.white60, fontSize: 12),
            ),
            const SizedBox(height: 14),
            TextField(
              controller: nameCtrl,
              autofocus: true,
              style: const TextStyle(color: Colors.white, fontSize: 13),
              decoration: InputDecoration(
                labelText: 'Widget Name',
                labelStyle: const TextStyle(color: Color(0xFF38BDF8)),
                hintText: 'e.g. My Studio Clock',
                hintStyle: const TextStyle(color: Colors.white30),
                filled: true,
                fillColor: Colors.white.withValues(alpha: 0.05),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(10),
                  borderSide: const BorderSide(color: Color(0xFF38BDF8)),
                ),
              ),
            ),
          ],
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text(
              'Cancel',
              style: TextStyle(color: Colors.white54),
            ),
          ),
          ElevatedButton(
            onPressed: () {
              final finalName = nameCtrl.text.trim().isNotEmpty
                  ? nameCtrl.text.trim()
                  : _widgetName;
              Navigator.pop(ctx);
              _performSave(finalName);
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF43E97B),
              foregroundColor: Colors.black,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            child: const Text(
              'Save & Apply Live',
              style: TextStyle(fontWeight: FontWeight.bold),
            ),
          ),
        ],
      ),
    );
  }

  void _performSave(String name) {
    setState(() {
      _widgetName = name;
    });

    final targetId =
        widget.existingWidget?.id ??
        'user_widget_${DateTime.now().millisecondsSinceEpoch}';

    final savedItem = SavedCustomWidget(
      id: targetId,
      name: name,
      elements: _elements.map((e) => e.copyWith()).toList(),
      width: _canvasWidth,
      height: _canvasHeight,
      createdAt:
          widget.existingWidget?.createdAt ??
          DateTime.now().millisecondsSinceEpoch,
    );

    final currentSaved = List<SavedCustomWidget>.from(
      widget.initialSettings.savedCustomWidgets,
    );
    final idx = currentSaved.indexWhere((w) => w.id == targetId);
    if (idx >= 0) {
      currentSaved[idx] = savedItem;
    } else {
      currentSaved.insert(0, savedItem);
    }

    final updated = widget.initialSettings.copyWith(
      widgetTemplate: 'custom',
      width: _canvasWidth,
      height: _canvasHeight,
      customElements: _elements.map((e) => e.copyWith()).toList(),
      savedCustomWidgets: currentSaved,
    );

    widget.onSave(updated);
    setState(() {
      _hasUnsavedChanges = false;
    });

    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Row(
          children: [
            const Icon(
              Icons.check_circle_rounded,
              color: Color(0xFF43E97B),
              size: 20,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '"$name" saved to User Designed Widgets & applied to desktop!',
                style: const TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
          ],
        ),
        backgroundColor: const Color(0xFF1E1E2E),
        behavior: SnackBarBehavior.floating,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  void _addElement(CustomWidgetElement element, [Offset? dropOffset]) {
    final newId = 'elem_${DateTime.now().microsecondsSinceEpoch}';
    final targetX = dropOffset != null
        ? dropOffset.dx.clamp(
            0.0,
            _canvasWidth - (element.width > 0 ? element.width : 60.0),
          )
        : (_canvasWidth / 2 - 40.0).clamp(10.0, _canvasWidth - 80.0);
    final targetY = dropOffset != null
        ? dropOffset.dy.clamp(
            0.0,
            _canvasHeight - (element.height > 0 ? element.height : 30.0),
          )
        : (_canvasHeight / 2 - 20.0).clamp(10.0, _canvasHeight - 40.0);

    final newElement = element.copyWith(id: newId, x: targetX, y: targetY);

    setState(() {
      _elements.add(newElement);
      _selectedElementId = newId;
      _hasUnsavedChanges = true;
    });
    _syncMediaSessionService();
    _syncConnectivityService();
  }

  void _deleteElement(String id) {
    setState(() {
      _elements.removeWhere((e) => e.id == id);
      if (_selectedElementId == id) {
        _selectedElementId = null;
      }
      _hasUnsavedChanges = true;
    });
    _syncMediaSessionService();
    _syncConnectivityService();
  }

  void _duplicateElement(String id) {
    final elem = _elements.firstWhere((e) => e.id == id);
    final dup = elem.copyWith(
      id: 'elem_${DateTime.now().microsecondsSinceEpoch}',
      x: (elem.x + 14.0).clamp(0.0, _canvasWidth - 40.0),
      y: (elem.y + 14.0).clamp(0.0, _canvasHeight - 40.0),
    );
    setState(() {
      _elements.add(dup);
      _selectedElementId = dup.id;
      _hasUnsavedChanges = true;
    });
    _syncMediaSessionService();
    _syncConnectivityService();
  }

  void _loadPreset(String name) {
    setState(() {
      if (name == 'robik_signature') {
        _elements = CustomWidgetElement.defaultCustomLayout();
        _canvasWidth = 480.0;
        _canvasHeight = 260.0;
      } else if (name == 'cyber_neon') {
        _elements = [
          CustomWidgetElement(
            id: 'c_box',
            type: 'neon_box',
            x: 20,
            y: 20,
            width: 440,
            height: 220,
            color: 0xFF00F0FF,
          ),
          CustomWidgetElement(
            id: 'c_hours',
            type: 'hours',
            x: 44,
            y: 40,
            fontFamily: 'Impact',
            fontSize: 72,
            isBold: true,
            color: 0xFFFACC15,
          ),
          CustomWidgetElement(
            id: 'c_colon',
            type: 'time_colon',
            x: 140,
            y: 40,
            fontFamily: 'Impact',
            fontSize: 64,
            color: 0xFF00F0FF,
          ),
          CustomWidgetElement(
            id: 'c_min',
            type: 'minutes',
            x: 170,
            y: 40,
            fontFamily: 'Impact',
            fontSize: 72,
            isBold: true,
            color: 0xFF00F0FF,
          ),
          CustomWidgetElement(
            id: 'c_cpu',
            type: 'cpu_bar',
            x: 44,
            y: 136,
            width: 190,
            color: 0xFF00FFCC,
          ),
          CustomWidgetElement(
            id: 'c_ram',
            type: 'ram_bar',
            x: 250,
            y: 136,
            width: 190,
            color: 0xFFA855F7,
          ),
          CustomWidgetElement(
            id: 'c_day',
            type: 'day',
            x: 44,
            y: 184,
            fontFamily: 'Montserrat',
            fontSize: 12,
            letterSpacing: 2,
            color: 0xFF38BDF8,
          ),
          CustomWidgetElement(
            id: 'c_date',
            type: 'full_date',
            x: 250,
            y: 184,
            fontFamily: 'Montserrat',
            fontSize: 12,
            color: 0xFFCBD5E1,
          ),
        ];
        _canvasWidth = 480.0;
        _canvasHeight = 260.0;
      } else if (name == 'minimalist') {
        _elements = [
          CustomWidgetElement(
            id: 'm_hours',
            type: 'hours',
            x: 30,
            y: 30,
            fontFamily: 'Consolas',
            fontSize: 48,
            isBold: true,
            color: 0xFFF1F5F9,
          ),
          CustomWidgetElement(
            id: 'm_colon',
            type: 'time_colon',
            x: 95,
            y: 30,
            fontFamily: 'Consolas',
            fontSize: 44,
            color: 0xFF94A3B8,
          ),
          CustomWidgetElement(
            id: 'm_min',
            type: 'minutes',
            x: 120,
            y: 30,
            fontFamily: 'Consolas',
            fontSize: 48,
            isBold: true,
            color: 0xFFF1F5F9,
          ),
          CustomWidgetElement(
            id: 'm_ampm',
            type: 'ampm',
            x: 195,
            y: 35,
            fontFamily: 'Consolas',
            fontSize: 12,
            color: 0xFF94A3B8,
          ),
          CustomWidgetElement(
            id: 'm_date',
            type: 'full_date',
            x: 30,
            y: 90,
            fontFamily: 'Consolas',
            fontSize: 12,
            letterSpacing: 1.0,
            color: 0xFF94A3B8,
          ),
        ];
        _canvasWidth = 360.0;
        _canvasHeight = 140.0;
      } else if (name == 'clear') {
        _elements = [];
      }
      _selectedElementId = null;
      _hasUnsavedChanges = true;
    });
    _syncMediaSessionService();
    _syncConnectivityService();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      backgroundColor: const Color(0xFF0D0F17),
      body: SafeArea(
        child: Column(
          children: [
            _buildTopStudioBar(),
            Expanded(
              child: Row(
                children: [
                  // ── Section 1: Main Window / Large Interactive Canvas ───────
                  Expanded(flex: 62, child: _buildCanvasSection()),

                  // ── Divider ──────────────────────────────────────────────
                  Container(
                    width: 1,
                    color: Colors.white.withValues(alpha: 0.08),
                  ),

                  // ── Section 2: Elements Showcase & Toolbox ───────────────
                  Expanded(flex: 38, child: _buildElementsToolbox()),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ── Top Studio Bar ────────────────────────────────────────────────────────
  Widget _buildTopStudioBar() {
    return Container(
      height: 60,
      padding: const EdgeInsets.symmetric(horizontal: 20),
      decoration: BoxDecoration(
        color: const Color(0xFF131722),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          // Back button
          OutlinedButton.icon(
            onPressed: widget.onBack,
            icon: const Icon(Icons.arrow_back_rounded, size: 16),
            label: const Text('Widgets'),
            style: OutlinedButton.styleFrom(
              foregroundColor: Colors.white70,
              side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
          const SizedBox(width: 16),

          // Studio Title & Badges
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                  ),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Row(
                  children: [
                    Icon(
                      Icons.dashboard_customize_rounded,
                      size: 13,
                      color: Colors.black,
                    ),
                    SizedBox(width: 5),
                    Text(
                      'CUSTOM WIDGET STUDIO',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.0,
                        color: Colors.black,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              if (_hasUnsavedChanges)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 3,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.amber.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.amber.withValues(alpha: 0.4),
                    ),
                  ),
                  child: const Text(
                    'UNSAVED CHANGES',
                    style: TextStyle(
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                      color: Colors.amber,
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
            ],
          ),

          const Spacer(),

          // Presets Dropdown
          PopupMenuButton<String>(
            tooltip: 'Load Layout Preset',
            onSelected: _loadPreset,
            color: const Color(0xFF1E2235),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'robik_signature',
                child: Row(
                  children: [
                    Icon(
                      Icons.auto_awesome_rounded,
                      size: 16,
                      color: Color(0xFFF18734),
                    ),
                    SizedBox(width: 8),
                    Text('Robik Signature (Default)'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'cyber_neon',
                child: Row(
                  children: [
                    Icon(
                      Icons.flash_on_rounded,
                      size: 16,
                      color: Color(0xFF00F0FF),
                    ),
                    SizedBox(width: 8),
                    Text('Cyberpunk Neon'),
                  ],
                ),
              ),
              const PopupMenuItem(
                value: 'minimalist',
                child: Row(
                  children: [
                    Icon(
                      Icons.crop_square_rounded,
                      size: 16,
                      color: Color(0xFF94A3B8),
                    ),
                    SizedBox(width: 8),
                    Text('Minimalist Monospace'),
                  ],
                ),
              ),
              const PopupMenuDivider(),
              const PopupMenuItem(
                value: 'clear',
                child: Row(
                  children: [
                    Icon(
                      Icons.delete_sweep_rounded,
                      size: 16,
                      color: Colors.redAccent,
                    ),
                    SizedBox(width: 8),
                    Text(
                      'Clear Canvas (Blank)',
                      style: TextStyle(color: Colors.redAccent),
                    ),
                  ],
                ),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: const Row(
                children: [
                  Icon(
                    Icons.auto_awesome_mosaic_rounded,
                    size: 15,
                    color: Colors.white70,
                  ),
                  SizedBox(width: 6),
                  Text(
                    'Presets',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: Colors.white54),
                ],
              ),
            ),
          ),
          const SizedBox(width: 12),

          // Canvas Background toggle
          PopupMenuButton<String>(
            tooltip: 'Canvas Preview Backdrop',
            onSelected: (val) => setState(() => _canvasBgMode = val),
            color: const Color(0xFF1E2235),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
            itemBuilder: (ctx) => [
              const PopupMenuItem(
                value: 'glass_dark',
                child: Text('Glass Dark (Translucent)'),
              ),
              const PopupMenuItem(value: 'grid', child: Text('Blueprint Grid')),
              const PopupMenuItem(
                value: 'pure_dark',
                child: Text('OLED Pure Dark'),
              ),
            ],
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(color: Colors.white.withValues(alpha: 0.1)),
              ),
              child: const Row(
                children: [
                  Icon(Icons.texture_rounded, size: 15, color: Colors.white70),
                  SizedBox(width: 6),
                  Text(
                    'Backdrop',
                    style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                  Icon(Icons.arrow_drop_down, size: 18, color: Colors.white54),
                ],
              ),
            ),
          ),
          const SizedBox(width: 14),

          // Save & Apply Button
          ElevatedButton.icon(
            onPressed: _promptSaveDialog,
            icon: const Icon(Icons.check_rounded, size: 17),
            label: const Text('Save & Apply Live'),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF43E97B),
              foregroundColor: Colors.black,
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
              elevation: 0,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              textStyle: const TextStyle(
                fontWeight: FontWeight.w800,
                fontSize: 12.5,
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── Section 1: Main Window / Large Interactive Canvas ─────────────────────
  Widget _buildCanvasSection() {
    return Column(
      children: [
        // Canvas Header Bar (Size presets & coordinate status)
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 10),
          decoration: BoxDecoration(
            color: Colors.black.withValues(alpha: 0.2),
            border: Border(
              bottom: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.aspect_ratio_rounded,
                size: 15,
                color: Colors.white54,
              ),
              const SizedBox(width: 8),
              Text(
                'Canvas: ${_canvasWidth.toInt()} × ${_canvasHeight.toInt()} px',
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
              const SizedBox(width: 16),
              // Size presets
              _buildCanvasSizeChip('Compact', 360, 200),
              const SizedBox(width: 6),
              _buildCanvasSizeChip('Standard', 480, 260),
              const SizedBox(width: 6),
              _buildCanvasSizeChip('Expansive', 600, 320),

              const Spacer(),
              Text(
                '${_elements.length} Elements on Canvas',
                style: const TextStyle(fontSize: 11, color: Colors.white38),
              ),
              const SizedBox(width: 12),
              IconButton(
                icon: const Icon(
                  Icons.deselect_rounded,
                  size: 17,
                  color: Colors.white54,
                ),
                tooltip: 'Deselect element',
                onPressed: () => setState(() => _selectedElementId = null),
              ),
            ],
          ),
        ),

        // Live Canvas Area (Interactive DragTarget)
        Expanded(
          child: Center(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: SingleChildScrollView(
                child: Padding(
                  padding: const EdgeInsets.all(32.0),
                  child: DragTarget<CustomWidgetElement>(
                    onAcceptWithDetails: (details) {
                      final box = context.findRenderObject() as RenderBox?;
                      if (box != null) {
                        _addElement(details.data, details.offset);
                      } else {
                        _addElement(details.data);
                      }
                    },
                    builder: (context, candidateData, rejectedData) {
                      final isHovered = candidateData.isNotEmpty;
                      return AnimatedContainer(
                        duration: const Duration(milliseconds: 180),
                        width: _canvasWidth,
                        height: _canvasHeight,
                        decoration: BoxDecoration(
                          color: _canvasBgMode == 'pure_dark'
                              ? Colors.black
                              : _canvasBgMode == 'grid'
                              ? const Color(0xFF0F172A)
                              : Colors.black.withValues(alpha: 0.55),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: isHovered
                                ? const Color(0xFF43E97B)
                                : Colors.white.withValues(alpha: 0.15),
                            width: isHovered ? 2.0 : 1.0,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: isHovered
                                  ? const Color(
                                      0xFF43E97B,
                                    ).withValues(alpha: 0.25)
                                  : Colors.black.withValues(alpha: 0.5),
                              blurRadius: isHovered ? 24 : 16,
                              spreadRadius: isHovered ? 2 : 0,
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(20),
                          child: Stack(
                            children: [
                              // Grid pattern backdrop if selected
                              if (_canvasBgMode == 'grid')
                                CustomPaint(
                                  size: Size(_canvasWidth, _canvasHeight),
                                  painter: _BlueprintGridPainter(),
                                ),

                              // Glassmorphic aura gradient
                              Container(
                                decoration: BoxDecoration(
                                  gradient: RadialGradient(
                                    center: Alignment.topLeft,
                                    radius: 1.2,
                                    colors: [
                                      const Color(
                                        0xFFF18734,
                                      ).withValues(alpha: 0.05),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),

                              // Interactive Elements Renderer
                              CustomWidgetRenderer(
                                elements: _elements,
                                dateTime: _now,
                                mediaInfo: _mediaInfo,
                                mediaThumbnailBytes: _mediaThumbnailBytes,
                                mediaPosition: _mediaPosition,
                                wifiEnabled: _connectivity.wifiEnabled,
                                bluetoothEnabled:
                                    _connectivity.bluetoothEnabled,
                                batteryInfo: _systemMetrics.battery,
                                diskInfo: _systemMetrics.disk,
                                isInteractive: true,
                                selectedElementId: _selectedElementId,
                                canvasWidth: _canvasWidth,
                                canvasHeight: _canvasHeight,
                                onSelectElement: (id) {
                                  setState(() {
                                    _selectedElementId = id;
                                  });
                                },
                                onElementMoved: (id, newX, newY) {
                                  setState(() {
                                    final elem = _elements.firstWhere(
                                      (e) => e.id == id,
                                    );
                                    elem.x = newX;
                                    elem.y = newY;
                                    _hasUnsavedChanges = true;
                                  });
                                },
                                onDeleteElement: _deleteElement,
                                onDuplicateElement: _duplicateElement,
                              ),

                              // Drop zone hint when dragging over
                              if (isHovered)
                                Center(
                                  child: Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                      vertical: 8,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF43E97B,
                                      ).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(10),
                                      border: Border.all(
                                        color: const Color(0xFF43E97B),
                                      ),
                                    ),
                                    child: const Text(
                                      '+ Drop Element Here',
                                      style: TextStyle(
                                        color: Color(0xFF43E97B),
                                        fontWeight: FontWeight.bold,
                                        fontSize: 13,
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
            ),
          ),
        ),

        // Contextual Floating Property Inspector for the Selected Element
        if (_selectedElement != null) _buildSelectedElementInspector(),
      ],
    );
  }

  Widget _buildCanvasSizeChip(String label, double w, double h) {
    final isSel = (_canvasWidth == w && _canvasHeight == h);
    return GestureDetector(
      onTap: () {
        setState(() {
          _canvasWidth = w;
          _canvasHeight = h;
          _hasUnsavedChanges = true;
        });
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: isSel
              ? const Color(0xFF38BDF8).withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(6),
          border: Border.all(
            color: isSel
                ? const Color(0xFF38BDF8)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            fontSize: 10.5,
            fontWeight: isSel ? FontWeight.w800 : FontWeight.w500,
            color: isSel ? const Color(0xFF38BDF8) : Colors.white54,
          ),
        ),
      ),
    );
  }

  // ── Selected Element Inspector Drawer ─────────────────────────────────────
  Widget _buildSelectedElementInspector() {
    final elem = _selectedElement!;
    final isIcon = elem.type == 'wifi_icon' || elem.type == 'bluetooth_icon';
    if (elem.type == 'custom_text' || elem.type == 'time_colon') {
      if (_customTextController == null ||
          _customTextControllerElementId != elem.id) {
        _customTextController?.dispose();
        _customTextController = TextEditingController(text: elem.text);
        _customTextControllerElementId = elem.id;
      } else if (!_customTextFocusNode.hasFocus &&
          _customTextController!.text != elem.text) {
        _customTextController!.text = elem.text;
      }
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF131726),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Row(
            children: [
              // Badge identifying element type
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  elem.type.toUpperCase(),
                  style: const TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w900,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),

              if (!isIcon) ...[
                // Font Selector Dropdown
                const Text(
                  'Font:',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(width: 6),
                Container(
                  height: 32,
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: DropdownButtonHideUnderline(
                    child: DropdownButton<String>(
                      value: _availableFonts.contains(elem.fontFamily)
                          ? elem.fontFamily
                          : 'Montserrat',
                      dropdownColor: const Color(0xFF1E2235),
                      style: const TextStyle(fontSize: 12, color: Colors.white),
                      items: _availableFonts.map((f) {
                        return DropdownMenuItem(
                          value: f,
                          child: Text(f, style: TextStyle(fontFamily: f)),
                        );
                      }).toList(),
                      onChanged: (val) {
                        if (val != null) {
                          setState(() {
                            elem.fontFamily = val;
                            _hasUnsavedChanges = true;
                          });
                        }
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 14),
              ],

              // Size Slider (Icon Size for Wi-Fi / Bluetooth, Font Size for text elements)
              Text(
                isIcon ? 'Icon Size:' : 'Size:',
                style: const TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 110,
                child: Slider(
                  value: (isIcon
                          ? (elem.width > 0
                              ? elem.width
                              : (elem.fontSize > 0 ? elem.fontSize : 24.0))
                          : elem.fontSize)
                      .clamp(8.0, 120.0),
                  min: 8.0,
                  max: 120.0,
                  activeColor: const Color(0xFF38BDF8),
                  onChanged: (val) {
                    setState(() {
                      if (isIcon) {
                        elem.width = val;
                        elem.height = val;
                        elem.fontSize = val;
                      } else {
                        elem.fontSize = val;
                      }
                      _hasUnsavedChanges = true;
                    });
                  },
                ),
              ),
              Text(
                '${(isIcon ? (elem.width > 0 ? elem.width : elem.fontSize) : elem.fontSize).toInt()}${isIcon ? 'px' : 'pt'}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),

              if (!isIcon) ...[
                const SizedBox(width: 14),
                // Bold toggle
                IconButton(
                  icon: Icon(
                    Icons.format_bold_rounded,
                    size: 18,
                    color: elem.isBold
                        ? const Color(0xFF38BDF8)
                        : Colors.white38,
                  ),
                  tooltip: 'Bold font',
                  onPressed: () {
                    setState(() {
                      elem.isBold = !elem.isBold;
                      _hasUnsavedChanges = true;
                    });
                  },
                ),
              ],

              const Spacer(),

              // Duplicate & Delete buttons
              IconButton(
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 16,
                  color: Colors.white70,
                ),
                tooltip: 'Duplicate element',
                onPressed: () => _duplicateElement(elem.id),
              ),
              IconButton(
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 18,
                  color: Colors.redAccent,
                ),
                tooltip: 'Delete element',
                onPressed: () => _deleteElement(elem.id),
              ),
            ],
          ),

          const SizedBox(height: 8),

          // Second inspector row: Color Swatches & Custom Text input (if applicable)
          Row(
            children: [
              const Text(
                'Color:',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              const SizedBox(width: 8),
              // Palette swatches
              ..._quickPalette.map((col) {
                final isCurrent = elem.color == col.toARGB32();
                return GestureDetector(
                  onTap: () {
                    setState(() {
                      elem.color = col.toARGB32();
                      _hasUnsavedChanges = true;
                    });
                  },
                  child: Container(
                    margin: const EdgeInsets.only(right: 6),
                    width: 20,
                    height: 20,
                    decoration: BoxDecoration(
                      color: col,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: isCurrent ? Colors.white : Colors.white24,
                        width: isCurrent ? 2.5 : 1,
                      ),
                      boxShadow: isCurrent
                          ? [
                              BoxShadow(
                                color: col.withValues(alpha: 0.6),
                                blurRadius: 6,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              }),

              if (elem.type == 'custom_text' || elem.type == 'time_colon') ...[
                const SizedBox(width: 14),
                const Text(
                  'Text:',
                  style: TextStyle(fontSize: 11, color: Colors.white54),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 160,
                  height: 32,
                  child: TextField(
                    controller: _customTextController,
                    focusNode: _customTextFocusNode,
                    onChanged: (val) {
                      elem.text = val;
                      _hasUnsavedChanges = true;
                      setState(() {});
                    },
                    onSubmitted: (val) {
                      setState(() {
                        elem.text = val;
                        _hasUnsavedChanges = true;
                      });
                    },
                    style: const TextStyle(fontSize: 12, color: Colors.white),
                    decoration: InputDecoration(
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(6),
                        borderSide: BorderSide(
                          color: Colors.white.withValues(alpha: 0.1),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  // ── Section 2: Elements Showcase & Toolbox ────────────────────────────────
  Widget _buildElementsToolbox() {
    final categories = [
      'All',
      'Time',
      'Date',
      'Bars',
      'Weather',
      'Media',
      'System',
      'Fonts',
    ];

    return Container(
      color: const Color(0xFF10131D),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Toolbox Header
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 18, 20, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(
                      Icons.widgets_rounded,
                      size: 18,
                      color: Color(0xFF38BDF8),
                    ),
                    const SizedBox(width: 8),
                    const Text(
                      'ELEMENTS SHOWCASE',
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w900,
                        letterSpacing: 1.2,
                        color: Colors.white,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.05),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Text(
                        'Drag to Canvas',
                        style: TextStyle(
                          fontSize: 10,
                          color: Colors.white54,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                // Search field
                TextField(
                  onChanged: (val) =>
                      setState(() => _searchQuery = val.toLowerCase()),
                  style: const TextStyle(fontSize: 12, color: Colors.white),
                  decoration: InputDecoration(
                    hintText: 'Search widget elements or fonts...',
                    hintStyle: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.3),
                    ),
                    prefixIcon: const Icon(
                      Icons.search_rounded,
                      size: 16,
                      color: Colors.white38,
                    ),
                    filled: true,
                    fillColor: Colors.white.withValues(alpha: 0.04),
                    contentPadding: const EdgeInsets.symmetric(vertical: 8),
                    border: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(10),
                      borderSide: BorderSide(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                  ),
                ),
                const SizedBox(height: 10),
                // Category Filter Chips
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: categories.map((cat) {
                      final isSel = _elementsCategory == cat;
                      return Padding(
                        padding: const EdgeInsets.only(right: 6),
                        child: GestureDetector(
                          onTap: () => setState(() => _elementsCategory = cat),
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 4,
                            ),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? const Color(
                                      0xFF38BDF8,
                                    ).withValues(alpha: 0.15)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(12),
                              border: Border.all(
                                color: isSel
                                    ? const Color(0xFF38BDF8)
                                    : Colors.white.withValues(alpha: 0.06),
                              ),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontSize: 10.5,
                                fontWeight: isSel
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: isSel
                                    ? const Color(0xFF38BDF8)
                                    : Colors.white54,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                ),
              ],
            ),
          ),

          const Divider(height: 1, color: Colors.white10),

          // Scrollable Element List
          Expanded(
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: _buildToolboxSections(),
            ),
          ),
        ],
      ),
    );
  }

  List<Widget> _buildToolboxSections() {
    final List<Widget> sections = [_buildCurrentElementsSection()];

    // Helper to filter
    bool matches(String title, String category) {
      if (_elementsCategory != 'All' && _elementsCategory != category) {
        return false;
      }
      if (_searchQuery.isNotEmpty &&
          !title.toLowerCase().contains(_searchQuery)) {
        return false;
      }
      return true;
    }

    // ── Time Category ──────────────────────────────────────────────────────
    if (_elementsCategory == 'All' || _elementsCategory == 'Time') {
      sections.add(
        _buildSectionHeader('TIME ELEMENTS', Icons.schedule_rounded),
      );
      sections.add(
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (matches('Hours (Separate)', 'Time'))
              _buildToolboxItem(
                title: 'Hours Block',
                subtitle: 'Separate hh display',
                element: CustomWidgetElement(
                  id: '',
                  type: 'hours',
                  fontFamily: 'Montserrat',
                  fontSize: 54,
                  isBold: true,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  '12',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Montserrat',
                  ),
                ),
              ),
            if (matches('Minutes (Separate)', 'Time'))
              _buildToolboxItem(
                title: 'Minutes Block',
                subtitle: 'Separate mm display',
                element: CustomWidgetElement(
                  id: '',
                  type: 'minutes',
                  fontFamily: 'Montserrat',
                  fontSize: 54,
                  isBold: true,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  '45',
                  style: TextStyle(
                    fontSize: 24,
                    fontWeight: FontWeight.bold,
                    fontFamily: 'Montserrat',
                  ),
                ),
              ),
            if (matches('Seconds', 'Time'))
              _buildToolboxItem(
                title: 'Seconds Block',
                subtitle: 'Separate ss tick',
                element: CustomWidgetElement(
                  id: '',
                  type: 'seconds',
                  fontFamily: 'Montserrat',
                  fontSize: 28,
                  isBold: true,
                  color: 0xFFF18734,
                ),
                preview: const Text(
                  '30',
                  style: TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF18734),
                    fontFamily: 'Montserrat',
                  ),
                ),
              ),
            if (matches('Separator Colon / Dot', 'Time'))
              _buildToolboxItem(
                title: 'Time Separator',
                subtitle: 'Colon or dot',
                element: CustomWidgetElement(
                  id: '',
                  type: 'time_colon',
                  text: ':',
                  fontFamily: 'Montserrat',
                  fontSize: 48,
                  isBold: true,
                  color: 0xFFF18734,
                ),
                preview: const Text(
                  ':',
                  style: TextStyle(
                    fontSize: 26,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFF18734),
                  ),
                ),
              ),
            if (matches('AM / PM Badge', 'Time'))
              _buildToolboxItem(
                title: 'AM / PM Badge',
                subtitle: 'Meridiem capsule',
                element: CustomWidgetElement(
                  id: '',
                  type: 'ampm',
                  fontFamily: 'Montserrat',
                  fontSize: 12,
                  isBold: true,
                  color: 0xFFF18734,
                ),
                preview: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFF18734).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: const Text(
                    'PM',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.bold,
                      color: Color(0xFFF18734),
                    ),
                  ),
                ),
              ),
            if (matches('Full Digital Clock', 'Time'))
              _buildToolboxItem(
                title: 'Full Clock',
                subtitle: 'Combined hh:mm:ss a',
                element: CustomWidgetElement(
                  id: '',
                  type: 'full_time',
                  fontFamily: 'Montserrat',
                  fontSize: 18,
                  isBold: true,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  '12:45:30 PM',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      );
      sections.add(const SizedBox(height: 20));
    }

    // ── Date Category ──────────────────────────────────────────────────────
    if (_elementsCategory == 'All' || _elementsCategory == 'Date') {
      sections.add(
        _buildSectionHeader('DATE & CALENDAR', Icons.calendar_today_rounded),
      );
      sections.add(
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (matches('Day Header', 'Date'))
              _buildToolboxItem(
                title: 'Day Header',
                subtitle: 'Robik signature font',
                element: CustomWidgetElement(
                  id: '',
                  type: 'day',
                  fontFamily: 'Product Sans',
                  fontSize: 13,
                  letterSpacing: 2.0,
                  isBold: true,
                  color: 0xFFF18734,
                ),
                preview: const Text(
                  'WEDNESDAY',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.5,
                    color: Color(0xFFF18734),
                  ),
                ),
              ),
            if (matches('Date Number', 'Date'))
              _buildToolboxItem(
                title: 'Date Number',
                subtitle: 'Day of month (1-31)',
                element: CustomWidgetElement(
                  id: '',
                  type: 'date',
                  fontFamily: 'Montserrat',
                  fontSize: 28,
                  isBold: true,
                  color: 0xFFCBD5E1,
                ),
                preview: const Text(
                  '21',
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFCBD5E1),
                  ),
                ),
              ),
            if (matches('Full Date String', 'Date'))
              _buildToolboxItem(
                title: 'Full Formatted Date',
                subtitle: 'e.g. 21 OCTOBER 2026',
                element: CustomWidgetElement(
                  id: '',
                  type: 'full_date',
                  fontFamily: 'Montserrat',
                  fontSize: 12,
                  letterSpacing: 0.8,
                  color: 0xFFCBD5E1,
                ),
                preview: const Text(
                  '21 OCTOBER 2026',
                  style: TextStyle(fontSize: 10.5, color: Color(0xFFCBD5E1)),
                ),
              ),
          ],
        ),
      );
      sections.add(const SizedBox(height: 20));
    }

    // ── Progress & System Bars ──────────────────────────────────────────────
    if (_elementsCategory == 'All' || _elementsCategory == 'Bars') {
      sections.add(
        _buildSectionHeader(
          'PROGRESS & SPACE BARS',
          Icons.linear_scale_rounded,
        ),
      );
      sections.add(
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (matches('CPU Bar', 'Bars'))
              _buildToolboxItem(
                title: 'CPU Usage Bar',
                subtitle: 'Live processor gauge',
                element: CustomWidgetElement(
                  id: '',
                  type: 'cpu_bar',
                  width: 190,
                  height: 34,
                  color: 0xFF00FFCC,
                ),
                preview: _buildMiniBarPreview(
                  'CPU',
                  24,
                  const Color(0xFF00FFCC),
                ),
              ),
            if (matches('RAM Bar', 'Bars'))
              _buildToolboxItem(
                title: 'RAM Usage Bar',
                subtitle: 'Live memory gauge',
                element: CustomWidgetElement(
                  id: '',
                  type: 'ram_bar',
                  width: 190,
                  height: 34,
                  color: 0xFFA855F7,
                ),
                preview: _buildMiniBarPreview(
                  'RAM',
                  58,
                  const Color(0xFFA855F7),
                ),
              ),
            if (matches('Space Bar / Storage', 'Bars'))
              _buildToolboxItem(
                title: 'Space Bar',
                subtitle: 'Storage gauge',
                element: CustomWidgetElement(
                  id: '',
                  type: 'space_bar',
                  width: 190,
                  height: 34,
                  color: 0xFF38BDF8,
                ),
                preview: _buildMiniBarPreview(
                  'SPACE',
                  64,
                  const Color(0xFF38BDF8),
                ),
              ),
            if (matches('Battery Bar', 'Bars'))
              _buildToolboxItem(
                title: 'Battery Bar',
                subtitle: 'Battery status indicator',
                element: CustomWidgetElement(
                  id: '',
                  type: 'battery_bar',
                  width: 190,
                  height: 34,
                  color: 0xFF00FF55,
                ),
                preview: _buildMiniBarPreview(
                  'BATTERY',
                  85,
                  const Color(0xFF00FF55),
                ),
              ),
            if (matches('Robik Accent Bar', 'Bars'))
              _buildToolboxItem(
                title: 'Robik Accent Bar',
                subtitle: 'Signature orange accent',
                element: CustomWidgetElement(
                  id: '',
                  type: 'accent_bar',
                  width: 64,
                  height: 4,
                  color: 0xFFF18734,
                ),
                preview: Container(
                  width: 50,
                  height: 4,
                  decoration: BoxDecoration(
                    color: const Color(0xFFF18734),
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
          ],
        ),
      );
      sections.add(const SizedBox(height: 20));
    }

    // ── Weather & Media ────────────────────────────────────────────────────
    if (_elementsCategory == 'All' ||
        _elementsCategory == 'Weather' ||
        _elementsCategory == 'Media') {
      sections.add(_buildSectionHeader('WEATHER & MEDIA', Icons.cloud_rounded));
      sections.add(
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (matches('Weather Pill Card', 'Weather'))
              _buildToolboxItem(
                title: 'Weather Capsule',
                subtitle: 'Icon + Temp + Condition',
                element: CustomWidgetElement(
                  id: '',
                  type: 'weather_pill',
                  width: 190,
                  color: 0xFF38BDF8,
                ),
                preview: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.wb_sunny_rounded,
                        size: 13,
                        color: Color(0xFF38BDF8),
                      ),
                      SizedBox(width: 4),
                      Text(
                        '24°C CLEAR',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (matches('Smart Media Pill', 'Media'))
              _buildToolboxItem(
                title: 'Media Capsule',
                subtitle: 'Neon green player pill',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_pill',
                  width: 420,
                  color: 0xFF00FF55,
                ),
                preview: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF00FF55).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.music_note_rounded,
                        size: 12,
                        color: Color(0xFF00FF55),
                      ),
                      SizedBox(width: 4),
                      Text(
                        'WallSync Audio',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF00FF55),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            if (matches('Media Track Title', 'Media'))
              _buildToolboxItem(
                title: 'Track Title',
                subtitle: 'Current session title',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_title',
                  width: 220,
                  fontSize: 18,
                  isBold: true,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  'Track title',
                  style: TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                  ),
                ),
              ),
            if (matches('Media Artist', 'Media'))
              _buildToolboxItem(
                title: 'Artist',
                subtitle: 'Current session artist',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_artist',
                  width: 180,
                  fontSize: 13,
                  color: 0xFFCBD5E1,
                ),
                preview: const Text(
                  'Artist',
                  style: TextStyle(color: Color(0xFFCBD5E1)),
                ),
              ),
            if (matches('Media Album', 'Media'))
              _buildToolboxItem(
                title: 'Album',
                subtitle: 'Current session album',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_album',
                  width: 180,
                  fontSize: 12,
                  color: 0xFFCBD5E1,
                ),
                preview: const Text(
                  'Album',
                  style: TextStyle(color: Color(0xFFCBD5E1)),
                ),
              ),
            if (matches('Media Source', 'Media'))
              _buildToolboxItem(
                title: 'Source App',
                subtitle: 'Application publishing the session',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_source',
                  width: 140,
                  fontSize: 11,
                  color: 0xFF00FF55,
                ),
                preview: const Text(
                  'Media app',
                  style: TextStyle(color: Color(0xFF00FF55)),
                ),
              ),
            if (matches('Media Playback Status', 'Media'))
              _buildToolboxItem(
                title: 'Playback Status',
                subtitle: 'Playing, paused, or idle',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_status',
                  width: 100,
                  fontSize: 11,
                  color: 0xFF00FF55,
                ),
                preview: const Text(
                  'Playing',
                  style: TextStyle(color: Color(0xFF00FF55)),
                ),
              ),
            if (matches('Media Artwork', 'Media'))
              _buildToolboxItem(
                title: 'Album Artwork',
                subtitle: 'Session thumbnail with fallback',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_artwork',
                  width: 72,
                  height: 72,
                  color: 0xFF00FF55,
                ),
                preview: const Icon(
                  Icons.album_rounded,
                  size: 24,
                  color: Color(0xFF00FF55),
                ),
              ),
            if (matches('Media Progress Bar', 'Media'))
              _buildToolboxItem(
                title: 'Playback Progress',
                subtitle: 'Session timeline progress',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_progress',
                  width: 220,
                  height: 4,
                  color: 0xFF00FF55,
                ),
                preview: const SizedBox(
                  width: 56,
                  child: LinearProgressIndicator(
                    value: 0.6,
                    minHeight: 3,
                    color: Color(0xFF00FF55),
                    backgroundColor: Colors.white12,
                  ),
                ),
              ),
            if (matches('Media Elapsed Time', 'Media'))
              _buildToolboxItem(
                title: 'Elapsed Time',
                subtitle: 'Current playback position',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_elapsed',
                  fontSize: 12,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  '01:24',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            if (matches('Media Total Duration', 'Media'))
              _buildToolboxItem(
                title: 'Total Duration',
                subtitle: 'Track duration when available',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_duration',
                  fontSize: 12,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  '03:48',
                  style: TextStyle(color: Colors.white),
                ),
              ),
            if (matches('Media Playback Controls', 'Media'))
              _buildToolboxItem(
                title: 'Playback Controls',
                subtitle: 'Session-supported previous/play/next',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_controls',
                  fontSize: 14,
                  color: 0xFF00FF55,
                ),
                preview: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(Icons.skip_previous_rounded, color: Color(0xFF00FF55)),
                    Icon(Icons.play_arrow_rounded, color: Color(0xFF00FF55)),
                    Icon(Icons.skip_next_rounded, color: Color(0xFF00FF55)),
                  ],
                ),
              ),
            if (matches('Media Playback Animation', 'Media'))
              _buildToolboxItem(
                title: 'Playback Animation',
                subtitle: 'Animated while a session is playing',
                element: CustomWidgetElement(
                  id: '',
                  type: 'media_animation',
                  width: 22,
                  height: 18,
                  color: 0xFF00FF55,
                ),
                preview: const Icon(
                  Icons.graphic_eq_rounded,
                  size: 20,
                  color: Color(0xFF00FF55),
                ),
              ),
          ],
        ),
      );
      sections.add(const SizedBox(height: 20));
    }

    // ── System & Typography ────────────────────────────────────────────────
    if (_elementsCategory == 'All' ||
        _elementsCategory == 'System' ||
        _elementsCategory == 'Fonts') {
      sections.add(
        _buildSectionHeader('FONTS & SYSTEM', Icons.text_fields_rounded),
      );
      sections.add(
        Wrap(
          spacing: 10,
          runSpacing: 10,
          children: [
            if (matches('Wi-Fi Icon', 'System'))
              _buildToolboxItem(
                title: 'Wi-Fi Status',
                subtitle: 'Connectivity icon',
                element: CustomWidgetElement(
                  id: '',
                  type: 'wifi_icon',
                  color: 0xFFF18734,
                ),
                preview: const Icon(
                  Icons.wifi_rounded,
                  size: 20,
                  color: Color(0xFFF18734),
                ),
              ),
            if (matches('Bluetooth Icon', 'System'))
              _buildToolboxItem(
                title: 'Bluetooth',
                subtitle: 'Connectivity icon',
                element: CustomWidgetElement(
                  id: '',
                  type: 'bluetooth_icon',
                  color: 0xFFF18734,
                ),
                preview: const Icon(
                  Icons.bluetooth_rounded,
                  size: 20,
                  color: Color(0xFFF18734),
                ),
              ),
            if (matches('Anurati Futuristic Text', 'Fonts'))
              _buildToolboxItem(
                title: 'Anurati Font Text',
                subtitle: 'Atomic clock font',
                element: CustomWidgetElement(
                  id: '',
                  type: 'custom_text',
                  text: 'ATOMIC 2026',
                  fontFamily: 'Anurati',
                  fontSize: 18,
                  color: 0xFF00F0FF,
                ),
                preview: const Text(
                  'ATOMIC 2026',
                  style: TextStyle(
                    fontFamily: 'Anurati',
                    fontSize: 13,
                    color: Color(0xFF00F0FF),
                  ),
                ),
              ),
            if (matches('Moving Skate Text', 'Fonts'))
              _buildToolboxItem(
                title: 'Moving Skate Font',
                subtitle: 'Robik skate font',
                element: CustomWidgetElement(
                  id: '',
                  type: 'custom_text',
                  text: 'ROBIK LIVE',
                  fontFamily: 'Moving Skate',
                  fontSize: 20,
                  color: 0xFFF18734,
                ),
                preview: const Text(
                  'ROBIK LIVE',
                  style: TextStyle(
                    fontFamily: 'Moving Skate',
                    fontSize: 14,
                    color: Color(0xFFF18734),
                  ),
                ),
              ),
            if (matches('Custom Text Header', 'Fonts'))
              _buildToolboxItem(
                title: 'Custom Text',
                subtitle: 'Editable label',
                element: CustomWidgetElement(
                  id: '',
                  type: 'custom_text',
                  text: 'MY DESKTOP',
                  fontFamily: 'Montserrat',
                  fontSize: 16,
                  isBold: true,
                  color: 0xFFFFFFFF,
                ),
                preview: const Text(
                  'MY DESKTOP',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
                ),
              ),
          ],
        ),
      );
    }

    return sections;
  }

  Widget _buildCurrentElementsSection() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _buildSectionHeader(
              'CURRENT WIDGET ELEMENTS (${_elements.length})',
              Icons.layers_rounded,
            ),
            const Spacer(),
            Text(
              'Select to customize',
              style: TextStyle(
                fontSize: 9.5,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        if (_elements.isEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 14),
            child: Text(
              'No elements yet. Add an element from the library below.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            ),
          )
        else
          ..._elements.map((element) {
            final isSelected = element.id == _selectedElementId;
            final label = _elementTypeLabel(element.type);
            final details =
                element.type == 'custom_text' && element.text.isNotEmpty
                ? element.text
                : 'X ${element.x.round()}  ·  Y ${element.y.round()}';
            return Padding(
              padding: const EdgeInsets.only(bottom: 5),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(8),
                  onTap: () => setState(() => _selectedElementId = element.id),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.12)
                          : Colors.white.withValues(alpha: 0.025),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.5)
                            : Colors.white.withValues(alpha: 0.07),
                      ),
                    ),
                    child: Row(
                      children: [
                        Icon(
                          Icons.widgets_rounded,
                          size: 14,
                          color: isSelected
                              ? const Color(0xFF38BDF8)
                              : Color(element.color),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: const TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 2),
                              Text(
                                details,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 9.5,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        Icon(
                          isSelected
                              ? Icons.tune_rounded
                              : Icons.chevron_right_rounded,
                          size: 16,
                          color: isSelected
                              ? const Color(0xFF38BDF8)
                              : Colors.white38,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
        const Divider(height: 22, color: Colors.white10),
      ],
    );
  }

  String _elementTypeLabel(String type) {
    const labels = {
      'time_colon': 'Time Separator',
      'full_time': 'Full Clock',
      'full_date': 'Full Date',
      'custom_text': 'Custom Text',
      'cpu_bar': 'CPU Usage Bar',
      'ram_bar': 'RAM Usage Bar',
      'space_bar': 'Disk Space Bar',
      'battery_bar': 'Battery Bar',
      'accent_bar': 'Accent Bar',
      'weather_temp': 'Weather Temperature',
      'weather_status': 'Weather Status',
      'weather_icon': 'Weather Icon',
      'weather_pill': 'Weather Pill',
      'media_pill': 'Media Pill',
      'media_title': 'Media Title',
      'media_artist': 'Media Artist',
      'media_album': 'Media Album',
      'media_source': 'Media Source',
      'media_status': 'Media Status',
      'media_artwork': 'Media Artwork',
      'media_progress': 'Media Progress',
      'media_elapsed': 'Media Elapsed Time',
      'media_duration': 'Media Duration',
      'media_controls': 'Media Controls',
      'media_animation': 'Media Animation',
      'wifi_icon': 'Wi-Fi Icon',
      'bluetooth_icon': 'Bluetooth Icon',
      'neon_box': 'Neon Box',
    };
    return labels[type] ??
        type
            .split('_')
            .map(
              (part) => part.isEmpty
                  ? part
                  : '${part[0].toUpperCase()}${part.substring(1)}',
            )
            .join(' ');
  }

  Widget _buildSectionHeader(String title, IconData icon) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8.0),
      child: Row(
        children: [
          Icon(icon, size: 14, color: const Color(0xFF38BDF8)),
          const SizedBox(width: 6),
          Text(
            title,
            style: const TextStyle(
              fontSize: 10.5,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Colors.white54,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolboxItem({
    required String title,
    required String subtitle,
    required CustomWidgetElement element,
    required Widget preview,
  }) {
    return Draggable<CustomWidgetElement>(
      data: element,
      feedback: Material(
        color: Colors.transparent,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
          decoration: BoxDecoration(
            color: const Color(0xFF1E2235),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(color: const Color(0xFF38BDF8)),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                blurRadius: 16,
              ),
            ],
          ),
          child: preview,
        ),
      ),
      child: Container(
        width: 165,
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.025),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Preview container
            Container(
              height: 48,
              width: double.infinity,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(6),
              ),
              child: Center(child: preview),
            ),
            const SizedBox(height: 8),
            Text(
              title,
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 2),
            Text(
              subtitle,
              style: const TextStyle(fontSize: 9.5, color: Colors.white38),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
            const SizedBox(height: 6),
            SizedBox(
              width: double.infinity,
              height: 24,
              child: OutlinedButton(
                onPressed: () => _addElement(element),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                  side: BorderSide(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                  ),
                  padding: EdgeInsets.zero,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(5),
                  ),
                ),
                child: const Text(
                  '+ Add',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildMiniBarPreview(String label, int val, Color color) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Text(
                label,
                style: const TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
              Text(
                '$val%',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: color,
                ),
              ),
            ],
          ),
          const SizedBox(height: 3),
          Container(
            height: 3,
            width: double.infinity,
            decoration: BoxDecoration(
              color: Colors.white12,
              borderRadius: BorderRadius.circular(1.5),
            ),
            child: FractionallySizedBox(
              alignment: Alignment.centerLeft,
              widthFactor: val / 100.0,
              child: Container(color: color),
            ),
          ),
        ],
      ),
    );
  }
}

/// Custom painter for blueprint grid preview
class _BlueprintGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;

    const step = 20.0;
    for (double x = 0; x < size.width; x += step) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), paint);
    }
    for (double y = 0; y < size.height; y += step) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
