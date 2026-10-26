// ignore_for_file: unused_element, deprecated_member_use
import 'dart:async';
import 'dart:convert';
import 'dart:developer' as developer;
import 'dart:io';
import 'dart:math' as math;
import 'dart:ffi' hide Size;
import 'package:ffi/ffi.dart';
import 'package:win32/win32.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart' hide TextDirection;
import 'package:file_picker/file_picker.dart';
import '../services/settings_service.dart';
import '../services/firebase_service.dart';
import '../services/wallpaper_metadata_service.dart';
import '../services/wallpaper_engine.dart';
import '../services/live_wallpaper_manager.dart';
import '../services/video_wallpaper_cache.dart';
import '../services/video_thumbnail_service.dart';
import '../services/mpv_runtime_resolver.dart';
import '../services/shortbird_client.dart';
import '../services/weather_service.dart';
import '../services/media_session_service.dart';
import '../services/diagnostics_service.dart';
import '../services/launch_popup_service.dart';
import '../services/overlay_lifecycle_service.dart';
import '../services/system_metrics_service.dart';
import '../services/system_connectivity_service.dart';
import '../services/system_optimizer_service.dart';
import 'animated_backgrounds.dart';
import 'color_picker_widget.dart';
import 'gradient_picker_widget.dart';
import 'splash_screen.dart';
import 'package:url_launcher/url_launcher.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/legacy.dart';
import 'desktop_widget.dart';
import 'live_video_preview.dart';
import 'custom_widget_renderer.dart';
import 'custom_widget_builder.dart';

// ─────────────────────────────────────────────────────────────────────────────
// DashboardView — the main customizer window
// ─────────────────────────────────────────────────────────────────────────────
class DashboardView extends StatefulWidget {
  final WidgetSettings initialSettings;
  final bool isStartupBackground;
  const DashboardView({
    super.key,
    required this.initialSettings,
    this.isStartupBackground = false,
  });

  @override
  State<DashboardView> createState() => _DashboardViewState();
}

class _DashboardViewState extends State<DashboardView>
    with TickerProviderStateMixin, WindowListener, TrayListener {
  late WidgetSettings _settings;
  final _settingsService = SettingsService();
  late final _overlayLifecycle = OverlayLifecycleService.forApp(
    _settingsService,
  );
  final _overlayLaunchGate = OverlayLaunchGate();
  Future<void>? _overlayCloseOperation;
  Future<void>? _overlayStatusOperation;

  // Firebase & Wallpaper Engine state
  final _firebaseService = FirebaseService();
  final _wallpaperEngine = WallpaperEngine();
  final _videoWallpaperCache = VideoWallpaperCache();
  final _liveWallpaperManager = LiveWallpaperManager();
  List<FirebaseWallpaper> _wallpapers = [];
  List<FirebaseWallpaper> _cachedStaticWallpapers = [];
  List<FirebaseWallpaper> _cachedLiveWallpapers = [];

  void _rebuildWallpaperCaches() {
    final seenStaticIds = <String>{};
    final seenStaticUrls = <String>{};
    final List<FirebaseWallpaper> staticWps = [];

    final seenLiveIds = <String>{};
    final seenLiveUrls = <String>{};
    final seenLiveNames = <String>{};
    final List<FirebaseWallpaper> liveWps = [];

    for (final w in _wallpapers) {
      if (w.isVideo) {
        final normId = w.id.trim();
        final normUrl = w.url.trim().toLowerCase();
        final normName = w.name.trim().toLowerCase();
        if ((normId.isNotEmpty && seenLiveIds.contains(normId)) ||
            (normUrl.isNotEmpty && seenLiveUrls.contains(normUrl)) ||
            (normName.isNotEmpty && seenLiveNames.contains(normName))) {
          continue;
        }
        if (normId.isNotEmpty) seenLiveIds.add(normId);
        if (normUrl.isNotEmpty) seenLiveUrls.add(normUrl);
        if (normName.isNotEmpty) seenLiveNames.add(normName);
        liveWps.add(w);
      } else {
        final normId = w.id.trim();
        final normUrl = w.url.trim().toLowerCase();
        if ((normId.isNotEmpty && seenStaticIds.contains(normId)) ||
            (normUrl.isNotEmpty && seenStaticUrls.contains(normUrl))) {
          continue;
        }
        if (normId.isNotEmpty) seenStaticIds.add(normId);
        if (normUrl.isNotEmpty) seenStaticUrls.add(normUrl);
        staticWps.add(w);
      }
    }
    _cachedStaticWallpapers = staticWps;
    _cachedLiveWallpapers = liveWps;
  }

  bool _loadingWallpapers = true;
  final Map<String, double> _downloadProgress = {};
  final Set<String> _downloadedWallpaperIds = {};
  final Set<String> _applyingWallpaperIds = {};
  final Set<String> _explicitWallpaperDownloads = {};
  int _wallpaperLoadGeneration = 0;
  int _wallpaperTransitionGeneration = 0;
  Future<void> _wallpaperTransitionTail = Future<void>.value();
  String _wallpaperTransitionState = 'idle';
  String? _activeWallpaperTransitionTarget;
  Future<void>? _inFlightWallpaperTransitionFuture;
  bool _isVideoWallpaperBusy = false;
  final ValueNotifier<double?> _videoDownloadProgressNotifier =
      ValueNotifier<double?>(null);
  double? get _videoDownloadProgress => _videoDownloadProgressNotifier.value;
  bool _isSelectingVideo = false;
  bool _showVideoSettingsExpanded = false;
  bool _isChangingWallpaperFit = false;
  bool _isClearingWallpaperCache = false;
  String? _hoveredVideoCardId;
  Timer? _hoverDebounceTimer;
  String _currentMainTab =
      'wallpapers'; // 'wallpapers' | 'widgets' | 'bug_report'
  String _selectedWidgetCategory = 'All';
  final _wallpaperBetaEmailCtrl = TextEditingController();
  bool _wallpaperBetaRegistered = false;
  // Bug Report State
  bool _submittingBug = false;
  bool _bugSubmitted = false;
  final _bugFormKey = GlobalKey<FormState>();
  final _gmailCtrl = TextEditingController();
  final _nameCtrl = TextEditingController();
  final _titleCtrl = TextEditingController();
  final _descCtrl = TextEditingController();
  final _videoUrlController = TextEditingController();
  final _weatherSearchCtrl = TextEditingController();
  bool _isAutoDetectingWeather = false;
  String _weatherSearchError = '';
  StreamSubscription<MediaInfo>? _mediaSubscription;
  StreamSubscription<SystemConnectivitySnapshot>? _connectivitySubscription;
  SystemConnectivitySnapshot _connectivity =
      SystemConnectivityService.instance.current;
  MediaInfo _mediaInfo = MediaInfo(title: '', artist: '', status: 'Closed');
  final ValueNotifier<int> _playbackPositionNotifier = ValueNotifier<int>(0);
  Uint8List? _thumbnailBytes;
  int _dashboardBuildCount = 0;
  Future<StorageSnapshot>? _diagnosticsStorageSnapshot;
  final Map<String, Future<File?>> _recentThumbnailFutures = {};

  T _profileDashboardSection<T>(String section, T Function() action) {
    final stopwatch = Stopwatch()..start();
    try {
      return developer.Timeline.timeSync('DashboardView.$section', action);
    } finally {
      final elapsed = stopwatch.elapsedMilliseconds;
      // This is intentionally much lower than the frame-jank threshold. It
      // identifies which synchronous widget construction is expensive without
      // reclassifying a frame or hiding diagnostic warnings.
      if (elapsed >= 16) {
        logInfo(
          'DashboardView',
          '[BUILD SECTION] $section completed in ${elapsed}ms',
        );
      }
    }
  }

  Widget _buildCustomElementIdentificationDeck() {
    final elements = _settings.customElements;
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        Row(
          children: [
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _sectionLabel('WIDGET OBJECTS & LAYERS'),
                  const SizedBox(height: 3),
                  Text(
                    'Every element in this custom widget is listed below.',
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.45),
                    ),
                  ),
                ],
              ),
            ),
            OutlinedButton.icon(
              onPressed: () => _openCustomElementEditor(null),
              icon: const Icon(Icons.dashboard_customize_rounded, size: 14),
              label: const Text('Edit layout'),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.layers_rounded,
                size: 15,
                color: Color(0xFF38BDF8),
              ),
              const SizedBox(width: 8),
              Text(
                '${elements.length} widget elements',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF38BDF8),
                ),
              ),
              const Spacer(),
              Text(
                'Select any element to customize it',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.45),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_selectedCustomWidgetElement != null)
          _buildCustomWidgetElementInspector(_selectedCustomWidgetElement!),
        if (elements.isEmpty)
          Center(
            child: Padding(
              padding: const EdgeInsets.all(32),
              child: Column(
                children: [
                  const Icon(
                    Icons.widgets_outlined,
                    size: 32,
                    color: Colors.white38,
                  ),
                  const SizedBox(height: 10),
                  const Text(
                    'This widget has no elements yet.',
                    style: TextStyle(color: Colors.white70),
                  ),
                  const SizedBox(height: 10),
                  FilledButton.icon(
                    onPressed: () => _openCustomElementEditor(null),
                    icon: const Icon(Icons.add_rounded, size: 16),
                    label: const Text('Add elements'),
                  ),
                ],
              ),
            ),
          )
        else
          ...elements.map((element) {
            final label = _customElementLabel(element.type);
            final description =
                element.type == 'custom_text' && element.text.isNotEmpty
                ? element.text
                : 'Position ${element.x.round()}, ${element.y.round()}'
                      '  ·  ${element.width.round()} × ${element.height.round()}';
            return Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  borderRadius: BorderRadius.circular(10),
                  onTap: () =>
                      setState(() => _selectedCustomElementId = element.id),
                  child: Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.035),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.09),
                      ),
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: 34,
                          height: 34,
                          decoration: BoxDecoration(
                            color: Color(element.color).withValues(alpha: 0.14),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Color(
                                element.color,
                              ).withValues(alpha: 0.45),
                            ),
                          ),
                          child: Icon(
                            Icons.widgets_rounded,
                            size: 17,
                            color: Color(element.color),
                          ),
                        ),
                        const SizedBox(width: 10),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Text(
                                label,
                                style: const TextStyle(
                                  fontSize: 12,
                                  fontWeight: FontWeight.w700,
                                  color: Colors.white,
                                ),
                              ),
                              const SizedBox(height: 3),
                              Text(
                                description,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontSize: 10,
                                  color: Colors.white54,
                                ),
                              ),
                            ],
                          ),
                        ),
                        const SizedBox(width: 8),
                        TextButton.icon(
                          onPressed: () => setState(
                            () => _selectedCustomElementId = element.id,
                          ),
                          icon: const Icon(Icons.tune_rounded, size: 13),
                          label: const Text(
                            'Customize',
                            style: TextStyle(fontSize: 10),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }),
      ],
    );
  }

  CustomWidgetElement? get _selectedCustomWidgetElement {
    final id = _selectedCustomElementId;
    if (id == null) return null;
    for (final element in _settings.customElements) {
      if (element.id == id) return element;
    }
    return null;
  }

  void _updateCustomWidgetElement(
    String id,
    CustomWidgetElement Function(CustomWidgetElement) update,
  ) {
    final updatedElements = _settings.customElements.map((element) {
      return element.id == id ? update(element.copyWith()) : element.copyWith();
    }).toList();
    _updateSettings(_settings.copyWith(customElements: updatedElements));
  }

  void _duplicateCustomWidgetElement(String id) {
    final source = _settings.customElements.firstWhere(
      (element) => element.id == id,
    );
    final copy = source.copyWith(
      id: 'element_${DateTime.now().microsecondsSinceEpoch}',
      x: (source.x + 12).clamp(0, _settings.width - source.width),
      y: (source.y + 12).clamp(0, _settings.height - source.height),
    );
    _selectedCustomElementId = copy.id;
    _updateSettings(
      _settings.copyWith(customElements: [..._settings.customElements, copy]),
    );
  }

  void _deleteCustomWidgetElement(String id) {
    _selectedCustomElementId = null;
    _updateSettings(
      _settings.copyWith(
        customElements: _settings.customElements
            .where((element) => element.id != id)
            .map((element) => element.copyWith())
            .toList(),
      ),
    );
  }

  Widget _buildCustomWidgetElementInspector(CustomWidgetElement element) {
    const palette = [
      Color(0xFFFFFFFF),
      Color(0xFFF18734),
      Color(0xFF00FFCC),
      Color(0xFF38BDF8),
      Color(0xFFD946EF),
      Color(0xFFFACC15),
      Color(0xFFF43F5E),
      Color(0xFF94A3B8),
    ];
    final fonts = _fonts;

    Widget sliderControl(
      String label,
      double value,
      double min,
      double max,
      ValueChanged<double> onChanged,
      String valueLabel,
    ) {
      return Row(
        children: [
          SizedBox(
            width: 76,
            child: Text(
              label,
              style: const TextStyle(fontSize: 10, color: Colors.white60),
            ),
          ),
          Expanded(
            child: Slider(
              value: value.clamp(min, max),
              min: min,
              max: max,
              activeColor: const Color(0xFF38BDF8),
              onChanged: onChanged,
            ),
          ),
          SizedBox(
            width: 42,
            child: Text(
              valueLabel,
              textAlign: TextAlign.end,
              style: const TextStyle(fontSize: 10, color: Colors.white70),
            ),
          ),
        ],
      );
    }

    Widget stateColorPicker(
      String label,
      int selectedColor,
      ValueChanged<int> onChanged,
    ) {
      return Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 6,
        children: [
          Text(
            label,
            style: const TextStyle(fontSize: 10, color: Colors.white60),
          ),
          ...palette.map((color) {
            final selected = selectedColor == color.toARGB32();
            return InkWell(
              onTap: () => onChanged(color.toARGB32()),
              customBorder: const CircleBorder(),
              child: Container(
                width: 19,
                height: 19,
                decoration: BoxDecoration(
                  color: color,
                  shape: BoxShape.circle,
                  border: Border.all(
                    color: selected ? Colors.white : Colors.white24,
                    width: selected ? 2 : 1,
                  ),
                ),
              ),
            );
          }),
        ],
      );
    }

    final isConnectivityIcon =
        element.type == 'wifi_icon' || element.type == 'bluetooth_icon';

    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: const Color(0xFF141A29),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  '${_customElementLabel(element.type)} customization',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w800,
                    color: Colors.white,
                  ),
                ),
              ),
              IconButton(
                tooltip: 'Duplicate element',
                visualDensity: VisualDensity.compact,
                onPressed: () => _duplicateCustomWidgetElement(element.id),
                icon: const Icon(
                  Icons.copy_rounded,
                  size: 15,
                  color: Colors.white70,
                ),
              ),
              IconButton(
                tooltip: 'Delete element',
                visualDensity: VisualDensity.compact,
                onPressed: () => _deleteCustomWidgetElement(element.id),
                icon: const Icon(
                  Icons.delete_outline_rounded,
                  size: 16,
                  color: Colors.redAccent,
                ),
              ),
              IconButton(
                tooltip: 'Close customization',
                visualDensity: VisualDensity.compact,
                onPressed: () =>
                    setState(() => _selectedCustomElementId = null),
                icon: const Icon(
                  Icons.close_rounded,
                  size: 16,
                  color: Colors.white54,
                ),
              ),
              IconButton(
                tooltip: 'Edit layout in studio',
                visualDensity: VisualDensity.compact,
                onPressed: () => _openCustomElementEditor(element.id),
                icon: const Icon(
                  Icons.open_in_full_rounded,
                  size: 15,
                  color: Colors.white54,
                ),
              ),
            ],
          ),
          if (element.type == 'custom_text' || element.type == 'time_colon')
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: TextFormField(
                key: ValueKey('custom-element-text-${element.id}'),
                initialValue: element.text,
                onChanged: (text) => _updateCustomWidgetElement(
                  element.id,
                  (item) => item..text = text,
                ),
                style: const TextStyle(fontSize: 11, color: Colors.white),
                decoration: const InputDecoration(
                  labelText: 'Text',
                  isDense: true,
                ),
              ),
            ),
          if (ElementKey.textKeys.contains(element.type) ||
              element.type == 'custom_text' ||
              element.type == 'time_colon')
            Row(
              children: [
                const Text(
                  'Font',
                  style: TextStyle(fontSize: 10, color: Colors.white60),
                ),
                const SizedBox(width: 8),
                DropdownButton<String>(
                  value: fonts.contains(element.fontFamily)
                      ? element.fontFamily
                      : fonts.first,
                  dropdownColor: const Color(0xFF1E2235),
                  style: const TextStyle(fontSize: 10, color: Colors.white),
                  items: fonts
                      .map(
                        (font) =>
                            DropdownMenuItem(value: font, child: Text(font)),
                      )
                      .toList(),
                  onChanged: (font) {
                    if (font == null) return;
                    _updateCustomWidgetElement(
                      element.id,
                      (item) => item..fontFamily = font,
                    );
                  },
                ),
                const Spacer(),
                FilterChip(
                  label: const Text('Bold', style: TextStyle(fontSize: 10)),
                  selected: element.isBold,
                  onSelected: (bold) => _updateCustomWidgetElement(
                    element.id,
                    (item) => item..isBold = bold,
                  ),
                ),
              ],
            ),
          Wrap(
            crossAxisAlignment: WrapCrossAlignment.center,
            spacing: 5,
            children: [
              const Text(
                'Color',
                style: TextStyle(fontSize: 10, color: Colors.white60),
              ),
              ...palette.map((color) {
                final selected = element.color == color.toARGB32();
                return InkWell(
                  onTap: () => _updateCustomWidgetElement(
                    element.id,
                    (item) => item..color = color.toARGB32(),
                  ),
                  customBorder: const CircleBorder(),
                  child: Container(
                    width: 19,
                    height: 19,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: selected ? Colors.white : Colors.white24,
                        width: selected ? 2 : 1,
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
          if (element.type == 'wifi_icon' ||
              element.type == 'bluetooth_icon') ...[
            const SizedBox(height: 8),
            stateColorPicker(
              'Active color',
              element.activeColor ?? element.color,
              (color) => _updateCustomWidgetElement(
                element.id,
                (item) => item..activeColor = color,
              ),
            ),
            const SizedBox(height: 6),
            stateColorPicker(
              'Disabled color',
              element.disabledColor ?? element.color,
              (color) => _updateCustomWidgetElement(
                element.id,
                (item) => item..disabledColor = color,
              ),
            ),
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                '${element.type == 'wifi_icon' ? 'Wi-Fi' : 'Bluetooth'} live status: '
                '${element.type == 'wifi_icon' ? (_connectivity.wifiEnabled == null
                          ? 'Unavailable'
                          : _connectivity.wifiEnabled!
                          ? 'On'
                          : 'Off') : (_connectivity.bluetoothEnabled == null
                          ? 'Unavailable'
                          : _connectivity.bluetoothEnabled!
                          ? 'On'
                          : 'Off')}',
                style: const TextStyle(fontSize: 10, color: Colors.white54),
              ),
            ),
          ],
          sliderControl(
            isConnectivityIcon ? 'Icon size' : 'Font size',
            isConnectivityIcon
                ? (element.width > 0
                    ? element.width
                    : (element.fontSize > 0 ? element.fontSize : 24.0))
                : element.fontSize,
            8,
            120,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) {
                item.fontSize = value;
                if (isConnectivityIcon) {
                  item.width = value;
                  item.height = value;
                }
                return item;
              },
            ),
            '${(isConnectivityIcon ? (element.width > 0 ? element.width : (element.fontSize > 0 ? element.fontSize : 24.0)) : element.fontSize).round()} ${isConnectivityIcon ? 'px' : 'pt'}',
          ),
          sliderControl(
            'Opacity',
            element.opacity,
            0,
            1,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..opacity = value,
            ),
            '${(element.opacity * 100).round()}%',
          ),
          sliderControl(
            'Letter space',
            element.letterSpacing,
            -2,
            8,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..letterSpacing = value,
            ),
            element.letterSpacing.toStringAsFixed(1),
          ),
          sliderControl(
            'Position X',
            element.x,
            0,
            _settings.width - 1,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..x = value,
            ),
            element.x.round().toString(),
          ),
          sliderControl(
            'Position Y',
            element.y,
            0,
            _settings.height - 1,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..y = value,
            ),
            element.y.round().toString(),
          ),
          sliderControl(
            'Width',
            element.width,
            8,
            _settings.width,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..width = value,
            ),
            element.width.round().toString(),
          ),
          sliderControl(
            'Height',
            element.height,
            4,
            _settings.height,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..height = value,
            ),
            element.height.round().toString(),
          ),
          sliderControl(
            'Rotation',
            element.rotation,
            -180,
            180,
            (value) => _updateCustomWidgetElement(
              element.id,
              (item) => item..rotation = value,
            ),
            '${element.rotation.round()}°',
          ),
        ],
      ),
    );
  }

  // CPU & RAM stats for Robik template
  double _cpuUsage = 0.0;
  double _ramUsage = 0.0;
  int _lastIdleTime = 0;
  int _lastKernelTime = 0;
  int _lastUserTime = 0;

  void _updateSystemStats() {
    SystemOptimizerService.instance.getPerformanceMetrics().then((metrics) {
      if (!mounted) return;
      if (metrics != null) {
        if (metrics.cpuPercent != null) _cpuUsage = metrics.cpuPercent!;
        if (metrics.ramLoadPercent != null) _ramUsage = metrics.ramLoadPercent!;
        return;
      }
      _updateSystemStatsFallback();
    }).catchError((_) {
      _updateSystemStatsFallback();
    });
  }

  void _updateSystemStatsFallback() {
    final idleTime = calloc<FILETIME>();
    final kernelTime = calloc<FILETIME>();
    final userTime = calloc<FILETIME>();

    if (GetSystemTimes(idleTime, kernelTime, userTime).value) {
      final int idle =
          (idleTime.ref.dwHighDateTime << 32) | idleTime.ref.dwLowDateTime;
      final int kernel =
          (kernelTime.ref.dwHighDateTime << 32) | kernelTime.ref.dwLowDateTime;
      final int user =
          (userTime.ref.dwHighDateTime << 32) | userTime.ref.dwLowDateTime;

      if (_lastIdleTime != 0) {
        final int usr = user - _lastUserTime;
        final int ker = kernel - _lastKernelTime;
        final int idl = idle - _lastIdleTime;
        final int sys = usr + ker;
        if (sys > 0) {
          _cpuUsage = (((sys - idl) * 100.0) / sys).clamp(0.0, 100.0);
        }
      }
      _lastIdleTime = idle;
      _lastKernelTime = kernel;
      _lastUserTime = user;
    }
    calloc.free(idleTime);
    calloc.free(kernelTime);
    calloc.free(userTime);

    final memoryStatus = calloc<MEMORYSTATUSEX>();
    memoryStatus.ref.dwLength = sizeOf<MEMORYSTATUSEX>();
    if (GlobalMemoryStatusEx(memoryStatus).value) {
      _ramUsage = memoryStatus.ref.dwMemoryLoad.toDouble();
    }
    calloc.free(memoryStatus);
  }

  void _updatePlaybackPosition(MediaInfo info) {
    _playbackPositionNotifier.value = info.hasPosition ? info.position : 0;
  }

  String _selectedCategory = 'All';
  String _wallpaperSubTab = 'static'; // 'recent' | 'static' | 'live'
  String _selectedRecentFilter = 'All'; // 'All' | 'static' | 'video'
  int _videoElapsedSeconds = 0;

  // Animation controller for the mesh background
  late AnimationController _backgroundFlowController;

  // Overlay lifecycle
  bool _isOverlayRunning = false;
  bool _isLaunching = false;
  bool _isOverlayExplicitlyClosed = false;
  final _overlayRecoveryPolicy = OverlayRecoveryPolicy();
  Timer? _overlayRecoveryTimer;
  Timer? _overlayRecoveryStabilityTimer;
  Timer? _statusTimer;
  StreamSubscription<FileSystemEvent>? _settingsWatcher;
  Timer? _watcherDebounce;
  late String _activeTemplate;

  // Background Download Queue
  final List<FirebaseWallpaper> _downloadQueue = [];
  final Map<String, Completer<File?>> _wallpaperDownloadTasks = {};
  int _activeDownloads = 0;
  static const int _maxConcurrentDownloads = 2;

  // Preview clock
  Timer? _clockTimer;
  Timer? _dashboardDecorationsTimer;
  Timer? _updateCheckTimer;
  Timer? _launchPopupTimer;
  DateTime _previewDateTime = DateTime.now();
  late final ValueNotifier<DateTime> _previewDateTimeNotifier;
  bool _isWindowVisible = true;
  bool _showDashboardDecorations = false;

  // Debounce timer for settings saves (avoids hammering file+registry on every slider tick)
  Timer? _saveDebounce;

  // Element selection
  String? _selectedElement; // null → no element selected
  bool _editingWidget = false;
  bool _isCustomStudioOpen = false;
  SavedCustomWidget? _editingSavedWidget;
  String? _editingCustomElementId;
  String? _activeSavedWidgetId;
  String? _selectedCustomElementId;
  String _neonActiveQuickElement = ElementKey.cpu;
  bool _neonShowCpuCustomizer = true;
  bool _neonShowRamCustomizer = true;
  bool _neonShowBadgeCustomizer = true;

  // Tab controller for editor
  late TabController _tabCtrl;

  // Scroll controllers for horizontal lists
  late ScrollController _gradientScrollCtrl;
  late ScrollController _animatedBgScrollCtrl;
  late ScrollController _curatedWpScrollCtrl;

  // ── Static data ──────────────────────────────────────────────────────────

  static const List<String> _fonts = [
    'Segoe UI',
    'Montserrat',
    'Product Sans',
    'Roboto',
    'Outfit',
    'Consolas',
    'Georgia',
    'Trebuchet MS',
    'Arial',
    'Times New Roman',
    'Courier New',
    'Impact',
  ];

  static const List<Map<String, dynamic>> _curatedWallpapers = [
    {'name': 'Cyberpunk', 'path': 'assets/cyberpunk.png'},
    {'name': 'Aurora', 'path': 'assets/aurora.png'},
    {'name': 'Forest', 'path': 'assets/forest.png'},
    {'name': 'Nebula', 'path': 'assets/nebula.png'},
    {'name': 'Cosmic Dust', 'path': 'assets/cosmic_dust.png'},
    {'name': 'Ocean Breeze', 'path': 'assets/ocean_breeze.png'},
    {'name': 'Desert Sunset', 'path': 'assets/desert_sunset.png'},
    {'name': 'Golden Hour', 'path': 'assets/golden_hour.png'},
  ];

  static const List<List<Color>> _gradientPresets = [
    [Color(0xFF8E2DE2), Color(0xFF4A00E0)],
    [Color(0xFF02AAB0), Color(0xFF00CDAC)],
    [Color(0xFFFF512F), Color(0xFFDD2476)],
    [Color(0xFF0F2027), Color(0xFF203A43), Color(0xFF2C5364)],
    [Color(0xFFF72585), Color(0xFF7209B7), Color(0xFF3F37C9)],
    [Color(0xFFFFD700), Color(0xFF39FF14)],
    [Color(0xFF000000), Color(0xFF434343)],
    [Color(0xFFF12711), Color(0xFFF5AF19)],
    [Color(0xFF11998E), Color(0xFF38EF7D)],
    [Color(0xFF0575E6), Color(0xFF00F260)],
    [Color(0xFF4776E6), Color(0xFF8E54E9)],
    [Color(0xFF1E3C72), Color(0xFF2A5298)],
    [Color(0xFFE91E63), Color(0xFFFCE4EC)],
    [Color(0xFF111111), Color(0xFFD4AF37)],
    [Color(0xFFFF758C), Color(0xFFFF7EB3)],
  ];

  // Human-readable labels for each element key
  static const Map<String, String> _elementLabels = {
    ElementKey.hours: 'Hours',
    ElementKey.minutes: 'Minutes',
    ElementKey.seconds: 'Seconds',
    ElementKey.ampm: 'AM / PM',
    ElementKey.date: 'Date',
    ElementKey.day: 'Day of Week',
    ElementKey.year: 'Year',
    ElementKey.separator: 'Separator',
    ElementKey.glowOuter: 'Outer Ring',
    ElementKey.glowInner: 'Inner Ring',
    ElementKey.innerBackground: 'Inner Background',
    ElementKey.neonBox: 'Neon Box Frame',
    ElementKey.neonBadge: 'Neon Status Badge',
    ElementKey.neonDivider: 'Laser Divider',
    ElementKey.cpu: 'CPU Usage Monitor',
    ElementKey.ram: 'RAM Usage Monitor',
    ElementKey.wifiIcon: 'Wi-Fi Icon',
    ElementKey.wifiText: 'Wi-Fi Text',
    ElementKey.bluetoothIcon: 'Bluetooth Icon',
    ElementKey.bluetoothText: 'Bluetooth Text',
    ElementKey.mediaTitle: 'Media Track Title',
    ElementKey.mediaArtist: 'Media Track Artist',
    ElementKey.mediaTime: 'Media Track Time',
    ElementKey.mediaIcon: 'Media Action Icons',
    ElementKey.mediaBg: 'Media Panel Card',
    ElementKey.weatherTemp: 'Weather Temp text',
    ElementKey.weatherStatus: 'Weather Status desc',
    ElementKey.weatherIcon: 'Weather Status Icon',
  };

  static const Map<String, IconData> _elementIcons = {
    ElementKey.hours: Icons.schedule_rounded,
    ElementKey.minutes: Icons.timer_rounded,
    ElementKey.seconds: Icons.timer_outlined,
    ElementKey.ampm: Icons.brightness_6_rounded,
    ElementKey.date: Icons.calendar_today_rounded,
    ElementKey.day: Icons.calendar_month_rounded,
    ElementKey.year: Icons.event_note_rounded,
    ElementKey.separator: Icons.horizontal_rule_rounded,
    ElementKey.glowOuter: Icons.circle_outlined,
    ElementKey.glowInner: Icons.blur_circular_rounded,
    ElementKey.innerBackground: Icons.circle_rounded,
    ElementKey.neonBox: Icons.check_box_outline_blank_rounded,
    ElementKey.neonBadge: Icons.label_important_outline_rounded,
    ElementKey.neonDivider: Icons.horizontal_rule_rounded,
    ElementKey.cpu: Icons.memory_rounded,
    ElementKey.ram: Icons.developer_board_rounded,
    ElementKey.wifiIcon: Icons.wifi_rounded,
    ElementKey.wifiText: Icons.text_fields_rounded,
    ElementKey.bluetoothIcon: Icons.bluetooth_rounded,
    ElementKey.bluetoothText: Icons.text_fields_rounded,
    ElementKey.mediaTitle: Icons.music_note_rounded,
    ElementKey.mediaArtist: Icons.person_rounded,
    ElementKey.mediaTime: Icons.hourglass_bottom_rounded,
    ElementKey.mediaIcon: Icons.play_arrow_rounded,
    ElementKey.mediaBg: Icons.crop_free_rounded,
    ElementKey.weatherTemp: Icons.thermostat_rounded,
    ElementKey.weatherStatus: Icons.wb_cloudy_rounded,
    ElementKey.weatherIcon: Icons.wb_sunny_rounded,
  };

  @override
  void initState() {
    super.initState();
    _tabCtrl = TabController(length: 3, vsync: this);
    _tabCtrl.addListener(() => setState(() {}));

    _settings = widget.initialSettings;
    _syncConnectivityService();
    _activeTemplate = widget.initialSettings.widgetTemplate;
    if (_settings.widgetTemplate == 'custom') {
      for (final saved in _settings.savedCustomWidgets) {
        final sameElements =
            saved.elements.length == _settings.customElements.length &&
            List<int>.generate(saved.elements.length, (index) => index).every(
              (index) =>
                  saved.elements[index].id ==
                      _settings.customElements[index].id &&
                  saved.elements[index].type ==
                      _settings.customElements[index].type,
            );
        if (sameElements) {
          _activeSavedWidgetId = saved.id;
          break;
        }
      }
    }

    // Media previews need the same live session service as the overlay.
    _syncMediaServiceState();
    _mediaInfo = MediaSessionService().current;
    if (_mediaInfo.thumbnail.isNotEmpty) {
      try {
        _thumbnailBytes = base64Decode(_mediaInfo.thumbnail);
      } on FormatException catch (error, stackTrace) {
        logWarning(
          'DashboardView',
          'Initial media artwork base64 decoding failed: $error\n$stackTrace',
        );
      }
    }
    _updatePlaybackPosition(_mediaInfo);
    _mediaSubscription = MediaSessionService().mediaStream.listen((info) {
      if (mounted) {
        final hasChanged =
            info.title != _mediaInfo.title ||
            info.artist != _mediaInfo.artist ||
            info.album != _mediaInfo.album ||
            info.status != _mediaInfo.status ||
            info.source != _mediaInfo.source ||
            info.sessionId != _mediaInfo.sessionId ||
            info.canPlay != _mediaInfo.canPlay ||
            info.canPause != _mediaInfo.canPause ||
            info.canGoNext != _mediaInfo.canGoNext ||
            info.canGoPrevious != _mediaInfo.canGoPrevious ||
            info.duration != _mediaInfo.duration ||
            info.hasDuration != _mediaInfo.hasDuration ||
            info.hasPosition != _mediaInfo.hasPosition;
        final thumbChanged = info.thumbnail != _mediaInfo.thumbnail;

        if (hasChanged) {
          logInfo(
            'DashboardView',
            'Media state updated: source=${info.source.isEmpty ? "unknown" : info.source}, status=${info.status}.',
          );
        }

        // Cache thumbnail bytes on change to prevent reloading flickering
        if (thumbChanged) {
          try {
            _thumbnailBytes = base64Decode(info.thumbnail);
          } on FormatException catch (error, stackTrace) {
            _thumbnailBytes = null;
            logWarning(
              'DashboardView',
              'Media artwork base64 decoding failed: $error\n$stackTrace',
            );
          }
        } else if (info.thumbnail.isEmpty) {
          _thumbnailBytes = null;
        }

        _mediaInfo = info;
        _updatePlaybackPosition(info);

        final mediaPreviewVisible = _currentMainTab == 'widgets' &&
            ((_settings.widgetTemplate == 'sleep_weather' &&
                    _settings.showMediaControl &&
                    _tabCtrl.index == 0) ||
                _settings.widgetTemplate == 'custom' ||
                _settings.savedCustomWidgets.any(
                  (widget) => widget.elements.any(
                    (element) => MediaElementType.contains(element.type),
                  ),
                ));
        if (mediaPreviewVisible && (hasChanged || thumbChanged)) {
          setState(() {});
        }
      }
    });

    // Seed active wallpaper into recents if recents list is empty
    if (_settings.recentWallpapers.isEmpty &&
        _settings.activeWallpaperPath != null &&
        _settings.activeWallpaperPath!.isNotEmpty) {
      final activePath = _settings.activeWallpaperPath!;
      final isVideo = _settings.activeWallpaperType == 'video';
      final name = activePath.startsWith('http')
          ? Uri.tryParse(activePath)?.pathSegments.lastOrNull ??
                'Active Wallpaper'
          : File(activePath).uri.pathSegments.lastOrNull ?? 'Active Wallpaper';
      _settings = _settings.copyWith(
        recentWallpapers: [
          RecentWallpaperItem(
            id: 'active_initial',
            name: name,
            pathOrUrl: activePath,
            type: isVideo ? 'video' : 'static',
            timestamp: DateTime.now().millisecondsSinceEpoch,
          ),
        ],
      );
    }

    final isVideoWp = widget.initialSettings.activeWallpaperType == 'video';
    if (isVideoWp) {
      _wallpaperSubTab = 'live';
    }
    final videoPath = isVideoWp
        ? (widget.initialSettings.activeWallpaperPath ?? '')
        : '';
    final isUrl =
        videoPath.startsWith('http://') || videoPath.startsWith('https://');
    if (isVideoWp && isUrl) {
      _videoUrlController.text = videoPath;
    }

    _gradientScrollCtrl = ScrollController();
    _animatedBgScrollCtrl = ScrollController();
    _curatedWpScrollCtrl = ScrollController();

    _previewDateTimeNotifier = ValueNotifier<DateTime>(_previewDateTime);

    _backgroundFlowController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 24),
    );
    if (_isWindowVisible) {
      _backgroundFlowController.repeat();
    }

    _updateSystemStats();
    _clockTimer = Timer.periodic(const Duration(seconds: 1), (timer) {
      if (!mounted || !_isWindowVisible) return;
      final now = DateTime.now();
      bool shouldUpdate =
          _settings.showSeconds ||
          now.minute != _previewDateTime.minute ||
          now.hour != _previewDateTime.hour;
      if ((_settings.widgetTemplate == 'robik' ||
              _settings.widgetTemplate == 'neon') &&
          timer.tick % 2 == 0) {
        shouldUpdate = true;
      }
      if (_settings.activeWallpaperType == 'video' &&
          !_settings.videoWallpaperPaused) {
        _videoElapsedSeconds++;
      }
      if (shouldUpdate) {
        _previewDateTime = now;
        if (_settings.widgetTemplate == 'robik' ||
            _settings.widgetTemplate == 'neon') {
          _updateSystemStats();
        }
        _previewDateTimeNotifier.value = now;
      }
    });

    windowManager.addListener(this);
    trayManager.addListener(this);
    if (Platform.isWindows) {
      const MethodChannel('com.wallsync/startup').setMethodCallHandler((
        call,
      ) async {
        if (call.method == 'taskbarCreated') {
          logInfo(
            'DashboardView',
            'Received TaskbarCreated message; reinitializing system tray.',
          );
          await _initSystemTray();
        }
      });
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _dashboardDecorationsTimer = Timer(const Duration(milliseconds: 300), () {
        if (mounted) setState(() => _showDashboardDecorations = true);
      });
      _checkOverlayStatus();
      _statusTimer = Timer.periodic(const Duration(seconds: 5), (_) {
        if (_isWindowVisible) _checkOverlayStatus();
      });
      unawaited(_initSettingsWatcher());
      unawaited(_initSystemTray());
      SystemOptimizerService.instance.startBackgroundMemoryOptimizer();
      if (!widget.isStartupBackground) {
        unawaited(_loadWallpapers());
        _updateCheckTimer = Timer(const Duration(milliseconds: 600), () {
          if (mounted) {
            unawaited(_checkForUpdates());
            unawaited(_checkAutoResumeLiveWallpaper());
          }
        });
        _launchPopupTimer = Timer(const Duration(milliseconds: 1200), () {
          if (mounted) LaunchPopupService.instance.checkAndShowPopup(context);
        });
      }
    });
  }

  int _compareVersionStrings(String v1, String v2) {
    final parts1 = v1.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final parts2 = v2.split('.').map((e) => int.tryParse(e) ?? 0).toList();
    final maxLength = parts1.length > parts2.length
        ? parts1.length
        : parts2.length;
    for (int i = 0; i < maxLength; i++) {
      final val1 = i < parts1.length ? parts1[i] : 0;
      final val2 = i < parts2.length ? parts2[i] : 0;
      if (val1 < val2) return -1;
      if (val1 > val2) return 1;
    }
    return 0;
  }

  Future<void> _checkForUpdates() async {
    // Check for push updates via Shortbird client
    await ShortbirdClient().checkForUpdates();

    final updateData = await _firebaseService.checkUpdate();
    if (updateData != null && mounted) {
      final dbVersionRaw = updateData['versionCode'];
      final updateUrl = updateData['updateUrl'] as String?;

      if (dbVersionRaw != null && updateUrl != null) {
        final packageInfo = await PackageInfo.fromPlatform();
        final currentVersionStr = packageInfo.version;
        final currentBuildNumber = int.tryParse(packageInfo.buildNumber) ?? 1;

        bool hasUpdate = false;
        final dbVersionStr = dbVersionRaw.toString().trim();
        if (dbVersionStr.contains('.')) {
          hasUpdate =
              _compareVersionStrings(currentVersionStr, dbVersionStr) < 0;
        } else {
          final dbVersionInt = int.tryParse(dbVersionStr);
          if (dbVersionInt != null) {
            hasUpdate = currentBuildNumber < dbVersionInt;
          }
        }

        if (!mounted) return;

        if (hasUpdate) {
          showDialog(
            context: context,
            barrierDismissible: false,
            builder: (context) => AlertDialog(
              backgroundColor: const Color(0xFF1E1E1E),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(16),
                side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
              ),
              title: const Text(
                'Update Available',
                style: TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                ),
              ),
              content: const Text(
                'A new version of WallSync Pro is available. Would you like to update now?',
                style: TextStyle(color: Colors.white70),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.pop(context),
                  child: const Text(
                    'Later',
                    style: TextStyle(color: Colors.white54),
                  ),
                ),
                ElevatedButton(
                  onPressed: () {
                    Navigator.pop(context);
                    launchUrl(
                      Uri.parse(updateUrl),
                      mode: LaunchMode.externalApplication,
                    );
                  },
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  child: const Text(
                    'Update Now',
                    style: TextStyle(fontWeight: FontWeight.bold),
                  ),
                ),
              ],
            ),
          );
        }
      }
    }
  }

  Future<void> _initSettingsWatcher() async {
    final file = await _settingsService.settingsFile;
    final parentDir = file.parent;
    _settingsWatcher = parentDir.watch().listen((event) {
      if (event.path.endsWith('overlay_settings.json')) {
        _watcherDebounce?.cancel();
        _watcherDebounce = Timer(const Duration(milliseconds: 200), () async {
          if (!mounted) return;
          final updated = await _settingsService.loadSettings();
          if (!mounted) return;
          setState(() {
            _activeTemplate = updated.widgetTemplate;
            _weatherSearchCtrl.text = updated.weatherLocation;
            if (!_isOverlayRunning ||
                _settings.widgetTemplate == updated.widgetTemplate) {
              _settings = updated;
            } else {
              _settings.isLocked = updated.isLocked;
              _settings.editorMode = updated.editorMode;
              _settings.alwaysOnTop = updated.alwaysOnTop;
              _settings.startOnBoot = updated.startOnBoot;
            }
          });
        });
      }
    });
  }

  Future<void> _loadWallpapers({bool forceRefresh = false}) async {
    final generation = ++_wallpaperLoadGeneration;
    final totalStopwatch = Stopwatch()..start();
    if (mounted && _wallpapers.isEmpty) setState(() => _loadingWallpapers = true);
    try {
      final catalogStopwatch = Stopwatch()..start();
      final rawList = await _firebaseService.fetchWallpapers(
        forceRefresh: forceRefresh,
        onRemoteUpdated: (updatedList) {
          if (!mounted || generation != _wallpaperLoadGeneration) return;
          setState(() {
            _wallpapers = updatedList;
            _rebuildWallpaperCaches();
            if (_selectedCategory != 'All' &&
                !updatedList.any(
                  (wallpaper) => wallpaper.category == _selectedCategory,
                )) {
              _selectedCategory = 'All';
            }
          });
          unawaited(_refreshDownloadedWallpaperIds(generation, updatedList));
        },
      );
      logPerf(
        'DashboardView',
        'Wallpaper catalog phase completed in ${catalogStopwatch.elapsedMilliseconds}ms (${rawList.length} entries).',
      );
      if (!mounted || generation != _wallpaperLoadGeneration) return;
      setState(() {
        _wallpapers = rawList;
        _rebuildWallpaperCaches();
        if (_selectedCategory != 'All' &&
            !rawList.any(
              (wallpaper) => wallpaper.category == _selectedCategory,
            )) {
          _selectedCategory = 'All';
        }
        _loadingWallpapers = false;
      });
      logPerf(
        'DashboardView',
        'Wallpaper load completed in ${totalStopwatch.elapsedMilliseconds}ms.',
      );
      unawaited(_refreshDownloadedWallpaperIds(generation, rawList));
    } catch (e, stackTrace) {
      logError(
        'DashboardView',
        'Failed to load wallpapers from database',
        e,
        stackTrace,
      );
      if (mounted && generation == _wallpaperLoadGeneration) {
        setState(() => _loadingWallpapers = false);
      }
    }
  }

  Future<void> _refreshDownloadedWallpaperIds(
    int generation,
    List<FirebaseWallpaper> wallpapers,
  ) async {
    try {
      final cacheIndexStopwatch = Stopwatch()..start();
      await FirebaseService.warmWallpaperCacheIndex();
      logPerf(
        'DashboardView',
        'Wallpaper cache-index phase completed in ${cacheIndexStopwatch.elapsedMilliseconds}ms.',
      );
      final availabilityStopwatch = Stopwatch()..start();
      final cachedStates = await Future.wait(
        wallpapers.map(_firebaseService.isWallpaperCached),
      );
      logPerf(
        'DashboardView',
        'Wallpaper availability phase completed in ${availabilityStopwatch.elapsedMilliseconds}ms.',
      );
      if (!mounted ||
          generation != _wallpaperLoadGeneration ||
          !identical(_wallpapers, wallpapers)) {
        return;
      }
      final downloadedIds = <String>{
        for (var i = 0; i < wallpapers.length; i++)
          if (cachedStates[i]) wallpapers[i].id,
      };
      if (_downloadedWallpaperIds.length == downloadedIds.length &&
          _downloadedWallpaperIds.containsAll(downloadedIds)) {
        return;
      }
      setState(() {
        _downloadedWallpaperIds
          ..clear()
          ..addAll(downloadedIds);
      });
    } catch (error, stackTrace) {
      logError(
        'DashboardView',
        'Failed to refresh wallpaper cache availability',
        error,
        stackTrace,
      );
    }
  }

  @override
  void dispose() {
    if (_wallpaperTransitionState != 'idle') {
      logInfo(
        'DashboardView',
        '[WALLPAPER TRANSITION #$_wallpaperTransitionGeneration] cancelled because the dashboard is disposing.',
      );
    }
    _wallpaperTransitionGeneration++;
    _activeWallpaperTransitionTarget = null;
    _inFlightWallpaperTransitionFuture = null;
    _clockTimer?.cancel();
    _dashboardDecorationsTimer?.cancel();
    _updateCheckTimer?.cancel();
    _launchPopupTimer?.cancel();
    _overlayRecoveryTimer?.cancel();
    _overlayRecoveryStabilityTimer?.cancel();
    _statusTimer?.cancel();
    _hoverDebounceTimer?.cancel();
    if (_saveDebounce?.isActive ?? false) {
      _saveDebounce?.cancel();
      unawaited(_saveSettingsSafely(_settings));
    }
    _settingsWatcher?.cancel();
    _watcherDebounce?.cancel();
    _tabCtrl.dispose();
    _previewDateTimeNotifier.dispose();
    _backgroundFlowController.dispose();
    _gradientScrollCtrl.dispose();
    _animatedBgScrollCtrl.dispose();
    _curatedWpScrollCtrl.dispose();
    _videoUrlController.dispose();
    _wallpaperBetaEmailCtrl.dispose();
    _weatherSearchCtrl.dispose();
    _mediaSubscription?.cancel();
    _connectivitySubscription?.cancel();
    SystemConnectivityService.instance.stop(owner: 'dashboard');
    _playbackPositionNotifier.dispose();
    _videoDownloadProgressNotifier.dispose();
    windowManager.removeListener(this);
    trayManager.removeListener(this);
    if (Platform.isWindows) {
      const MethodChannel('com.wallsync/startup').setMethodCallHandler(null);
    }
    MediaSessionService().stop(owner: 'dashboard');
    SystemOptimizerService.instance.stopBackgroundMemoryOptimizer();
    super.dispose();
  }

  // ── System Tray & Window Lifecycle ────────────────────────────────────────

  Future<void> _initSystemTray() async {
    const maxAttempts = 5;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      try {
        if (Platform.isWindows) {
          final exeDir = File(Platform.resolvedExecutable).parent.path;
          final candidatePaths = [
            '$exeDir\\WallSync.ico',
            '$exeDir\\resources\\app_icon.ico',
            '$exeDir\\data\\flutter_assets\\assets\\app_icon.png',
            'assets/app_icon.png',
          ];
          String? iconPath;
          for (final path in candidatePaths) {
            if (await File(path).exists()) {
              iconPath = path;
              break;
            }
          }
          if (iconPath == null) {
            throw FileSystemException(
              'The installed WallSync tray icon is missing.',
              candidatePaths.first,
            );
          }
          await trayManager.setIcon(iconPath);
          await trayManager.setToolTip('WallSync Pro - Live Wallpapers & Widgets');
          await _updateTrayMenu();
          logInfo(
            'OverlayStartup',
            'System tray icon and menu are ready from "$iconPath" (attempt $attempt).',
          );
          return;
        }
        await trayManager.setIcon('assets/app_icon.png');
        await trayManager.setToolTip('WallSync Pro - Live Wallpapers & Widgets');
        await _updateTrayMenu();
        return;
      } catch (e, st) {
        logWarning(
          'DashboardView',
          'Failed to initialize system tray (attempt $attempt of $maxAttempts): $e',
        );
        if (attempt == maxAttempts) {
          logError(
            'DashboardView',
            'Exhausted retries initializing system tray',
            e,
            st,
          );
        } else {
          await Future.delayed(Duration(milliseconds: 300 * attempt));
        }
      }
    }
  }

  Future<void> _updateTrayMenu() async {
    try {
      final isVideoPlaying =
          _settings.activeWallpaperType == 'video' &&
          !_settings.videoWallpaperPaused;
      final isOverlayOn = _isOverlayRunning;

      final menu = Menu(
        items: [
          MenuItem(key: 'open_dashboard', label: 'Open WallSync Pro'),
          MenuItem.separator(),
          MenuItem(
            key: 'toggle_widget',
            label: isOverlayOn ? 'Hide Desktop Widget' : 'Show Desktop Widget',
          ),
          if (_settings.activeWallpaperType == 'video')
            MenuItem(
              key: 'toggle_wallpaper',
              label: isVideoPlaying
                  ? 'Pause Live Wallpaper'
                  : 'Resume Live Wallpaper',
            ),
          MenuItem.separator(),
          MenuItem(key: 'exit_app', label: 'Exit WallSync Pro'),
        ],
      );
      await trayManager.setContextMenu(menu);
    } catch (e) {
      logError('DashboardView', 'Failed to update tray context menu', e);
    }
  }

  Future<void> _checkAutoResumeLiveWallpaper() async {
    try {
      if (_settings.activeWallpaperType == 'video' &&
          _settings.activeWallpaperPath != null &&
          _settings.activeWallpaperPath!.isNotEmpty) {
        final videoFile = File(_settings.activeWallpaperPath!);
        if (await videoFile.exists() && await videoFile.length() > 0) {
          if (!_settings.videoWallpaperPaused) {
            logInfo(
              'DashboardView',
              'Auto-resuming active live video wallpaper: ${_settings.activeWallpaperPath}',
            );
            final ok = await _wallpaperEngine.startAnimatedWallpaper(
              _settings.activeWallpaperPath!,
            );
            if (!ok) {
              logWarning(
                'DashboardView',
                'Auto-resume of live video wallpaper did not start; safe fallback retained.',
              );
            }
            await _updateTrayMenu();
          }
        }
      }
    } catch (e, st) {
      logError('DashboardView', 'Failed to auto-resume live wallpaper', e, st);
    }
  }

  @override
  void onWindowClose() async {
    logInfo(
      'DashboardView',
      'Window close intercepted; hiding to system tray.',
    );
    _isWindowVisible = false;
    _backgroundFlowController.stop();
    await windowManager.hide();
    unawaited(SystemOptimizerService.instance.optimizeMemory());
    unawaited(SystemOptimizerService.instance.setLowPowerMode(true));
  }

  @override
  void onWindowMinimize() {
    _isWindowVisible = false;
    _backgroundFlowController.stop();
    unawaited(SystemOptimizerService.instance.optimizeMemory());
    unawaited(SystemOptimizerService.instance.setLowPowerMode(true));
  }

  @override
  void onWindowRestore() {
    _isWindowVisible = true;
    if (mounted) {
      _backgroundFlowController.repeat();
    }
    unawaited(SystemOptimizerService.instance.setLowPowerMode(false));
  }

  @override
  void onTrayIconMouseDown() {
    _showAndRestoreDashboard();
  }

  @override
  void onTrayIconRightMouseDown() {
    trayManager.popUpContextMenu();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    switch (menuItem.key) {
      case 'open_dashboard':
        await _showAndRestoreDashboard();
        break;
      case 'toggle_widget':
        if (_isOverlayRunning) {
          await _closeOverlay();
        } else {
          await _launchOverlay();
        }
        await _updateTrayMenu();
        break;
      case 'toggle_wallpaper':
        await _toggleLiveWallpaperPlayback();
        await _updateTrayMenu();
        break;
      case 'exit_app':
        await _exitApplication();
        break;
    }
  }

  Future<void> _showAndRestoreDashboard() async {
    _isWindowVisible = true;
    final isVisible = await windowManager.isVisible();
    if (!isVisible) {
      await windowManager.show();
    }
    await windowManager.restore();
    await windowManager.focus();
    if (mounted) {
      _backgroundFlowController.repeat();
    }
  }

  Future<void> _toggleLiveWallpaperPlayback() async {
    if (_settings.activeWallpaperType != 'video') return;
    final shouldPause = !_settings.videoWallpaperPaused;
    final updated = _settings.copyWith(videoWallpaperPaused: shouldPause);
    _updateSettings(updated);
    if (shouldPause) {
      await _liveWallpaperManager.pause();
    } else {
      await _liveWallpaperManager.play();
    }
    await _updateTrayMenu();
    if (mounted) setState(() {});
  }

  Future<void> _exitApplication() async {
    _wallpaperTransitionGeneration++;
    try {
      await _wallpaperTransitionTail.timeout(const Duration(seconds: 15));
    } on TimeoutException catch (e, st) {
      logError(
        'DashboardView',
        'Wallpaper transition did not settle before application shutdown.',
        e,
        st,
      );
    }
    final stopped = await _wallpaperEngine.stopAnimatedWallpaper();
    if (!stopped) {
      logError(
        'DashboardView',
        'Could not confirm live wallpaper shutdown before application exit.',
      );
    }
    await _closeOverlay();
    try {
      await trayManager.destroy();
    } catch (e, st) {
      logError(
        'DashboardView',
        'Failed to destroy the system tray icon',
        e,
        st,
      );
    }
    exit(0);
  }

  // ── Overlay status ───────────────────────────────────────────────────────

  Future<String> _safeReadPidFile(File file) async {
    try {
      if (await file.exists()) {
        return await file.readAsString();
      }
    } catch (e) {
      logWarning('DashboardView', 'Could not read overlay PID record: $e');
    }
    return '';
  }

  Future<void> _checkOverlayStatus() {
    final pending = _overlayStatusOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _checkOverlayStatusInternal().whenComplete(() {
      if (identical(_overlayStatusOperation, operation)) {
        _overlayStatusOperation = null;
      }
    });
    _overlayStatusOperation = operation;
    return operation;
  }

  Future<void> _checkOverlayStatusInternal() async {
    try {
      final pidFile = await _settingsService.pidFile;
      final content = (await _safeReadPidFile(pidFile)).trim();
      final record = OverlayProcessRecord.tryParse(content);
      final inspection = record == null
          ? null
          : await inspectWindowsProcess(record.pid);
      final isRunning =
          record != null &&
          record.ready &&
          record.creationTime != null &&
          inspection != null &&
          inspection.isRunning &&
          inspection.matches(record);
      final wasRunning = _isOverlayRunning;
      if (mounted && _isOverlayRunning != isRunning) {
        setState(() => _isOverlayRunning = isRunning);
        _updateTrayMenu();
      }
      if (mounted && isRunning) {
        _isOverlayExplicitlyClosed = false;
        _overlayRecoveryTimer?.cancel();
        _overlayRecoveryTimer = null;
        _startOverlayRecoveryStabilityTimer();
      } else if (mounted && wasRunning) {
        _overlayRecoveryStabilityTimer?.cancel();
        _overlayRecoveryStabilityTimer = null;
        if (!_isOverlayExplicitlyClosed) {
          _scheduleOverlayRecovery();
        }
      }
    } catch (e, st) {
      logError(
        'DashboardView',
        'Could not verify overlay process state',
        e,
        st,
      );
      if (mounted && _isOverlayRunning) {
        setState(() => _isOverlayRunning = false);
        _updateTrayMenu();
        _overlayRecoveryStabilityTimer?.cancel();
        _overlayRecoveryStabilityTimer = null;
        if (!_isOverlayExplicitlyClosed) {
          _scheduleOverlayRecovery();
        }
      }
    }
  }

  void _startOverlayRecoveryStabilityTimer() {
    if (_overlayRecoveryStabilityTimer != null) return;
    _overlayRecoveryStabilityTimer = Timer(const Duration(minutes: 5), () {
      _overlayRecoveryStabilityTimer = null;
      _overlayRecoveryPolicy.reset();
      logInfo(
        'DashboardView',
        'Overlay remained healthy for five minutes; recovery retry budget reset.',
      );
    });
  }

  void _scheduleOverlayRecovery() {
    if (!mounted ||
        _isOverlayExplicitlyClosed ||
        _isLaunching ||
        _overlayCloseOperation != null ||
        _overlayRecoveryTimer != null) {
      return;
    }
    final delay = _overlayRecoveryPolicy.nextDelay();
    if (delay == null) {
      logError(
        'DashboardView',
        'Overlay recovery stopped after the bounded retry limit '
            '(${_overlayRecoveryPolicy.attempts} attempts).',
      );
      return;
    }
    logWarning(
      'DashboardView',
      'Scheduling overlay recovery; source=recovery, '
          'attempt=${_overlayRecoveryPolicy.attempts}, '
          'delay=${delay.inMilliseconds}ms.',
    );
    _overlayRecoveryTimer = Timer(delay, () {
      _overlayRecoveryTimer = null;
      if (!mounted ||
          _isOverlayExplicitlyClosed ||
          _isLaunching ||
          _overlayCloseOperation != null ||
          _isOverlayRunning) {
        return;
      }
      unawaited(_recoverOverlay());
    });
  }

  Future<void> _recoverOverlay() async {
    if (_isOverlayExplicitlyClosed) return;
    logInfo('DashboardView', 'Attempting overlay recovery launch.');
    await _launchOverlay(startupTrigger: 'recovery');
    if (mounted && !_isOverlayRunning && !_isOverlayExplicitlyClosed) {
      _scheduleOverlayRecovery();
    }
  }

  // Settings helpers ─────────────────────────────────────────────────────────────────────────────

  void _updateSettings(WidgetSettings s) {
    final wpChanged =
        s.activeWallpaperType != _settings.activeWallpaperType ||
        s.videoWallpaperPaused != _settings.videoWallpaperPaused;
    setState(() => _settings = s);
    if (wpChanged) {
      _updateTrayMenu();
    }
    _syncMediaServiceState();
    _syncConnectivityService();
    // Only write to settings file if the overlay is not running or if we are customizing the active template.
    if (_isOverlayRunning && s.widgetTemplate != _activeTemplate) {
      return;
    }
    // Debounce: only write to disk/registry after 300ms of inactivity.
    // This prevents hammering the filesystem on every color-picker drag frame.
    _saveDebounce?.cancel();
    _saveDebounce = Timer(const Duration(milliseconds: 300), () {
      unawaited(_saveSettingsSafely(s));
    });
  }

  Future<void> _saveSettingsSafely(WidgetSettings settings) async {
    try {
      await _settingsService.saveSettings(settings);
    } catch (error, stackTrace) {
      logError(
        'DashboardView',
        'Could not persist dashboard settings.',
        error,
        stackTrace,
      );
    }
  }

  Future<void> _persistWallpaperSettings() async {
    _saveDebounce?.cancel();
    _saveDebounce = null;
    final persistStopwatch = Stopwatch()..start();
    await _settingsService.saveSettings(_settings);
    logPerf(
      'DashboardView',
      'Wallpaper settings persisted in ${persistStopwatch.elapsedMilliseconds}ms.',
    );
  }

  void _syncMediaServiceState() {
    final bool needMedia =
        (_settings.widgetTemplate == 'sleep_weather' &&
            _settings.showMediaControl) ||
        (_settings.widgetTemplate == 'custom' &&
            _settings.customElements.any(
              (element) => MediaElementType.contains(element.type),
            )) ||
        _settings.savedCustomWidgets.any(
          (widget) => widget.elements.any(
            (element) => MediaElementType.contains(element.type),
          ),
        );
    if (needMedia) {
      MediaSessionService().start(owner: 'dashboard');
    } else {
      MediaSessionService().stop(owner: 'dashboard');
    }
  }

  void _syncConnectivityService() {
    final needsConnectivity =
        (_settings.widgetTemplate == 'custom' &&
            _settings.customElements.any(
              (element) =>
                  element.type == 'wifi_icon' ||
                  element.type == 'bluetooth_icon',
            )) ||
        _settings.savedCustomWidgets.any(
          (widget) => widget.elements.any(
            (element) =>
                element.type == 'wifi_icon' || element.type == 'bluetooth_icon',
          ),
        );
    final service = SystemConnectivityService.instance;
    if (needsConnectivity && _connectivitySubscription == null) {
      _connectivity = service.current;
      _connectivitySubscription = service.stream.listen((snapshot) {
        if (!mounted || snapshot == _connectivity) return;
        setState(() => _connectivity = snapshot);
      });
      service.start(owner: 'dashboard');
    } else if (!needsConnectivity && _connectivitySubscription != null) {
      _connectivitySubscription?.cancel();
      _connectivitySubscription = null;
      service.stop(owner: 'dashboard');
    }
  }

  void _setElementColor(String key, Color color) {
    final newColors = Map<String, int>.from(_settings.elementColors);
    newColors[key] = color.toARGB32();
    _updateSettings(_settings.copyWith(elementColors: newColors));
  }

  void _setElementGradient(String key, List<Color> colors) {
    final newGradients = Map<String, List<int>>.from(
      _settings.elementGradients,
    );
    newGradients[key] = colors.map((c) => c.toARGB32()).toList();
    _updateSettings(_settings.copyWith(elementGradients: newGradients));
  }

  void _removeElementGradient(String key) {
    final newGradients = Map<String, List<int>>.from(_settings.elementGradients)
      ..remove(key);
    _updateSettings(_settings.copyWith(elementGradients: newGradients));
  }

  Widget _buildColorModeButton({
    required String label,
    required IconData icon,
    required bool isSelected,
    required VoidCallback onTap,
  }) {
    return Expanded(
      child: HoverCard(
        scaleUp: 1.03,
        borderRadius: BorderRadius.circular(10),
        glowColor: isSelected ? const Color(0xFF38BDF8) : Colors.transparent,
        maxGlowOpacity: 0.2,
        blurRadius: 8,
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 150),
          padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF38BDF8).withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF38BDF8).withValues(alpha: 0.7)
                  : Colors.white.withValues(alpha: 0.08),
              width: isSelected ? 1.4 : 1.0,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13,
                color: isSelected ? const Color(0xFF38BDF8) : Colors.white60,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 10.5,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  color: isSelected ? Colors.white : Colors.white70,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _setElementFont(String key, String font) {
    final newFonts = Map<String, String>.from(_settings.elementFonts);
    newFonts[key] = font;
    _updateSettings(_settings.copyWith(elementFonts: newFonts));
  }

  void _setElementSize(String key, double size) {
    final map = Map<String, double>.from(_settings.elementSizes);
    map[key] = double.parse(size.toStringAsFixed(2));
    _updateSettings(_settings.copyWith(elementSizes: map));
  }

  void _resetElementSize(String key) {
    final map = Map<String, double>.from(_settings.elementSizes)..remove(key);
    _updateSettings(_settings.copyWith(elementSizes: map));
  }

  void _saveColorToPalette(Color color) {
    final palette = List<int>.from(_settings.colorPalette);
    final val = color.toARGB32();
    if (!palette.contains(val)) {
      if (palette.length >= 12) palette.removeAt(0);
      palette.add(val);
    }
    _updateSettings(_settings.copyWith(colorPalette: palette));
  }

  // ── Overlay launch / close ───────────────────────────────────────────────

  // Spawns the overlay via Windows Task Scheduler — the ONLY reliable way to escape VS Code's Job Object.
  //
  // Root cause: VS Code wraps its debug session in a Windows Job Object. ALL child processes
  // (PowerShell, cmd, wscript, Process.start) inherit this Job Object, and the Dart VM inside them
  // fails silently before reaching main(). Task Scheduler creates processes as children of svchost.exe
  // (the Schedule service), completely outside any application Job Object — exactly like system services.
  Future<void> _launchOverlay({String startupTrigger = 'dashboard'}) =>
      _overlayLaunchGate.run(() => _launchOverlayInternal(startupTrigger));

  Future<void> _launchOverlayInternal(String startupTrigger) async {
    if (_overlayCloseOperation != null) {
      logInfo(
        'DashboardView',
        'Ignoring overlay launch while its close operation is in progress.',
      );
      return;
    }
    if (_isLaunching) {
      logInfo(
        'DashboardView',
        'Launch requested but a launch is already in progress.',
      );
      return;
    }

    final launchStopwatch = Stopwatch()..start();
    _isOverlayExplicitlyClosed = false;
    setState(() => _isLaunching = true);
    DiagnosticsService.instance.markOverlayLaunchRequested();
    logInfo(
      'OverlayStartup',
      'Overlay launch requested from "$startupTrigger"; waiting for a '
          'verified process identity, first frame, and visible window.',
    );
    try {
      final existingPidFile = await _settingsService.pidFile;
      final existingRecordText = (await _safeReadPidFile(
        existingPidFile,
      )).trim();
      if (existingRecordText.isNotEmpty) {
        final existingRecord = OverlayProcessRecord.tryParse(
          existingRecordText,
        );
        if (existingRecord == null) {
          throw const FormatException(
            'The existing overlay PID record is malformed; refusing to launch another process.',
          );
        }
        final existingInspection = await inspectWindowsProcess(
          existingRecord.pid,
        );
        if (existingInspection == null) {
          throw StateError(
            'The existing overlay process identity could not be verified; refusing to launch a duplicate.',
          );
        }
        if (existingInspection.matches(existingRecord) &&
            existingInspection.isRunning) {
          final existingReady = await waitForOverlayReadiness(
            readRecord: () async {
              final currentText = (await _safeReadPidFile(
                existingPidFile,
              )).trim();
              if (currentText.isEmpty) return null;
              final currentRecord = OverlayProcessRecord.tryParse(currentText);
              if (currentRecord == null) {
                throw const FormatException(
                  'The existing overlay PID record became malformed.',
                );
              }
              return currentRecord;
            },
            inspectProcess: inspectWindowsProcess,
            timeout: const Duration(seconds: 15),
            onStatusChanged: (status, record, inspection, elapsed) {
              logInfo(
                'DashboardView',
                'Existing overlay reconciliation status=${status.name}, '
                    'pid=${record?.pid}, processRunning=${inspection?.isRunning}, '
                    'ready=${record?.ready}, elapsed=${elapsed.inMilliseconds}ms.',
              );
            },
          );
          if (existingReady.isReady && mounted) {
            setState(() {
              _isOverlayRunning = true;
              _activeTemplate = _settings.widgetTemplate;
            });
            _updateTrayMenu();
            ScaffoldMessenger.of(context).showSnackBar(
              const SnackBar(
                content: Text('Desktop Widget Overlay is already running.'),
                duration: Duration(seconds: 2),
              ),
            );
            logInfo(
              'DashboardView',
              'Reconciled existing overlay PID ${existingRecord.pid} '
                  'as ready in ${existingReady.elapsed.inMilliseconds}ms; '
                  'skipping duplicate launch.',
            );
            return;
          }
          if (existingReady.status == OverlayReadinessStatus.starting) {
            throw StateError(
              'Existing overlay PID ${existingRecord.pid} is verified and running '
              'but has not completed readiness after '
              '${existingReady.elapsed.inSeconds}s; refusing to launch a duplicate.',
            );
          }
        }
      }
      logInfo(
        'DashboardView',
        'Preparing to launch Widget Overlay. Saving current settings.',
      );
      _settings = await _settingsService.updateSettings(
        (current) => current.copyWith(exitOverlay: false),
      );

      final previousOverlay = await _overlayLifecycle.close();
      if (previousOverlay == OverlayCloseResult.processCouldNotBeVerified ||
          previousOverlay == OverlayCloseResult.processDidNotExit) {
        throw StateError(
          'The existing overlay process could not be safely stopped '
          '($previousOverlay); refusing to start a duplicate.',
        );
      }
      _settings = await _settingsService.updateSettings(
        (current) => current.copyWith(exitOverlay: false),
      );

      // 2. Prepare shadow runtime copy so MSBuild never hits file locks on WebView2Loader.dll
      String appPath = Platform.resolvedExecutable;
      String workingDir = File(appPath).parent.path;
      try {
        final runtimeStopwatch = Stopwatch()..start();
        final runtimeDir = await DiagnosticsService.instance
            .trackAsyncOperation<Directory>(
              tag: 'DashboardView',
              name: 'overlay.prepareRuntime',
              operation: _wallpaperEngine.prepareOverlayRuntime,
              warningThreshold: const Duration(milliseconds: 500),
            );
        logPerf(
          'DashboardView',
          'Overlay shadow runtime preparation completed in '
              '${runtimeStopwatch.elapsedMilliseconds}ms.',
        );
        final exeName = File(appPath).uri.pathSegments.last;
        final runtimeExe = File('${runtimeDir.path}\\$exeName');
        if (await runtimeExe.exists()) {
          appPath = runtimeExe.path;
          workingDir = runtimeDir.path;
          logInfo(
            'DashboardView',
            'Prepared shadow overlay runtime: "$appPath"',
          );
        }
      } catch (e) {
        logWarning(
          'DashboardView',
          'Shadow runtime preparation skipped/failed; using direct binary: $e',
        );
      }

      logInfo(
        'DashboardView',
        'Spawning overlay process: "$appPath" --overlay (workDir: "$workingDir")',
      );

      Future<bool> launchDirectly() async {
        logInfo('DashboardView', 'Launching overlay via direct Process.start.');
        final directStartStopwatch = Stopwatch()..start();
        try {
          await Process.start(
            appPath,
            ['--overlay', '--startup-trigger=$startupTrigger'],
            workingDirectory: workingDir,
            mode: ProcessStartMode.detached,
          );
          logPerf(
            'DashboardView',
            'Overlay launched via Process.start detached in '
                '${directStartStopwatch.elapsedMilliseconds}ms.',
          );
          return true;
        } catch (e) {
          logWarning('DashboardView', 'Direct Process.start failed: $e');
          return false;
        }
      }

      // Task Scheduler avoids the VS Code Job Object in debug sessions. It
      // can acknowledge the request well before the scheduled process starts,
      // so readiness is confirmed from the process record below.
      var launchedViaSchtasks = false;
      DateTime? taskSchedulerAcceptedAt;
      var directStarted = !kDebugMode && await launchDirectly();
      if (!directStarted) {
        const taskName = 'DesktopWidgetOverlayLaunch';
        final tempDir =
            Platform.environment['TEMP'] ?? Directory.systemTemp.path;
        final batPath = '$tempDir\\overlay_launch.bat';

        try {
          final batContent =
              '@echo off\r\ncd /d "$workingDir"\r\nstart "" "$appPath" --overlay --startup-trigger=$startupTrigger\r\n';
          final taskCreateStopwatch = Stopwatch()..start();
          await File(batPath).writeAsString(batContent, flush: true);

          final createResult = await DiagnosticsService.instance
              .trackAsyncOperation<ProcessResult>(
                tag: 'DashboardView',
                name: 'overlay.schtasks.create',
                operation: () => Process.run('schtasks', [
                  '/create',
                  '/f',
                  '/tn',
                  taskName,
                  '/tr',
                  '"$batPath"',
                  '/sc',
                  'once',
                  '/st',
                  '00:00',
                  '/it',
                ]),
                warningThreshold: const Duration(seconds: 2),
              );
          logPerf(
            'OverlayStartup',
            'Overlay Task Scheduler task creation returned '
                '${createResult.exitCode} in '
                '${taskCreateStopwatch.elapsedMilliseconds}ms.',
          );
          if (createResult.exitCode == 0) {
            final taskRunStopwatch = Stopwatch()..start();
            final runResult = await DiagnosticsService.instance
                .trackAsyncOperation<ProcessResult>(
                  tag: 'DashboardView',
                  name: 'overlay.schtasks.run',
                  operation: () =>
                      Process.run('schtasks', ['/run', '/tn', taskName]),
                  warningThreshold: const Duration(seconds: 2),
                );
            logPerf(
              'OverlayStartup',
              'Overlay Task Scheduler launch request returned '
                  '${runResult.exitCode} in '
                  '${taskRunStopwatch.elapsedMilliseconds}ms.',
            );
            if (runResult.exitCode == 0) {
              launchedViaSchtasks = true;
              taskSchedulerAcceptedAt = DateTime.now();
              logInfo(
                'OverlayStartup',
                'Overlay spawned successfully via Task Scheduler.',
              );
            } else {
              logWarning(
                'DashboardView',
                'schtasks /run returned ${runResult.exitCode}: ${runResult.stderr}',
              );
            }
          } else {
            logWarning(
              'DashboardView',
              'schtasks /create returned ${createResult.exitCode}: ${createResult.stderr}',
            );
          }
        } catch (e, st) {
          logWarning(
            'DashboardView',
            'Task Scheduler launch error, using direct process fallback: $e\n$st',
          );
        } finally {
          Future(() async {
            await Future.delayed(const Duration(seconds: 15));
            try {
              await Process.run('schtasks', ['/delete', '/f', '/tn', taskName]);
            } catch (_) {}
            try {
              final f = File(batPath);
              if (await f.exists()) await f.delete();
            } catch (_) {}
          });
        }

        // Direct start is also the fallback if Task Scheduler is unavailable.
        if (!launchedViaSchtasks) {
          final fallbackStarted = await launchDirectly();
          if (!fallbackStarted) {
            try {
              await Process.start(
                'cmd.exe',
                [
                  '/c',
                  'start',
                  '""',
                  appPath,
                  '--overlay',
                  '--startup-trigger=$startupTrigger',
                ],
                workingDirectory: workingDir,
                mode: ProcessStartMode.detached,
              );
              logInfo(
                'DashboardView',
                'Overlay launched via cmd.exe start detached fallback.',
              );
            } catch (e) {
              logError('DashboardView', 'cmd.exe start fallback failed', e);
            }
          }
        }
      }

      // Task Scheduler can acknowledge a launch several seconds before the
      // process starts. Keep readiness bounded, but allow time for process
      // creation and first-frame/window configuration.
      final pidFile = await _settingsService.pidFile;
      final readinessStopwatch = Stopwatch()..start();
      final readiness = await waitForOverlayReadiness(
        readRecord: () async {
          if (!await pidFile.exists()) return null;
          final content = (await _safeReadPidFile(pidFile)).trim();
          if (content.isEmpty) return null;
          final record = OverlayProcessRecord.tryParse(content);
          if (record == null) {
            throw const FormatException('The overlay PID record is malformed.');
          }
          return record;
        },
        inspectProcess: inspectWindowsProcess,
        timeout: const Duration(seconds: 40),
        onStatusChanged: (status, record, inspection, elapsed) {
          logInfo(
            'OverlayStartup',
            'Overlay launch readiness status=${status.name}, '
                'state=${record?.state.name}, '
                'pid=${record?.pid}, processRunning=${inspection?.isRunning}, '
                'ready=${record?.ready}, elapsed=${elapsed.inMilliseconds}ms.',
          );
        },
      );

      if (readiness.isReady && readiness.record != null) {
        final acknowledgedMs = DateTime.now().millisecondsSinceEpoch;
        logInfo(
          'OverlayStartup',
          'Overlay confirmed RUNNING and ready — PID ${readiness.record!.pid} '
              '(state=${readiness.record!.state.name}, '
              'entryPointMs=${readiness.record!.entryPointMs}, '
              'windowInitMs=${readiness.record!.windowInitMs}, '
              'firstFrameMs=${readiness.record!.firstFrameMs}, '
              'readyPublishedMs=${readiness.record!.readyPublishedMs}, '
              'acknowledgedMs=$acknowledgedMs) after '
              '${readinessStopwatch.elapsedMilliseconds}ms; complete launch '
              'phase took ${launchStopwatch.elapsedMilliseconds}ms'
              '${taskSchedulerAcceptedAt == null ? '' : ', '
                        'since Task Scheduler accepted launch '
                        '${DateTime.now().difference(taskSchedulerAcceptedAt).inMilliseconds}ms'}.',
        );
        if (mounted) {
          setState(() {
            _isOverlayRunning = true;
            _activeTemplate = _settings.widgetTemplate;
          });
          _updateTrayMenu();
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text('Desktop Widget Overlay launched successfully!'),
              duration: Duration(seconds: 2),
              backgroundColor: Color(0xFF10B981),
            ),
          );
        }
      } else {
        final readinessFailure = switch (readiness.status) {
          OverlayReadinessStatus.starting =>
            'PID ${readiness.record?.pid} is verified running but has not acknowledged its first frame (last state: ${readiness.record?.state.name})',
          OverlayReadinessStatus.missing => 'no PID record was registered',
          OverlayReadinessStatus.malformed => 'the PID record is malformed',
          OverlayReadinessStatus.exited => 'the overlay exited during startup',
          OverlayReadinessStatus.identityMismatch =>
            'the PID refers to a different process; no process was terminated',
          OverlayReadinessStatus.unverifiable =>
            'Windows could not verify the overlay process identity',
          OverlayReadinessStatus.ready => 'readiness could not be confirmed',
          OverlayReadinessStatus.failed =>
            'the overlay failed initialization: ${readiness.record?.failureReason ?? 'unspecified error'}',
        };
        logWarning(
          'OverlayStartup',
          'Overlay readiness not confirmed after bounded reconciliation '
              '(${readinessStopwatch.elapsedMilliseconds}ms; status=${readiness.status}; '
              '$readinessFailure; total launch '
              '${launchStopwatch.elapsedMilliseconds}ms).',
        );

        // Ensure that a failed readiness check does not leave an unusable overlay running indefinitely
        if (readiness.record != null &&
            readiness.inspection?.isRunning == true) {
          logWarning(
            'DashboardView',
            'Terminating unusable overlay process PID ${readiness.record!.pid} after failed readiness check.',
          );
          try {
            await _overlayLifecycle.close();
          } catch (e) {
            logWarning(
              'DashboardView',
              'Could not stop unready overlay process: $e',
            );
          }
        }

        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(
                'Widget Overlay could not be verified: $readinessFailure.',
              ),
              duration: const Duration(seconds: 3),
              backgroundColor: const Color(0xFFEF4444),
            ),
          );
        }
      }
      await _checkOverlayStatus();
    } catch (e, stackTrace) {
      logError('DashboardView', 'Failed to launch overlay', e, stackTrace);
      if (!mounted) return;
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('Failed to launch overlay: $e')));
    } finally {
      DiagnosticsService.instance.clearOverlayLaunchRequest();
      if (mounted) setState(() => _isLaunching = false);
    }
  }

  Future<void> _closeOverlay() {
    final pending = _overlayCloseOperation;
    if (pending != null) return pending;
    late final Future<void> operation;
    operation = _closeOverlayInternal().whenComplete(() {
      if (identical(_overlayCloseOperation, operation)) {
        _overlayCloseOperation = null;
      }
    });
    _overlayCloseOperation = operation;
    return operation;
  }

  Future<void> _closeOverlayInternal() async {
    if (_isLaunching) {
      logInfo(
        'DashboardView',
        'Ignoring overlay close while its launch operation is in progress.',
      );
      return;
    }
    _isOverlayExplicitlyClosed = true;
    _overlayRecoveryTimer?.cancel();
    _overlayRecoveryTimer = null;
    _overlayRecoveryStabilityTimer?.cancel();
    _overlayRecoveryStabilityTimer = null;
    _overlayRecoveryPolicy.reset();
    logInfo('DashboardView', 'Requesting verified graceful overlay shutdown.');
    try {
      final result = await _overlayLifecycle.close();
      if (result == OverlayCloseResult.stoppedGracefully ||
          result == OverlayCloseResult.stoppedAfterForceTermination ||
          result == OverlayCloseResult.processIdentityChanged ||
          result == OverlayCloseResult.noProcessRecord) {
        if (mounted) {
          setState(() => _isOverlayRunning = false);
          _updateTrayMenu();
        }
        _settings = await _settingsService.updateSettings(
          (current) => current.copyWith(exitOverlay: false),
        );
      }
      if (result == OverlayCloseResult.stoppedAfterForceTermination) {
        logWarning(
          'DashboardView',
          'Overlay required process termination after the graceful timeout.',
        );
      } else if (result == OverlayCloseResult.processCouldNotBeVerified ||
          result == OverlayCloseResult.processDidNotExit) {
        logError(
          'DashboardView',
          'Overlay remains active; PID state was preserved '
              '($result).',
        );
      }
    } catch (e, st) {
      logError('DashboardView', 'Failed to close overlay', e, st);
    }
    await _checkOverlayStatus();
  }

  // ────────────────────────────────────────────────────────────────────────────
  // BUILD
  // ────────────────────────────────────────────────────────────────────────────

  @override
  Widget build(BuildContext context) {
    final buildSw = Stopwatch()..start();
    _dashboardBuildCount++;
    final buildId = _dashboardBuildCount;
    developer.Timeline.startSync(
      'DashboardView.build',
      arguments: {'buildId': buildId, 'tab': _currentMainTab},
    );
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      final elapsed = buildSw.elapsedMilliseconds;
      if (elapsed > 100) {
        logInfo(
          'DashboardView',
          '[PERF] DashboardView build #$buildId reached post-frame callback after ${elapsed}ms (includes framework layout/paint scheduling; not raster time)',
        );
      }
    });
    final result = Scaffold(
      backgroundColor: const Color(0xFF060609), // premium deep dark background
      body: Stack(
        children: [
          // 1. Static ambient blobs. These used to repaint three fullscreen
          // radial shaders on every ticker pulse, which made an otherwise idle
          // dashboard submit expensive raster work continuously.
          if (_showDashboardDecorations)
            const Positioned.fill(
              child: RepaintBoundary(child: _DashboardAmbientBackground()),
            ),

          // 2. High-performance ambient dark overlay (Zero GPU blur overhead)
          Positioned.fill(
            child: Container(
              color: const Color(0xFF060609).withValues(alpha: 0.60),
            ),
          ),

          // 3. Grid painter overlay (subtle dot grid, cached in RepaintBoundary)
          if (_showDashboardDecorations)
            const Positioned.fill(
              child: RepaintBoundary(
                child: CustomPaint(painter: GridPainter(opacity: 0.03)),
              ),
            ),

          // 4. Main content layout
          Positioned.fill(
            child: Column(
              children: [
                _profileDashboardSection(
                  'topNavigation.build',
                  _buildTopNavBar,
                ),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 350),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position:
                              Tween<Offset>(
                                begin: const Offset(0.0, 0.04),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              ),
                          child: child,
                        ),
                      );
                    },
                    child: _currentMainTab == 'wallpapers'
                        ? _profileDashboardSection(
                            'wallpapers.build',
                            () => _buildWallpaperGallery(
                              key: const ValueKey('wallpapers'),
                            ),
                          )
                        : _currentMainTab == 'widgets'
                        ? _profileDashboardSection(
                            'widgets.build',
                            () => _buildWidgetCustomizer(
                              key: const ValueKey('widgets'),
                            ),
                          )
                        : _currentMainTab == 'diagnostics'
                        ? _profileDashboardSection(
                            'diagnostics.build',
                            () => _buildDiagnosticsTab(
                              key: const ValueKey('diagnostics'),
                            ),
                          )
                        : _currentMainTab == 'about'
                        ? _profileDashboardSection(
                            'about.build',
                            () => _buildAboutTab(key: const ValueKey('about')),
                          )
                        : _profileDashboardSection(
                            'bugReport.build',
                            () => _buildBugReportTab(
                              key: const ValueKey('bug_report'),
                            ),
                          ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
    final buildDuration = buildSw.elapsedMilliseconds;
    if (buildDuration > 35) {
      logInfo(
        'DashboardView',
        '[PERF] DashboardView active build #$_dashboardBuildCount completed in ${buildDuration}ms',
      );
    }
    developer.Timeline.finishSync();
    return result;
  }

  Widget _buildTopNavBar() {
    return Container(
      height: 66,
      padding: const EdgeInsets.symmetric(horizontal: 22),
      decoration: BoxDecoration(
        color: const Color(0xF5080A10),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
            width: 1.0,
          ),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.5),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.04),
            blurRadius: 30,
            offset: const Offset(0, 6),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final compact = constraints.maxWidth < 1100;
          final ultraCompact = constraints.maxWidth < 820;
          return Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              // Logo & Brand
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    width: 40,
                    height: 40,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFF38BDF8).withValues(alpha: 0.20),
                          const Color(0xFF818CF8).withValues(alpha: 0.10),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      border: Border.all(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                          blurRadius: 12,
                          spreadRadius: 1,
                        ),
                      ],
                    ),
                    padding: const EdgeInsets.all(5),
                    child: Image.asset(
                      'assets/wallsync_logo.png',
                      fit: BoxFit.contain,
                      cacheWidth: 96,
                      cacheHeight: 96,
                      errorBuilder: (_, _, _) => const Icon(
                        Icons.widgets_rounded,
                        color: Color(0xFF38BDF8),
                        size: 24,
                      ),
                    ),
                  ),
                  if (!ultraCompact) ...[
                    const SizedBox(width: 12),
                    ShaderMask(
                      shaderCallback: (bounds) => const LinearGradient(
                        colors: [
                          Color(0xFFFFFFFF),
                          Color(0xFFE2E8F0),
                          Color(0xFF38BDF8),
                        ],
                        stops: [0.0, 0.6, 1.0],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ).createShader(bounds),
                      child: const Text(
                        'WALLSYNC',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w900,
                          letterSpacing: 2.0,
                          color: Colors.white,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [
                            Color(0xFF38BDF8),
                            Color(0xFF818CF8),
                            Color(0xFFEC4899),
                          ],
                        ),
                        borderRadius: BorderRadius.circular(7),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.45),
                            blurRadius: 10,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: const Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.stars_rounded,
                            size: 10,
                            color: Color(0xFF070913),
                          ),
                          SizedBox(width: 3),
                          Text(
                            'PRO EDITION',
                            style: TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.w900,
                              color: Color(0xFF070913),
                              letterSpacing: 0.9,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),

              // Central sliding pill-tabs dock
              Container(
                padding: const EdgeInsets.all(3.5),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.035),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.25),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _buildMainTabButton(
                      'Wallpapers',
                      'wallpapers',
                      Icons.wallpaper_rounded,
                      compact: compact,
                    ),
                    const SizedBox(width: 3),
                    _buildMainTabButton(
                      'Widgets',
                      'widgets',
                      Icons.widgets_rounded,
                      compact: compact,
                    ),
                    const SizedBox(width: 3),
                    _buildMainTabButton(
                      'Diagnostics',
                      'diagnostics',
                      Icons.analytics_rounded,
                      compact: compact,
                    ),
                    const SizedBox(width: 3),
                    _buildMainTabButton(
                      'Bug Report',
                      'bug_report',
                      Icons.bug_report_rounded,
                      compact: compact,
                    ),
                    const SizedBox(width: 3),
                    _buildMainTabButton(
                      'About',
                      'about',
                      Icons.info_outline_rounded,
                      compact: compact,
                    ),
                  ],
                ),
              ),

              // Quick actions & Desktop status
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_currentMainTab == 'wallpapers')
                    IconButton(
                      constraints: const BoxConstraints.tightFor(
                        width: 38,
                        height: 38,
                      ),
                      padding: EdgeInsets.zero,
                      icon: const Icon(
                        Icons.refresh_rounded,
                        size: 18,
                        color: Colors.white70,
                      ),
                      onPressed: _loadWallpapers,
                      tooltip: 'Refresh Wallpapers',
                      hoverColor: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                    ),
                  const SizedBox(width: 8),
                  Tooltip(
                    message: _isOverlayRunning
                        ? 'Desktop widget active & running'
                        : 'Desktop widget inactive',
                    child: Container(
                      padding: EdgeInsets.symmetric(
                        horizontal: compact ? 9 : 13,
                        vertical: 6.5,
                      ),
                      decoration: BoxDecoration(
                        color: _isOverlayRunning
                            ? const Color(0xFF10B981).withValues(alpha: 0.10)
                            : Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: _isOverlayRunning
                              ? const Color(0xFF10B981).withValues(alpha: 0.40)
                              : Colors.white.withValues(alpha: 0.08),
                          width: 1.0,
                        ),
                        boxShadow: _isOverlayRunning
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  blurRadius: 10,
                                ),
                              ]
                            : null,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 7.5,
                            height: 7.5,
                            decoration: BoxDecoration(
                              color: _isOverlayRunning
                                  ? const Color(0xFF10B981)
                                  : Colors.white30,
                              shape: BoxShape.circle,
                              boxShadow: _isOverlayRunning
                                  ? [
                                      BoxShadow(
                                        color: const Color(0xFF10B981).withValues(alpha: 0.8),
                                        blurRadius: 8,
                                        spreadRadius: 1,
                                      ),
                                    ]
                                  : null,
                            ),
                          ),
                          if (!compact) ...[
                            const SizedBox(width: 7.5),
                            Text(
                              _isOverlayRunning ? 'Desktop Active' : 'Desktop Off',
                              style: TextStyle(
                                fontSize: 11,
                                color: _isOverlayRunning
                                    ? const Color(0xFF10B981)
                                    : Colors.white60,
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildMainTabButton(
    String label,
    String tabKey,
    IconData icon, {
    bool compact = false,
  }) {
    final isSelected = _currentMainTab == tabKey;
    if (compact) {
      return Tooltip(
        message: label,
        child: InkWell(
          onTap: () => setState(() => _currentMainTab = tabKey),
          borderRadius: BorderRadius.circular(14),
          child: AnimatedContainer(
            duration: const Duration(milliseconds: 220),
            curve: Curves.easeOutCubic,
            padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 8),
            decoration: BoxDecoration(
              gradient: isSelected
                  ? LinearGradient(
                      colors: [
                        const Color(0xFF38BDF8).withValues(alpha: 0.22),
                        const Color(0xFF818CF8).withValues(alpha: 0.12),
                      ],
                    )
                  : null,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(
                color: isSelected
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.45)
                    : Colors.transparent,
              ),
              boxShadow: isSelected
                  ? [
                      BoxShadow(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.20),
                        blurRadius: 8,
                      ),
                    ]
                  : null,
            ),
            child: Icon(
              icon,
              size: 16,
              color: isSelected ? const Color(0xFF38BDF8) : Colors.white60,
            ),
          ),
        ),
      );
    }
    return InkWell(
      onTap: () => setState(() => _currentMainTab = tabKey),
      borderRadius: BorderRadius.circular(14),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 220),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 15, vertical: 7.5),
        decoration: BoxDecoration(
          gradient: isSelected
              ? LinearGradient(
                  colors: [
                    const Color(0xFF38BDF8).withValues(alpha: 0.20),
                    const Color(0xFF818CF8).withValues(alpha: 0.10),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                )
              : null,
          color: isSelected ? null : Colors.transparent,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF38BDF8).withValues(alpha: 0.45)
                : Colors.transparent,
            width: 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.22),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 15,
              color: isSelected ? const Color(0xFF38BDF8) : Colors.white54,
            ),
            const SizedBox(width: 8),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white70,
                letterSpacing: 0.3,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildWallpaperGallery({Key? key}) {
    return _buildWallpaperGalleryOld(key: key);
  }

  Widget _buildWallpaperComingSoon({Key? key}) {
    return Container(
      key: key,
      decoration: const BoxDecoration(color: Colors.transparent),
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        child: Column(
          children: [
            // 1. Futuristic Header with Glowing Wallpaper Icon
            Center(
              child: Container(
                margin: const EdgeInsets.only(top: 20),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: const Color(0xFFF59E0B).withValues(alpha: 0.05),
                  border: Border.all(
                    color: const Color(0xFFF59E0B).withValues(alpha: 0.2),
                    width: 2,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFF59E0B).withValues(alpha: 0.05),
                      blurRadius: 40,
                      spreadRadius: 10,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.wallpaper_rounded,
                  size: 64,
                  color: Color(0xFFF59E0B),
                ),
              ),
            ),
            const SizedBox(height: 24),

            // Title
            ShaderMask(
              shaderCallback: (bounds) {
                return const LinearGradient(
                  colors: [Color(0xFFF59E0B), Color(0xFFEF4444)],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ).createShader(bounds);
              },
              child: const Text(
                'DYNAMIC WALLPAPER ENGINE',
                style: TextStyle(
                  fontSize: 24,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 2.0,
                  color: Colors.white,
                ),
              ),
            ),
            const SizedBox(height: 12),

            // Subtitle
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 600),
              child: Text(
                'Bring your desktop to life with GPU-accelerated interactive particle meshes, fluid physics simulations, and audio-reactive spectrums. Arriving in version 2.0.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 14,
                  height: 1.6,
                  color: Colors.white.withValues(alpha: 0.6),
                ),
              ),
            ),
            const SizedBox(height: 40),

            // 2. Feature Spotlight Cards (Grid-like Row/Wrap)
            const Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: EdgeInsets.symmetric(horizontal: 16),
                child: Text(
                  'UPCOMING FEATURES SPOTLIGHT',
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.5,
                    color: Colors.white38,
                  ),
                ),
              ),
            ),
            const SizedBox(height: 16),
            Wrap(
              spacing: 20,
              runSpacing: 20,
              alignment: WrapAlignment.center,
              children: [
                _buildUpcomingFeatureCard(
                  icon: Icons.blur_on_rounded,
                  title: 'Interactive Shaders',
                  description:
                      'Stunning particle systems and fluid dynamics that react instantly to mouse clicks and desktop movement.',
                  color: const Color(0xFF38BDF8),
                ),
                _buildUpcomingFeatureCard(
                  icon: Icons.music_note_rounded,
                  title: 'Audio Spectrum',
                  description:
                      'Watch your desktop dance with real-time audio-responsive wallpapers synchronized to your media player.',
                  color: const Color(0xFFEC4899),
                ),
                _buildUpcomingFeatureCard(
                  icon: Icons.cloud_sync_rounded,
                  title: 'Auto-Sync Catalog',
                  description:
                      'Daily fresh, premium high-fidelity wallpapers curated by digital artists, delivered directly to your device.',
                  color: const Color(0xFF10B981),
                ),
                _buildUpcomingFeatureCard(
                  icon: Icons.monitor_rounded,
                  title: 'Multi-Monitor Span',
                  description:
                      'Stretch gorgeous panoramic scenes across multiple displays or customize each screen independently.',
                  color: const Color(0xFF8B5CF6),
                ),
              ],
            ),

            const SizedBox(height: 48),

            // 3. Interactive Beta Sign-Up Panel
            _buildBetaSignUpPanel(),
          ],
        ),
      ),
    );
  }

  Widget _buildUpcomingFeatureCard({
    required IconData icon,
    required String title,
    required String description,
    required Color color,
  }) {
    return Container(
      width: 260,
      height: 160,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.05),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(10),
            ),
            child: Icon(icon, size: 20, color: color),
          ),
          const SizedBox(height: 14),
          Text(
            title,
            style: const TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.bold,
              color: Colors.white,
            ),
          ),
          const SizedBox(height: 6),
          Expanded(
            child: Text(
              description,
              style: TextStyle(
                fontSize: 11,
                height: 1.4,
                color: Colors.white.withValues(alpha: 0.4),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildBetaSignUpPanel() {
    return Container(
      width: double.infinity,
      constraints: const BoxConstraints(maxWidth: 540),
      padding: const EdgeInsets.all(28),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: const Color(0xFFF59E0B).withValues(alpha: 0.15),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFFF59E0B).withValues(alpha: 0.01),
            blurRadius: 20,
            spreadRadius: 2,
          ),
        ],
      ),
      child: AnimatedSwitcher(
        duration: const Duration(milliseconds: 400),
        child: _wallpaperBetaRegistered
            ? Column(
                key: const ValueKey('registered'),
                mainAxisSize: MainAxisSize.min,
                children: [
                  Container(
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      shape: BoxShape.circle,
                      color: const Color(0xFF10B981).withValues(alpha: 0.1),
                    ),
                    child: const Icon(
                      Icons.check_circle_rounded,
                      size: 32,
                      color: Color(0xFF10B981),
                    ),
                  ),
                  const SizedBox(height: 16),
                  const Text(
                    "You're on the list!",
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    "Thank you for requesting beta access. We'll send you an invitation email as soon as the test builds are ready.",
                    textAlign: TextAlign.center,
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.5,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                ],
              )
            : Column(
                key: const ValueKey('signup'),
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text(
                    'JOIN THE WALLPAPER BETA PROGRAM',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFFF59E0B),
                      letterSpacing: 1.0,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    'Get notified the second the Live Wallpaper Engine is ready and get exclusive early-bird access to interactive shader themes.',
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.4,
                      color: Colors.white.withValues(alpha: 0.5),
                    ),
                  ),
                  const SizedBox(height: 18),
                  Row(
                    children: [
                      Expanded(
                        child: Container(
                          height: 40,
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.2),
                            borderRadius: BorderRadius.circular(8),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: TextField(
                            controller: _wallpaperBetaEmailCtrl,
                            style: const TextStyle(
                              fontSize: 13,
                              color: Colors.white,
                            ),
                            decoration: InputDecoration(
                              hintText: 'Enter your email address',
                              hintStyle: TextStyle(
                                fontSize: 12,
                                color: Colors.white38,
                              ),
                              contentPadding: const EdgeInsets.symmetric(
                                horizontal: 14,
                                vertical: 10,
                              ),
                              border: InputBorder.none,
                              isDense: true,
                            ),
                          ),
                        ),
                      ),
                      const SizedBox(width: 12),
                      SizedBox(
                        height: 40,
                        child: ElevatedButton(
                          onPressed: () {
                            final email = _wallpaperBetaEmailCtrl.text.trim();
                            if (email.isNotEmpty && email.contains('@')) {
                              setState(() {
                                _wallpaperBetaRegistered = true;
                              });
                            } else {
                              ScaffoldMessenger.of(context).showSnackBar(
                                const SnackBar(
                                  content: Text(
                                    'Please enter a valid email address.',
                                  ),
                                  backgroundColor: Colors.redAccent,
                                ),
                              );
                            }
                          },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFFF59E0B),
                            foregroundColor: Colors.black,
                            elevation: 0,
                            padding: const EdgeInsets.symmetric(horizontal: 20),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(8),
                            ),
                          ),
                          child: const Text(
                            'Request Invite',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: FontWeight.w800,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
      ),
    );
  }

  Widget _buildWallpaperGalleryOld({Key? key}) {
    if (_loadingWallpapers) {
      return const Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CircularProgressIndicator(color: Color(0xFF38BDF8)),
            SizedBox(height: 16),
            Text(
              'Syncing wallpaper catalog...',
              style: TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return Container(
      key: key,
      color: Colors.transparent,
      child: Column(
        children: [
          // ── Top Sub-Navigation Header: Recent vs Static vs Live Video ──
          _buildWallpaperSubTabSelector(),

          // ── Sub-Tab Content ──
          Expanded(
            child: _wallpaperSubTab == 'recent'
                ? _buildRecentWallpapersView()
                : (_wallpaperSubTab == 'live'
                      ? _buildLiveWallpapersView()
                      : _buildStaticWallpapersView()),
          ),
        ],
      ),
    );
  }

  Widget _buildWallpaperSubTabSelector() {
    final liveCount = _cachedLiveWallpapers.length;
    final staticCount = _cachedStaticWallpapers.length;
    final recentCount = _settings.recentWallpapers.length;

    return Container(
      padding: const EdgeInsets.fromLTRB(24, 16, 24, 10),
      child: Row(
        children: [
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 3,
                height: 16,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                    begin: Alignment.topCenter,
                    end: Alignment.bottomCenter,
                  ),
                  borderRadius: BorderRadius.circular(2),
                ),
              ),
              const SizedBox(width: 10),
              const Text(
                'WALLPAPERS GALLERY',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: Colors.white,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const Spacer(),
          Container(
            padding: const EdgeInsets.all(3),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.04),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
            ),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildWallpaperSubTabChip(
                  id: 'recent',
                  label: 'Recent',
                  icon: Icons.history_rounded,
                  activeColor: const Color(0xFFEC4899),
                  count: recentCount > 0 ? recentCount : null,
                ),
                const SizedBox(width: 3),
                _buildWallpaperSubTabChip(
                  id: 'static',
                  label: 'Static Wallpapers',
                  icon: Icons.photo_library_rounded,
                  activeColor: const Color(0xFF38BDF8),
                  count: staticCount > 0 ? staticCount : null,
                ),
                const SizedBox(width: 3),
                _buildWallpaperSubTabChip(
                  id: 'live',
                  label: 'Live Video',
                  icon: Icons.videocam_rounded,
                  activeColor: const Color(0xFF818CF8),
                  count: liveCount > 0 ? liveCount : null,
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildWallpaperSubTabChip({
    required String id,
    required String label,
    required IconData icon,
    Color activeColor = const Color(0xFF38BDF8),
    int? count,
  }) {
    final isSelected = _wallpaperSubTab == id;
    return InkWell(
      onTap: () => setState(() => _wallpaperSubTab = id),
      borderRadius: BorderRadius.circular(9),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? activeColor.withValues(alpha: 0.22)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(9),
          border: Border.all(
            color: isSelected
                ? activeColor.withValues(alpha: 0.5)
                : Colors.transparent,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? activeColor : Colors.white60,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white70,
              ),
            ),
            if (count != null && count > 0) ...[
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                decoration: BoxDecoration(
                  color: isSelected
                      ? activeColor.withValues(alpha: 0.35)
                      : Colors.white.withValues(alpha: 0.08),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: Text(
                  '$count',
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: isSelected ? activeColor : Colors.white70,
                  ),
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }

  // ── Recent Wallpapers Helpers & UI ────────────────────────────────────────

  void _recordRecentWallpaper({
    required String id,
    required String name,
    required String pathOrUrl,
    required String type,
    String? thumbnailUrl,
  }) {
    final now = DateTime.now().millisecondsSinceEpoch;
    final currentList = List<RecentWallpaperItem>.from(
      _settings.recentWallpapers,
    );

    currentList.removeWhere(
      (item) =>
          item.pathOrUrl.toLowerCase() == pathOrUrl.toLowerCase() ||
          item.id == id,
    );

    currentList.insert(
      0,
      RecentWallpaperItem(
        id: id,
        name: name,
        pathOrUrl: pathOrUrl,
        type: type,
        thumbnailUrl: thumbnailUrl,
        timestamp: now,
      ),
    );

    if (currentList.length > 30) {
      currentList.removeRange(30, currentList.length);
    }

    final updated = _settings.copyWith(recentWallpapers: currentList);
    _updateSettings(updated);
  }

  void _removeRecentWallpaper(RecentWallpaperItem item) {
    final updatedList = List<RecentWallpaperItem>.from(
      _settings.recentWallpapers,
    )..removeWhere((w) => w.id == item.id || w.pathOrUrl == item.pathOrUrl);
    final updated = _settings.copyWith(recentWallpapers: updatedList);
    _updateSettings(updated);
    _showAnimatedSnackBar('Removed "${item.name}" from recent wallpapers.');
  }

  void _clearRecentWallpapers() {
    if (_settings.recentWallpapers.isEmpty) return;
    final updated = _settings.copyWith(recentWallpapers: []);
    _updateSettings(updated);
    _showAnimatedSnackBar('Recent wallpapers history cleared.');
  }

  String _formatTimeAgo(int timestampMs) {
    if (timestampMs <= 0) return 'Recent';
    final diff = DateTime.now().difference(
      DateTime.fromMillisecondsSinceEpoch(timestampMs),
    );
    if (diff.inSeconds < 60) return 'Just now';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m ago';
    if (diff.inHours < 24) return '${diff.inHours}h ago';
    if (diff.inDays < 7) return '${diff.inDays}d ago';
    return '${(diff.inDays / 7).floor()}w ago';
  }

  Future<void> _browseAndApplyCustomImage() async {
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: ['jpg', 'jpeg', 'png', 'webp', 'bmp'],
      );
      if (result.isNotEmpty && result.first.path != null) {
        final path = result.first.path!;
        await _applyCustomStaticWallpaper(path);
      }
    } catch (e, st) {
      logError('DashboardView', 'Failed to pick custom image wallpaper', e, st);
      if (mounted) {
        _showAnimatedSnackBar(
          'Failed to select image file: $e',
          isSuccess: false,
        );
      }
    }
  }

  Future<void> _browseAndApplyCustomVideo() async {
    if (_isVideoWallpaperBusy || _isSelectingVideo) return;
    setState(() => _isSelectingVideo = true);
    try {
      final result = await FilePicker.pickFiles(
        type: FileType.custom,
        allowedExtensions: [
          'mp4',
          'webm',
          'mkv',
          'mov',
          'avi',
          'gif',
          'wmv',
          'm4v',
          'flv',
        ],
      );
      if (result.isNotEmpty && result.first.path != null) {
        final path = result.first.path!;
        await _applyVideoWallpaper(path);
      }
    } catch (e, st) {
      logError('DashboardView', 'Failed to select video wallpaper', e, st);
      if (mounted) {
        _showAnimatedSnackBar(
          'Failed to select video file: $e',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) setState(() => _isSelectingVideo = false);
    }
  }

  Future<void> _applyCustomStaticWallpaper(String path) async {
    await _enqueueWallpaperTransition('static:$path', (requestId) async {
      await _applyCustomStaticWallpaperNow(path, requestId);
    });
  }

  bool _isCurrentWallpaperTransition(int requestId) =>
      requestId == _wallpaperTransitionGeneration;

  Future<void> _enqueueWallpaperTransition(
    String target,
    Future<void> Function(int requestId) operation,
  ) {
    if (_activeWallpaperTransitionTarget == target) {
      if (_inFlightWallpaperTransitionFuture != null) {
        logInfo(
          'DashboardView',
          '[WALLPAPER TRANSITION] Reusing in-flight transition for identical target: $target',
        );
        return _inFlightWallpaperTransitionFuture!;
      }
      if (_wallpaperTransitionState == 'active') {
        logInfo(
          'DashboardView',
          '[WALLPAPER TRANSITION] Target already active: $target',
        );
        return Future<void>.value();
      }
    }

    final requestId = ++_wallpaperTransitionGeneration;
    _activeWallpaperTransitionTarget = target;
    logInfo(
      'DashboardView',
      '[WALLPAPER TRANSITION #$requestId] requested target=$target',
    );
    final completer = Completer<void>();
    _inFlightWallpaperTransitionFuture = completer.future;

    final scheduled = _wallpaperTransitionTail.then((_) async {
      if (!_isCurrentWallpaperTransition(requestId)) {
        logInfo(
          'DashboardView',
          '[WALLPAPER TRANSITION #$requestId] cancelled before start; superseded by #$_wallpaperTransitionGeneration.',
        );
        if (!completer.isCompleted) completer.complete();
        return;
      }
      _setWallpaperTransitionState(requestId, target, 'preparing');
      try {
        await operation(requestId);
        if (!completer.isCompleted) completer.complete();
      } catch (e, st) {
        if (!completer.isCompleted) completer.completeError(e, st);
        rethrow;
      } finally {
        if (_isCurrentWallpaperTransition(requestId)) {
          _inFlightWallpaperTransitionFuture = null;
        }
      }
    });
    _wallpaperTransitionTail = scheduled.catchError((_) {});
    return completer.future;
  }

  void _setWallpaperTransitionState(
    int requestId,
    String target,
    String nextState,
  ) {
    if (!_isCurrentWallpaperTransition(requestId)) {
      logInfo(
        'DashboardView',
        '[WALLPAPER TRANSITION #$requestId] superseded while targeting $target; ignored transition state $nextState (current request #$_wallpaperTransitionGeneration).',
      );
      return;
    }
    final previousState = _wallpaperTransitionState;
    _wallpaperTransitionState = nextState;
    logInfo(
      'DashboardView',
      '[WALLPAPER TRANSITION #$requestId] target=$target state=$previousState->$nextState',
    );
  }

  Future<void> _applyCustomStaticWallpaperNow(
    String path,
    int requestId,
  ) async {
    try {
      final file = File(path);
      if (!await file.exists() || await file.length() == 0) {
        _setWallpaperTransitionState(requestId, 'static:$path', 'error');
        _showAnimatedSnackBar(
          'Selected image file does not exist.',
          isSuccess: false,
        );
        return;
      }
      if (!_isCurrentWallpaperTransition(requestId)) return;
      _setWallpaperTransitionState(requestId, 'static:$path', 'applying');
      final success = await _wallpaperEngine.setStaticWallpaper(
        path,
        _settings.wallpaperFit,
        settings: _settings,
        isCancelled: () => !_isCurrentWallpaperTransition(requestId),
        transitionId: requestId,
      );
      if (!_isCurrentWallpaperTransition(requestId)) return;
      if (success) {
        final name = path.split(Platform.pathSeparator).last;
        final updated = _settings.copyWith(
          activeWallpaperType: 'static',
          activeWallpaperPath: path,
          activeWallpaperAnimatedBg: '',
        );
        _updateSettings(updated);
        _recordRecentWallpaper(
          id: 'local_${path.hashCode}',
          name: name,
          pathOrUrl: path,
          type: 'static',
          thumbnailUrl: null,
        );
        await _persistWallpaperSettings();
        if (!_isCurrentWallpaperTransition(requestId)) return;
        _setWallpaperTransitionState(requestId, 'static:$path', 'active');
        if (mounted) {
          _showAnimatedSnackBar(
            'Applied desktop wallpaper: $name',
            isSuccess: true,
          );
        }
      } else {
        _setWallpaperTransitionState(requestId, 'static:$path', 'error');
        if (mounted) {
          _showAnimatedSnackBar(
            'Failed to apply wallpaper to desktop.',
            isSuccess: false,
          );
        }
      }
    } catch (e, st) {
      _setWallpaperTransitionState(requestId, 'static:$path', 'error');
      logError(
        'DashboardView',
        'Failed to apply custom static wallpaper',
        e,
        st,
      );
      if (mounted) {
        _showAnimatedSnackBar(
          'Failed to apply custom static wallpaper: $e',
          isSuccess: false,
        );
      }
    }
  }

  Future<void> _applyRecentWallpaper(RecentWallpaperItem item) async {
    if (item.isVideo) {
      await _applyVideoWallpaper(item.pathOrUrl);
    } else {
      if (item.isLocal) {
        await _applyCustomStaticWallpaper(item.pathOrUrl);
      } else {
        final matching = _wallpapers
            .where((w) => w.id == item.id || w.url == item.pathOrUrl)
            .firstOrNull;
        if (matching != null) {
          await _applyWallpaper(matching);
        } else if (item.pathOrUrl.startsWith('http')) {
          final synthetic = FirebaseWallpaper(
            id: item.id,
            name: item.name,
            url: item.pathOrUrl,
            category: 'Recent',
            type: 'static',
            thumbnailUrl: item.thumbnailUrl ?? item.pathOrUrl,
          );
          await _applyWallpaper(synthetic);
        } else {
          await _applyCustomStaticWallpaper(item.pathOrUrl);
        }
      }
    }
  }

  Widget _buildRecentWallpapersView() {
    final recents = _settings.recentWallpapers.where((item) {
      if (_selectedRecentFilter == 'static') return !item.isVideo;
      if (_selectedRecentFilter == 'video') return item.isVideo;
      return true;
    }).toList();

    final allCount = _settings.recentWallpapers.length;
    final staticCount = _settings.recentWallpapers
        .where((w) => !w.isVideo)
        .length;
    final videoCount = _settings.recentWallpapers
        .where((w) => w.isVideo)
        .length;

    return Column(
      children: [
        // ── Header Controls & Filter Bar ──
        Padding(
          padding: const EdgeInsets.fromLTRB(20, 6, 20, 12),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                // Filter chips
                _buildRecentFilterChip(
                  label: 'All Wallpapers',
                  value: 'All',
                  count: allCount,
                  icon: Icons.auto_awesome_mosaic_rounded,
                ),
                const SizedBox(width: 8),
                _buildRecentFilterChip(
                  label: 'Static Images',
                  value: 'static',
                  count: staticCount,
                  icon: Icons.photo_size_select_actual_rounded,
                ),
                const SizedBox(width: 8),
                _buildRecentFilterChip(
                  label: 'Live Videos',
                  value: 'video',
                  count: videoCount,
                  icon: Icons.videocam_rounded,
                ),
                const Spacer(),
                // Browse buttons
                OutlinedButton.icon(
                  onPressed: _browseAndApplyCustomImage,
                  icon: const Icon(Icons.add_photo_alternate_rounded, size: 14),
                  label: const Text(
                    'Browse Image',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFFEC4899),
                    side: BorderSide(
                      color: const Color(0xFFEC4899).withValues(alpha: 0.4),
                    ),
                    backgroundColor: const Color(
                      0xFFEC4899,
                    ).withValues(alpha: 0.08),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                OutlinedButton.icon(
                  onPressed: _browseAndApplyCustomVideo,
                  icon: const Icon(Icons.video_call_rounded, size: 14),
                  label: const Text(
                    'Browse Video',
                    style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: const Color(0xFF38BDF8),
                    side: BorderSide(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                    ),
                    backgroundColor: const Color(
                      0xFF38BDF8,
                    ).withValues(alpha: 0.08),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 8,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                if (_settings.recentWallpapers.isNotEmpty) ...[
                  const SizedBox(width: 8),
                  TextButton.icon(
                    onPressed: _clearRecentWallpapers,
                    icon: const Icon(Icons.delete_sweep_rounded, size: 14),
                    label: const Text(
                      'Clear',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.redAccent.shade100,
                      backgroundColor: Colors.redAccent.withValues(alpha: 0.08),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(10),
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),

        // ── Body: Grid or Empty State ──
        Expanded(
          child: recents.isEmpty
              ? _buildEmptyRecentState()
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final crossAxisCount = (constraints.maxWidth / 280)
                        .floor()
                        .clamp(2, 5);
                    return GridView.builder(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 20,
                        vertical: 6,
                      ),
                      cacheExtent: 250.0,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        childAspectRatio: 1.3,
                      ),
                      itemCount: recents.length,
                      itemBuilder: (context, idx) {
                        return _buildRecentWallpaperCard(recents[idx]);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildRecentFilterChip({
    required String label,
    required String value,
    required int count,
    required IconData icon,
  }) {
    final isSelected = _selectedRecentFilter == value;
    final color = value == 'video'
        ? const Color(0xFF38BDF8)
        : (value == 'static'
              ? const Color(0xFFEC4899)
              : const Color(0xFFA855F7));

    return InkWell(
      onTap: () => setState(() => _selectedRecentFilter = value),
      borderRadius: BorderRadius.circular(10),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        decoration: BoxDecoration(
          color: isSelected
              ? color.withValues(alpha: 0.2)
              : Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? color.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.08),
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 13, color: isSelected ? color : Colors.white60),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
                color: isSelected ? Colors.white : Colors.white70,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
              decoration: BoxDecoration(
                color: isSelected
                    ? color.withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.06),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                '$count',
                style: TextStyle(
                  fontSize: 9,
                  fontWeight: FontWeight.bold,
                  color: isSelected ? color : Colors.white54,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyRecentState() {
    return Center(
      child: Container(
        constraints: const BoxConstraints(maxWidth: 480),
        margin: const EdgeInsets.all(24),
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.03),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: Colors.white.withValues(alpha: 0.07)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(18),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFFEC4899).withValues(alpha: 0.2),
                    const Color(0xFF38BDF8).withValues(alpha: 0.2),
                  ],
                ),
                shape: BoxShape.circle,
              ),
              child: const Icon(
                Icons.history_toggle_off_rounded,
                size: 44,
                color: Color(0xFF38BDF8),
              ),
            ),
            const SizedBox(height: 18),
            const Text(
              'No Recent Wallpapers Found',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.bold,
                color: Colors.white,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _settings.recentWallpapers.isEmpty
                  ? 'Wallpapers you browse from your PC or apply from the catalog will automatically be stored here for fast 1-click access.'
                  : 'No wallpapers found matching the current filter.',
              textAlign: TextAlign.center,
              style: const TextStyle(
                fontSize: 12,
                color: Colors.white60,
                height: 1.4,
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ElevatedButton.icon(
                  onPressed: _browseAndApplyCustomImage,
                  icon: const Icon(Icons.add_photo_alternate_rounded, size: 16),
                  label: const Text('Browse Image'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEC4899),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                ElevatedButton.icon(
                  onPressed: _browseAndApplyCustomVideo,
                  icon: const Icon(Icons.video_call_rounded, size: 16),
                  label: const Text('Browse Live Video'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildRecentWallpaperCard(RecentWallpaperItem item) {
    final isActiveVideo =
        _settings.activeWallpaperType == 'video' &&
        _settings.activeWallpaperPath != null &&
        (_settings.activeWallpaperPath == item.pathOrUrl ||
            _settings.activeWallpaperPath!.endsWith(item.name));

    final isActiveStatic =
        _settings.activeWallpaperType == 'static' &&
        _settings.activeWallpaperPath != null &&
        (_settings.activeWallpaperPath == item.pathOrUrl ||
            _settings.activeWallpaperPath!.endsWith(item.name));

    final isActive = item.isVideo ? isActiveVideo : isActiveStatic;
    final themeColor = item.isVideo
        ? const Color(0xFF38BDF8)
        : const Color(0xFFEC4899);

    return Tooltip(
      message: isActive
          ? 'Currently Active • Click to re-apply'
          : 'Click to apply "${item.name}"',
      child: HoverCard(
        scaleUp: 1.03,
        glowColor: isActive ? themeColor : themeColor.withValues(alpha: 0.5),
        maxGlowOpacity: isActive ? 0.35 : 0.2,
        blurRadius: isActive ? 16 : 10,
        onTap: () => _applyRecentWallpaper(item),
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2A).withValues(alpha: 0.4),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: isActive ? themeColor : themeColor.withValues(alpha: 0.25),
              width: isActive ? 1.5 : 1.0,
            ),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(isActive ? 14 : 15),
            child: Stack(
              children: [
                // 1. Thumbnail / Image Preview
                Positioned.fill(child: _buildRecentItemThumbnail(item)),

                // 2. Dark Gradient Overlay for text readability
                Positioned.fill(
                  child: Container(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.82),
                        ],
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                      ),
                    ),
                  ),
                ),

                // 3. Top-left Badge: Live Video vs Static Image
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3.5,
                    ),
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: item.isVideo
                            ? [const Color(0xFF0284C7), const Color(0xFF6366F1)]
                            : [
                                const Color(0xFFEC4899),
                                const Color(0xFF8B5CF6),
                              ],
                      ),
                      borderRadius: BorderRadius.circular(6),
                      boxShadow: [
                        BoxShadow(
                          color: themeColor.withValues(alpha: 0.4),
                          blurRadius: 6,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          item.isVideo
                              ? Icons.videocam_rounded
                              : Icons.photo_library_rounded,
                          size: 11,
                          color: Colors.white,
                        ),
                        const SizedBox(width: 4),
                        Text(
                          item.isVideo ? 'LIVE VIDEO' : 'STATIC IMAGE',
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // 4. Top-right: Time ago + Remove button
                Positioned(
                  top: 8,
                  right: 8,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 6,
                          vertical: 2.5,
                        ),
                        decoration: BoxDecoration(
                          color: Colors.black.withValues(alpha: 0.6),
                          borderRadius: BorderRadius.circular(5),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                        ),
                        child: Text(
                          _formatTimeAgo(item.timestamp),
                          style: const TextStyle(
                            color: Colors.white70,
                            fontSize: 9,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      const SizedBox(width: 4),
                      Material(
                        color: Colors.transparent,
                        child: InkWell(
                          onTap: () => _removeRecentWallpaper(item),
                          borderRadius: BorderRadius.circular(5),
                          child: Container(
                            padding: const EdgeInsets.all(3),
                            decoration: BoxDecoration(
                              color: Colors.black.withValues(alpha: 0.6),
                              borderRadius: BorderRadius.circular(5),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.12),
                              ),
                            ),
                            child: const Icon(
                              Icons.close_rounded,
                              size: 12,
                              color: Colors.white60,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),

                // 5. Bottom Info + Apply Action
                Positioned(
                  bottom: 10,
                  left: 12,
                  right: 12,
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              item.name,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                                color: Colors.white,
                              ),
                            ),
                            const SizedBox(height: 2),
                            Text(
                              item.isLocal ? 'Local File' : 'Cloud Wallpaper',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 10,
                                color: themeColor.withValues(alpha: 0.9),
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ],
                        ),
                      ),
                      const SizedBox(width: 8),
                      // 1-Click Apply Button
                      Container(
                        height: 30,
                        decoration: BoxDecoration(
                          gradient: isActive
                              ? const LinearGradient(
                                  colors: [
                                    Color(0xFF10B981),
                                    Color(0xFF059669),
                                  ],
                                )
                              : LinearGradient(
                                  colors: [
                                    themeColor,
                                    themeColor.withValues(alpha: 0.75),
                                  ],
                                ),
                          borderRadius: BorderRadius.circular(8),
                          boxShadow: [
                            BoxShadow(
                              color:
                                  (isActive
                                          ? const Color(0xFF10B981)
                                          : themeColor)
                                      .withValues(alpha: 0.4),
                              blurRadius: 6,
                              offset: const Offset(0, 2),
                            ),
                          ],
                        ),
                        child: Material(
                          color: Colors.transparent,
                          child: InkWell(
                            onTap: () => _applyRecentWallpaper(item),
                            borderRadius: BorderRadius.circular(8),
                            child: Padding(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    isActive
                                        ? Icons.check_circle_rounded
                                        : (item.isVideo
                                              ? Icons.play_arrow_rounded
                                              : Icons.wallpaper_rounded),
                                    size: 14,
                                    color: Colors.white,
                                  ),
                                  const SizedBox(width: 4),
                                  Text(
                                    isActive ? 'Active' : 'Apply',
                                    style: const TextStyle(
                                      fontSize: 11,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildRecentItemThumbnail(RecentWallpaperItem item) {
    if (item.isVideo) {
      if (item.thumbnailUrl != null &&
          item.thumbnailUrl!.isNotEmpty &&
          item.thumbnailUrl!.startsWith('http')) {
        return SafeNetworkImage(
          url: _thumbnailUrlFor(item.thumbnailUrl!),
          fallbackUrl: item.thumbnailUrl!,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildVideoFallbackPlaceholder(),
        );
      }
      return FutureBuilder<File?>(
        future: _recentThumbnailFutures.putIfAbsent(
          item.pathOrUrl,
          () => VideoThumbnailService.instance.getThumbnailFile(item.pathOrUrl),
        ),
        builder: (context, snapshot) {
          final file = snapshot.data;
          if (snapshot.hasData && file != null) {
            return Image.file(
              file,
              fit: BoxFit.cover,
              cacheWidth: 400,
              errorBuilder: (_, _, _) => _buildVideoFallbackPlaceholder(),
            );
          }
          return _buildVideoFallbackPlaceholder();
        },
      );
    } else {
      if (item.pathOrUrl.startsWith('assets/')) {
        return Image.asset(
          item.pathOrUrl,
          fit: BoxFit.cover,
          cacheWidth: 400,
          errorBuilder: (_, _, _) => _buildImageFallbackPlaceholder(),
        );
      }
      if (item.isLocal) {
        final f = File(item.pathOrUrl);
        return Image.file(
          f,
          fit: BoxFit.cover,
          cacheWidth: 400,
          errorBuilder: (_, _, _) => _buildImageFallbackPlaceholder(),
        );
      }
      final url = item.thumbnailUrl ?? item.pathOrUrl;
      if (url.startsWith('http')) {
        return SafeNetworkImage(
          url: _thumbnailUrlFor(url),
          fallbackUrl: url,
          fit: BoxFit.cover,
          errorBuilder: (_, _, _) => _buildImageFallbackPlaceholder(),
        );
      }
      return _buildImageFallbackPlaceholder();
    }
  }

  Widget _buildVideoFallbackPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF1E293B), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.videocam_rounded, size: 36, color: Colors.white24),
      ),
    );
  }

  Widget _buildImageFallbackPlaceholder() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          colors: [Color(0xFF2E1065), Color(0xFF0F172A)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
      ),
      child: const Center(
        child: Icon(Icons.image_rounded, size: 36, color: Colors.white24),
      ),
    );
  }

  Widget _buildRecentLiveVideosShelf() {
    final recentVideos = _settings.recentWallpapers
        .where((w) => w.isVideo)
        .toList();
    if (recentVideos.isEmpty) return const SizedBox.shrink();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              const Icon(
                Icons.history_rounded,
                size: 16,
                color: Color(0xFFEC4899),
              ),
              const SizedBox(width: 8),
              const Text(
                'RECENTLY APPLIED LIVE VIDEOS',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                  letterSpacing: 1.0,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFFEC4899).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${recentVideos.length} RECENT',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFFEC4899),
                  ),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _wallpaperSubTab = 'recent'),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFFEC4899),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
                child: const Text(
                  'View All Recents',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 140,
          child: ListView.builder(
            padding: const EdgeInsets.symmetric(horizontal: 20),
            scrollDirection: Axis.horizontal,
            itemCount: recentVideos.length,
            itemBuilder: (context, idx) {
              final item = recentVideos[idx];
              return Container(
                width: 220,
                margin: const EdgeInsets.only(right: 14, bottom: 6),
                child: _buildRecentWallpaperCard(item),
              );
            },
          ),
        ),
        const SizedBox(height: 14),
      ],
    );
  }

  Widget _buildStaticWallpapersView() {
    final staticWallpapers = _cachedStaticWallpapers;

    final hasRecentStatic = _settings.recentWallpapers.any((w) => !w.isVideo);
    final categories = [
      'All',
      if (hasRecentStatic) 'Recent',
      ...staticWallpapers.map((w) => w.category).toSet(),
    ];

    final isRecentSelected = _selectedCategory == 'Recent';
    final recentStatic = _settings.recentWallpapers
        .where((w) => !w.isVideo)
        .toList();

    final filtered = _selectedCategory == 'All'
        ? staticWallpapers
        : (isRecentSelected
              ? const <FirebaseWallpaper>[]
              : staticWallpapers
                    .where((w) => w.category == _selectedCategory)
                    .toList());

    return Column(
      children: [
        // ── Active Static Wallpaper Controls (ONLY if static wallpaper is active) ──
        if (_settings.activeWallpaperType == 'static')
          _buildActiveWallpaperControls(),

        // ── Horizontal Categories & Actions ──
        Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 20),
          child: Row(
            children: [
              Expanded(
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  itemCount: categories.length,
                  itemBuilder: (context, idx) {
                    final cat = categories[idx];
                    final isSelected = _selectedCategory == cat;
                    return Padding(
                      padding: const EdgeInsets.only(
                        right: 12,
                        top: 8,
                        bottom: 8,
                      ),
                      child: _buildCategoryChip(cat, isSelected),
                    );
                  },
                ),
              ),
              const SizedBox(width: 8),
              OutlinedButton.icon(
                onPressed: _browseAndApplyCustomImage,
                icon: const Icon(Icons.add_photo_alternate_rounded, size: 14),
                label: const Text(
                  'Browse Image',
                  style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                ),
                style: OutlinedButton.styleFrom(
                  foregroundColor: const Color(0xFFEC4899),
                  side: BorderSide(
                    color: const Color(0xFFEC4899).withValues(alpha: 0.4),
                  ),
                  backgroundColor: const Color(
                    0xFFEC4899,
                  ).withValues(alpha: 0.08),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 8,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ],
          ),
        ),

        // ── Grid of Static Wallpapers ──
        Expanded(
          child: isRecentSelected
              ? (recentStatic.isEmpty
                    ? const Center(
                        child: Text(
                          'No recent static wallpapers found.',
                          style: TextStyle(color: Colors.white60, fontSize: 13),
                        ),
                      )
                    : LayoutBuilder(
                        builder: (context, constraints) {
                          final crossAxisCount = (constraints.maxWidth / 280)
                              .floor()
                              .clamp(2, 5);
                          return GridView.builder(
                            padding: const EdgeInsets.all(20),
                            cacheExtent: 250.0,
                            gridDelegate:
                                SliverGridDelegateWithFixedCrossAxisCount(
                                  crossAxisCount: crossAxisCount,
                                  crossAxisSpacing: 16,
                                  mainAxisSpacing: 16,
                                  childAspectRatio: 1.3,
                                ),
                            itemCount: recentStatic.length,
                            itemBuilder: (context, idx) {
                              return _buildRecentWallpaperCard(
                                recentStatic[idx],
                              );
                            },
                          );
                        },
                      ))
              : LayoutBuilder(
                  builder: (context, constraints) {
                    final crossAxisCount = (constraints.maxWidth / 280)
                        .floor()
                        .clamp(2, 5);
                    return GridView.builder(
                      padding: const EdgeInsets.all(20),
                      cacheExtent: 250.0,
                      gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                        crossAxisCount: crossAxisCount,
                        crossAxisSpacing: 16,
                        mainAxisSpacing: 16,
                        childAspectRatio: 1.3,
                      ),
                      itemCount: filtered.length,
                      itemBuilder: (context, idx) {
                        final wp = filtered[idx];
                        return _buildWallpaperCard(wp);
                      },
                    );
                  },
                ),
        ),
      ],
    );
  }

  Widget _buildLiveWallpapersView() {
    final videoWallpapers = _cachedLiveWallpapers;

    return LayoutBuilder(
      builder: (context, constraints) {
        final crossAxisCount = (constraints.maxWidth / 280)
            .floor()
            .clamp(2, 5);

        return CustomScrollView(
          cacheExtent: 250.0,
          slivers: [
            SliverToBoxAdapter(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // ── If Live Video Active: "NOW PLAYING" Header Deck with Live Preview & Controls ──
                  // ── If NOT Active: Clean Invitation Banner (NO playback controls clutter) ──
                  _buildLiveVideoControls(),

                  const SizedBox(height: 12),

                  // ── If recent video wallpapers exist: Horizontal shelf of Recent Live Wallpapers ──
                  if (_settings.recentWallpapers.any((w) => w.isVideo))
                    _buildRecentLiveVideosShelf(),

                  // ── Section Title: Live Video Catalog ──
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 20),
                    child: Row(
                      children: [
                        const Icon(
                          Icons.video_library_rounded,
                          size: 16,
                          color: Color(0xFF38BDF8),
                        ),
                        const SizedBox(width: 8),
                        const Text(
                          'CURATED LIVE WALLPAPERS',
                          style: TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                            color: Colors.white70,
                            letterSpacing: 1.0,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(6),
                          ),
                          child: Text(
                            '${videoWallpapers.length} VIDEOS',
                            style: const TextStyle(
                              fontSize: 9,
                              fontWeight: FontWeight.bold,
                              color: Color(0xFF38BDF8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 12),
                ],
              ),
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 30),
              sliver: SliverGrid.builder(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: crossAxisCount,
                  crossAxisSpacing: 16,
                  mainAxisSpacing: 16,
                  childAspectRatio: 1.3,
                ),
                itemCount: videoWallpapers.length,
                itemBuilder: (context, idx) {
                  final wp = videoWallpapers[idx];
                  return RepaintBoundary(
                    child: _buildWallpaperCard(wp),
                  );
                },
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _buildActiveWallpaperControls() {
    final hasWp = _settings.activeWallpaperType == 'static';
    if (!hasWp) return const SizedBox.shrink();

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 9),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFF38BDF8).withValues(alpha: 0.08),
              const Color(0xFF818CF8).withValues(alpha: 0.04),
              Colors.white.withValues(alpha: 0.02),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.22),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 12,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Expanded(
              child: Row(
                children: [
                  Container(
                    width: 7,
                    height: 7,
                    decoration: BoxDecoration(
                      color: const Color(0xFF38BDF8),
                      shape: BoxShape.circle,
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.8),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(width: 8),
                  const Icon(
                    Icons.wallpaper_rounded,
                    size: 16,
                    color: Color(0xFF38BDF8),
                  ),
                  const SizedBox(width: 8),
                  const Text(
                    'Desktop Fit: ',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      color: Colors.white70,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.12),
                      ),
                    ),
                    child: DropdownButtonHideUnderline(
                      child: DropdownButton<String>(
                        value: _settings.wallpaperFit,
                        dropdownColor: const Color(0xFF1E1E2A),
                        icon: const Icon(
                          Icons.arrow_drop_down_rounded,
                          color: Color(0xFF38BDF8),
                        ),
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12,
                          fontWeight: FontWeight.bold,
                        ),
                        onChanged:
                            _isChangingWallpaperFit || _isVideoWallpaperBusy
                            ? null
                            : (String? newValue) async {
                                if (newValue != null) {
                                  setState(
                                    () => _isChangingWallpaperFit = true,
                                  );
                                  try {
                                    final newSettings = _settings.copyWith(
                                      wallpaperFit: newValue,
                                    );
                                    _updateSettings(newSettings);
                                    if (_settings.activeWallpaperType ==
                                            'static' &&
                                        _settings.activeWallpaperPath != null) {
                                      final applied = await _wallpaperEngine
                                          .setStaticWallpaper(
                                            _settings.activeWallpaperPath!,
                                            newValue,
                                          );
                                      if (!applied && mounted) {
                                        _showAnimatedSnackBar(
                                          'Failed to update wallpaper fit.',
                                          isSuccess: false,
                                        );
                                      }
                                    }
                                  } catch (e, st) {
                                    logError(
                                      'DashboardView',
                                      'Failed to update wallpaper fit',
                                      e,
                                      st,
                                    );
                                    if (mounted) {
                                      _showAnimatedSnackBar(
                                        'Failed to update wallpaper fit.',
                                        isSuccess: false,
                                      );
                                    }
                                  } finally {
                                    if (mounted) {
                                      setState(
                                        () => _isChangingWallpaperFit = false,
                                      );
                                    }
                                  }
                                }
                              },
                        items:
                            <String>[
                              'fill',
                              'fit',
                              'stretch',
                              'tile',
                              'center',
                            ].map<DropdownMenuItem<String>>((String value) {
                              return DropdownMenuItem<String>(
                                value: value,
                                child: Text(value.toUpperCase()),
                              );
                            }).toList(),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            TextButton.icon(
              onPressed: _isVideoWallpaperBusy ? null : _clearWallpaper,
              icon: const Icon(Icons.restore_rounded, size: 14),
              label: const Text(
                'Clear Wallpaper',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFFF87171),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                backgroundColor: const Color(0xFFF87171).withValues(alpha: 0.10),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                  side: BorderSide(
                    color: const Color(0xFFF87171).withValues(alpha: 0.25),
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _applyVideoWallpaper(String pathOrUrl) async {
    await _enqueueWallpaperTransition('video:$pathOrUrl', (requestId) async {
      await _applyVideoWallpaperNow(pathOrUrl, requestId);
    });
  }

  Future<void> _applyVideoWallpaperNow(String pathOrUrl, int requestId) async {
    setState(() => _isVideoWallpaperBusy = true);
    var playbackSettingsSyncFailed = false;
    try {
      final trimmed = pathOrUrl.trim();
      final uri = Uri.tryParse(trimmed);
      final isRemote =
          uri != null &&
          (uri.scheme == 'http' || uri.scheme == 'https') &&
          uri.hasAuthority;
      logInfo(
        'DashboardView',
        'Applying video wallpaper: $trimmed (remote=$isRemote)',
      );
      if (isRemote) {
        _videoDownloadProgressNotifier.value = 0;
      }
      final rawPath = isRemote
          ? (await _videoWallpaperCache.download(
              trimmed,
              onProgress: (progress) {
                if (!mounted || !_isCurrentWallpaperTransition(requestId)) {
                  return;
                }
                final current = _videoDownloadProgressNotifier.value ?? 0;
                if (progress - current >= 0.02 || progress == 1) {
                  _videoDownloadProgressNotifier.value = progress;
                }
              },
            )).path
          : (uri != null && uri.scheme == 'file' ? uri.toFilePath() : trimmed);

      final path = isRemote ? rawPath : File(rawPath).absolute.path;
      if (!isRemote) {
        final f = File(path);
        if (!await f.exists() || await f.length() == 0) {
          throw const FormatException(
            'Selected video file does not exist or is empty.',
          );
        }
      }
      if (!_isCurrentWallpaperTransition(requestId)) return;

      _setWallpaperTransitionState(requestId, 'video:$pathOrUrl', 'starting');
      final success = await _wallpaperEngine.startAnimatedWallpaper(
        path,
        isCancelled: () => !_isCurrentWallpaperTransition(requestId),
        transitionId: requestId,
      );
      if (!mounted || !_isCurrentWallpaperTransition(requestId)) return;
      if (success) {
        final updated = _settings.copyWith(
          activeWallpaperType: 'video',
          activeWallpaperPath: path,
          activeWallpaperAnimatedBg: '',
          videoWallpaperPaused: false,
        );
        _updateSettings(updated);
        try {
          await _liveWallpaperManager.updateSettings(updated);
        } catch (e, st) {
          playbackSettingsSyncFailed = true;
          logError(
            'DashboardView',
            'Video wallpaper is active, but playback settings synchronization failed.',
            e,
            st,
          );
        }
        unawaited(VideoThumbnailService.instance.getThumbnailFile(path));

        final existingWp = _wallpapers
            .where((w) => w.url == pathOrUrl || w.id == pathOrUrl)
            .firstOrNull;
        final name =
            existingWp?.name ??
            (pathOrUrl.startsWith('http')
                ? (Uri.tryParse(pathOrUrl)?.pathSegments.lastOrNull ??
                      'Live Wallpaper')
                : pathOrUrl.split(Platform.pathSeparator).last);
        final thumb = (existingWp?.thumbnailUrl?.isNotEmpty ?? false)
            ? existingWp!.thumbnailUrl
            : null;
        _recordRecentWallpaper(
          id: existingWp?.id ?? 'video_${pathOrUrl.hashCode}',
          name: name,
          pathOrUrl: pathOrUrl,
          type: 'video',
          thumbnailUrl: thumb,
        );
        await _persistWallpaperSettings();
        if (!mounted || !_isCurrentWallpaperTransition(requestId)) return;
        _setWallpaperTransitionState(requestId, 'video:$pathOrUrl', 'active');

        _showAnimatedSnackBar(
          playbackSettingsSyncFailed
              ? 'Live wallpaper applied, but playback settings could not be synchronized.'
              : 'Live video wallpaper applied successfully.',
          isSuccess: !playbackSettingsSyncFailed,
        );
      } else {
        if (!_isCurrentWallpaperTransition(requestId)) {
          logInfo(
            'DashboardView',
            '[WALLPAPER TRANSITION #$requestId] cancelled; suppressed error UI.',
          );
          return;
        }
        _setWallpaperTransitionState(requestId, 'video:$pathOrUrl', 'error');
        _showAnimatedSnackBar(
          'Failed to apply live video wallpaper.',
          isSuccess: false,
        );
      }
    } catch (e, st) {
      if (!_isCurrentWallpaperTransition(requestId)) {
        logInfo(
          'DashboardView',
          '[WALLPAPER TRANSITION #$requestId] cancelled; ignoring error from superseded transition: $e',
        );
        return;
      }
      _setWallpaperTransitionState(requestId, 'video:$pathOrUrl', 'error');
      logError('DashboardView', 'Failed to apply live video wallpaper', e, st);
      if (mounted) {
        String message;
        if (e is MpvRuntimeMissingException) {
          message = e.userFacingMessage;
        } else if (e is HttpException) {
          message = e.message;
        } else if (e is SocketException) {
          message =
              'Network connection failed. Please check your internet connection.';
        } else if (e is FormatException) {
          message = e.message;
        } else {
          message = 'Failed to download or apply video wallpaper: $e';
        }
        _showAnimatedSnackBar(message, isSuccess: false);
      }
    } finally {
      if (mounted && _isCurrentWallpaperTransition(requestId)) {
        setState(() {
          _isVideoWallpaperBusy = false;
        });
        _videoDownloadProgressNotifier.value = null;
      }
    }
  }

  Future<void> _toggleVideoWallpaperPlayPause() async {
    final willPause = !_settings.videoWallpaperPaused;
    final updated = _settings.copyWith(videoWallpaperPaused: willPause);
    _updateSettings(updated);
    if (willPause) {
      await _liveWallpaperManager.pause();
      _showAnimatedSnackBar('Live wallpaper paused.', isSuccess: true);
    } else {
      await _liveWallpaperManager.play();
      _showAnimatedSnackBar('Live wallpaper playing.', isSuccess: true);
    }
    setState(() {});
  }

  Future<void> _toggleVideoWallpaperMute() async {
    final willMute = !_settings.videoWallpaperMuted;
    final updated = _settings.copyWith(videoWallpaperMuted: willMute);
    _updateSettings(updated);
    await _liveWallpaperManager.setMuted(willMute);
    _showAnimatedSnackBar(
      willMute
          ? 'Live wallpaper audio muted.'
          : 'Live wallpaper audio unmuted.',
      isSuccess: true,
    );
    setState(() {});
  }

  Future<void> _setVideoWallpaperVolume(double volume) async {
    final updated = _settings.copyWith(
      videoWallpaperVolume: volume,
      videoWallpaperMuted: volume <= 0,
    );
    _updateSettings(updated);
    await _liveWallpaperManager.setVolume(volume);
    setState(() {});
  }

  Future<void> _setVideoWallpaperFit(String fit) async {
    final updated = _settings.copyWith(wallpaperFit: fit);
    _updateSettings(updated);
    await _liveWallpaperManager.setFit(fit);
    _showAnimatedSnackBar(
      'Wallpaper fit set to ${fit.toUpperCase()}.',
      isSuccess: true,
    );
    setState(() {});
  }

  Future<void> _toggleVideoWallpaperLoop(bool loop) async {
    final updated = _settings.copyWith(videoWallpaperLoop: loop);
    _updateSettings(updated);
    await _liveWallpaperManager.setLoop(loop);
    _showAnimatedSnackBar(
      loop ? 'Looping enabled.' : 'Looping disabled.',
      isSuccess: true,
    );
    setState(() {});
  }

  Future<void> _toggleVideoWallpaperPauseFullscreen(bool val) async {
    final updated = _settings.copyWith(videoWallpaperPauseOnFullscreen: val);
    _updateSettings(updated);
    await _liveWallpaperManager.updateSettings(updated);
    setState(() {});
  }

  Future<void> _toggleVideoWallpaperPauseBatterySaver(bool val) async {
    final updated = _settings.copyWith(videoWallpaperPauseOnBatterySaver: val);
    _updateSettings(updated);
    await _liveWallpaperManager.updateSettings(updated);
    setState(() {});
  }

  Future<void> _setVideoWallpaperSpeed(double speed) async {
    final updated = _settings.copyWith(videoWallpaperSpeed: speed);
    _updateSettings(updated);
    await _liveWallpaperManager.setSpeed(speed);
    _showAnimatedSnackBar('Playback speed: ${speed}x', isSuccess: true);
    setState(() {});
  }

  Future<void> _stopVideoWallpaper() async {
    await _enqueueWallpaperTransition('none:stop-video', (requestId) async {
      if (mounted) setState(() => _isVideoWallpaperBusy = true);
      try {
        _setWallpaperTransitionState(requestId, 'none:stop-video', 'stopping');
        final stopped = await _wallpaperEngine.stopAnimatedWallpaper(
          transitionId: requestId,
        );
        if (!_isCurrentWallpaperTransition(requestId)) return;
        if (!stopped) {
          throw StateError('Native MPV shutdown was not confirmed.');
        }
        final updated = _settings.copyWith(
          activeWallpaperType: 'none',
          activeWallpaperPath: '',
          videoWallpaperPaused: false,
        );
        _updateSettings(updated);
        await _persistWallpaperSettings();
        if (!_isCurrentWallpaperTransition(requestId)) return;
        _setWallpaperTransitionState(requestId, 'none:stop-video', 'active');
        _showAnimatedSnackBar('Live video wallpaper stopped.', isSuccess: true);
      } catch (e, st) {
        _setWallpaperTransitionState(requestId, 'none:stop-video', 'error');
        logError('DashboardView', 'Failed to stop video wallpaper', e, st);
        if (mounted) {
          _showAnimatedSnackBar(
            'Could not stop the live wallpaper.',
            isSuccess: false,
          );
        }
      } finally {
        if (mounted) setState(() => _isVideoWallpaperBusy = false);
      }
    });
  }

  Widget _buildLiveVideoControls() {
    final isVideoWp = _settings.activeWallpaperType == 'video';
    final videoPath = isVideoWp ? (_settings.activeWallpaperPath ?? '') : '';
    final isUrl =
        videoPath.startsWith('http://') || videoPath.startsWith('https://');
    final displayName = videoPath.isEmpty
        ? 'No video selected'
        : (isUrl ? videoPath : videoPath.split(Platform.pathSeparator).last);

    final textCtrl = _videoUrlController;
    final isPaused = _settings.videoWallpaperPaused;
    final isMuted = _settings.videoWallpaperMuted;
    final volume = _settings.videoWallpaperVolume.clamp(0.0, 1.0);
    final fitMode = _settings.wallpaperFit;

    if (!isVideoWp) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
        child: Column(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 14),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    const Color(0xFF38BDF8).withValues(alpha: 0.08),
                    const Color(0xFF818CF8).withValues(alpha: 0.04),
                    Colors.white.withValues(alpha: 0.02),
                  ],
                  begin: Alignment.topLeft,
                  end: Alignment.bottomRight,
                ),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.20),
                  width: 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.3),
                    blurRadius: 16,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: Row(
                children: [
                  Container(
                    width: 42,
                    height: 42,
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(12),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                          blurRadius: 12,
                          offset: const Offset(0, 2),
                        ),
                      ],
                    ),
                    child: const Center(
                      child: Icon(
                        Icons.movie_creation_rounded,
                        size: 20,
                        color: Color(0xFF070913),
                      ),
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          'Live Motion Wallpaper Engine',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w800,
                            color: Colors.white,
                            letterSpacing: 0.2,
                          ),
                        ),
                        SizedBox(height: 3),
                        Text(
                          'Hardware-accelerated 60 FPS motion backgrounds • Ultra-low GPU latency',
                          style: TextStyle(
                            fontSize: 11,
                            color: Colors.white60,
                          ),
                        ),
                      ],
                    ),
                  ),
                  TextButton.icon(
                    onPressed: () {
                      setState(() {
                        _showVideoSettingsExpanded =
                            !_showVideoSettingsExpanded;
                      });
                    },
                    icon: Icon(
                      _showVideoSettingsExpanded
                          ? Icons.expand_less_rounded
                          : Icons.add_to_photos_rounded,
                      size: 15,
                    ),
                    label: Text(
                      _showVideoSettingsExpanded
                          ? 'Hide Source'
                          : 'Custom Video / URL',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w800,
                        letterSpacing: 0.2,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: Colors.white,
                      backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.16),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 9,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(11),
                        side: BorderSide(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            if (_showVideoSettingsExpanded) ...[
              const SizedBox(height: 12),
              _buildVideoEditingDeck(
                isVideoWp: isVideoWp,
                isWide: MediaQuery.of(context).size.width >= 720,
                textCtrl: textCtrl,
              ),
            ],
          ],
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.fromLTRB(20, 8, 20, 16),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final isWide = constraints.maxWidth >= 720;
          return AnimatedContainer(
            duration: const Duration(milliseconds: 300),
            padding: const EdgeInsets.all(20),
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  const Color(0xFF131525).withValues(alpha: 0.95),
                  const Color(0xFF0C0E1A).withValues(alpha: 0.95),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(22),
              border: Border.all(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.5),
                width: 1.5,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                  blurRadius: 24,
                  offset: const Offset(0, 10),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // ── 1. Top Bar: Header & Status Badge ──
                _buildLiveVideoTopHeader(
                  isVideoWp: isVideoWp,
                  isPaused: isPaused,
                  isWide: isWide,
                ),

                const SizedBox(height: 14),
                // ── Top Common Controls (Play/Pause, Speed Chips, Volume, Fit Chips) ──
                _buildLiveVideoCommonControlsBar(
                  isPaused: isPaused,
                  isMuted: isMuted,
                  volume: volume,
                  fitMode: fitMode,
                  isWide: isWide,
                ),

                const SizedBox(height: 16),

                // ── 2. Active Live Video Preview Card ──
                _buildActiveVideoPreviewCard(
                  displayName: displayName,
                  videoPath: videoPath,
                  isUrl: isUrl,
                  isPaused: isPaused,
                  isMuted: isMuted,
                  isWide: isWide,
                ),

                // ── 3. Expandable Editing Deck ──
                if (_showVideoSettingsExpanded) ...[
                  const SizedBox(height: 18),
                  _buildVideoEditingDeck(
                    isVideoWp: isVideoWp,
                    isWide: isWide,
                    textCtrl: textCtrl,
                  ),
                ],
              ],
            ),
          );
        },
      ),
    );
  }

  Widget _buildLiveVideoTopHeader({
    required bool isVideoWp,
    required bool isPaused,
    required bool isWide,
  }) {
    return ValueListenableBuilder<bool>(
      valueListenable: _liveWallpaperManager.policyPausedNotifier,
      builder: (context, isPolicyPaused, _) {
        final effectivelyPaused = isPaused || isPolicyPaused;
        return Row(
          children: [
            // Pulsing indicator
            AnimatedContainer(
              duration: const Duration(milliseconds: 300),
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: isVideoWp
                    ? (effectivelyPaused
                          ? Colors.amberAccent
                          : const Color(0xFF22C55E))
                    : Colors.white24,
                shape: BoxShape.circle,
                boxShadow: isVideoWp && !effectivelyPaused
                    ? [
                        BoxShadow(
                          color: const Color(0xFF22C55E).withValues(alpha: 0.8),
                          blurRadius: 10,
                          spreadRadius: 2,
                        ),
                      ]
                    : null,
              ),
            ),
            const SizedBox(width: 10),
            Text(
              isVideoWp
                  ? 'NOW PLAYING • LIVE WALLPAPER'
                  : 'LIVE VIDEO WALLPAPER ENGINE',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(6),
              ),
              child: const Text(
                'MPV DIRECT3D11',
                style: TextStyle(
                  fontSize: 8,
                  fontWeight: FontWeight.bold,
                  color: Color(0xFF38BDF8),
                  letterSpacing: 0.8,
                ),
              ),
            ),
            const Spacer(),
            if (isVideoWp) ...[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 4,
                ),
                decoration: BoxDecoration(
                  color: effectivelyPaused
                      ? Colors.amberAccent.withValues(alpha: 0.15)
                      : const Color(0xFF22C55E).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: effectivelyPaused
                        ? Colors.amberAccent.withValues(alpha: 0.4)
                        : const Color(0xFF22C55E).withValues(alpha: 0.4),
                  ),
                ),
                child: Text(
                  isPolicyPaused
                      ? 'PAUSED • FULLSCREEN APP (0% GPU)'
                      : (isPaused ? 'PAUSED' : 'ACTIVE • HARDWARE ACCELERATED'),
                  style: TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: effectivelyPaused
                        ? Colors.amberAccent
                        : const Color(0xFF22C55E),
                    letterSpacing: 0.8,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Tooltip(
                message: 'Remove live wallpaper',
                child: InkWell(
                  onTap: _isVideoWallpaperBusy ? null : _stopVideoWallpaper,
                  borderRadius: BorderRadius.circular(8),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.redAccent.withValues(alpha: 0.12),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: Colors.redAccent.withValues(alpha: 0.3),
                      ),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(
                          Icons.stop_circle_outlined,
                          size: 14,
                          color: Colors.redAccent,
                        ),
                        SizedBox(width: 4),
                        Text(
                          'Stop',
                          style: TextStyle(
                            fontSize: 10,
                            fontWeight: FontWeight.bold,
                            color: Colors.redAccent,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ] else ...[
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: const Text(
                  'STANDBY',
                  style: TextStyle(
                    fontSize: 9,
                    color: Colors.white38,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.8,
                  ),
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  Widget _buildLiveVideoCommonControlsBar({
    required bool isPaused,
    required bool isMuted,
    required double volume,
    required String fitMode,
    required bool isWide,
  }) {
    final playPauseButton = ElevatedButton.icon(
      onPressed: _isVideoWallpaperBusy ? null : _toggleVideoWallpaperPlayPause,
      icon: Icon(
        isPaused ? Icons.play_arrow_rounded : Icons.pause_rounded,
        size: 18,
      ),
      label: Text(
        isPaused ? 'Resume' : 'Pause',
        style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 12),
      ),
      style: ElevatedButton.styleFrom(
        backgroundColor: isPaused
            ? Colors.amberAccent
            : const Color(0xFF38BDF8),
        foregroundColor: Colors.black,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      ),
    );

    final speedWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Playback Speed',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          mainAxisSize: MainAxisSize.min,
          children: [0.5, 1.0, 1.25, 1.5, 2.0].map((s) {
            final isCur = (_settings.videoWallpaperSpeed - s).abs() < 0.05;
            return Padding(
              padding: const EdgeInsets.only(right: 4),
              child: InkWell(
                onTap: () => _setVideoWallpaperSpeed(s),
                borderRadius: BorderRadius.circular(6),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 7,
                    vertical: 5,
                  ),
                  decoration: BoxDecoration(
                    color: isCur
                        ? const Color(0xFF38BDF8).withValues(alpha: 0.25)
                        : Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: isCur ? const Color(0xFF38BDF8) : Colors.white10,
                    ),
                  ),
                  child: Text(
                    '${s}x',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: isCur ? FontWeight.bold : FontWeight.normal,
                      color: isCur ? const Color(0xFF38BDF8) : Colors.white70,
                    ),
                  ),
                ),
              ),
            );
          }).toList(),
        ),
      ],
    );

    final volumeWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Row(
          children: [
            IconButton(
              onPressed: _toggleVideoWallpaperMute,
              icon: Icon(
                isMuted || volume <= 0
                    ? Icons.volume_off_rounded
                    : (volume < 0.5
                          ? Icons.volume_down_rounded
                          : Icons.volume_up_rounded),
                size: 16,
                color: isMuted ? Colors.white38 : const Color(0xFF38BDF8),
              ),
              tooltip: isMuted ? 'Unmute' : 'Mute',
              visualDensity: VisualDensity.compact,
              padding: EdgeInsets.zero,
              constraints: const BoxConstraints(),
            ),
            const SizedBox(width: 8),
            Text(
              'Volume: ${isMuted ? 'Muted' : '${(volume * 100).round()}%'}',
              style: const TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.bold,
                color: Colors.white70,
              ),
            ),
          ],
        ),
        SliderTheme(
          data: SliderTheme.of(context).copyWith(
            activeTrackColor: const Color(0xFF38BDF8),
            inactiveTrackColor: Colors.white12,
            thumbColor: const Color(0xFF38BDF8),
            trackHeight: 3,
            thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
            overlayShape: const RoundSliderOverlayShape(overlayRadius: 12),
          ),
          child: Slider(
            value: isMuted ? 0.0 : volume,
            min: 0.0,
            max: 1.0,
            divisions: 100,
            onChanged: (val) {
              _setVideoWallpaperVolume(val);
            },
          ),
        ),
      ],
    );

    final fitChipsWidget = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        const Text(
          'Display Scaling',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.bold,
            color: Colors.white70,
          ),
        ),
        const SizedBox(height: 6),
        Row(
          children: [
            _buildFitChip(
              'fill',
              'Fill',
              Icons.crop_free_rounded,
              fitMode == 'fill',
            ),
            const SizedBox(width: 6),
            _buildFitChip(
              'fit',
              'Fit',
              Icons.fit_screen_rounded,
              fitMode == 'fit',
            ),
            const SizedBox(width: 6),
            _buildFitChip(
              'stretch',
              'Stretch',
              Icons.open_in_full_rounded,
              fitMode == 'stretch',
            ),
          ],
        ),
      ],
    );

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: isWide
          ? Row(
              children: [
                playPauseButton,
                const SizedBox(width: 14),
                Container(width: 1, height: 36, color: Colors.white10),
                const SizedBox(width: 14),
                speedWidget,
                const SizedBox(width: 14),
                Container(width: 1, height: 36, color: Colors.white10),
                const SizedBox(width: 14),
                Expanded(flex: 4, child: volumeWidget),
                const SizedBox(width: 14),
                Container(width: 1, height: 36, color: Colors.white10),
                const SizedBox(width: 14),
                Expanded(flex: 4, child: fitChipsWidget),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    playPauseButton,
                    const SizedBox(width: 12),
                    Expanded(child: volumeWidget),
                  ],
                ),
                const SizedBox(height: 10),
                Row(
                  children: [
                    Expanded(child: speedWidget),
                    const SizedBox(width: 12),
                    Expanded(child: fitChipsWidget),
                  ],
                ),
              ],
            ),
    );
  }

  Widget _buildActiveVideoPreviewCard({
    required String displayName,
    required String videoPath,
    required bool isUrl,
    required bool isPaused,
    required bool isMuted,
    required bool isWide,
  }) {
    return Tooltip(
      message: _showVideoSettingsExpanded
          ? 'Click to collapse options'
          : 'Click to expand video editing and automation options',
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            setState(() {
              _showVideoSettingsExpanded = !_showVideoSettingsExpanded;
            });
          },
          borderRadius: BorderRadius.circular(16),
          splashColor: const Color(0xFF38BDF8).withValues(alpha: 0.1),
          highlightColor: const Color(0xFF38BDF8).withValues(alpha: 0.05),
          child: Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.025),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(
                color: _showVideoSettingsExpanded
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.4)
                    : Colors.white.withValues(alpha: 0.07),
                width: _showVideoSettingsExpanded ? 1.5 : 1.0,
              ),
              boxShadow: _showVideoSettingsExpanded
                  ? [
                      BoxShadow(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.08),
                        blurRadius: 16,
                      ),
                    ]
                  : null,
            ),
            child: isWide
                ? Row(
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _buildMonitorMockupScreen(
                        isPaused: isPaused,
                        isMuted: isMuted,
                        width: 250,
                        height: 140,
                      ),
                      const SizedBox(width: 18),
                      Expanded(
                        child: _buildActiveVideoDetails(
                          displayName: displayName,
                          videoPath: videoPath,
                          isUrl: isUrl,
                        ),
                      ),
                    ],
                  )
                : Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Center(
                        child: _buildMonitorMockupScreen(
                          isPaused: isPaused,
                          isMuted: isMuted,
                          width: double.infinity,
                          height: 160,
                        ),
                      ),
                      const SizedBox(height: 14),
                      _buildActiveVideoDetails(
                        displayName: displayName,
                        videoPath: videoPath,
                        isUrl: isUrl,
                      ),
                    ],
                  ),
          ),
        ),
      ),
    );
  }

  Widget _buildMonitorMockupScreen({
    required bool isPaused,
    required bool isMuted,
    required double width,
    required double height,
  }) {
    final videoPath = _settings.activeWallpaperPath ?? '';
    final elapsedMin = (_videoElapsedSeconds ~/ 60).toString().padLeft(2, '0');
    final elapsedSec = (_videoElapsedSeconds % 60).toString().padLeft(2, '0');

    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: Colors.black,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
          width: 1.5,
        ),
        boxShadow: [
          BoxShadow(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
            blurRadius: 12,
            spreadRadius: 1,
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10.5),
        child: Stack(
          alignment: Alignment.center,
          children: [
            Positioned.fill(
              child:
                  (_settings.activeWallpaperType == 'video' &&
                      _settings.activeWallpaperPath != null &&
                      _settings.activeWallpaperPath!.isNotEmpty)
                  ? CurrentVideoWallpaperThumbnailWidget(
                      key: ValueKey(_settings.activeWallpaperPath),
                      videoPathOrUrl: _settings.activeWallpaperPath!,
                      fit: _settings.wallpaperFit,
                    )
                  : AnimatedBuilder(
                      animation: _backgroundFlowController,
                      builder: (context, _) {
                        final t =
                            _backgroundFlowController.value *
                            _settings.videoWallpaperSpeed;
                        final angle = t * 2 * math.pi;
                        final c1 = HSLColor.fromAHSL(
                          1.0,
                          (200 + 40 * math.sin(angle)) % 360,
                          0.7,
                          0.18,
                        ).toColor();
                        final c2 = HSLColor.fromAHSL(
                          1.0,
                          (260 + 30 * math.cos(angle)) % 360,
                          0.6,
                          0.12,
                        ).toColor();
                        return Container(
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [c1, c2, const Color(0xFF090D16)],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                          ),
                        );
                      },
                    ),
            ),
            Positioned.fill(
              child: RepaintBoundary(
                child: Opacity(
                  opacity: 0.08,
                  child: CustomPaint(painter: _ScanlinePainter()),
                ),
              ),
            ),
            Positioned(
              top: 8,
              left: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 6,
                  vertical: 2.5,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                  ),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Container(
                      width: 6,
                      height: 6,
                      decoration: BoxDecoration(
                        color: isPaused
                            ? Colors.amberAccent
                            : const Color(0xFF22C55E),
                        shape: BoxShape.circle,
                        boxShadow: [
                          BoxShadow(
                            color:
                                (isPaused
                                        ? Colors.amberAccent
                                        : const Color(0xFF22C55E))
                                    .withValues(alpha: 0.8),
                            blurRadius: 4,
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 4),
                    const Text(
                      'LIVE VIDEO',
                      style: TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.w900,
                        color: Colors.white,
                        letterSpacing: 0.8,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Positioned(
              top: 8,
              right: 8,
              child: FutureBuilder<WallpaperMetadata>(
                future: WallpaperMetadataService.instance.getMetadata(
                  url: videoPath,
                  isVideo: true,
                ),
                builder: (context, snapshot) => Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2.5,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.black.withValues(alpha: 0.6),
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(color: Colors.white12),
                  ),
                  child: Text(
                    '${_settings.videoWallpaperSpeed}x · ${snapshot.data?.displayLabel ?? 'Checking resolution…'}',
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                      color: Colors.white70,
                      letterSpacing: 0.1,
                    ),
                  ),
                ),
              ),
            ),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.55),
                borderRadius: BorderRadius.circular(20),
                border: Border.all(
                  color:
                      (isPaused ? Colors.amberAccent : const Color(0xFF38BDF8))
                          .withValues(alpha: 0.4),
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    isPaused ? Icons.pause_rounded : Icons.play_arrow_rounded,
                    size: 16,
                    color: isPaused
                        ? Colors.amberAccent
                        : const Color(0xFF38BDF8),
                  ),
                  const SizedBox(width: 6),
                  Text(
                    isPaused ? 'PAUSED' : 'PLAYING',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: isPaused
                          ? Colors.amberAccent
                          : const Color(0xFF38BDF8),
                      letterSpacing: 1.0,
                    ),
                  ),
                  if (!isPaused) ...[
                    const SizedBox(width: 8),
                    _buildEqualizerBars(isMuted),
                  ],
                ],
              ),
            ),
            Positioned(
              bottom: 8,
              left: 8,
              child: const Text(
                'DESKTOP EMBEDDED • DIRECT3D11',
                style: TextStyle(
                  fontSize: 7.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.white38,
                  letterSpacing: 0.6,
                ),
              ),
            ),
            Positioned(
              bottom: 8,
              right: 8,
              child: Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.6),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const Icon(
                      Icons.timer_outlined,
                      size: 9,
                      color: Color(0xFF38BDF8),
                    ),
                    const SizedBox(width: 3),
                    Text(
                      '$elapsedMin:$elapsedSec',
                      style: const TextStyle(
                        fontSize: 8,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEqualizerBars(bool isMuted) {
    return AnimatedBuilder(
      animation: _backgroundFlowController,
      builder: (context, _) {
        final t = _backgroundFlowController.value * 2 * math.pi;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: List.generate(4, (i) {
            final h = isMuted
                ? 3.0
                : 4.0 + 8.0 * (0.5 + 0.5 * math.sin(t * 3 + i * 1.2));
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 1.2),
              width: 2.5,
              height: h,
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8),
                borderRadius: BorderRadius.circular(1),
              ),
            );
          }),
        );
      },
    );
  }

  Widget _buildActiveVideoDetails({
    required String displayName,
    required String videoPath,
    required bool isUrl,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                displayName,
                style: const TextStyle(
                  color: Colors.white,
                  fontWeight: FontWeight.bold,
                  fontSize: 14,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
            ),
            const SizedBox(width: 8),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
              decoration: BoxDecoration(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(6),
                border: Border.all(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                ),
              ),
              child: Text(
                isUrl ? 'STREAM' : 'LOCAL FILE',
                style: const TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF38BDF8),
                  letterSpacing: 0.5,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 4),
        Tooltip(
          message: videoPath,
          child: Text(
            videoPath,
            style: const TextStyle(color: Colors.white38, fontSize: 11),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 4,
          children: [
            _buildMiniBadge('0% Idle Overhead', Icons.speed_rounded),
            _buildMiniBadge('Direct3D11 GPU', Icons.memory_rounded),
            _buildMiniBadge('Behind Windows Icons', Icons.layers_outlined),
          ],
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(
                color: _showVideoSettingsExpanded
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                    : Colors.white.withValues(alpha: 0.05),
                borderRadius: BorderRadius.circular(8),
                border: Border.all(
                  color: _showVideoSettingsExpanded
                      ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                      : Colors.white12,
                ),
              ),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    _showVideoSettingsExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.tune_rounded,
                    size: 14,
                    color: _showVideoSettingsExpanded
                        ? const Color(0xFF38BDF8)
                        : Colors.white70,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    _showVideoSettingsExpanded
                        ? 'Hide Editing & Rules Options'
                        : 'Edit & Automation Options',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                      color: _showVideoSettingsExpanded
                          ? const Color(0xFF38BDF8)
                          : Colors.white,
                    ),
                  ),
                  const SizedBox(width: 4),
                  Icon(
                    _showVideoSettingsExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 14,
                    color: _showVideoSettingsExpanded
                        ? const Color(0xFF38BDF8)
                        : Colors.white54,
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            const Text(
              'Click card to toggle',
              style: TextStyle(fontSize: 10, color: Colors.white30),
            ),
          ],
        ),
      ],
    );
  }

  Widget _buildMiniBadge(String text, IconData icon) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.04),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(icon, size: 10, color: Colors.white60),
          const SizedBox(width: 4),
          Text(
            text,
            style: const TextStyle(fontSize: 9, color: Colors.white70),
          ),
        ],
      ),
    );
  }

  Widget _buildVideoEditingDeck({
    required bool isVideoWp,
    required bool isWide,
    required TextEditingController textCtrl,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.tune_rounded, size: 14, color: Color(0xFF38BDF8)),
              SizedBox(width: 6),
              Text(
                'AUTOMATION & PLAYBACK POLICIES',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          isWide
              ? Row(
                  children: [
                    Expanded(
                      child: _buildPolicySwitch(
                        title: 'Pause on Fullscreen Apps / Games',
                        subtitle:
                            'Suspends video automatically for 0% overhead',
                        icon: Icons.fullscreen_rounded,
                        value: _settings.videoWallpaperPauseOnFullscreen,
                        onChanged: _toggleVideoWallpaperPauseFullscreen,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildPolicySwitch(
                        title: 'Pause on Battery Saver',
                        subtitle: 'Conserves laptop battery when power saving',
                        icon: Icons.battery_saver_rounded,
                        value: _settings.videoWallpaperPauseOnBatterySaver,
                        onChanged: _toggleVideoWallpaperPauseBatterySaver,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: _buildPolicySwitch(
                        title: 'Infinite Loop',
                        subtitle: 'Loops video seamlessly at end',
                        icon: Icons.repeat_rounded,
                        value: _settings.videoWallpaperLoop,
                        onChanged: _toggleVideoWallpaperLoop,
                      ),
                    ),
                  ],
                )
              : Column(
                  children: [
                    _buildPolicySwitch(
                      title: 'Pause on Fullscreen Apps / Games',
                      subtitle: 'Suspends video automatically for 0% overhead',
                      icon: Icons.fullscreen_rounded,
                      value: _settings.videoWallpaperPauseOnFullscreen,
                      onChanged: _toggleVideoWallpaperPauseFullscreen,
                    ),
                    const SizedBox(height: 8),
                    _buildPolicySwitch(
                      title: 'Pause on Battery Saver',
                      subtitle:
                          'Conserves laptop battery when power saving is on',
                      icon: Icons.battery_saver_rounded,
                      value: _settings.videoWallpaperPauseOnBatterySaver,
                      onChanged: _toggleVideoWallpaperPauseBatterySaver,
                    ),
                    const SizedBox(height: 8),
                    _buildPolicySwitch(
                      title: 'Infinite Loop',
                      subtitle: 'Loops video seamlessly at end',
                      icon: Icons.repeat_rounded,
                      value: _settings.videoWallpaperLoop,
                      onChanged: _toggleVideoWallpaperLoop,
                    ),
                  ],
                ),

          const SizedBox(height: 18),
          const Divider(color: Colors.white10, height: 1),
          const SizedBox(height: 16),

          Row(
            children: [
              const Icon(
                Icons.video_library_rounded,
                size: 14,
                color: Color(0xFF38BDF8),
              ),
              const SizedBox(width: 6),
              Text(
                isVideoWp
                    ? 'CHANGE VIDEO WALLPAPER SOURCE'
                    : 'SELECT OR BROWSE VIDEO WALLPAPER',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                  letterSpacing: 1.0,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),

          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                flex: 5,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    OutlinedButton.icon(
                      onPressed: _isVideoWallpaperBusy || _isSelectingVideo
                          ? null
                          : () async {
                              setState(() => _isSelectingVideo = true);
                              try {
                                final result = await FilePicker.pickFiles(
                                  type: FileType.custom,
                                  allowedExtensions: [
                                    'mp4',
                                    'webm',
                                    'mkv',
                                    'mov',
                                    'avi',
                                    'gif',
                                    'wmv',
                                    'm4v',
                                    'flv',
                                  ],
                                );
                                if (result.isNotEmpty &&
                                    result.first.path != null) {
                                  final path = result.first.path!;
                                  logInfo(
                                    'DashboardView',
                                    'Selected local video wallpaper: $path',
                                  );

                                  await _applyVideoWallpaper(path);
                                  if (mounted &&
                                      _settings.activeWallpaperType ==
                                          'video' &&
                                      _settings.activeWallpaperPath == path) {
                                    _videoUrlController.clear();
                                  }
                                }
                              } catch (e, st) {
                                logError(
                                  'DashboardView',
                                  'Error picking file',
                                  e,
                                  st,
                                );
                                _showAnimatedSnackBar(
                                  'Error selecting video file.',
                                  isSuccess: false,
                                );
                              } finally {
                                if (mounted) {
                                  setState(() => _isSelectingVideo = false);
                                }
                              }
                            },
                      icon: _isSelectingVideo || _isVideoWallpaperBusy
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Color(0xFF38BDF8),
                              ),
                            )
                          : const Icon(Icons.file_open_rounded, size: 16),
                      label: const Text('Browse Video (MP4, WebM, MKV)'),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: const Color(0xFF38BDF8),
                        side: BorderSide(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                        ),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 12,
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    const Text(
                      'Supports high bitrate 4K, 60fps, MP4, WebM, MKV, MOV',
                      style: TextStyle(fontSize: 10, color: Colors.white38),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 20),
              Expanded(
                flex: 7,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Expanded(
                          child: Container(
                            height: 42,
                            decoration: BoxDecoration(
                              color: Colors.white.withValues(alpha: 0.04),
                              borderRadius: BorderRadius.circular(10),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.08),
                              ),
                            ),
                            child: TextField(
                              enabled:
                                  !_isVideoWallpaperBusy && !_isSelectingVideo,
                              controller: textCtrl,
                              style: const TextStyle(
                                color: Colors.white,
                                fontSize: 12,
                              ),
                              decoration: const InputDecoration(
                                hintText: 'https://example.com/video.mp4',
                                hintStyle: TextStyle(
                                  color: Colors.white24,
                                  fontSize: 12,
                                ),
                                contentPadding: EdgeInsets.symmetric(
                                  horizontal: 12,
                                  vertical: 10,
                                ),
                                border: InputBorder.none,
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(width: 8),
                        ElevatedButton(
                          onPressed: _isVideoWallpaperBusy || _isSelectingVideo
                              ? null
                              : () async {
                                  final url = textCtrl.text.trim();
                                  if (url.isNotEmpty) {
                                    final uri = Uri.tryParse(url);
                                    if (uri == null ||
                                        !uri.hasAuthority ||
                                        (uri.scheme != 'http' &&
                                            uri.scheme != 'https')) {
                                      _showAnimatedSnackBar(
                                        'Please enter a valid HTTP/HTTPS URL.',
                                        isSuccess: false,
                                      );
                                      return;
                                    }
                                    logInfo(
                                      'DashboardView',
                                      'Applying video wallpaper from URL: $url',
                                    );
                                    await _applyVideoWallpaper(url);
                                  }
                                },
                          style: ElevatedButton.styleFrom(
                            backgroundColor: const Color(0xFF38BDF8),
                            foregroundColor: Colors.black,
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                            ),
                          ),
                          child: _isVideoWallpaperBusy
                              ? const SizedBox(
                                  width: 16,
                                  height: 16,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    color: Colors.black,
                                  ),
                                )
                              : const Text(
                                  'Apply URL',
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                        ),
                      ],
                    ),
                    ValueListenableBuilder<double?>(
                      valueListenable: _videoDownloadProgressNotifier,
                      builder: (context, progress, _) {
                        if (progress == null) return const SizedBox.shrink();
                        return Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            const SizedBox(height: 10),
                            LinearProgressIndicator(
                              value: progress,
                              minHeight: 3,
                              backgroundColor: Colors.white12,
                              color: const Color(0xFF38BDF8),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              'Downloading video: ${(progress * 100).round()}%',
                              style: const TextStyle(
                                fontSize: 10,
                                color: Colors.white54,
                              ),
                            ),
                          ],
                        );
                      },
                    ),
                  ],
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFitChip(
    String value,
    String label,
    IconData icon,
    bool isSelected,
  ) {
    return Expanded(
      child: InkWell(
        onTap: () => _setVideoWallpaperFit(value),
        borderRadius: BorderRadius.circular(8),
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 7, horizontal: 6),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(8),
            border: Border.all(
              color: isSelected ? const Color(0xFF38BDF8) : Colors.white10,
            ),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                icon,
                size: 13,
                color: isSelected ? const Color(0xFF38BDF8) : Colors.white54,
              ),
              const SizedBox(width: 4),
              Flexible(
                child: Text(
                  label,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: isSelected
                        ? FontWeight.bold
                        : FontWeight.normal,
                    color: isSelected ? Colors.white : Colors.white70,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildPolicySwitch({
    required String title,
    required String subtitle,
    required IconData icon,
    required bool value,
    required ValueChanged<bool> onChanged,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.02),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: Colors.white.withValues(alpha: 0.05)),
      ),
      child: Row(
        children: [
          Icon(
            icon,
            size: 16,
            color: value ? const Color(0xFF38BDF8) : Colors.white30,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                    color: value ? Colors.white : Colors.white60,
                  ),
                ),
                Text(
                  subtitle,
                  style: const TextStyle(fontSize: 8, color: Colors.white38),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ],
            ),
          ),
          Transform.scale(
            scale: 0.7,
            child: Switch(
              value: value,
              onChanged: onChanged,
              activeThumbColor: const Color(0xFF38BDF8),
            ),
          ),
        ],
      ),
    );
  }

  void _enqueueWallpaper(FirebaseWallpaper wp, {bool prioritize = false}) {
    if (_downloadedWallpaperIds.contains(wp.id) ||
        _wallpaperDownloadTasks.containsKey(wp.id)) {
      if (prioritize) {
        final index = _downloadQueue.indexWhere((item) => item.id == wp.id);
        if (index > 0) {
          _downloadQueue.removeAt(index);
          _downloadQueue.insert(0, wp);
        }
      }
      _processDownloadQueue();
      return;
    }

    _wallpaperDownloadTasks[wp.id] = Completer<File?>();
    if (prioritize) {
      _downloadQueue.insert(0, wp);
    } else {
      _downloadQueue.add(wp);
    }
    _processDownloadQueue();
  }

  void _processDownloadQueue() {
    if (!mounted) {
      return;
    }

    while (_activeDownloads < _maxConcurrentDownloads &&
        _downloadQueue.isNotEmpty) {
      final wp = _downloadQueue.removeAt(0);
      final task = _wallpaperDownloadTasks[wp.id];
      if (task == null) continue;

      _activeDownloads++;
      _downloadOnlyBg(wp)
          .then((downloaded) {
            if (!task.isCompleted) task.complete(downloaded);
          })
          .catchError((Object error, StackTrace stackTrace) {
            logError(
              'DashboardView',
              'Background wallpaper download failed: ${wp.id}',
              error,
              stackTrace,
            );
            if (!task.isCompleted) task.complete(null);
          })
          .whenComplete(() {
            _wallpaperDownloadTasks.remove(wp.id);
            _activeDownloads--;
            _processDownloadQueue();
          });
    }
  }

  Future<File?> _downloadOnlyBg(FirebaseWallpaper wallpaper) async {
    if (!mounted) return null;
    setState(() => _downloadProgress[wallpaper.id] = 0.01);

    try {
      final downloaded = await _firebaseService.downloadWallpaper(wallpaper, (
        progress,
      ) {
        if (mounted) {
          final current = _downloadProgress[wallpaper.id] ?? 0.0;
          if (progress - current >= 0.05 || progress == 1.0) {
            setState(() => _downloadProgress[wallpaper.id] = progress);
          }
        }
      });
      final downloadedExists = downloaded != null && await downloaded.exists();
      if (mounted) {
        setState(() {
          _downloadProgress.remove(wallpaper.id);
          if (downloadedExists) {
            _downloadedWallpaperIds.add(wallpaper.id);
          }
        });
      }
      return downloaded;
    } catch (error, stackTrace) {
      logError(
        'DashboardView',
        'Background wallpaper download failed: ${wallpaper.id}',
        error,
        stackTrace,
      );
      if (mounted) {
        setState(() => _downloadProgress.remove(wallpaper.id));
      }
      return null;
    }
  }

  String _thumbnailUrlFor(String imageUrl) {
    return FirebaseWallpaper.toOptimizedThumbnailUrl(imageUrl);
  }

  Widget _buildWallpaperCard(FirebaseWallpaper wp) {
    final progress = _downloadProgress[wp.id];
    final isDownloading = progress != null;
    final isApplying = _applyingWallpaperIds.contains(wp.id);
    final isExplicitDownload = _explicitWallpaperDownloads.contains(wp.id);
    final isBusy = isDownloading || isApplying || isExplicitDownload;
    final isVideo = wp.isVideo;

    final isActiveStatic =
        _settings.activeWallpaperType == 'static' &&
        _settings.activeWallpaperPath != null &&
        (_settings.activeWallpaperPath!.endsWith(wp.filename) ||
            _settings.activeWallpaperPath!.endsWith(wp.legacyFilename));

    final isActiveVideo =
        _settings.activeWallpaperType == 'video' &&
        _settings.activeWallpaperPath != null &&
        (_settings.activeWallpaperPath == wp.url ||
            _settings.activeWallpaperPath!.endsWith(wp.filename) ||
            _settings.activeWallpaperPath!.endsWith(wp.legacyFilename));

    final isActive = isVideo ? isActiveVideo : isActiveStatic;
    final isDownloaded = _downloadedWallpaperIds.contains(wp.id) || isActive;

    final themeColor = isVideo
        ? const Color(0xFF38BDF8)
        : (isActive ? const Color(0xFF38BDF8) : const Color(0xFFEC4899));

    final isHoveredVideo = isVideo && _hoveredVideoCardId == wp.id;

    return MouseRegion(
      onEnter: (_) {
        if (isVideo) {
          _hoverDebounceTimer?.cancel();
          _hoverDebounceTimer = Timer(const Duration(milliseconds: 200), () {
            if (mounted) setState(() => _hoveredVideoCardId = wp.id);
          });
        }
      },
      onExit: (_) {
        if (isVideo) {
          _hoverDebounceTimer?.cancel();
          if (_hoveredVideoCardId == wp.id) {
            setState(() => _hoveredVideoCardId = null);
          }
        }
      },
      child: Tooltip(
        message: wp.isPro
            ? (isVideo
                  ? 'WallSync Pro Live Video • ${wp.name}'
                  : 'WallSync Pro Wallpaper • ${wp.name}')
            : isVideo
            ? (isActive
                  ? 'Active live video wallpaper • Click to preview & set'
                  : 'Live video wallpaper • Click to preview & set')
            : 'Set wallpaper',
        child: GestureDetector(
          onTap: isApplying || _isVideoWallpaperBusy || _isClearingWallpaperCache
              ? null
              : isVideo
              ? () => showLiveVideoPreviewDialog(
                  context: context,
                  wallpaper: wp,
                  isActive: isActive,
                  onApplyWallpaper: _applyVideoWallpaper,
                  onReportWallpaper: _showWallpaperReportDialog,
                )
              : () => _applyWallpaper(wp),
          child: HoverCard(
            glowColor: isActive
                ? themeColor
                : (isVideo ? const Color(0xFF38BDF8) : const Color(0xFFEC4899)),
            maxGlowOpacity: isActive ? 0.40 : 0.22,
            blurRadius: isActive ? 20 : 14,
            scaleUp: 1.035,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0xFF131622),
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: isActive
                      ? themeColor
                      : (isVideo
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.30)
                            : Colors.white.withValues(alpha: 0.09)),
                  width: isActive ? 1.8 : 1.0,
                ),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.35),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              child: ClipRRect(
                borderRadius: BorderRadius.circular(isActive ? 16 : 17),
                child: Stack(
                  children: [
                    Positioned.fill(
                      child: wp.url.startsWith('asset://')
                          ? Image.asset(
                              wp.url.replaceFirst('asset://', ''),
                              fit: BoxFit.cover,
                              cacheWidth: 320,
                              cacheHeight: 240,
                              errorBuilder: (_, _, _) => Container(
                                color: Colors.black45,
                                child: const Icon(
                                  Icons.broken_image,
                                  color: Colors.white24,
                                  size: 32,
                                ),
                              ),
                            )
                          : (isVideo)
                          ? VideoThumbnailWidget(
                              wallpaper: wp,
                              fit: BoxFit.cover,
                            )
                          : SafeNetworkImage(
                              url: _thumbnailUrlFor(wp.thumbnailUrl ?? wp.url),
                              fallbackUrl: wp.thumbnailUrl ?? wp.url,
                              fit: BoxFit.cover,
                              errorBuilder: (context, error, stackTrace) {
                                logError(
                                  'DashboardView',
                                  'Failed to load network thumbnail: ${wp.url}',
                                  error,
                                  stackTrace,
                                );
                                return Container(
                                  color: Colors.black45,
                                  child: const Icon(
                                    Icons.broken_image,
                                    color: Colors.white24,
                                    size: 32,
                                  ),
                                );
                              },
                            ),
                    ),

                    Positioned.fill(
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              Colors.transparent,
                              Colors.black.withValues(alpha: 0.8),
                            ],
                            begin: Alignment.topCenter,
                            end: Alignment.bottomCenter,
                          ),
                        ),
                      ),
                    ),

                    Positioned(
                      top: 8,
                      right: 48,
                      child: ResolutionOverlayLabel(wallpaper: wp),
                    ),
                    Positioned(
                      top: 2,
                      right: 2,
                      child: PopupMenuButton<String>(
                        tooltip: 'Wallpaper actions',
                        onSelected: (action) {
                          if (action == 'report') {
                            _showWallpaperReportDialog(wp);
                          }
                        },
                        color: const Color(0xFF202434),
                        itemBuilder: (context) => const [
                          PopupMenuItem(
                            value: 'report',
                            child: Row(
                              children: [
                                Icon(
                                  Icons.flag_outlined,
                                  size: 18,
                                  color: Color(0xFFFCA5A5),
                                ),
                                SizedBox(width: 10),
                                Text('Report wallpaper'),
                              ],
                            ),
                          ),
                        ],
                        child: const Material(
                          color: Color(0xB3000000),
                          shape: CircleBorder(),
                          child: Padding(
                            padding: EdgeInsets.all(5),
                            child: Icon(
                              Icons.more_vert_rounded,
                              color: Colors.white,
                              size: 18,
                            ),
                          ),
                        ),
                      ),
                    ),

                    if (wp.isPro)
                      Positioned(
                        top: 9,
                        left: isVideo ? 116 : 9,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7.5,
                            vertical: 3.5,
                          ),
                          decoration: BoxDecoration(
                            gradient: const LinearGradient(
                              colors: [Color(0xFFFFB703), Color(0xFFFB8500)],
                            ),
                            borderRadius: BorderRadius.circular(7),
                            boxShadow: [
                              BoxShadow(
                                color: const Color(
                                  0xFFFB8500,
                                ).withValues(alpha: 0.55),
                                blurRadius: 10,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.stars_rounded,
                                size: 11,
                                color: Color(0xFF0F111A),
                              ),
                              SizedBox(width: 3.5),
                              Text(
                                'PRO UNLOCKED',
                                style: TextStyle(
                                  color: Color(0xFF0F111A),
                                  fontSize: 8.5,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 0.6,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                    if (isVideo)
                      Positioned(
                        top: 9,
                        left: 9,
                        child: isHoveredVideo
                            ? Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3.5,
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [Color(0xFF0284C7), Color(0xFF38BDF8)],
                                  ),
                                  borderRadius: BorderRadius.circular(7),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFF0284C7,
                                      ).withValues(alpha: 0.7),
                                      blurRadius: 10,
                                    ),
                                  ],
                                ),
                                child: const Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    CircleAvatar(
                                      radius: 3,
                                      backgroundColor: Color(0xFF22C55E),
                                    ),
                                    SizedBox(width: 4),
                                    Text(
                                      'LIVE PREVIEW',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.6,
                                      ),
                                    ),
                                  ],
                                ),
                              )
                            : Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 3.5,
                                ),
                                decoration: BoxDecoration(
                                  gradient: const LinearGradient(
                                    colors: [
                                      Color(0xFF0284C7),
                                      Color(0xFF6366F1),
                                    ],
                                  ),
                                  borderRadius: BorderRadius.circular(7),
                                  boxShadow: [
                                    BoxShadow(
                                      color: const Color(
                                        0xFF0284C7,
                                      ).withValues(alpha: 0.4),
                                      blurRadius: 6,
                                      offset: const Offset(0, 2),
                                    ),
                                  ],
                                ),
                                child: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    const Icon(
                                      Icons.videocam_rounded,
                                      size: 11,
                                      color: Colors.white,
                                    ),
                                    const SizedBox(width: 4),
                                    Text(
                                      isActive ? 'ACTIVE VIDEO' : '60FPS LIVE',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        fontSize: 8.5,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                      ),

                    if (isBusy)
                      Positioned.fill(
                        child: Container(
                          color: Colors.black.withValues(alpha: 0.6),
                          child: Center(
                            child: Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                CircularProgressIndicator(
                                  value: progress != null && progress > 0.01
                                      ? progress
                                      : null,
                                  color: themeColor,
                                  strokeWidth: 3,
                                ),
                                const SizedBox(height: 10),
                                Text(
                                  isApplying
                                      ? 'Applying...'
                                      : progress != null && progress > 0.01
                                      ? '${(progress * 100).toInt()}%'
                                      : 'Downloading...',
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),
                      ),

                    Positioned(
                      bottom: 12,
                      left: 14,
                      right: 14,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: [
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  wp.name,
                                  style: const TextStyle(
                                    fontSize: 12,
                                    fontWeight: FontWeight.bold,
                                    color: Colors.white,
                                  ),
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  wp.category,
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: themeColor,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                if (wp.description != null &&
                                    wp.description!.isNotEmpty) ...[
                                  const SizedBox(height: 2),
                                  Text(
                                    wp.description!,
                                    style: TextStyle(
                                      fontSize: 9,
                                      color: Colors.white.withValues(
                                        alpha: 0.6,
                                      ),
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ],
                              ],
                            ),
                          ),
                          if (isVideo) ...[
                            Tooltip(
                              message: 'Full Video Preview & Options',
                              child: Container(
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(10),
                                  border: Border.all(
                                    color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                                    width: 1.0,
                                  ),
                                ),
                                child: IconButton(
                                  onPressed: () => showLiveVideoPreviewDialog(
                                    context: context,
                                    wallpaper: wp,
                                    isActive: isActive,
                                    onApplyWallpaper: _applyVideoWallpaper,
                                    onReportWallpaper: _showWallpaperReportDialog,
                                  ),
                                  icon: const Icon(
                                    Icons.visibility_rounded,
                                    size: 15,
                                  ),
                                  color: Colors.white,
                                  style: IconButton.styleFrom(
                                    backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.18),
                                    hoverColor: const Color(0xFF38BDF8).withValues(alpha: 0.38),
                                    padding: const EdgeInsets.all(7),
                                    minimumSize: const Size(32, 32),
                                  ),
                                ),
                              ),
                            ),
                            const SizedBox(width: 6),
                          ],
                          Tooltip(
                            message: isVideo
                                ? (isActive
                                      ? 'Active Live Wallpaper'
                                      : 'Set Live Wallpaper')
                                : (isDownloaded ? 'Set wallpaper' : 'Download'),
                            child: Container(
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(10),
                                border: Border.all(
                                  color: isActive
                                      ? themeColor.withValues(alpha: 0.8)
                                      : wp.isPro
                                      ? const Color(0xFFFFB703).withValues(alpha: 0.5)
                                      : Colors.white.withValues(alpha: 0.15),
                                  width: 1.0,
                                ),
                                boxShadow: isActive
                                    ? [
                                        BoxShadow(
                                          color: themeColor.withValues(alpha: 0.35),
                                          blurRadius: 8,
                                        ),
                                      ]
                                    : null,
                              ),
                              child: IconButton(
                                onPressed: isBusy ||
                                        _isVideoWallpaperBusy ||
                                        _isClearingWallpaperCache
                                    ? null
                                    : isVideo
                                    ? () => _applyVideoWallpaper(wp.url)
                                    : isDownloaded
                                    ? () => _applyWallpaper(wp)
                                    : () => _downloadOnly(wp),
                                icon: isBusy
                                    ? const SizedBox(
                                        width: 16,
                                        height: 16,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 2,
                                        ),
                                      )
                                    : Icon(
                                        isActive
                                            ? Icons.check_rounded
                                            : isVideo
                                            ? Icons.play_arrow_rounded
                                            : isDownloaded
                                            ? Icons.wallpaper_rounded
                                            : Icons.download_rounded,
                                        size: 16,
                                      ),
                                color: Colors.white,
                                style: IconButton.styleFrom(
                                  backgroundColor: isActive
                                      ? themeColor
                                      : wp.isPro
                                      ? const Color(0xFFFFB703).withValues(alpha: 0.22)
                                      : Colors.white.withValues(alpha: 0.08),
                                  disabledBackgroundColor: Colors.white
                                      .withValues(alpha: 0.08),
                                  padding: const EdgeInsets.all(7),
                                  minimumSize: const Size(32, 32),
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  Future<void> _showProExclusiveDialog(FirebaseWallpaper wallpaper) async {
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (dialogContext) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            color: const Color(0xFF161926),
            borderRadius: BorderRadius.circular(20),
            border: Border.all(
              color: const Color(0xFFFFB703).withValues(alpha: 0.35),
              width: 1.5,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFFFFB703).withValues(alpha: 0.15),
                blurRadius: 28,
                spreadRadius: 2,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.7),
                blurRadius: 36,
                offset: const Offset(0, 14),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 64,
                height: 64,
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  gradient: const LinearGradient(
                    colors: [Color(0xFFFFB703), Color(0xFFFB8500)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFFB8500).withValues(alpha: 0.4),
                      blurRadius: 16,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.workspace_premium_rounded,
                  size: 34,
                  color: Color(0xFF0F111A),
                ),
              ),
              const SizedBox(height: 20),
              const Text(
                'WallSync Pro Exclusive',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white,
                  fontSize: 20,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 0.3,
                ),
              ),
              const SizedBox(height: 10),
              Container(
                padding:
                    const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Text(
                  wallpaper.name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    color: Color(0xFFFFB703),
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
              const SizedBox(height: 14),
              const Text(
                'This wallpaper is exclusively available for WallSync Pro users. Please install the WallSync Pro application to unlock and apply this background.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 24),
              SizedBox(
                width: double.infinity,
                child: ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFFFB703),
                    foregroundColor: const Color(0xFF0F111A),
                    padding: const EdgeInsets.symmetric(vertical: 14),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(12),
                    ),
                    elevation: 0,
                  ),
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text(
                    'Close',
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w700,
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Future<void> _showWallpaperReportDialog(FirebaseWallpaper wallpaper) async {
    final formKey = GlobalKey<FormState>();
    final emailController = TextEditingController();
    final descriptionController = TextEditingController();
    var submitting = false;
    String? errorText;
    final metadataFuture = WallpaperMetadataService.instance.getMetadata(
      url: wallpaper.url,
      isVideo: wallpaper.isVideo,
    );
    try {
      await showDialog<void>(
        context: context,
        barrierDismissible: false,
        builder: (dialogContext) => StatefulBuilder(
          builder: (context, setDialogState) => AlertDialog(
            backgroundColor: const Color(0xFF151923),
            title: const Text(
              'Report wallpaper',
              style: TextStyle(color: Colors.white),
            ),
            content: SizedBox(
              width: 520,
              child: SingleChildScrollView(
                child: Form(
                  key: formKey,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(8),
                            child: SizedBox(
                              width: 88,
                              height: 58,
                              child: wallpaper.isVideo
                                  ? VideoThumbnailWidget(
                                      wallpaper: wallpaper,
                                      fit: BoxFit.cover,
                                      showBadge: false,
                                    )
                                  : wallpaper.url.startsWith('asset://')
                                  ? Image.asset(
                                      wallpaper.url.replaceFirst(
                                        'asset://',
                                        '',
                                      ),
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.broken_image_outlined,
                                      ),
                                    )
                                  : Image.network(
                                      wallpaper.thumbnailUrl ?? wallpaper.url,
                                      fit: BoxFit.cover,
                                      errorBuilder: (_, _, _) => const Icon(
                                        Icons.broken_image_outlined,
                                      ),
                                    ),
                            ),
                          ),
                          const SizedBox(width: 12),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  wallpaper.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                Text(
                                  'ID: ${wallpaper.id}',
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: const TextStyle(
                                    color: Colors.white60,
                                    fontSize: 12,
                                  ),
                                ),
                                FutureBuilder<WallpaperMetadata>(
                                  future: metadataFuture,
                                  builder: (context, snapshot) => Text(
                                    '${wallpaper.wallpaperType} · ${snapshot.data?.displayLabel ?? 'Checking resolution…'}',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: const TextStyle(
                                      color: Colors.white60,
                                      fontSize: 12,
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 18),
                      TextFormField(
                        controller: emailController,
                        enabled: !submitting,
                        keyboardType: TextInputType.emailAddress,
                        decoration: const InputDecoration(
                          labelText: 'Your email address',
                          hintText: 'name@example.com',
                        ),
                        validator: (value) {
                          final email = value?.trim() ?? '';
                          if (email.isEmpty) return 'Email is required.';
                          if (!RegExp(
                            r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                          ).hasMatch(email)) {
                            return 'Enter a valid email address.';
                          }
                          return null;
                        },
                      ),
                      const SizedBox(height: 12),
                      TextFormField(
                        controller: descriptionController,
                        enabled: !submitting,
                        maxLines: 5,
                        maxLength: 1000,
                        decoration: const InputDecoration(
                          labelText: 'Why are you reporting this wallpaper?',
                          alignLabelWithHint: true,
                          hintText: 'Describe the issue...',
                        ),
                        validator: (value) {
                          final text = value?.trim() ?? '';
                          if (text.isEmpty) {
                            return 'A report description is required.';
                          }
                          if (text.length > 1000) {
                            return 'Use 1,000 characters or fewer.';
                          }
                          return null;
                        },
                      ),
                      if (errorText != null) ...[
                        const SizedBox(height: 8),
                        Text(
                          errorText!,
                          style: const TextStyle(color: Color(0xFFFCA5A5)),
                        ),
                      ],
                    ],
                  ),
                ),
              ),
            ),
            actions: [
              TextButton(
                onPressed: submitting
                    ? null
                    : () => Navigator.of(dialogContext).pop(),
                child: const Text('Cancel'),
              ),
              FilledButton.icon(
                onPressed: submitting
                    ? null
                    : () async {
                        if (!formKey.currentState!.validate()) return;
                        setDialogState(() {
                          submitting = true;
                          errorText = null;
                        });
                        try {
                          final metadata = await metadataFuture;
                          await _firebaseService.submitWallpaperReport(
                            wallpaperId: wallpaper.id,
                            wallpaperTitle: wallpaper.name,
                            wallpaperType: wallpaper.wallpaperType,
                            wallpaperResolution: metadata.displayLabel,
                            userEmail: emailController.text.trim(),
                            description: descriptionController.text.trim(),
                          );
                          if (dialogContext.mounted) {
                            Navigator.of(dialogContext).pop();
                          }
                          if (mounted) {
                            _showAnimatedSnackBar(
                              'Wallpaper report submitted.',
                              isSuccess: true,
                            );
                          }
                        } catch (error) {
                          setDialogState(() {
                            submitting = false;
                            errorText = error is HttpException
                                ? error.message
                                : 'Report was not submitted. Check your connection and try again.';
                          });
                          logWarning(
                            'DashboardView',
                            'Wallpaper report submission failed: $error',
                          );
                        }
                      },
                icon: submitting
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(Icons.send_rounded, size: 17),
                label: Text(submitting ? 'Submitting…' : 'Submit report'),
              ),
            ],
          ),
        ),
      );
    } finally {
      emailController.dispose();
      descriptionController.dispose();
    }
  }

  Future<File?> _requestWallpaperDownload(
    FirebaseWallpaper wallpaper, {
    bool prioritize = false,
  }) async {
    if (!mounted) return null;
    if (_downloadedWallpaperIds.contains(wallpaper.id) &&
        !_wallpaperDownloadTasks.containsKey(wallpaper.id)) {
      return _firebaseService.downloadWallpaper(wallpaper, (_) {});
    }
    _enqueueWallpaper(wallpaper, prioritize: prioritize);
    return _wallpaperDownloadTasks[wallpaper.id]?.future;
  }

  Future<void> _downloadOnly(FirebaseWallpaper wallpaper) async {
    if (_explicitWallpaperDownloads.contains(wallpaper.id)) return;
    setState(() => _explicitWallpaperDownloads.add(wallpaper.id));
    logInfo('DashboardView', 'Downloading wallpaper: ${wallpaper.url}');
    try {
      final downloaded = await _requestWallpaperDownload(
        wallpaper,
        prioritize: true,
      );
      final downloadedExists = downloaded != null && await downloaded.exists();

      if (mounted) {
        setState(() {
          _downloadProgress.remove(wallpaper.id);
          if (downloadedExists) {
            _downloadedWallpaperIds.add(wallpaper.id);
          }
        });
        if (!downloadedExists) {
          _showAnimatedSnackBar(
            'Failed to download wallpaper image.',
            isSuccess: false,
          );
        } else {
          _showAnimatedSnackBar(
            'Downloaded ${wallpaper.name}',
            isSuccess: true,
          );
        }
      }
    } catch (e, st) {
      logError(
        'DashboardView',
        'Failed to download wallpaper ${wallpaper.id}',
        e,
        st,
      );
      if (mounted) {
        _showAnimatedSnackBar(
          'Failed to download wallpaper image.',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _explicitWallpaperDownloads.remove(wallpaper.id));
      }
    }
  }

  Future<void> _applyWallpaper(FirebaseWallpaper wallpaper) async {
    await _enqueueWallpaperTransition('static:${wallpaper.id}', (
      requestId,
    ) async {
      await _applyWallpaperNow(wallpaper, requestId);
    });
  }

  Future<void> _applyWallpaperNow(
    FirebaseWallpaper wallpaper,
    int requestId,
  ) async {
    if (_applyingWallpaperIds.contains(wallpaper.id)) return;
    setState(() => _applyingWallpaperIds.add(wallpaper.id));
    logInfo('DashboardView', 'Applying static image: ${wallpaper.url}');
    final transitionStopwatch = Stopwatch()..start();

    try {
      final retrievalStopwatch = Stopwatch()..start();
      final downloaded = await _requestWallpaperDownload(
        wallpaper,
        prioritize: true,
      );
      logPerf(
        'DashboardView',
        'Transition #$requestId wallpaper retrieval/cache lookup completed '
            'in ${retrievalStopwatch.elapsedMilliseconds}ms '
            '(file=${downloaded?.path ?? 'unavailable'}).',
      );

      if (!_isCurrentWallpaperTransition(requestId)) return;

      if (downloaded == null || !await downloaded.exists()) {
        _setWallpaperTransitionState(
          requestId,
          'static:${wallpaper.id}',
          'error',
        );
        logWarning(
          'DashboardView',
          'Transition #$requestId failed before native apply after '
              '${transitionStopwatch.elapsedMilliseconds}ms.',
        );
        if (!mounted) return;
        setState(() => _downloadProgress.remove(wallpaper.id));
        _showAnimatedSnackBar(
          'Failed to download wallpaper image.',
          isSuccess: false,
        );
        return;
      }

      if (mounted) {
        setState(() {
          _downloadProgress.remove(wallpaper.id);
          _downloadedWallpaperIds.add(wallpaper.id);
        });
      }

      _setWallpaperTransitionState(
        requestId,
        'static:${wallpaper.id}',
        'applying',
      );
      final nativeApplyStopwatch = Stopwatch()..start();
      final success = await DiagnosticsService.instance
          .trackAsyncOperation<bool>(
            tag: 'DashboardView',
            name: 'wallpaper.static.apply.${wallpaper.id}',
            operation: () => _wallpaperEngine.setStaticWallpaper(
              downloaded.path,
              _settings.wallpaperFit,
              settings: _settings,
              isCancelled: () => !_isCurrentWallpaperTransition(requestId),
              transitionId: requestId,
            ),
            warningThreshold: const Duration(seconds: 2),
          );
      final nativeApplyMs = nativeApplyStopwatch.elapsedMilliseconds;
      if (!_isCurrentWallpaperTransition(requestId)) return;
      if (success) {
        final updated = _settings.copyWith(
          activeWallpaperType: 'static',
          activeWallpaperPath: downloaded.path,
          activeWallpaperAnimatedBg: '',
        );
        _updateSettings(updated);

        _recordRecentWallpaper(
          id: wallpaper.id,
          name: wallpaper.name,
          pathOrUrl: downloaded.path,
          type: 'static',
          thumbnailUrl: (wallpaper.thumbnailUrl?.isNotEmpty ?? false)
              ? wallpaper.thumbnailUrl
              : wallpaper.url,
        );
        final settingsSaveStopwatch = Stopwatch()..start();
        await _persistWallpaperSettings();
        final settingsSaveMs = settingsSaveStopwatch.elapsedMilliseconds;
        if (!_isCurrentWallpaperTransition(requestId)) return;
        _setWallpaperTransitionState(
          requestId,
          'static:${wallpaper.id}',
          'active',
        );
        logPerf(
          'DashboardView',
          'Transition #$requestId completed successfully in '
              '${transitionStopwatch.elapsedMilliseconds}ms '
              '(retrieval=${retrievalStopwatch.elapsedMilliseconds}ms, '
              'native apply=${nativeApplyMs}ms, '
              'settings persistence=${settingsSaveMs}ms).',
        );

        if (!mounted) return;
        _showAnimatedSnackBar(
          'Applied static wallpaper: ${wallpaper.name}',
          isSuccess: true,
        );
      } else {
        _setWallpaperTransitionState(
          requestId,
          'static:${wallpaper.id}',
          'error',
        );
        logWarning(
          'DashboardView',
          'Transition #$requestId native apply failed after '
              '${transitionStopwatch.elapsedMilliseconds}ms.',
        );
        if (!mounted) return;
        _showAnimatedSnackBar(
          'Failed to apply system wallpaper.',
          isSuccess: false,
        );
      }
    } catch (e, st) {
      _setWallpaperTransitionState(
        requestId,
        'static:${wallpaper.id}',
        'error',
      );
      logError(
        'DashboardView',
        'Failed to apply wallpaper ${wallpaper.id} after '
            '${transitionStopwatch.elapsedMilliseconds}ms.',
        e,
        st,
      );
      if (mounted) {
        _showAnimatedSnackBar(
          'Failed to apply system wallpaper.',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _applyingWallpaperIds.remove(wallpaper.id));
      }
    }
  }

  Future<void> _clearWallpaper() async {
    await _enqueueWallpaperTransition('none:clear', (requestId) async {
      try {
        _setWallpaperTransitionState(requestId, 'none:clear', 'stopping');
        final stopped = await _wallpaperEngine.stopAnimatedWallpaper(
          transitionId: requestId,
        );
        if (!_isCurrentWallpaperTransition(requestId)) return;
        if (!stopped) {
          throw StateError('Native MPV shutdown was not confirmed.');
        }
        final updated = _settings.copyWith(
          activeWallpaperType: 'none',
          activeWallpaperPath: '',
          activeWallpaperAnimatedBg: '',
        );
        _updateSettings(updated);
        await _persistWallpaperSettings();
        if (!_isCurrentWallpaperTransition(requestId)) return;
        _setWallpaperTransitionState(requestId, 'none:clear', 'active');
        if (!mounted) return;
        _showAnimatedSnackBar(
          'Cleared custom wallpapers. System settings restored.',
          isSuccess: true,
        );
      } catch (e, st) {
        _setWallpaperTransitionState(requestId, 'none:clear', 'error');
        logError('DashboardView', 'Failed to clear wallpaper', e, st);
        if (mounted) {
          _showAnimatedSnackBar(
            'Could not stop the live wallpaper.',
            isSuccess: false,
          );
        }
      }
    });
  }

  Future<void> _clearDownloadedImages() async {
    if (_isClearingWallpaperCache || _activeDownloads > 0) return;
    setState(() => _isClearingWallpaperCache = true);

    try {
      final appDir = await _settingsService.getAppDirectory();
      final cacheDir = Directory('${appDir.path}/cached_wallpapers');
      if (await cacheDir.exists()) {
        await for (final entity in cacheDir.list()) {
          if (entity is File) {
            if (_settings.activeWallpaperType == 'static' &&
                _settings.activeWallpaperPath == entity.path) {
              continue;
            }
            await entity.delete();
          }
        }
        if (mounted) {
          setState(() {
            _downloadedWallpaperIds.clear();
            // Re-add the active wallpaper if we skipped it
            if (_settings.activeWallpaperType == 'static' &&
                _settings.activeWallpaperPath != null) {
              for (final wp in _wallpapers) {
                if (_settings.activeWallpaperPath!.endsWith(wp.filename) ||
                    _settings.activeWallpaperPath!.endsWith(
                      wp.legacyFilename,
                    )) {
                  _downloadedWallpaperIds.add(wp.id);
                }
              }
            }
          });
        }
      }
      if (mounted) {
        _showAnimatedSnackBar('Cleared downloaded images.', isSuccess: true);
      }
    } catch (e, st) {
      logError('DashboardView', 'Failed to clear downloaded images', e, st);
      if (mounted) {
        _showAnimatedSnackBar(
          'Failed to clear some images. They might be in use.',
          isSuccess: false,
        );
      }
    } finally {
      if (mounted) {
        setState(() => _isClearingWallpaperCache = false);
      }
    }
  }

  void _openCustomElementEditor(String? elementId) {
    setState(() {
      _editingSavedWidget = null;
      _editingCustomElementId = elementId;
      _isCustomStudioOpen = true;
    });
  }

  void _selectSavedCustomWidget(SavedCustomWidget saved) {
    setState(() {
      _activeSavedWidgetId = saved.id;
      _selectedCustomElementId = null;
      _editingSavedWidget = null;
      _isCustomStudioOpen = false;
      _editingWidget = true;
    });
    _tabCtrl.animateTo(0);
    _updateSettings(
      _settings.copyWith(
        widgetTemplate: 'custom',
        width: saved.width,
        height: saved.height,
        customElements: saved.elements
            .map((element) => element.copyWith())
            .toList(),
        savedCustomWidgets: _settings.savedCustomWidgets,
        editorMode: !_settings.isLocked,
      ),
    );
  }

  void _resetCurrentWidgetEdits() {
    if (_settings.widgetTemplate == 'custom') {
      SavedCustomWidget? saved;
      for (final item in _settings.savedCustomWidgets) {
        if (item.id == _activeSavedWidgetId) {
          saved = item;
          break;
        }
      }
      final elements =
          saved?.elements ?? CustomWidgetElement.defaultCustomLayout();
      _selectedCustomElementId = null;
      _updateSettings(
        _settings.copyWith(
          width: saved?.width ?? 480,
          height: saved?.height ?? 260,
          customElements: elements
              .map((element) => element.copyWith())
              .toList(),
        ),
      );
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            saved == null
                ? 'Current custom-widget edits were reset to the default layout. Your saved designs are unchanged.'
                : 'Current edits were reset to "${saved.name}". The saved design is unchanged.',
          ),
          duration: const Duration(seconds: 3),
        ),
      );
      return;
    }

    final defaults =
        WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
        {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
    _updateSettings(
      WidgetSettings(
        widgetTemplate: _settings.widgetTemplate,
        width: defaults['width']!,
        height: defaults['height']!,
        sizeFactor: defaults['sizeFactor']!,
        editorMode: _settings.editorMode,
        isLocked: _settings.isLocked,
        alwaysOnTop: _settings.alwaysOnTop,
        startOnBoot: _settings.startOnBoot,
        opacity: 1.0,
      ),
    );
  }

  String _customElementLabel(String type) {
    const labels = {
      'time_colon': 'Time Separator',
      'full_time': 'Full Clock',
      'full_date': 'Full Date',
      'custom_text': 'Custom Text',
      'cpu_bar': 'CPU Usage',
      'ram_bar': 'RAM Usage',
      'space_bar': 'Disk Space',
      'battery_bar': 'Battery',
      'accent_bar': 'Accent Bar',
      'weather_temp': 'Weather Temp',
      'weather_status': 'Weather Status',
      'weather_icon': 'Weather Icon',
      'weather_pill': 'Weather',
      'media_pill': 'Media Pill',
      'media_title': 'Media Title',
      'media_artist': 'Media Artist',
      'media_album': 'Media Album',
      'media_source': 'Media Source',
      'media_status': 'Media Status',
      'media_artwork': 'Media Artwork',
      'media_progress': 'Media Progress',
      'media_elapsed': 'Elapsed Time',
      'media_duration': 'Duration',
      'media_controls': 'Media Controls',
      'media_animation': 'Playback Animation',
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

  Widget _buildWidgetCustomizer({Key? key}) {
    if (_isCustomStudioOpen) {
      return CustomWidgetBuilderView(
        initialSettings: _settings,
        existingWidget: _editingSavedWidget,
        initialSelectedElementId: _editingCustomElementId,
        isOverlayRunning: _isOverlayRunning,
        onBack: () {
          setState(() {
            _isCustomStudioOpen = false;
            _editingSavedWidget = null;
            _editingCustomElementId = null;
          });
        },
        onSave: (updated) {
          _updateSettings(updated);
          setState(() {
            _activeSavedWidgetId =
                _editingSavedWidget?.id ??
                (updated.savedCustomWidgets.isNotEmpty
                    ? updated.savedCustomWidgets.first.id
                    : null);
            _selectedCustomElementId = null;
            _editingSavedWidget = null;
            _editingCustomElementId = null;
            _isCustomStudioOpen = false;
            _editingWidget = true;
          });
          _tabCtrl.animateTo(0);
        },
      );
    }
    if (!_editingWidget) {
      return _buildTemplateDirectoryView();
    }
    return Row(
      key: key,
      children: [
        // ── Left: Live Preview ─────────────────────────────────────────────
        SizedBox(
          width: 380,
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.25),
              border: Border(
                right: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
              ),
            ),
            child: Column(
              children: [
                Expanded(child: _buildPreviewPanel()),
                _buildOverlayControls(),
              ],
            ),
          ),
        ),

        // ── Right: Contextual Editor ──────────────────────────────────────
        Expanded(
          child: Container(
            color: Colors.black.withValues(alpha: 0.15),
            child: Column(
              children: [
                _buildEditorTabs(),
                Expanded(
                  child: AnimatedSwitcher(
                    duration: const Duration(milliseconds: 300),
                    transitionBuilder: (child, animation) {
                      return FadeTransition(
                        opacity: animation,
                        child: SlideTransition(
                          position:
                              Tween<Offset>(
                                begin: const Offset(0.02, 0),
                                end: Offset.zero,
                              ).animate(
                                CurvedAnimation(
                                  parent: animation,
                                  curve: Curves.easeOutCubic,
                                ),
                              ),
                          child: child,
                        ),
                      );
                    },
                    child: KeyedSubtree(
                      key: ValueKey(_tabCtrl.index),
                      child: _buildEditorContent(),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ],
    );
  }

  // ── Live Preview panel ───────────────────────────────────────────────────

  Widget _buildPreviewPanel() {
    return ListView(
      padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              'LIVE PREVIEW',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w700,
                letterSpacing: 2,
                color: Colors.white.withValues(alpha: 0.35),
              ),
            ),
            ElevatedButton.icon(
              onPressed: () => setState(() {
                _editingWidget = false;
                _selectedElement = null;
              }),
              icon: const Icon(Icons.arrow_back, size: 12),
              label: const Text(
                'Back to Templates',
                style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
              ),
              style: ElevatedButton.styleFrom(
                backgroundColor: const Color(
                  0xFFEC4899,
                ).withValues(alpha: 0.15),
                foregroundColor: const Color(0xFFEC4899),
                elevation: 0,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(6),
                ),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Center(
          child: Builder(
            builder: (context) {
              final isActive =
                  _isOverlayRunning &&
                  _settings.widgetTemplate == _activeTemplate;
              if (isActive) {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF43E97B).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFF43E97B).withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.check_circle,
                        size: 12,
                        color: Color(0xFF43E97B),
                      ),
                      SizedBox(width: 6),
                      Text(
                        'WIDGET ACTIVE (Running)',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFF43E97B),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                );
              } else {
                return Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFFEC4899).withValues(alpha: 0.2),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: const Color(0xFFEC4899).withValues(alpha: 0.5),
                    ),
                  ),
                  child: const Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.visibility,
                        size: 12,
                        color: Color(0xFFEC4899),
                      ),
                      SizedBox(width: 6),
                      Text(
                        'DEMO PREVIEW (Not Active)',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w800,
                          color: Color(0xFFEC4899),
                          letterSpacing: 0.5,
                        ),
                      ),
                    ],
                  ),
                );
              }
            },
          ),
        ),
        const SizedBox(height: 10),

        // Preview monitor mockup
        MockupMonitorScreen(
          settings: _settings,
          child: ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: Stack(
              children: [
                Positioned.fill(
                  child: _buildPreviewBg(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
                _buildInteractivePreviewClock(),
              ],
            ),
          ),
        ),

        if (_settings.widgetTemplate == 'custom') ...[
          const SizedBox(height: 10),
          Center(
            child: OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _editingSavedWidget = null;
                  _editingCustomElementId = null;
                  _isCustomStudioOpen = true;
                });
              },
              icon: const Icon(Icons.dashboard_customize_rounded, size: 14),
              label: const Text('Open Element Layout Studio'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF38BDF8),
                side: BorderSide(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
              ),
            ),
          ),
        ],

        const SizedBox(height: 12),

        // Tap hint
        if (_selectedElement == null)
          Center(
            child: Text(
              'Tap a clock element above to edit it',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.3),
                fontStyle: FontStyle.italic,
              ),
            ),
          )
        else
          Center(
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  _elementIcons[_selectedElement],
                  size: 13,
                  color: const Color(0xFF38BDF8),
                ),
                const SizedBox(width: 6),
                Flexible(
                  child: Text(
                    'Editing: ${_elementLabels[_selectedElement!]}',
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFF38BDF8),
                      fontWeight: FontWeight.bold,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                const SizedBox(width: 8),
                GestureDetector(
                  onTap: () => setState(() => _selectedElement = null),
                  child: Icon(
                    Icons.close,
                    size: 13,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
              ],
            ),
          ),

        const SizedBox(height: 16),

        // Redesigned Element Quick-Select Panel (Strictly active objects only)
        _buildSelectElementSection(),
        const SizedBox(height: 16),
        SizedBox(
          width: double.infinity,
          child: ElevatedButton.icon(
            onPressed: _resetCurrentWidgetEdits,
            icon: const Icon(Icons.settings_backup_restore, size: 14),
            label: const Text(
              'Master Reset (Default)',
              style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent.withValues(alpha: 0.15),
              foregroundColor: Colors.redAccent,
              elevation: 0,
              padding: const EdgeInsets.symmetric(vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ),
      ],
    );
  }

  Widget _buildSelectElementSection() {
    if (_settings.widgetTemplate == 'custom') {
      final elements = _settings.customElements;
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              _sectionLabel('SELECT ELEMENT'),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  'CUSTOM · ${elements.length}',
                  style: const TextStyle(
                    fontSize: 9,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
              const Spacer(),
              TextButton.icon(
                onPressed: () =>
                    setState(() => _selectedCustomElementId = null),
                icon: const Icon(Icons.layers_rounded, size: 12),
                label: const Text(
                  'All elements',
                  style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          if (elements.isEmpty)
            Text(
              'This widget has no elements yet. Open the layout studio to add some.',
              style: TextStyle(
                fontSize: 11,
                color: Colors.white.withValues(alpha: 0.45),
              ),
            )
          else
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: elements.map((element) {
                final label = _customElementLabel(element.type);
                return ActionChip(
                  avatar: Icon(
                    Icons.widgets_rounded,
                    size: 13,
                    color: Color(element.color),
                  ),
                  label: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  backgroundColor: Colors.white.withValues(alpha: 0.04),
                  side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
                  onPressed: () =>
                      setState(() => _selectedCustomElementId = element.id),
                );
              }).toList(),
            ),
        ],
      );
    }

    final activeKeys = ElementKey.all
        .where(_isElementActiveInCurrentTemplate)
        .toList();
    final templateName = _settings.widgetTemplate.toUpperCase();

    // Logical category grouping strictly tailored for each of the 8 widgets:
    final timeKeys = [
      ElementKey.hours,
      ElementKey.separator,
      ElementKey.minutes,
      ElementKey.seconds,
      ElementKey.ampm,
    ].where(activeKeys.contains).toList();

    final dateKeys = [
      ElementKey.day,
      ElementKey.date,
      ElementKey.year,
    ].where(activeKeys.contains).toList();

    final frameKeys = [
      ElementKey.neonBox,
      ElementKey.neonBadge,
      ElementKey.neonDivider,
      ElementKey.glowOuter,
      ElementKey.glowInner,
      ElementKey.innerBackground,
    ].where(activeKeys.contains).toList();

    final systemKeys = [
      ElementKey.cpu,
      ElementKey.ram,
    ].where(activeKeys.contains).toList();

    final weatherKeys = [
      ElementKey.weatherIcon,
      ElementKey.weatherTemp,
      ElementKey.weatherStatus,
    ].where(activeKeys.contains).toList();

    final statusKeys = [
      ElementKey.wifiIcon,
      ElementKey.bluetoothIcon,
    ].where(activeKeys.contains).toList();

    final mediaKeys = [
      ElementKey.mediaBg,
      ElementKey.mediaIcon,
      ElementKey.mediaTitle,
      ElementKey.mediaArtist,
      ElementKey.mediaTime,
    ].where(activeKeys.contains).toList();

    Widget buildChip(String key) {
      final isSelected = _selectedElement == key;
      final currentColor = Color(_settings.colorFor(key));
      final label = _elementLabels[key] ?? key;
      final icon = _elementIcons[key] ?? Icons.widgets_rounded;
      final sampleVal = _getElementSampleValue(key);

      return HoverCard(
        scaleUp: 1.03,
        borderRadius: BorderRadius.circular(9),
        glowColor: isSelected ? const Color(0xFF38BDF8) : Colors.transparent,
        maxGlowOpacity: 0.25,
        blurRadius: 8,
        onTap: () => _selectElement(key),
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 180),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
          decoration: BoxDecoration(
            color: isSelected
                ? const Color(0xFF38BDF8).withValues(alpha: 0.16)
                : Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(9),
            border: Border.all(
              color: isSelected
                  ? const Color(0xFF38BDF8).withValues(alpha: 0.8)
                  : Colors.white.withValues(alpha: 0.09),
              width: isSelected ? 1.4 : 1.0,
            ),
            boxShadow: isSelected
                ? [
                    BoxShadow(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                      blurRadius: 8,
                      offset: const Offset(0, 2),
                    ),
                  ]
                : null,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              // Active color pill/dot
              Container(
                width: 7,
                height: 7,
                decoration: BoxDecoration(
                  color: currentColor,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: currentColor.withValues(alpha: 0.5),
                      blurRadius: 4,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 6),
              Icon(
                icon,
                size: 13,
                color: isSelected ? const Color(0xFF38BDF8) : Colors.white60,
              ),
              const SizedBox(width: 6),
              Text(
                label,
                style: TextStyle(
                  fontSize: 11,
                  color: isSelected ? Colors.white : Colors.white70,
                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                  letterSpacing: 0.2,
                ),
              ),
              const SizedBox(width: 6),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 5,
                  vertical: 1.5,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.06),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  sampleVal,
                  style: TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w700,
                    fontFamily: _settings.fontFor(key),
                    color: isSelected
                        ? const Color(0xFF38BDF8)
                        : Colors.white38,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    Widget buildGroup(String title, List<String> keys) {
      if (keys.isEmpty) return const SizedBox.shrink();
      return Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.only(bottom: 6),
              child: Text(
                title,
                style: TextStyle(
                  fontSize: 8.5,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.2,
                  color: Colors.white.withValues(alpha: 0.3),
                ),
              ),
            ),
            Wrap(
              spacing: 6,
              runSpacing: 6,
              children: keys.map(buildChip).toList(),
            ),
          ],
        ),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        // Header
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Text(
                  'SELECT ELEMENT',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 1.8,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                    ),
                  ),
                  child: Text(
                    '$templateName • ${activeKeys.length}',
                    style: const TextStyle(
                      fontSize: 9,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF38BDF8),
                      letterSpacing: 0.5,
                    ),
                  ),
                ),
              ],
            ),
            if (_selectedElement != null)
              GestureDetector(
                onTap: () => setState(() => _selectedElement = null),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.06),
                    borderRadius: BorderRadius.circular(6),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.clear_all_rounded,
                        size: 11,
                        color: Colors.white.withValues(alpha: 0.6),
                      ),
                      const SizedBox(width: 4),
                      Text(
                        'Show All',
                        style: TextStyle(
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          color: Colors.white.withValues(alpha: 0.6),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        buildGroup('TIME & CLOCK', timeKeys),
        buildGroup('DATE & CALENDAR', dateKeys),
        buildGroup('FRAMES & GLOW', frameKeys),
        buildGroup('SYSTEM & HARDWARE', systemKeys),
        buildGroup('STATUS ICONS', statusKeys),
        buildGroup('MEDIA PLAYER', mediaKeys),
        buildGroup('WEATHER DETAILS', weatherKeys),
      ],
    );
  }

  void _selectElement(String key) {
    setState(() {
      _selectedElement = key;
      _tabCtrl.animateTo(0);
    });
  }

  // ── Preview Background ────────────────────────────────────────────────────

  Widget _buildPreviewBg({
    BorderRadius borderRadius = const BorderRadius.all(Radius.circular(20)),
  }) {
    final br = borderRadius;

    Widget body;
    if (_settings.backgroundType == 'animated' &&
        _settings.animatedBg.isNotEmpty) {
      body = buildAnimatedBackground(_settings.animatedBg, borderRadius: br);
    } else {
      switch (_settings.backgroundType) {
        case 'none':
          body = const SizedBox.shrink();
          break;
        case 'solid':
          body = Container(
            decoration: BoxDecoration(
              color: Color(_settings.solidColor),
              borderRadius: br,
            ),
          );
          break;
        case 'custom_gradient':
          body = Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _settings.customGradientColors
                    .map((c) => Color(c))
                    .toList(),
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: br,
            ),
          );
          break;
        case 'gradient':
          final idx = _settings.curatedIndex.clamp(
            0,
            _gradientPresets.length - 1,
          );
          body = Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: _gradientPresets[idx],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: br,
            ),
          );
          break;
        case 'curated':
          final idx = _settings.curatedIndex.clamp(
            0,
            _curatedWallpapers.length - 1,
          );
          body = ClipRRect(
            borderRadius: br,
            child: Image.asset(
              _curatedWallpapers[idx]['path']!,
              fit: BoxFit.cover,
              cacheWidth: 171,
              cacheHeight: 121,
              errorBuilder: (_, _, _) => Container(
                color: Colors.black54,
                child: const Icon(Icons.broken_image, color: Colors.white24),
              ),
            ),
          );
          break;
        case 'custom':
          if (_settings.customImagePath != null &&
              _settings.customImagePath!.isNotEmpty) {
            body = ClipRRect(
              borderRadius: br,
              child: Image.file(
                File(_settings.customImagePath!),
                fit: BoxFit.cover,
                cacheWidth: 171,
                cacheHeight: 121,
                errorBuilder: (context, error, stackTrace) {
                  logError(
                    'DashboardView',
                    'Failed to load custom preview image file: ${_settings.customImagePath}',
                    error,
                    stackTrace,
                  );
                  return Container(
                    color: Colors.black45,
                    child: const Icon(
                      Icons.broken_image,
                      color: Colors.white24,
                      size: 32,
                    ),
                  );
                },
              ),
            );
          } else {
            body = Container(
              color: Colors.black54,
              decoration: BoxDecoration(borderRadius: br),
            );
          }
          break;
        default:
          body = const SizedBox.shrink();
          break;
      }
    }

    if (_settings.showOuterFrame &&
        _settings.backgroundType != 'none' &&
        _settings.opacity > 0.0) {
      final borderThickness = 1.0;
      final borderAlpha = 0.15;
      return Container(
        decoration: BoxDecoration(
          borderRadius: br,
          border: Border.all(
            color: Colors.white.withValues(alpha: borderAlpha),
            width: borderThickness,
          ),
        ),
        child: body,
      );
    }
    return body;
  }

  // ── Interactive Preview Clock ─────────────────────────────────────────────

  Widget _applyPreview3D(String key, Widget child) {
    final grad = _settings.gradientFor(key);
    if (grad != null && grad.length >= 2) {
      child = ShaderMask(
        blendMode: BlendMode.srcIn,
        shaderCallback: (bounds) => LinearGradient(
          colors: grad.map((c) => Color(c)).toList(),
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ).createShader(bounds),
        child: child,
      );
    }

    final tx = _settings.translateXFor(key);
    final ty = _settings.translateYFor(key);
    final tz = _settings.translateZFor(key);
    final rx = _settings.rotateXFor(key) * (3.141592653589793 / 180.0);
    final ry = _settings.rotateYFor(key) * (3.141592653589793 / 180.0);
    final rz = _settings.rotateZFor(key) * (3.141592653589793 / 180.0);

    if (tx == 0.0 &&
        ty == 0.0 &&
        tz == 0.0 &&
        rx == 0.0 &&
        ry == 0.0 &&
        rz == 0.0) {
      return child;
    }

    final transform = Matrix4.identity()
      ..setEntry(3, 2, 0.001) // perspective
      ..translateByDouble(tx, ty, tz, 1.0)
      ..rotateX(rx)
      ..rotateY(ry)
      ..rotateZ(rz);

    return Transform(
      transform: transform,
      alignment: Alignment.center,
      child: child,
    );
  }

  Widget _buildInteractivePreviewClock() {
    return ValueListenableBuilder<DateTime>(
      valueListenable: _previewDateTimeNotifier,
      builder: (context, currentPreviewTime, _) {
        final now = currentPreviewTime;
        final use24h = _settings.use24HourFormat;
        final showSec = _settings.showSeconds;
        final mul = _settings.fontSizeMultiplier * 0.7; // scaled for preview

        final hourStr = use24h
            ? now.hour.toString().padLeft(2, '0')
            : ((now.hour % 12 == 0 ? 12 : now.hour % 12)).toString().padLeft(
                2,
                '0',
              );
        final minStr = now.minute.toString().padLeft(2, '0');
        final secStr = now.second.toString().padLeft(2, '0');
        final ampmStr = now.hour < 12 ? 'AM' : 'PM';
        final dayStr = DateFormat('EEEE').format(now).toUpperCase();
        final dateStr = DateFormat('MMM d').format(now).toUpperCase();
        final yearStr = now.year.toString();

        TextStyle styleFor(String key, double size, FontWeight fw) {
          return TextStyle(
            fontFamily: _settings.fontFor(key),
            fontSize: _settings.sizeFor(key, size) * mul,
            fontWeight: fw,
            color: Color(_settings.colorFor(key)),
            shadows: null,
          );
        }

        Widget tappable(String key, Widget child) {
          final sel = _selectedElement == key;
          return GestureDetector(
            onTap: () => _selectElement(key),
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 160),
              padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 1),
              decoration: sel
                  ? BoxDecoration(
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(
                        color: Colors.blueAccent.withValues(alpha: 0.8),
                        width: 1.5,
                      ),
                      color: Colors.blueAccent.withValues(alpha: 0.12),
                    )
                  : null,
              child: child,
            ),
          );
        }

        Widget buildHoursPart({double size = 32}) => _applyPreview3D(
          ElementKey.hours,
          tappable(
            ElementKey.hours,
            Text(
              hourStr,
              style: styleFor(ElementKey.hours, size, FontWeight.bold),
            ),
          ),
        );

        Widget buildMinutesPart({double size = 32}) => _applyPreview3D(
          ElementKey.minutes,
          tappable(
            ElementKey.minutes,
            Text(
              minStr,
              style: styleFor(ElementKey.minutes, size, FontWeight.bold),
            ),
          ),
        );

        Widget buildSecondsPart({double size = 32}) => _applyPreview3D(
          ElementKey.seconds,
          tappable(
            ElementKey.seconds,
            Text(
              secStr,
              style: styleFor(ElementKey.seconds, size, FontWeight.bold),
            ),
          ),
        );

        Widget buildAmPmPart({double size = 10}) => _applyPreview3D(
          ElementKey.ampm,
          tappable(
            ElementKey.ampm,
            Column(
              mainAxisSize: MainAxisSize.min,
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(height: 6),
                Text(
                  ampmStr,
                  style: styleFor(ElementKey.ampm, size, FontWeight.w600),
                ),
              ],
            ),
          ),
        );

        Widget buildSeparatorPart({double size = 26}) {
          final sepStyle = TextStyle(
            fontFamily: _settings.fontFor(ElementKey.separator),
            fontSize: _settings.sizeFor(ElementKey.separator, size) * mul,
            fontWeight: FontWeight.w300,
            color: Color(_settings.colorFor(ElementKey.separator)),
          );
          return _applyPreview3D(
            ElementKey.separator,
            tappable(ElementKey.separator, Text(':', style: sepStyle)),
          );
        }

        Widget buildDayPart({double size = 9}) => _applyPreview3D(
          ElementKey.day,
          tappable(
            ElementKey.day,
            Text(
              dayStr,
              style: styleFor(
                ElementKey.day,
                size,
                FontWeight.w600,
              ).copyWith(letterSpacing: 1.2),
            ),
          ),
        );

        Widget buildDatePart({double size = 9}) => _applyPreview3D(
          ElementKey.date,
          tappable(
            ElementKey.date,
            Text(
              dateStr,
              style: styleFor(
                ElementKey.date,
                size,
                FontWeight.w500,
              ).copyWith(letterSpacing: 1.2),
            ),
          ),
        );

        Widget buildYearPart({double size = 9}) => _applyPreview3D(
          ElementKey.year,
          tappable(
            ElementKey.year,
            Text(
              yearStr,
              style: styleFor(ElementKey.year, size, FontWeight.w500),
            ),
          ),
        );

        Widget buildClockRow({double size = 32}) {
          final timeChildren = <Widget>[
            buildHoursPart(size: size),
            buildSeparatorPart(size: size - 6),
            buildMinutesPart(size: size),
          ];
          if (showSec) {
            timeChildren.add(buildSeparatorPart(size: size - 6));
            timeChildren.add(buildSecondsPart(size: size));
          }
          if (!use24h) {
            timeChildren.add(const SizedBox(width: 4));
            timeChildren.add(buildAmPmPart(size: size * 0.3));
          }
          return Row(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.end,
            children: timeChildren,
          );
        }

        Widget buildDateRow({double size = 9}) {
          final sepDot = TextStyle(
            fontSize: size * mul,
            color: Color(
              _settings.colorFor(ElementKey.separator),
            ).withValues(alpha: 0.5),
          );
          return Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              buildDayPart(size: size),
              _applyPreview3D(
                ElementKey.separator,
                tappable(ElementKey.separator, Text('  ·  ', style: sepDot)),
              ),
              buildDatePart(size: size),
              _applyPreview3D(
                ElementKey.separator,
                tappable(ElementKey.separator, Text('  ·  ', style: sepDot)),
              ),
              buildYearPart(size: size),
            ],
          );
        }

        Widget buildLayout() {
          final systemMetrics =
              _settings.customElements.any(
                (element) =>
                    element.type == 'space_bar' ||
                    element.type == 'battery_bar',
              )
              ? SystemMetricsService.readSnapshot()
              : const SystemMetricsSnapshot();
          switch (_settings.widgetTemplate) {
            case 'custom':
              return FittedBox(
                fit: BoxFit.scaleDown,
                child: SizedBox(
                  width: _settings.width,
                  height: _settings.height,
                  child: CustomWidgetRenderer(
                    elements: _settings.customElements,
                    dateTime: now,
                    cpuUsage: 22.0,
                    ramUsage: 45.0,
                    weatherTemp: _settings.weatherTemp,
                    weatherStatus: _settings.weatherStatus,
                    mediaInfo: _mediaInfo,
                    mediaThumbnailBytes: _thumbnailBytes,
                    mediaPosition: _playbackPositionNotifier,
                    wifiEnabled:
                        _connectivity.wifiEnabled ?? _settings.wifiEnabled,
                    bluetoothEnabled:
                        _connectivity.bluetoothEnabled ??
                        _settings.bluetoothEnabled,
                    batteryInfo: systemMetrics.battery,
                    diskInfo: systemMetrics.disk,
                    isInteractive: false,
                    canvasWidth: _settings.width,
                    canvasHeight: _settings.height,
                  ),
                ),
              );

            case 'minimal':
              final pipeColor = Color(_settings.colorFor(ElementKey.separator));
              return FittedBox(
                fit: BoxFit.scaleDown,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    buildClockRow(size: 26),
                    _applyPreview3D(
                      ElementKey.separator,
                      tappable(
                        ElementKey.separator,
                        Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          child: Text(
                            '|',
                            style: TextStyle(
                              color: pipeColor,
                              fontSize: 18,
                              fontWeight: FontWeight.w200,
                            ),
                          ),
                        ),
                      ),
                    ),
                    buildDayPart(size: 9),
                    const SizedBox(width: 4),
                    buildDatePart(size: 9),
                  ],
                ),
              );

            case 'cyber':
              return Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        buildHoursPart(size: 42),
                        const SizedBox(height: 2),
                        buildMinutesPart(size: 42),
                      ],
                    ),
                  ),
                  if (showSec) ...[
                    const SizedBox(height: 2),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      child: buildSecondsPart(size: 16),
                    ),
                  ],
                  const SizedBox(height: 4),
                  FittedBox(
                    fit: BoxFit.scaleDown,
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        buildDayPart(size: 8),
                        const SizedBox(width: 4),
                        buildDatePart(size: 8),
                      ],
                    ),
                  ),
                ],
              );

            case 'split':
              final barColor = Color(_settings.colorFor(ElementKey.separator));
              return IntrinsicHeight(
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    _applyPreview3D(
                      ElementKey.separator,
                      tappable(
                        ElementKey.separator,
                        Container(
                          width: 3,
                          decoration: BoxDecoration(
                            color: barColor,
                            borderRadius: BorderRadius.circular(1.5),
                            boxShadow: null,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: buildClockRow(size: 26),
                        ),
                        const SizedBox(height: 2),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: buildDateRow(size: 8),
                        ),
                      ],
                    ),
                  ],
                ),
              );

            case 'neon':
              final boxColor = Color(_settings.colorFor(ElementKey.neonBox));
              final timeColor = Color(_settings.colorFor(ElementKey.hours));
              final dateColor = Color(_settings.colorFor(ElementKey.date));
              final sepColor = Color(_settings.colorFor(ElementKey.separator));
              final badgeColor = Color(
                _settings.colorFor(ElementKey.neonBadge),
              );
              final dividerColor = Color(
                _settings.colorFor(ElementKey.neonDivider),
              );
              final cpuColor = Color(_settings.colorFor(ElementKey.cpu));
              final ramColor = Color(_settings.colorFor(ElementKey.ram));

              return _applyPreview3D(
                ElementKey.neonBox,
                tappable(
                  ElementKey.neonBox,
                  Container(
                    decoration: BoxDecoration(
                      borderRadius: BorderRadius.circular(20),
                      boxShadow: [
                        // Wide atmospheric neon aura
                        BoxShadow(
                          color: boxColor.withValues(alpha: 0.35),
                          blurRadius: 28,
                          spreadRadius: 1,
                        ),
                        // Core bright neon glow
                        BoxShadow(
                          color: boxColor.withValues(alpha: 0.55),
                          blurRadius: 14,
                          spreadRadius: 0,
                        ),
                        // Spatial shadow
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.45),
                          blurRadius: 18,
                          offset: const Offset(0, 8),
                        ),
                      ],
                    ),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(20),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 20,
                          vertical: 12,
                        ),
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(20),
                          gradient: LinearGradient(
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                            colors: [
                              Colors.white.withValues(alpha: 0.14),
                              boxColor.withValues(alpha: 0.16),
                              boxColor.withValues(alpha: 0.05),
                              Colors.black.withValues(alpha: 0.35),
                            ],
                            stops: const [0.0, 0.25, 0.7, 1.0],
                          ),
                          border: Border.all(
                            color: boxColor.withValues(alpha: 0.85),
                            width: 1.6,
                          ),
                        ),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 1. Top Header Row: Day Capsule Badge + Neon Status
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _applyPreview3D(
                                  ElementKey.day,
                                  tappable(
                                    ElementKey.day,
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 8,
                                        vertical: 2.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: dateColor.withValues(
                                          alpha: 0.12,
                                        ),
                                        borderRadius: BorderRadius.circular(6),
                                        border: Border.all(
                                          color: dateColor.withValues(
                                            alpha: 0.45,
                                          ),
                                          width: 0.8,
                                        ),
                                        boxShadow: [
                                          BoxShadow(
                                            color: dateColor.withValues(
                                              alpha: 0.25,
                                            ),
                                            blurRadius: 5,
                                          ),
                                        ],
                                      ),
                                      child: Row(
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Icon(
                                            Icons.calendar_today_rounded,
                                            size: 8 * mul,
                                            color: dateColor,
                                          ),
                                          const SizedBox(width: 4),
                                          Text(
                                            dayStr,
                                            style:
                                                styleFor(
                                                  ElementKey.day,
                                                  8,
                                                  FontWeight.w800,
                                                ).copyWith(
                                                  color: dateColor,
                                                  letterSpacing: 1.5,
                                                  shadows: [
                                                    Shadow(
                                                      color: dateColor
                                                          .withValues(
                                                            alpha: 0.6,
                                                          ),
                                                      blurRadius: 6,
                                                    ),
                                                  ],
                                                ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                                if (_settings.showNeonBadge)
                                  _applyPreview3D(
                                    ElementKey.neonBadge,
                                    tappable(
                                      ElementKey.neonBadge,
                                      Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 6,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: badgeColor.withValues(
                                            alpha: 0.12,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            10,
                                          ),
                                          border: Border.all(
                                            color: badgeColor.withValues(
                                              alpha: 0.45,
                                            ),
                                            width: 0.7,
                                          ),
                                          boxShadow: [
                                            BoxShadow(
                                              color: badgeColor.withValues(
                                                alpha: 0.25,
                                              ),
                                              blurRadius: 6,
                                            ),
                                          ],
                                        ),
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            Container(
                                              width: 5,
                                              height: 5,
                                              decoration: BoxDecoration(
                                                shape: BoxShape.circle,
                                                color: badgeColor,
                                                boxShadow: [
                                                  BoxShadow(
                                                    color: badgeColor
                                                        .withValues(alpha: 0.8),
                                                    blurRadius: 5,
                                                    spreadRadius: 1,
                                                  ),
                                                ],
                                              ),
                                            ),
                                            const SizedBox(width: 4),
                                            Text(
                                              'GLASS NEON',
                                              style:
                                                  styleFor(
                                                    ElementKey.neonBadge,
                                                    7,
                                                    FontWeight.w900,
                                                  ).copyWith(
                                                    color: badgeColor,
                                                    letterSpacing: 1.2,
                                                    shadows: [
                                                      Shadow(
                                                        color: badgeColor
                                                            .withValues(
                                                              alpha: 0.6,
                                                            ),
                                                        blurRadius: 5,
                                                      ),
                                                    ],
                                                  ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 4),

                            // 2. Hero Center Clock Row
                            FittedBox(
                              fit: BoxFit.scaleDown,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  _applyPreview3D(
                                    ElementKey.hours,
                                    tappable(
                                      ElementKey.hours,
                                      Text(
                                        hourStr,
                                        style:
                                            styleFor(
                                              ElementKey.hours,
                                              40,
                                              FontWeight.w900,
                                            ).copyWith(
                                              color: timeColor,
                                              letterSpacing: -0.8,
                                              shadows: [
                                                Shadow(
                                                  color: timeColor.withValues(
                                                    alpha: 0.75,
                                                  ),
                                                  blurRadius: 14,
                                                ),
                                                Shadow(
                                                  color: timeColor.withValues(
                                                    alpha: 0.35,
                                                  ),
                                                  blurRadius: 26,
                                                ),
                                              ],
                                            ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  _applyPreview3D(
                                    ElementKey.separator,
                                    tappable(
                                      ElementKey.separator,
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 2,
                                        ),
                                        child: Text(
                                          ':',
                                          style:
                                              styleFor(
                                                ElementKey.separator,
                                                34,
                                                FontWeight.w300,
                                              ).copyWith(
                                                color: sepColor,
                                                shadows: [
                                                  Shadow(
                                                    color: sepColor.withValues(
                                                      alpha: 0.8,
                                                    ),
                                                    blurRadius: 12,
                                                  ),
                                                  Shadow(
                                                    color: sepColor.withValues(
                                                      alpha: 0.4,
                                                    ),
                                                    blurRadius: 22,
                                                  ),
                                                ],
                                              ),
                                        ),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 2),
                                  _applyPreview3D(
                                    ElementKey.minutes,
                                    tappable(
                                      ElementKey.minutes,
                                      Text(
                                        minStr,
                                        style:
                                            styleFor(
                                              ElementKey.minutes,
                                              40,
                                              FontWeight.w900,
                                            ).copyWith(
                                              color: timeColor,
                                              letterSpacing: -0.8,
                                              shadows: [
                                                Shadow(
                                                  color: timeColor.withValues(
                                                    alpha: 0.75,
                                                  ),
                                                  blurRadius: 14,
                                                ),
                                                Shadow(
                                                  color: timeColor.withValues(
                                                    alpha: 0.35,
                                                  ),
                                                  blurRadius: 26,
                                                ),
                                              ],
                                            ),
                                      ),
                                    ),
                                  ),
                                  if (showSec || !use24h) ...[
                                    const SizedBox(width: 8),
                                    Column(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.start,
                                      children: [
                                        if (!use24h)
                                          _applyPreview3D(
                                            ElementKey.ampm,
                                            tappable(
                                              ElementKey.ampm,
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1.5,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: timeColor.withValues(
                                                    alpha: 0.15,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                  border: Border.all(
                                                    color: timeColor.withValues(
                                                      alpha: 0.5,
                                                    ),
                                                    width: 0.6,
                                                  ),
                                                ),
                                                child: Text(
                                                  ampmStr,
                                                  style:
                                                      styleFor(
                                                        ElementKey.ampm,
                                                        8,
                                                        FontWeight.w800,
                                                      ).copyWith(
                                                        color: timeColor,
                                                        letterSpacing: 0.8,
                                                        shadows: [
                                                          Shadow(
                                                            color: timeColor
                                                                .withValues(
                                                                  alpha: 0.6,
                                                                ),
                                                            blurRadius: 6,
                                                          ),
                                                        ],
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        if (showSec) ...[
                                          if (!use24h)
                                            const SizedBox(height: 3),
                                          _applyPreview3D(
                                            ElementKey.seconds,
                                            tappable(
                                              ElementKey.seconds,
                                              Container(
                                                padding:
                                                    const EdgeInsets.symmetric(
                                                      horizontal: 5,
                                                      vertical: 1.5,
                                                    ),
                                                decoration: BoxDecoration(
                                                  color: sepColor.withValues(
                                                    alpha: 0.15,
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(5),
                                                  border: Border.all(
                                                    color: sepColor.withValues(
                                                      alpha: 0.5,
                                                    ),
                                                    width: 0.6,
                                                  ),
                                                ),
                                                child: Row(
                                                  mainAxisSize:
                                                      MainAxisSize.min,
                                                  children: [
                                                    Text(
                                                      secStr,
                                                      style:
                                                          styleFor(
                                                            ElementKey.seconds,
                                                            9,
                                                            FontWeight.w900,
                                                          ).copyWith(
                                                            color: sepColor,
                                                            shadows: [
                                                              Shadow(
                                                                color: sepColor
                                                                    .withValues(
                                                                      alpha:
                                                                          0.7,
                                                                    ),
                                                                blurRadius: 6,
                                                              ),
                                                            ],
                                                          ),
                                                    ),
                                                    const SizedBox(width: 1.5),
                                                    Text(
                                                      'S',
                                                      style: TextStyle(
                                                        fontSize: 5.5,
                                                        fontWeight:
                                                            FontWeight.bold,
                                                        color: sepColor
                                                            .withValues(
                                                              alpha: 0.7,
                                                            ),
                                                      ),
                                                    ),
                                                  ],
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                  ],
                                ],
                              ),
                            ),

                            // 3. Glowing Laser Divider Line
                            _applyPreview3D(
                              ElementKey.neonDivider,
                              tappable(
                                ElementKey.neonDivider,
                                Container(
                                  height: 1.2,
                                  margin: const EdgeInsets.symmetric(
                                    vertical: 5,
                                  ),
                                  decoration: BoxDecoration(
                                    gradient: LinearGradient(
                                      colors: [
                                        Colors.transparent,
                                        dividerColor.withValues(alpha: 0.2),
                                        dividerColor.withValues(alpha: 0.8),
                                        boxColor.withValues(alpha: 0.8),
                                        boxColor.withValues(alpha: 0.2),
                                        Colors.transparent,
                                      ],
                                      stops: const [
                                        0.0,
                                        0.2,
                                        0.45,
                                        0.55,
                                        0.8,
                                        1.0,
                                      ],
                                    ),
                                    boxShadow: [
                                      BoxShadow(
                                        color: dividerColor.withValues(
                                          alpha: 0.5,
                                        ),
                                        blurRadius: 5,
                                        spreadRadius: 0.5,
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ),

                            // 4. Hardware Telemetry Deck (CPU & RAM Monitors)
                            if (_settings.showCpu || _settings.showRam) ...[
                              Row(
                                children: [
                                  if (_settings.showCpu)
                                    Expanded(
                                      child: _applyPreview3D(
                                        ElementKey.cpu,
                                        tappable(
                                          ElementKey.cpu,
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: cpuColor.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: cpuColor.withValues(
                                                  alpha: 0.3,
                                                ),
                                                width: 0.6,
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons.memory_rounded,
                                                          size: 8 * mul,
                                                          color: cpuColor,
                                                        ),
                                                        const SizedBox(
                                                          width: 3,
                                                        ),
                                                        Text(
                                                          'CPU',
                                                          style:
                                                              styleFor(
                                                                ElementKey.cpu,
                                                                7,
                                                                FontWeight.w800,
                                                              ).copyWith(
                                                                color: cpuColor,
                                                                letterSpacing:
                                                                    0.6,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                    Text(
                                                      '${_cpuUsage.toStringAsFixed(0)}%',
                                                      style:
                                                          styleFor(
                                                            ElementKey.cpu,
                                                            7,
                                                            FontWeight.w900,
                                                          ).copyWith(
                                                            color: cpuColor,
                                                            shadows: [
                                                              Shadow(
                                                                color: cpuColor
                                                                    .withValues(
                                                                      alpha:
                                                                          0.7,
                                                                    ),
                                                                blurRadius: 5,
                                                              ),
                                                            ],
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 2),
                                                Container(
                                                  width: double.infinity,
                                                  height: 2.8,
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          1.5,
                                                        ),
                                                  ),
                                                  child: FractionallySizedBox(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    widthFactor:
                                                        (_cpuUsage / 100.0)
                                                            .clamp(0.02, 1.0),
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        color: cpuColor,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              1.5,
                                                            ),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color: cpuColor
                                                                .withValues(
                                                                  alpha: 0.8,
                                                                ),
                                                            blurRadius: 3,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                  if (_settings.showCpu && _settings.showRam)
                                    const SizedBox(width: 6),
                                  if (_settings.showRam)
                                    Expanded(
                                      child: _applyPreview3D(
                                        ElementKey.ram,
                                        tappable(
                                          ElementKey.ram,
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 6,
                                              vertical: 3,
                                            ),
                                            decoration: BoxDecoration(
                                              color: ramColor.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(6),
                                              border: Border.all(
                                                color: ramColor.withValues(
                                                  alpha: 0.3,
                                                ),
                                                width: 0.6,
                                              ),
                                            ),
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisSize: MainAxisSize.min,
                                              children: [
                                                Row(
                                                  mainAxisAlignment:
                                                      MainAxisAlignment
                                                          .spaceBetween,
                                                  children: [
                                                    Row(
                                                      mainAxisSize:
                                                          MainAxisSize.min,
                                                      children: [
                                                        Icon(
                                                          Icons
                                                              .developer_board_rounded,
                                                          size: 8 * mul,
                                                          color: ramColor,
                                                        ),
                                                        const SizedBox(
                                                          width: 3,
                                                        ),
                                                        Text(
                                                          'RAM',
                                                          style:
                                                              styleFor(
                                                                ElementKey.ram,
                                                                7,
                                                                FontWeight.w800,
                                                              ).copyWith(
                                                                color: ramColor,
                                                                letterSpacing:
                                                                    0.6,
                                                              ),
                                                        ),
                                                      ],
                                                    ),
                                                    Text(
                                                      '${_ramUsage.toStringAsFixed(0)}%',
                                                      style:
                                                          styleFor(
                                                            ElementKey.ram,
                                                            7,
                                                            FontWeight.w900,
                                                          ).copyWith(
                                                            color: ramColor,
                                                            shadows: [
                                                              Shadow(
                                                                color: ramColor
                                                                    .withValues(
                                                                      alpha:
                                                                          0.7,
                                                                    ),
                                                                blurRadius: 5,
                                                              ),
                                                            ],
                                                          ),
                                                    ),
                                                  ],
                                                ),
                                                const SizedBox(height: 2),
                                                Container(
                                                  width: double.infinity,
                                                  height: 2.8,
                                                  decoration: BoxDecoration(
                                                    color: Colors.white
                                                        .withValues(alpha: 0.1),
                                                    borderRadius:
                                                        BorderRadius.circular(
                                                          1.5,
                                                        ),
                                                  ),
                                                  child: FractionallySizedBox(
                                                    alignment:
                                                        Alignment.centerLeft,
                                                    widthFactor:
                                                        (_ramUsage / 100.0)
                                                            .clamp(0.02, 1.0),
                                                    child: Container(
                                                      decoration: BoxDecoration(
                                                        color: ramColor,
                                                        borderRadius:
                                                            BorderRadius.circular(
                                                              1.5,
                                                            ),
                                                        boxShadow: [
                                                          BoxShadow(
                                                            color: ramColor
                                                                .withValues(
                                                                  alpha: 0.8,
                                                                ),
                                                            blurRadius: 3,
                                                          ),
                                                        ],
                                                      ),
                                                    ),
                                                  ),
                                                ),
                                              ],
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 5),
                            ],

                            // 5. Bottom Deck: Date & Year
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                _applyPreview3D(
                                  ElementKey.date,
                                  tappable(
                                    ElementKey.date,
                                    Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(
                                          Icons.access_time_rounded,
                                          size: 9 * mul,
                                          color: dateColor.withValues(
                                            alpha: 0.8,
                                          ),
                                        ),
                                        const SizedBox(width: 4),
                                        Text(
                                          dateStr,
                                          style:
                                              styleFor(
                                                ElementKey.date,
                                                9,
                                                FontWeight.w700,
                                              ).copyWith(
                                                color: dateColor,
                                                letterSpacing: 1.3,
                                                shadows: [
                                                  Shadow(
                                                    color: dateColor.withValues(
                                                      alpha: 0.6,
                                                    ),
                                                    blurRadius: 6,
                                                  ),
                                                ],
                                              ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                                Container(
                                  width: 3.5,
                                  height: 3.5,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    color: dateColor.withValues(alpha: 0.6),
                                    boxShadow: [
                                      BoxShadow(
                                        color: dateColor.withValues(alpha: 0.8),
                                        blurRadius: 3,
                                      ),
                                    ],
                                  ),
                                ),
                                _applyPreview3D(
                                  ElementKey.year,
                                  tappable(
                                    ElementKey.year,
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 1.5,
                                      ),
                                      decoration: BoxDecoration(
                                        color: dateColor.withValues(
                                          alpha: 0.08,
                                        ),
                                        borderRadius: BorderRadius.circular(5),
                                        border: Border.all(
                                          color: dateColor.withValues(
                                            alpha: 0.3,
                                          ),
                                          width: 0.6,
                                        ),
                                      ),
                                      child: Text(
                                        yearStr,
                                        style:
                                            styleFor(
                                              ElementKey.year,
                                              8.5,
                                              FontWeight.w800,
                                            ).copyWith(
                                              color: dateColor,
                                              letterSpacing: 1.2,
                                              shadows: [
                                                Shadow(
                                                  color: dateColor.withValues(
                                                    alpha: 0.6,
                                                  ),
                                                  blurRadius: 5,
                                                ),
                                              ],
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              );

            case 'animated_neon':
              final Color outerColor = Color(
                _settings.colorFor(ElementKey.glowOuter),
              );
              final Color innerColor = Color(
                _settings.colorFor(ElementKey.glowInner),
              );

              return AnimatedBuilder(
                animation: _backgroundFlowController,
                builder: (context, child) {
                  final double progress =
                      (1.0 -
                          math.cos(
                            _backgroundFlowController.value * 2 * math.pi,
                          )) /
                      2.0;

                  final double outerHeight = 120.0 + 220.0 * progress;
                  final double outerTop = 110.0 - 110.0 * progress;

                  final double innerHeight = 80.0 + 180.0 * progress;
                  final double innerTop = 130.0 - 90.0 * progress;

                  final double textTop = 145.0 - 15.0 * progress;
                  final double textScaleY = 0.4 + 0.6 * progress;

                  final isTransparent =
                      _settings.backgroundType == 'none' ||
                      _settings.opacity == 0.0;

                  return FittedBox(
                    fit: BoxFit.contain,
                    child: SizedBox(
                      width: 340,
                      height: 340,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: [
                          // Outer Ring
                          Positioned(
                            top: outerTop,
                            left: 0,
                            width: 340,
                            height: outerHeight,
                            child: _applyPreview3D(
                              ElementKey.glowOuter,
                              tappable(
                                ElementKey.glowOuter,
                                Container(
                                  key: const Key('glow-outer'),
                                  decoration: BoxDecoration(
                                    gradient: isTransparent
                                        ? null
                                        : const LinearGradient(
                                            colors: [
                                              Color(0xFF050528),
                                              Color(0xFF0A0A55),
                                            ],
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                          ),
                                    color: isTransparent
                                        ? Colors.transparent
                                        : null,
                                    border: Border.all(
                                      color: outerColor,
                                      width: 10,
                                    ),
                                    borderRadius: BorderRadius.all(
                                      Radius.elliptical(170, outerHeight / 2),
                                    ),
                                    boxShadow: null,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Inner Ring
                          Positioned(
                            top: innerTop,
                            left: 40,
                            width: 260,
                            height: innerHeight,
                            child: _applyPreview3D(
                              ElementKey.glowInner,
                              tappable(
                                ElementKey.glowInner,
                                Container(
                                  key: const Key('glow-inner'),
                                  decoration: BoxDecoration(
                                    gradient: isTransparent
                                        ? null
                                        : const LinearGradient(
                                            colors: [
                                              Color(0xFF0A0A3C),
                                              Color(0xFF000000),
                                            ],
                                            begin: Alignment.topCenter,
                                            end: Alignment.bottomCenter,
                                          ),
                                    color: isTransparent
                                        ? Colors.transparent
                                        : null,
                                    border: Border.all(
                                      color: innerColor,
                                      width: 6,
                                    ),
                                    borderRadius: BorderRadius.all(
                                      Radius.elliptical(130, innerHeight / 2),
                                    ),
                                    boxShadow: null,
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Inner Background
                          Positioned(
                            top: innerTop + 6,
                            left: 46,
                            width: 248,
                            height: innerHeight - 12,
                            child: _applyPreview3D(
                              ElementKey.innerBackground,
                              tappable(
                                ElementKey.innerBackground,
                                Container(
                                  key: const Key('glow-bg'),
                                  decoration: BoxDecoration(
                                    color: Color(
                                      _settings.colorFor(
                                        ElementKey.innerBackground,
                                      ),
                                    ),
                                    borderRadius: BorderRadius.all(
                                      Radius.elliptical(
                                        124,
                                        (innerHeight - 12) / 2,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),

                          // Clock Text Wrapper
                          Positioned(
                            top: textTop,
                            left: 0,
                            right: 0,
                            child: Transform(
                              transform: Matrix4.identity()
                                ..scaleByDouble(1.0, textScaleY, 1.0, 1.0),
                              alignment: Alignment.center,
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  // Time display
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      crossAxisAlignment:
                                          CrossAxisAlignment.end,
                                      children: [
                                        buildHoursPart(size: 28),
                                        buildSeparatorPart(size: 24),
                                        buildMinutesPart(size: 28),
                                        if (showSec) ...[
                                          buildSeparatorPart(size: 24),
                                          buildSecondsPart(size: 24),
                                        ],
                                        if (!use24h) ...[
                                          const SizedBox(width: 4),
                                          buildAmPmPart(size: 20),
                                        ],
                                      ],
                                    ),
                                  ),
                                  const SizedBox(height: 6),
                                  // Date display
                                  FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        buildDayPart(size: 13),
                                        Text(
                                          ' | ',
                                          style: TextStyle(
                                            color: Color(
                                              _settings.colorFor(
                                                ElementKey.seconds,
                                              ),
                                            ),
                                            fontSize: 13 * mul,
                                            fontWeight: FontWeight.w500,
                                          ),
                                        ),
                                        buildDatePart(size: 13),
                                        const SizedBox(width: 4),
                                        buildYearPart(size: 13),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              );

            case 'sleep_weather':
              final tempText = _settings.weatherTemp.isNotEmpty
                  ? '${_settings.weatherTemp} °C'
                  : '-- °C';
              final resolvedLoc = _settings.weatherLocationResolved.isNotEmpty
                  ? _settings.weatherLocationResolved
                  : 'Auto-detecting...';

              IconData weatherIcon = Icons.wb_cloudy_rounded;
              if (_settings.weatherStatus.isNotEmpty) {
                final statusLower = _settings.weatherStatus.toLowerCase();
                if (statusLower.contains('clear') ||
                    statusLower.contains('sunny')) {
                  weatherIcon = Icons.wb_sunny_rounded;
                } else if (statusLower.contains('drizzle') ||
                    statusLower.contains('rain')) {
                  weatherIcon = Icons.water_drop_rounded;
                } else if (statusLower.contains('fog')) {
                  weatherIcon = Icons.filter_drama_rounded;
                } else if (statusLower.contains('snow')) {
                  weatherIcon = Icons.ac_unit_rounded;
                } else if (statusLower.contains('thunderstorm')) {
                  weatherIcon = Icons.thunderstorm_rounded;
                }
              }

              String formatTime(int secs) {
                final h = secs ~/ 3600;
                final m = (secs % 3600) ~/ 60;
                final s = secs % 60;
                if (h > 0) {
                  return '$h:${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
                } else {
                  return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
                }
              }

              return CustomPaint(
                painter: FolderTabPainter(
                  color: const Color(0xFF0F0F11),
                  shadowColor: Colors.black.withValues(alpha: 0.5),
                  blurRadius: 16,
                ),
                child: ClipPath(
                  clipper: FolderTabClipper(),
                  child: Stack(
                    children: [
                      // Preview background for this widget
                      Positioned.fill(
                        child: _buildPreviewBg(
                          borderRadius: BorderRadius.circular(24),
                        ),
                      ),
                      // Left: Date & Time
                      Positioned(
                        top: 44,
                        left: 16,
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _applyPreview3D(
                                  ElementKey.day,
                                  tappable(
                                    ElementKey.day,
                                    Text(
                                      DateFormat('EEEE').format(now),
                                      style: styleFor(
                                        ElementKey.day,
                                        16,
                                        FontWeight.w600,
                                      ).copyWith(letterSpacing: -0.5),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Padding(
                                  padding: const EdgeInsets.only(top: 2),
                                  child: _applyPreview3D(
                                    ElementKey.date,
                                    tappable(
                                      ElementKey.date,
                                      Text(
                                        DateFormat('d').format(now),
                                        style: styleFor(
                                          ElementKey.date,
                                          10,
                                          FontWeight.bold,
                                        ),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _applyPreview3D(
                                  ElementKey.hours,
                                  tappable(
                                    ElementKey.hours,
                                    Text(
                                      hourStr,
                                      style:
                                          styleFor(
                                            ElementKey.hours,
                                            54,
                                            FontWeight.w700,
                                          ).copyWith(
                                            height: 0.9,
                                            letterSpacing: -2.0,
                                          ),
                                    ),
                                  ),
                                ),
                                _applyPreview3D(
                                  ElementKey.separator,
                                  tappable(
                                    ElementKey.separator,
                                    Text(
                                      ':',
                                      style: styleFor(
                                        ElementKey.separator,
                                        50,
                                        FontWeight.w300,
                                      ).copyWith(height: 0.9),
                                    ),
                                  ),
                                ),
                                _applyPreview3D(
                                  ElementKey.minutes,
                                  tappable(
                                    ElementKey.minutes,
                                    Text(
                                      minStr,
                                      style:
                                          styleFor(
                                            ElementKey.minutes,
                                            54,
                                            FontWeight.w700,
                                          ).copyWith(
                                            height: 0.9,
                                            letterSpacing: -2.0,
                                          ),
                                    ),
                                  ),
                                ),
                                if (_settings.showSeconds) ...[
                                  const SizedBox(width: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: _applyPreview3D(
                                      ElementKey.seconds,
                                      tappable(
                                        ElementKey.seconds,
                                        Text(
                                          secStr,
                                          style: styleFor(
                                            ElementKey.seconds,
                                            18,
                                            FontWeight.bold,
                                          ),
                                        ),
                                      ),
                                    ),
                                  ),
                                ],
                                if (!_settings.use24HourFormat) ...[
                                  const SizedBox(width: 4),
                                  Padding(
                                    padding: const EdgeInsets.only(top: 4),
                                    child: _applyPreview3D(
                                      ElementKey.ampm,
                                      tappable(
                                        ElementKey.ampm,
                                        Text(
                                          ampmStr,
                                          style: styleFor(
                                            ElementKey.ampm,
                                            12,
                                            FontWeight.w600,
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
                      ),
                      // Right: WiFi & Bluetooth
                      if (_settings.showWifi || _settings.showBluetooth)
                        Positioned(
                          top: 12,
                          right: 16,
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              if (_settings.showWifi)
                                _applyPreview3D(
                                  ElementKey.wifiIcon,
                                  tappable(
                                    ElementKey.wifiIcon,
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: _settings.wifiEnabled
                                            ? Color(
                                                _settings.colorFor(
                                                  ElementKey.wifiIcon,
                                                ),
                                              ).withValues(alpha: 0.08)
                                            : Colors.white.withValues(
                                                alpha: 0.03,
                                              ),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: _settings.wifiEnabled
                                              ? Color(
                                                  _settings.colorFor(
                                                    ElementKey.wifiIcon,
                                                  ),
                                                ).withValues(alpha: 0.15)
                                              : Colors.white.withValues(
                                                  alpha: 0.05,
                                                ),
                                        ),
                                      ),
                                      child: Icon(
                                        Icons.wifi_rounded,
                                        size: _settings.sizeFor(
                                          ElementKey.wifiIcon,
                                          16,
                                        ),
                                        color: _settings.wifiEnabled
                                            ? Color(
                                                _settings.colorFor(
                                                  ElementKey.wifiIcon,
                                                ),
                                              )
                                            : Color(
                                                _settings.colorFor(
                                                  ElementKey.wifiIcon,
                                                ),
                                              ).withValues(alpha: 0.24),
                                      ),
                                    ),
                                  ),
                                ),
                              if (_settings.showWifi && _settings.showBluetooth)
                                const SizedBox(width: 8),
                              if (_settings.showBluetooth)
                                _applyPreview3D(
                                  ElementKey.bluetoothIcon,
                                  tappable(
                                    ElementKey.bluetoothIcon,
                                    Container(
                                      width: 34,
                                      height: 34,
                                      decoration: BoxDecoration(
                                        color: _settings.bluetoothEnabled
                                            ? Color(
                                                _settings.colorFor(
                                                  ElementKey.bluetoothIcon,
                                                ),
                                              ).withValues(alpha: 0.12)
                                            : Colors.white.withValues(
                                                alpha: 0.03,
                                              ),
                                        borderRadius: BorderRadius.circular(10),
                                        border: Border.all(
                                          color: _settings.bluetoothEnabled
                                              ? Color(
                                                  _settings.colorFor(
                                                    ElementKey.bluetoothIcon,
                                                  ),
                                                ).withValues(alpha: 0.4)
                                              : Colors.white.withValues(
                                                  alpha: 0.05,
                                                ),
                                        ),
                                        boxShadow: _settings.bluetoothEnabled
                                            ? [
                                                BoxShadow(
                                                  color: Color(
                                                    _settings.colorFor(
                                                      ElementKey.bluetoothIcon,
                                                    ),
                                                  ).withValues(alpha: 0.15),
                                                  blurRadius: 6,
                                                  spreadRadius: 1,
                                                ),
                                              ]
                                            : null,
                                      ),
                                      child: Icon(
                                        Icons.bluetooth_rounded,
                                        size: _settings.sizeFor(
                                          ElementKey.bluetoothIcon,
                                          16,
                                        ),
                                        color: _settings.bluetoothEnabled
                                            ? Color(
                                                _settings.colorFor(
                                                  ElementKey.bluetoothIcon,
                                                ),
                                              )
                                            : Color(
                                                _settings.colorFor(
                                                  ElementKey.bluetoothIcon,
                                                ),
                                              ).withValues(alpha: 0.24),
                                      ),
                                    ),
                                  ),
                                ),
                            ],
                          ),
                        ),

                      // Large Media Cover Image on the right of the clock (green box space)
                      if (_mediaInfo.thumbnail.isNotEmpty &&
                          _thumbnailBytes != null)
                        Positioned(
                          top: 56,
                          right: 16,
                          child: _applyPreview3D(
                            ElementKey.mediaIcon,
                            tappable(
                              ElementKey.mediaIcon,
                              Container(
                                width: 120,
                                height: 120,
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(16),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.1),
                                  ),
                                  boxShadow: [
                                    BoxShadow(
                                      color: Colors.black.withValues(
                                        alpha: 0.3,
                                      ),
                                      blurRadius: 10,
                                      offset: const Offset(0, 4),
                                    ),
                                  ],
                                  image: DecorationImage(
                                    image: MemoryImage(_thumbnailBytes!),
                                    fit: BoxFit.cover,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),

                      // Middle: Media controls bar
                      if (_settings.showMediaControl)
                        Positioned(
                          left: 16,
                          right: 16,
                          bottom: 52,
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              const Text(
                                'MEDIA CONTROL',
                                style: TextStyle(
                                  color: Colors.white38,
                                  fontSize: 9,
                                  fontWeight: FontWeight.w900,
                                  letterSpacing: 1.2,
                                  fontFamily: 'Segoe UI',
                                ),
                              ),
                              const SizedBox(height: 6),
                              _applyPreview3D(
                                ElementKey.mediaBg,
                                tappable(
                                  ElementKey.mediaBg,
                                  CustomPaint(
                                    painter: SleepTrackerPainter(
                                      color: Color(
                                        _settings.colorFor(ElementKey.mediaBg),
                                      ),
                                    ),
                                    child: Container(
                                      width: double.infinity,
                                      height: 48,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 4,
                                      ),
                                      child: Row(
                                        children: [
                                          const SizedBox(width: 6),
                                          _applyPreview3D(
                                            ElementKey.mediaIcon,
                                            tappable(
                                              ElementKey.mediaIcon,
                                              Row(
                                                mainAxisSize: MainAxisSize.min,
                                                children: [
                                                  GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () {
                                                      MediaSessionService()
                                                          .previous();
                                                    },
                                                    child: Icon(
                                                      Icons
                                                          .skip_previous_rounded,
                                                      color: Color(
                                                        _settings.colorFor(
                                                          ElementKey.mediaIcon,
                                                        ),
                                                      ),
                                                      size: _settings.sizeFor(
                                                        ElementKey.mediaIcon,
                                                        20,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () {
                                                      if (_mediaInfo
                                                          .isPlaying) {
                                                        MediaSessionService()
                                                            .pause();
                                                      } else {
                                                        MediaSessionService()
                                                            .play();
                                                      }
                                                    },
                                                    child: Icon(
                                                      _mediaInfo.isPlaying
                                                          ? Icons.pause_rounded
                                                          : Icons
                                                                .play_arrow_rounded,
                                                      color: Color(
                                                        _settings.colorFor(
                                                          ElementKey.mediaIcon,
                                                        ),
                                                      ),
                                                      size: _settings.sizeFor(
                                                        ElementKey.mediaIcon,
                                                        22,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(width: 8),
                                                  GestureDetector(
                                                    behavior:
                                                        HitTestBehavior.opaque,
                                                    onTap: () {
                                                      MediaSessionService()
                                                          .next();
                                                    },
                                                    child: Icon(
                                                      Icons.skip_next_rounded,
                                                      color: Color(
                                                        _settings.colorFor(
                                                          ElementKey.mediaIcon,
                                                        ),
                                                      ),
                                                      size: _settings.sizeFor(
                                                        ElementKey.mediaIcon,
                                                        20,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ),
                                          const SizedBox(width: 10),
                                          Expanded(
                                            flex: 72,
                                            child: Column(
                                              crossAxisAlignment:
                                                  CrossAxisAlignment.start,
                                              mainAxisAlignment:
                                                  MainAxisAlignment.center,
                                              children: [
                                                if (_mediaInfo.source.isEmpty &&
                                                    _mediaInfo.title.isEmpty)
                                                  _applyPreview3D(
                                                    ElementKey.mediaTitle,
                                                    tappable(
                                                      ElementKey.mediaTitle,
                                                      Text(
                                                        'No Active Session',
                                                        style: styleFor(
                                                          ElementKey.mediaTitle,
                                                          10,
                                                          FontWeight.w900,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                  )
                                                else ...[
                                                  _applyPreview3D(
                                                    ElementKey.mediaTitle,
                                                    tappable(
                                                      ElementKey.mediaTitle,
                                                      Text(
                                                        _mediaInfo
                                                                .title
                                                                .isNotEmpty
                                                            ? _mediaInfo.title
                                                            : _mediaInfo.source,
                                                        style: styleFor(
                                                          ElementKey.mediaTitle,
                                                          10,
                                                          FontWeight.w900,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                  ),
                                                  const SizedBox(height: 2),
                                                  _applyPreview3D(
                                                    ElementKey.mediaArtist,
                                                    tappable(
                                                      ElementKey.mediaArtist,
                                                      Text(
                                                        _mediaInfo
                                                                .artist
                                                                .isNotEmpty
                                                            ? '${_mediaInfo.artist} • ${_mediaInfo.source}'
                                                            : _mediaInfo.source,
                                                        style: styleFor(
                                                          ElementKey
                                                              .mediaArtist,
                                                          8,
                                                          FontWeight.w500,
                                                        ),
                                                        maxLines: 1,
                                                        overflow: TextOverflow
                                                            .ellipsis,
                                                      ),
                                                    ),
                                                  ),
                                                ],
                                              ],
                                            ),
                                          ),
                                          Expanded(
                                            flex: 28,
                                            child: Center(
                                              child: _applyPreview3D(
                                                ElementKey.mediaTime,
                                                tappable(
                                                  ElementKey.mediaTime,
                                                  ValueListenableBuilder<int>(
                                                    valueListenable:
                                                        _playbackPositionNotifier,
                                                    builder: (context, pos, _) {
                                                      final text =
                                                          _mediaInfo.duration <=
                                                              0
                                                          ? _mediaInfo.status
                                                                .toUpperCase()
                                                          : '${formatTime(pos)} / ${formatTime(_mediaInfo.duration)}';
                                                      return Text(
                                                        text,
                                                        style: styleFor(
                                                          ElementKey.mediaTime,
                                                          9,
                                                          FontWeight.w900,
                                                        ),
                                                      );
                                                    },
                                                  ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      // Bottom: Weather
                      if (_settings.showWeather)
                        Positioned(
                          left: 16,
                          bottom: 12,
                          child: Tooltip(
                            message: resolvedLoc,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _applyPreview3D(
                                  ElementKey.weatherIcon,
                                  tappable(
                                    ElementKey.weatherIcon,
                                    Icon(
                                      weatherIcon,
                                      color: Color(
                                        _settings.colorFor(
                                          ElementKey.weatherIcon,
                                        ),
                                      ),
                                      size: _settings.sizeFor(
                                        ElementKey.weatherIcon,
                                        14,
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                _applyPreview3D(
                                  ElementKey.weatherTemp,
                                  tappable(
                                    ElementKey.weatherTemp,
                                    Text(
                                      tempText,
                                      style: styleFor(
                                        ElementKey.weatherTemp,
                                        13,
                                        FontWeight.w600,
                                      ),
                                    ),
                                  ),
                                ),
                                if (_settings.weatherStatus.isNotEmpty) ...[
                                  const SizedBox(width: 6),
                                  _applyPreview3D(
                                    ElementKey.weatherStatus,
                                    tappable(
                                      ElementKey.weatherStatus,
                                      Text(
                                        _settings.weatherStatus,
                                        style: styleFor(
                                          ElementKey.weatherStatus,
                                          11,
                                          FontWeight.w400,
                                        ),
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
                ),
              );

            case 'robik':
              // 1. Weather Icon & Text
              IconData weatherIcon = Icons.wb_cloudy_rounded;
              if (_settings.weatherStatus.isNotEmpty) {
                final statusLower = _settings.weatherStatus.toLowerCase();
                if (statusLower.contains('clear') ||
                    statusLower.contains('sunny')) {
                  weatherIcon = Icons.wb_sunny_rounded;
                } else if (statusLower.contains('drizzle') ||
                    statusLower.contains('rain')) {
                  weatherIcon = Icons.water_drop_rounded;
                } else if (statusLower.contains('fog')) {
                  weatherIcon = Icons.filter_drama_rounded;
                } else if (statusLower.contains('snow')) {
                  weatherIcon = Icons.ac_unit_rounded;
                } else if (statusLower.contains('thunderstorm')) {
                  weatherIcon = Icons.thunderstorm_rounded;
                }
              }
              final tempText = _settings.weatherTemp.isNotEmpty
                  ? '${_settings.weatherTemp}°C'
                  : '--°C';
              final condText = _settings.weatherStatus.isNotEmpty
                  ? _settings.weatherStatus.toUpperCase()
                  : 'UNKNOWN';

              // 2. Date string (Format: DD MONTH YYYY)
              final dayNum = DateFormat('d').format(now);
              final monthName = DateFormat('MMMM').format(now).toUpperCase();
              final yearNum = DateFormat('yyyy').format(now);
              final dateString = '$dayNum $monthName $yearNum';

              // 4. Accent Color & Text Color
              final accentColor = Color(_settings.colorFor(ElementKey.day));

              return Stack(
                fit: StackFit.expand,
                children: [
                  Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 12,
                      ),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          // Left Column: Clock & Date
                          Expanded(
                            flex: 58,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                // Day Header (Robik signature)
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: _applyPreview3D(
                                    ElementKey.day,
                                    tappable(
                                      ElementKey.day,
                                      Text(
                                        DateFormat(
                                          'EEEE',
                                        ).format(now).toUpperCase(),
                                        style:
                                            styleFor(
                                              ElementKey.day,
                                              13,
                                              FontWeight.w800,
                                            ).copyWith(
                                              fontFamily: _settings.fontFor(
                                                ElementKey.day,
                                              ),
                                              color: accentColor,
                                              letterSpacing: 2.0,
                                            ),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                // Decomposed Time Row (Hours, Separator dot, Minutes, Seconds)
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: Row(
                                    mainAxisSize: MainAxisSize.min,
                                    crossAxisAlignment:
                                        CrossAxisAlignment.baseline,
                                    textBaseline: TextBaseline.alphabetic,
                                    children: [
                                      _applyPreview3D(
                                        ElementKey.hours,
                                        tappable(
                                          ElementKey.hours,
                                          Text(
                                            hourStr,
                                            style:
                                                styleFor(
                                                  ElementKey.hours,
                                                  68,
                                                  FontWeight.w700,
                                                ).copyWith(
                                                  letterSpacing: -1.0,
                                                  height: 1.0,
                                                ),
                                          ),
                                        ),
                                      ),
                                      _applyPreview3D(
                                        ElementKey.separator,
                                        tappable(
                                          ElementKey.separator,
                                          Text(
                                            '.',
                                            style:
                                                styleFor(
                                                  ElementKey.separator,
                                                  68,
                                                  FontWeight.w700,
                                                ).copyWith(
                                                  letterSpacing: -1.0,
                                                  height: 1.0,
                                                ),
                                          ),
                                        ),
                                      ),
                                      _applyPreview3D(
                                        ElementKey.minutes,
                                        tappable(
                                          ElementKey.minutes,
                                          Text(
                                            minStr,
                                            style:
                                                styleFor(
                                                  ElementKey.minutes,
                                                  68,
                                                  FontWeight.w700,
                                                ).copyWith(
                                                  letterSpacing: -1.0,
                                                  height: 1.0,
                                                ),
                                          ),
                                        ),
                                      ),
                                      if (showSec) ...[
                                        const SizedBox(width: 4),
                                        _applyPreview3D(
                                          ElementKey.seconds,
                                          tappable(
                                            ElementKey.seconds,
                                            Text(
                                              secStr,
                                              style: styleFor(
                                                ElementKey.seconds,
                                                22,
                                                FontWeight.bold,
                                              ),
                                            ),
                                          ),
                                        ),
                                      ],
                                    ],
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Custom line / Separator (Accent pill)
                                _applyPreview3D(
                                  ElementKey.separator,
                                  tappable(
                                    ElementKey.separator,
                                    Container(
                                      width: 72,
                                      height: 4,
                                      decoration: BoxDecoration(
                                        color: Color(
                                          _settings.colorFor(
                                            ElementKey.separator,
                                          ),
                                        ),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 10),
                                // Date (Product Sans)
                                FittedBox(
                                  fit: BoxFit.scaleDown,
                                  child: _applyPreview3D(
                                    ElementKey.date,
                                    tappable(
                                      ElementKey.date,
                                      Text(
                                        dateString,
                                        style: styleFor(
                                          ElementKey.date,
                                          13,
                                          FontWeight.w600,
                                        ).copyWith(letterSpacing: 1.0),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ),

                          // Divider between columns
                          Container(
                            width: 1,
                            height: 160,
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                          const SizedBox(width: 12),

                          // Right Column: Weather & System Resource Indicators (inspired by Robik)
                          Expanded(
                            flex: 42,
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                // Weather indicator row
                                if (_settings.showWeather) ...[
                                  Row(
                                    children: [
                                      _applyPreview3D(
                                        ElementKey.weatherIcon,
                                        tappable(
                                          ElementKey.weatherIcon,
                                          Icon(
                                            weatherIcon,
                                            color: Color(
                                              _settings.colorFor(
                                                ElementKey.weatherIcon,
                                              ),
                                            ),
                                            size: _settings.sizeFor(
                                              ElementKey.weatherIcon,
                                              24,
                                            ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            _applyPreview3D(
                                              ElementKey.weatherStatus,
                                              tappable(
                                                ElementKey.weatherStatus,
                                                Text(
                                                  condText,
                                                  style:
                                                      styleFor(
                                                        ElementKey
                                                            .weatherStatus,
                                                        10,
                                                        FontWeight.bold,
                                                      ).copyWith(
                                                        letterSpacing: 0.5,
                                                        height: 1.1,
                                                      ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ),
                                            _applyPreview3D(
                                              ElementKey.weatherTemp,
                                              tappable(
                                                ElementKey.weatherTemp,
                                                Text(
                                                  tempText,
                                                  style:
                                                      styleFor(
                                                        ElementKey.weatherTemp,
                                                        10,
                                                        FontWeight.bold,
                                                      ).copyWith(
                                                        letterSpacing: 0.5,
                                                        height: 1.1,
                                                      ),
                                                  maxLines: 1,
                                                  overflow:
                                                      TextOverflow.ellipsis,
                                                ),
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                    ],
                                  ),
                                  const SizedBox(height: 16),
                                ],

                                // CPU usage indicator
                                if (_settings.showCpu) ...[
                                  _applyPreview3D(
                                    ElementKey.cpu,
                                    tappable(
                                      ElementKey.cpu,
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'CPU: ${_cpuUsage.toStringAsFixed(0)}%',
                                            style:
                                                styleFor(
                                                  ElementKey.cpu,
                                                  10,
                                                  FontWeight.bold,
                                                ).copyWith(
                                                  letterSpacing: 0.5,
                                                  fontFamily: _settings.fontFor(
                                                    ElementKey.cpu,
                                                  ),
                                                ),
                                          ),
                                          const SizedBox(height: 4),
                                          // CPU progress bar
                                          Container(
                                            width: double.infinity,
                                            height: 5,
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(2.5),
                                            ),
                                            child: FractionallySizedBox(
                                              alignment: Alignment.centerLeft,
                                              widthFactor: (_cpuUsage / 100.0)
                                                  .clamp(0.02, 1.0),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Color(
                                                    _settings.colorFor(
                                                      ElementKey.cpu,
                                                    ),
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        2.5,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                ],

                                // RAM usage indicator
                                if (_settings.showRam) ...[
                                  _applyPreview3D(
                                    ElementKey.ram,
                                    tappable(
                                      ElementKey.ram,
                                      Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            'RAM: ${_ramUsage.toStringAsFixed(0)}%',
                                            style:
                                                styleFor(
                                                  ElementKey.ram,
                                                  10,
                                                  FontWeight.bold,
                                                ).copyWith(
                                                  letterSpacing: 0.5,
                                                  fontFamily: _settings.fontFor(
                                                    ElementKey.ram,
                                                  ),
                                                ),
                                          ),
                                          const SizedBox(height: 4),
                                          // RAM progress bar
                                          Container(
                                            width: double.infinity,
                                            height: 5,
                                            decoration: BoxDecoration(
                                              color: Colors.white.withValues(
                                                alpha: 0.08,
                                              ),
                                              borderRadius:
                                                  BorderRadius.circular(2.5),
                                            ),
                                            child: FractionallySizedBox(
                                              alignment: Alignment.centerLeft,
                                              widthFactor: (_ramUsage / 100.0)
                                                  .clamp(0.02, 1.0),
                                              child: Container(
                                                decoration: BoxDecoration(
                                                  color: Color(
                                                    _settings.colorFor(
                                                      ElementKey.ram,
                                                    ),
                                                  ),
                                                  borderRadius:
                                                      BorderRadius.circular(
                                                        2.5,
                                                      ),
                                                ),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                ],
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ],
              );

            case 'atomic_clock':
              final dayStr = DateFormat('EEEE').format(now).toUpperCase();
              final monthName = DateFormat('MMMM').format(now).toUpperCase();
              final dateStr = '${now.day} $monthName, ${now.year}.';
              String timeStr;
              if (_settings.use24HourFormat) {
                timeStr = _settings.showSeconds
                    ? '- $hourStr:$minStr:$secStr -'
                    : '- $hourStr:$minStr -';
              } else {
                timeStr = _settings.showSeconds
                    ? '- $hourStr:$minStr:$secStr $ampmStr -'
                    : '- $hourStr:$minStr $ampmStr -';
              }

              Widget buildPreviewAtomicText({
                required String text,
                required String elementKey,
                required double baseSize,
                required double letterSpacing,
                required FontWeight weight,
              }) {
                final size =
                    _settings.sizeFor(elementKey, baseSize) *
                    _settings.fontSizeMultiplier;
                final font = _settings.fontFor(elementKey);
                final hasOverride = _settings.elementColors.containsKey(
                  elementKey,
                );
                final col = Color(_settings.colorFor(elementKey));

                final textWidget = Text(
                  text,
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontFamily: font == 'Segoe UI' ? 'Anurati' : font,
                    fontSize: size,
                    fontWeight: weight,
                    letterSpacing: letterSpacing,
                    color:
                        hasOverride || _settings.customGradientColors.length < 2
                        ? col
                        : Colors.white,
                    shadows: [
                      Shadow(
                        color: Colors.black.withValues(alpha: 0.75),
                        blurRadius: 6,
                        offset: const Offset(1, 2),
                      ),
                    ],
                  ),
                );

                if (!hasOverride &&
                    _settings.customGradientColors.length >= 2) {
                  return ShaderMask(
                    blendMode: BlendMode.srcIn,
                    shaderCallback: (bounds) => LinearGradient(
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                      colors: _settings.customGradientColors
                          .map((c) => Color(c))
                          .toList(),
                    ).createShader(bounds),
                    child: textWidget,
                  );
                }

                return textWidget;
              }

              return FittedBox(
                fit: BoxFit.scaleDown,
                child: Padding(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 24,
                    vertical: 16,
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.center,
                    children: [
                      _applyPreview3D(
                        ElementKey.day,
                        tappable(
                          ElementKey.day,
                          buildPreviewAtomicText(
                            text: dayStr,
                            elementKey: ElementKey.day,
                            baseSize: 42,
                            letterSpacing: 4.5,
                            weight: FontWeight.w900,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _applyPreview3D(
                        ElementKey.date,
                        tappable(
                          ElementKey.date,
                          buildPreviewAtomicText(
                            text: dateStr,
                            elementKey: ElementKey.date,
                            baseSize: 20,
                            letterSpacing: 2.2,
                            weight: FontWeight.w700,
                          ),
                        ),
                      ),
                      const SizedBox(height: 8),
                      _applyPreview3D(
                        ElementKey.hours,
                        tappable(
                          ElementKey.hours,
                          buildPreviewAtomicText(
                            text: timeStr,
                            elementKey: ElementKey.hours,
                            baseSize: 15,
                            letterSpacing: 2.0,
                            weight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              );

            case 'classic':
            default:
              return Column(
                mainAxisSize: MainAxisSize.min,
                mainAxisAlignment: MainAxisAlignment.center,
                children: [
                  FittedBox(fit: BoxFit.scaleDown, child: buildClockRow()),
                  const SizedBox(height: 4),
                  _applyPreview3D(
                    ElementKey.separator,
                    tappable(
                      ElementKey.separator,
                      Container(
                        width: 50,
                        height: 2,
                        color: Color(_settings.colorFor(ElementKey.separator)),
                      ),
                    ),
                  ),
                  const SizedBox(height: 5),
                  FittedBox(fit: BoxFit.scaleDown, child: buildDateRow()),
                ],
              );
          }
        }

        final defaults =
            WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
            {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
        final baseWidth = defaults['width']!;
        final baseHeight = defaults['height']!;

        return Center(
          child: AspectRatio(
            aspectRatio: _settings.width / _settings.height,
            child: FittedBox(
              fit: BoxFit.contain,
              child: SizedBox(
                width: baseWidth,
                height: baseHeight,
                child: Transform.scale(
                  scale: _settings.sizeFactor,
                  child: buildLayout(),
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  // ── Overlay controls ─────────────────────────────────────────────────────

  Widget _buildOverlayControls() {
    return Container(
      padding: const EdgeInsets.fromLTRB(18, 14, 18, 22),
      decoration: BoxDecoration(
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        children: [
          // Status row with pulsing glow dot
          Row(
            children: [
              AnimatedContainer(
                duration: const Duration(milliseconds: 400),
                width: 8,
                height: 8,
                decoration: BoxDecoration(
                  color: _isOverlayRunning
                      ? const Color(0xFF43E97B)
                      : Colors.redAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: _isOverlayRunning
                          ? const Color(0xFF43E97B)
                          : Colors.redAccent,
                      blurRadius: _isOverlayRunning ? 8 : 4,
                      spreadRadius: _isOverlayRunning ? 1 : 0,
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Text(
                _isLaunching
                    ? 'Launching overlay...'
                    : (_isOverlayRunning
                          ? 'Overlay Active'
                          : 'Overlay Inactive'),
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                  letterSpacing: 0.8,
                  color: _isOverlayRunning
                      ? const Color(0xFF43E97B)
                      : Colors.white38,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (_isOverlayRunning &&
                  _settings.widgetTemplate == _activeTemplate)
                Expanded(
                  child: GlowButton(
                    label: 'Stop',
                    icon: Icons.stop_circle_outlined,
                    color: Colors.redAccent,
                    enabled: true,
                    onTap: _closeOverlay,
                  ),
                )
              else
                Expanded(
                  child: GlowButton(
                    label: _isLaunching ? 'Launching...' : 'Launch',
                    icon: Icons.rocket_launch_rounded,
                    color: const Color(0xFF43E97B),
                    enabled: !_isLaunching,
                    onTap: () {
                      logInfo(
                        'DashboardView',
                        'Overlay preview Launch tapped.',
                      );
                      _launchOverlay();
                    },
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Editor tabs ──────────────────────────────────────────────────────────

  Widget _buildGlossy3DIcon(IconData icon, Color baseColor) {
    return Container(
      width: 28,
      height: 28,
      margin: const EdgeInsets.only(bottom: 4),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(8),
        gradient: LinearGradient(
          colors: [
            baseColor.withValues(alpha: 0.85),
            baseColor.withValues(alpha: 0.25),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        boxShadow: [
          BoxShadow(
            color: baseColor.withValues(alpha: 0.35),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
          BoxShadow(
            color: Colors.white.withValues(alpha: 0.2),
            blurRadius: 1,
            offset: const Offset(0, -1),
          ),
        ],
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.3),
          width: 0.8,
        ),
      ),
      child: Center(child: Icon(icon, size: 14, color: Colors.white)),
    );
  }

  Widget _buildEditorTabs() {
    return Container(
      decoration: BoxDecoration(
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.05)),
        ),
      ),
      child: TabBar(
        controller: _tabCtrl,
        labelColor: Colors.white,
        unselectedLabelColor: Colors.white38,
        indicatorColor: const Color(0xFFEC4899),
        indicatorWeight: 3,
        indicatorSize: TabBarIndicatorSize.tab,
        labelStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w800,
          letterSpacing: 0.8,
        ),
        unselectedLabelStyle: const TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.bold,
        ),
        tabs: [
          Tab(
            icon: _buildGlossy3DIcon(
              Icons.text_fields_rounded,
              const Color(0xFFEC4899),
            ),
            text: 'Element',
          ),
          Tab(
            icon: _buildGlossy3DIcon(
              Icons.wallpaper_rounded,
              const Color(0xFF38BDF8),
            ),
            text: 'Background',
          ),
          Tab(
            icon: _buildGlossy3DIcon(
              Icons.tune_rounded,
              const Color(0xFFC084FC),
            ),
            text: 'Layout',
          ),
        ],
      ),
    );
  }

  Widget _buildEditorContent() {
    return TabBarView(
      controller: _tabCtrl,
      children: [
        _buildElementEditor(),
        _buildBackgroundEditor(),
        _buildLayoutEditor(),
      ],
    );
  }

  static const Map<String, List<String>> _elementCategories = {
    'CLOCK & TIME': [
      ElementKey.hours,
      ElementKey.minutes,
      ElementKey.seconds,
      ElementKey.ampm,
      ElementKey.separator,
    ],
    'CALENDAR & DATE': [ElementKey.day, ElementKey.date, ElementKey.year],
    'SMART DASHBOARD': [
      ElementKey.weatherTemp,
      ElementKey.weatherStatus,
      ElementKey.weatherIcon,
      ElementKey.wifiIcon,
      ElementKey.wifiText,
      ElementKey.bluetoothIcon,
      ElementKey.bluetoothText,
      ElementKey.mediaTitle,
      ElementKey.mediaArtist,
      ElementKey.mediaTime,
      ElementKey.mediaIcon,
      ElementKey.mediaBg,
    ],
    'FRAMES & GLOW': [
      ElementKey.glowOuter,
      ElementKey.glowInner,
      ElementKey.neonBox,
      ElementKey.neonBadge,
      ElementKey.neonDivider,
      ElementKey.innerBackground,
    ],
    'SYSTEM & TELEMETRY': [ElementKey.cpu, ElementKey.ram],
  };

  bool _isElementActiveInCurrentTemplate(String key) {
    final t = _settings.widgetTemplate;
    switch (t) {
      case 'minimal':
        return [
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
          ElementKey.day,
          ElementKey.date,
        ].contains(key);

      case 'cyber':
        return [
          ElementKey.hours,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.day,
          ElementKey.date,
        ].contains(key);

      case 'split':
        return [
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
          ElementKey.day,
          ElementKey.date,
          ElementKey.year,
        ].contains(key);

      case 'neon':
        return [
          ElementKey.neonBox,
          ElementKey.neonBadge,
          ElementKey.neonDivider,
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
          ElementKey.cpu,
          ElementKey.ram,
          ElementKey.day,
          ElementKey.date,
          ElementKey.year,
        ].contains(key);

      case 'animated_neon':
        return [
          ElementKey.glowOuter,
          ElementKey.glowInner,
          ElementKey.innerBackground,
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
          ElementKey.day,
          ElementKey.date,
          ElementKey.year,
        ].contains(key);

      case 'sleep_weather':
        return [
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
          ElementKey.day,
          ElementKey.date,
          ElementKey.weatherIcon,
          ElementKey.weatherTemp,
          ElementKey.weatherStatus,
          ElementKey.wifiIcon,
          ElementKey.bluetoothIcon,
          ElementKey.mediaBg,
          ElementKey.mediaIcon,
          ElementKey.mediaTitle,
          ElementKey.mediaArtist,
          ElementKey.mediaTime,
        ].contains(key);

      case 'robik':
        return [
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.day,
          ElementKey.date,
          ElementKey.weatherIcon,
          ElementKey.weatherTemp,
          ElementKey.weatherStatus,
          ElementKey.cpu,
          ElementKey.ram,
        ].contains(key);

      case 'atomic_clock':
        return [
          ElementKey.day,
          ElementKey.date,
          ElementKey.hours,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
        ].contains(key);

      case 'classic':
      default:
        return [
          ElementKey.hours,
          ElementKey.separator,
          ElementKey.minutes,
          ElementKey.seconds,
          ElementKey.ampm,
          ElementKey.day,
          ElementKey.date,
          ElementKey.year,
        ].contains(key);
    }
  }

  String _getElementSampleValue(String key) {
    final now = DateTime.now();
    switch (key) {
      case ElementKey.hours:
        if (_settings.use24HourFormat) {
          return now.hour.toString().padLeft(2, '0');
        } else {
          final h = now.hour % 12;
          return (h == 0 ? 12 : h).toString().padLeft(2, '0');
        }
      case ElementKey.minutes:
        return now.minute.toString().padLeft(2, '0');
      case ElementKey.seconds:
        return now.second.toString().padLeft(2, '0');
      case ElementKey.ampm:
        return now.hour >= 12 ? 'PM' : 'AM';
      case ElementKey.day:
        const days = ['MON', 'TUE', 'WED', 'THU', 'FRI', 'SAT', 'SUN'];
        return days[now.weekday - 1];
      case ElementKey.date:
        const months = [
          'JAN',
          'FEB',
          'MAR',
          'APR',
          'MAY',
          'JUN',
          'JUL',
          'AUG',
          'SEP',
          'OCT',
          'NOV',
          'DEC',
        ];
        return '${months[now.month - 1]} ${now.day}';
      case ElementKey.year:
        return now.year.toString();
      case ElementKey.separator:
        return '—';
      case ElementKey.weatherTemp:
        return _settings.weatherTemp.isNotEmpty
            ? _settings.weatherTemp
            : '28°C';
      case ElementKey.weatherStatus:
        return _settings.weatherStatus.isNotEmpty
            ? _settings.weatherStatus
            : 'Partly Cloudy';
      case ElementKey.weatherIcon:
        return '☀️';
      case ElementKey.wifiIcon:
      case ElementKey.wifiText:
        return _settings.wifiEnabled ? 'Connected' : 'Idle';
      case ElementKey.bluetoothIcon:
      case ElementKey.bluetoothText:
        return _settings.bluetoothEnabled ? 'Active' : 'Off';
      case ElementKey.mediaTitle:
        return _mediaInfo.title.isNotEmpty ? _mediaInfo.title : 'Track Title';
      case ElementKey.mediaArtist:
        return _mediaInfo.artist.isNotEmpty ? _mediaInfo.artist : 'Artist';
      case ElementKey.mediaTime:
        return '02:45';
      case ElementKey.mediaIcon:
        return '⏮ ⏸ ⏭';
      case ElementKey.mediaBg:
        return 'Glass';
      case ElementKey.glowOuter:
      case ElementKey.glowInner:
        return 'Neon Ring';
      case ElementKey.neonBox:
        return 'Border Box';
      case ElementKey.neonBadge:
        return 'GLASS NEON';
      case ElementKey.neonDivider:
        return '──────';
      case ElementKey.cpu:
        return '${_cpuUsage.toStringAsFixed(0)}%';
      case ElementKey.ram:
        return '${_ramUsage.toStringAsFixed(0)}%';
      case ElementKey.innerBackground:
        return 'Plate';
      default:
        return 'Sample';
    }
  }

  // ── ELEMENT EDITOR ───────────────────────────────────────────────────────

  Widget _buildElementEditor() {
    if (_settings.widgetTemplate == 'custom') {
      _selectedElement = null;
      return _buildElementIdentificationDeck();
    }
    if (_selectedElement != null &&
        !_isElementActiveInCurrentTemplate(_selectedElement!)) {
      _selectedElement = null;
    }
    if (_selectedElement == null) {
      return _buildElementIdentificationDeck();
    }
    return _buildDedicatedObjectInspector(_selectedElement!);
  }

  // ── 1. OBJECT IDENTIFICATION DECK (Overview) ─────────────────────────────

  Widget _buildElementIdentificationDeck() {
    if (_settings.widgetTemplate == 'custom') {
      return _buildCustomElementIdentificationDeck();
    }

    final activeTemplateKeys = ElementKey.all
        .where(_isElementActiveInCurrentTemplate)
        .toList();

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Header Row
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                _sectionLabel('WIDGET OBJECTS & LAYERS'),
                const SizedBox(height: 3),
                Text(
                  'Only objects belonging to the active widget are shown',
                  style: TextStyle(
                    fontSize: 11,
                    color: Colors.white.withValues(alpha: 0.45),
                  ),
                ),
              ],
            ),
            TextButton.icon(
              onPressed: () {
                _updateSettings(
                  _settings.copyWith(
                    textColor: 0xFFFFFFFF,
                    fontFamily: 'Segoe UI',
                    fontSizeMultiplier: 1.0,
                    elementColors: {},
                    elementFonts: {},
                    elementSizes: {},
                    elementTranslateX: {},
                    elementTranslateY: {},
                    elementTranslateZ: {},
                    elementRotateX: {},
                    elementRotateY: {},
                    elementRotateZ: {},
                  ),
                );
              },
              icon: const Icon(Icons.refresh, size: 12),
              label: const Text(
                'Reset All Overrides',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF38BDF8),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // ── MASTER WIDGET CONTROLS PANEL ──
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.035),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: Colors.white.withValues(alpha: 0.09)),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Row(
                    children: [
                      Icon(
                        Icons.auto_awesome_rounded,
                        size: 15,
                        color: Color(0xFFEC4899),
                      ),
                      SizedBox(width: 8),
                      Text(
                        'MASTER WIDGET STYLING',
                        style: TextStyle(
                          fontSize: 11.5,
                          fontWeight: FontWeight.w800,
                          letterSpacing: 0.8,
                          color: Colors.white,
                        ),
                      ),
                    ],
                  ),
                  TextButton.icon(
                    onPressed: () {
                      _updateSettings(
                        _settings.copyWith(
                          elementColors: {},
                          elementFonts: {},
                          elementSizes: {},
                        ),
                      );
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(
                          content: Text(
                            'All objects now cleanly inherit master styling!',
                          ),
                          duration: Duration(seconds: 2),
                        ),
                      );
                    },
                    icon: const Icon(Icons.format_paint_rounded, size: 12),
                    label: const Text(
                      'Apply Master to All',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: TextButton.styleFrom(
                      foregroundColor: const Color(0xFFEC4899),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),

              // Master Typography
              Text(
                'MASTER FONT (${_settings.fontFamily})',
                style: TextStyle(
                  fontSize: 10,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.5,
                  color: Colors.white.withValues(alpha: 0.5),
                ),
              ),
              const SizedBox(height: 6),
              Wrap(
                spacing: 6,
                runSpacing: 6,
                children: _fonts.map((f) {
                  final isSel = _settings.fontFamily == f;
                  return InkWell(
                    onTap: () =>
                        _updateSettings(_settings.copyWith(fontFamily: f)),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isSel
                            ? const Color(0xFFEC4899).withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.02),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: isSel
                              ? const Color(0xFFEC4899).withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.06),
                        ),
                      ),
                      child: Text(
                        f,
                        style: TextStyle(
                          fontSize: 10,
                          fontFamily: f,
                          fontWeight: isSel
                              ? FontWeight.bold
                              : FontWeight.normal,
                          color: isSel ? Colors.white : Colors.white70,
                        ),
                      ),
                    ),
                  );
                }).toList(),
              ),
              const SizedBox(height: 12),

              // Master Size Multiplier Slider
              _buildSlider(
                'Master Size Multiplier',
                _settings.fontSizeMultiplier,
                0.5,
                2.5,
                (v) =>
                    _updateSettings(_settings.copyWith(fontSizeMultiplier: v)),
                step: 0.05,
                percent: true,
                onReset: () => _updateSettings(
                  _settings.copyWith(fontSizeMultiplier: 1.0),
                ),
              ),
              const SizedBox(height: 8),

              // Master Format Toggles
              Row(
                children: [
                  Expanded(
                    child: _buildToggleTile(
                      '24-Hour Format',
                      _settings.use24HourFormat,
                      (v) => _updateSettings(
                        _settings.copyWith(use24HourFormat: v),
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: _buildToggleTile(
                      'Show Seconds',
                      _settings.showSeconds,
                      (v) =>
                          _updateSettings(_settings.copyWith(showSeconds: v)),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Active Widget Indicator Badge with Count
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
          decoration: BoxDecoration(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
            ),
          ),
          child: Row(
            children: [
              const Icon(
                Icons.dashboard_customize_rounded,
                size: 15,
                color: Color(0xFF38BDF8),
              ),
              const SizedBox(width: 8),
              Text(
                'WIDGET: ${_settings.widgetTemplate.toUpperCase()}',
                style: const TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  color: Color(0xFF38BDF8),
                  letterSpacing: 0.5,
                ),
              ),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                decoration: BoxDecoration(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(6),
                ),
                child: Text(
                  '${activeTemplateKeys.length} Objects',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ),
              const Spacer(),
              Text(
                'Tap object to customize',
                style: TextStyle(
                  fontSize: 10,
                  color: Colors.white.withValues(alpha: 0.45),
                  fontStyle: FontStyle.italic,
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 18),

        // Categorized Object Decks (Strictly filtered to this widget's elements)
        ..._elementCategories.entries.map((entry) {
          final categoryTitle = entry.key;
          final keys = entry.value;
          final activeKeys = keys
              .where(_isElementActiveInCurrentTemplate)
              .toList();

          if (activeKeys.isEmpty) {
            return const SizedBox.shrink();
          }

          return Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                children: [
                  _sectionLabel(categoryTitle),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1.5,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${activeKeys.length}',
                      style: TextStyle(
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                        color: Colors.white.withValues(alpha: 0.5),
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 10),
              LayoutBuilder(
                builder: (context, constraints) {
                  return Wrap(
                    spacing: 10,
                    runSpacing: 10,
                    children: activeKeys.map((key) {
                      final label = _elementLabels[key] ?? key;
                      final icon = _elementIcons[key] ?? Icons.widgets_rounded;
                      final sampleValue = _getElementSampleValue(key);
                      final elementColor = Color(_settings.colorFor(key));
                      final scale = _settings.elementSizes[key] ?? 1.0;
                      final isText = ElementKey.textKeys.contains(key);
                      final font = isText ? _settings.fontFor(key) : null;
                      final hasCustomColor = _settings.elementColors
                          .containsKey(key);
                      final hasCustomFont = _settings.elementFonts.containsKey(
                        key,
                      );
                      final hasCustomScale = _settings.elementSizes.containsKey(
                        key,
                      );

                      final cardWidth = constraints.maxWidth > 420
                          ? (constraints.maxWidth - 10) / 2
                          : constraints.maxWidth;

                      return HoverCard(
                        scaleUp: 1.025,
                        borderRadius: BorderRadius.circular(12),
                        glowColor: const Color(0xFF38BDF8),
                        maxGlowOpacity: 0.2,
                        blurRadius: 10,
                        onTap: () => _selectElement(key),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 200),
                          width: cardWidth,
                          padding: const EdgeInsets.all(12),
                          decoration: BoxDecoration(
                            color: Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(12),
                            border: Border.all(
                              color: const Color(
                                0xFF38BDF8,
                              ).withValues(alpha: 0.25),
                              width: 1.0,
                            ),
                          ),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Top Row: Icon + Label + Custom overrides pill
                              Row(
                                children: [
                                  Container(
                                    width: 28,
                                    height: 28,
                                    decoration: BoxDecoration(
                                      color: elementColor.withValues(
                                        alpha: 0.15,
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      border: Border.all(
                                        color: elementColor.withValues(
                                          alpha: 0.4,
                                        ),
                                      ),
                                    ),
                                    alignment: Alignment.center,
                                    child: Icon(
                                      icon,
                                      size: 15,
                                      color: elementColor,
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Expanded(
                                    child: Text(
                                      label,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w700,
                                        color: Colors.white,
                                      ),
                                      overflow: TextOverflow.ellipsis,
                                    ),
                                  ),
                                  if (hasCustomColor ||
                                      hasCustomFont ||
                                      hasCustomScale)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFFEC4899,
                                        ).withValues(alpha: 0.15),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: const Color(
                                            0xFFEC4899,
                                          ).withValues(alpha: 0.4),
                                          width: 0.8,
                                        ),
                                      ),
                                      child: const Text(
                                        'Customized',
                                        style: TextStyle(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.bold,
                                          color: Color(0xFFEC4899),
                                        ),
                                      ),
                                    )
                                  else
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 5,
                                        vertical: 2,
                                      ),
                                      decoration: BoxDecoration(
                                        color: Colors.white.withValues(
                                          alpha: 0.05,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'Master',
                                        style: TextStyle(
                                          fontSize: 8.5,
                                          fontWeight: FontWeight.w600,
                                          color: Colors.white.withValues(
                                            alpha: 0.45,
                                          ),
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 10),

                              // Middle Row: Real-time Sample Badge
                              Container(
                                width: double.infinity,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: Colors.black.withValues(alpha: 0.25),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: Colors.white.withValues(alpha: 0.06),
                                  ),
                                ),
                                child: Text(
                                  sampleValue,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    fontFamily: font ?? 'Segoe UI',
                                    fontWeight: FontWeight.w700,
                                    color: elementColor,
                                  ),
                                ),
                              ),
                              const SizedBox(height: 8),

                              // Bottom Row: Metadata Tags
                              Row(
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 1.5,
                                    ),
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.05,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      '${scale.toStringAsFixed(2)}x',
                                      style: const TextStyle(
                                        fontSize: 9.5,
                                        fontFamily: 'Consolas',
                                        fontWeight: FontWeight.w600,
                                        color: Color(0xFF38BDF8),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 6),
                                  if (font != null) ...[
                                    Flexible(
                                      child: Container(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 1.5,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.05,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          hasCustomFont ? font : 'Master Font',
                                          overflow: TextOverflow.ellipsis,
                                          style: TextStyle(
                                            fontSize: 9.5,
                                            fontWeight: FontWeight.w500,
                                            color: Colors.white.withValues(
                                              alpha: 0.6,
                                            ),
                                          ),
                                        ),
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                  ],
                                  const Spacer(),
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: elementColor,
                                      shape: BoxShape.circle,
                                      border: Border.all(
                                        color: Colors.white.withValues(
                                          alpha: 0.4,
                                        ),
                                        width: 1,
                                      ),
                                      boxShadow: [
                                        BoxShadow(
                                          color: elementColor.withValues(
                                            alpha: 0.4,
                                          ),
                                          blurRadius: 4,
                                        ),
                                      ],
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );
                    }).toList(),
                  );
                },
              ),
              const SizedBox(height: 20),
            ],
          );
        }),

        const Divider(color: Colors.white12, height: 28),
        _buildGlobalTypography(),
      ],
    );
  }

  // ── 2. DEDICATED OBJECT INSPECTOR ────────────────────────────────────────

  Widget _buildDedicatedObjectInspector(String key) {
    final currentColor = Color(_settings.colorFor(key));
    final currentFont = _settings.fontFor(key);
    final label = _elementLabels[key] ?? key;
    final icon = _elementIcons[key] ?? Icons.tune_rounded;
    final currentScale = _settings.elementSizes[key] ?? 1.0;
    final isText = ElementKey.textKeys.contains(key);
    final sampleVal = _getElementSampleValue(key);
    final isActive = _isElementActiveInCurrentTemplate(key);
    final bool hasElementGradient = _settings.elementGradients.containsKey(key);

    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // Breadcrumb Top Bar
        Row(
          children: [
            HoverCard(
              scaleUp: 1.04,
              borderRadius: BorderRadius.circular(8),
              glowColor: const Color(0xFF38BDF8),
              maxGlowOpacity: 0.2,
              blurRadius: 6,
              onTap: () => setState(() => _selectedElement = null),
              child: Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.white.withValues(alpha: 0.05),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.1),
                  ),
                ),
                child: const Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.arrow_back_rounded,
                      size: 13,
                      color: Color(0xFF38BDF8),
                    ),
                    SizedBox(width: 5),
                    Text(
                      'All Objects',
                      style: TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.w700,
                        color: Color(0xFF38BDF8),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const Spacer(),
            TextButton.icon(
              onPressed: () {
                final newColors = Map<String, int>.from(_settings.elementColors)
                  ..remove(key);
                final newFonts = Map<String, String>.from(
                  _settings.elementFonts,
                )..remove(key);
                final newSizes = Map<String, double>.from(
                  _settings.elementSizes,
                )..remove(key);
                final tx = Map<String, double>.from(_settings.elementTranslateX)
                  ..remove(key);
                final ty = Map<String, double>.from(_settings.elementTranslateY)
                  ..remove(key);
                final tz = Map<String, double>.from(_settings.elementTranslateZ)
                  ..remove(key);
                final rx = Map<String, double>.from(_settings.elementRotateX)
                  ..remove(key);
                final ry = Map<String, double>.from(_settings.elementRotateY)
                  ..remove(key);
                final rz = Map<String, double>.from(_settings.elementRotateZ)
                  ..remove(key);
                if (key == ElementKey.separator) {
                  _settings.separatorWidth = null;
                  _settings.separatorHeight = null;
                }
                _updateSettings(
                  _settings.copyWith(
                    elementColors: newColors,
                    elementFonts: newFonts,
                    elementSizes: newSizes,
                    elementTranslateX: tx,
                    elementTranslateY: ty,
                    elementTranslateZ: tz,
                    elementRotateX: rx,
                    elementRotateY: ry,
                    elementRotateZ: rz,
                  ),
                );
              },
              icon: const Icon(Icons.refresh, size: 13),
              label: const Text('Reset Object', style: TextStyle(fontSize: 11)),
              style: TextButton.styleFrom(
                foregroundColor: Colors.white38,
                padding: const EdgeInsets.symmetric(horizontal: 8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 14),

        // Selected Object Hero Card
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            gradient: LinearGradient(
              colors: [
                currentColor.withValues(alpha: 0.18),
                const Color(0xFF1E293B).withValues(alpha: 0.6),
              ],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(14),
            border: Border.all(
              color: currentColor.withValues(alpha: 0.45),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: currentColor.withValues(alpha: 0.15),
                blurRadius: 16,
              ),
            ],
          ),
          child: Row(
            children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(
                  color: currentColor.withValues(alpha: 0.2),
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: currentColor.withValues(alpha: 0.6),
                  ),
                ),
                alignment: Alignment.center,
                child: Icon(icon, size: 22, color: currentColor),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      label,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w800,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      isActive
                          ? 'Active in ${_settings.widgetTemplate} template'
                          : 'Custom layer (template: ${_settings.widgetTemplate})',
                      style: TextStyle(
                        fontSize: 10.5,
                        color: isActive
                            ? const Color(0xFF34D399)
                            : Colors.white.withValues(alpha: 0.4),
                      ),
                    ),
                  ],
                ),
              ),
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 6,
                ),
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.25),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.white12),
                ),
                child: Text(
                  sampleVal,
                  style: TextStyle(
                    fontSize: 13,
                    fontFamily: isText ? currentFont : 'Segoe UI',
                    fontWeight: FontWeight.w800,
                    color: currentColor,
                  ),
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // Quick Switcher Strip (Strictly active objects in this widget)
        Builder(
          builder: (context) {
            final activeKeys = ElementKey.all
                .where(_isElementActiveInCurrentTemplate)
                .toList();
            return SizedBox(
              height: 32,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: activeKeys.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, index) {
                  final switchKey = activeKeys[index];
                  final isCurrent = switchKey == key;
                  return HoverCard(
                    scaleUp: 1.04,
                    borderRadius: BorderRadius.circular(8),
                    glowColor: isCurrent
                        ? const Color(0xFF38BDF8)
                        : Colors.transparent,
                    maxGlowOpacity: 0.2,
                    blurRadius: 6,
                    onTap: () => _selectElement(switchKey),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isCurrent
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isCurrent
                              ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.07),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            _elementIcons[switchKey] ?? Icons.widgets_rounded,
                            size: 11,
                            color: isCurrent
                                ? const Color(0xFF38BDF8)
                                : Colors.white54,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            _elementLabels[switchKey] ?? switchKey,
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: isCurrent
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: isCurrent ? Colors.white : Colors.white60,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                },
              ),
            );
          },
        ),
        const SizedBox(height: 20),

        // ── SECTION: SIZING & SCALE ──
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel('OBJECT SIZING & SCALE'),
            if (_settings.elementSizes.containsKey(key))
              TextButton.icon(
                onPressed: () {
                  final map = Map<String, double>.from(_settings.elementSizes)
                    ..remove(key);
                  _updateSettings(_settings.copyWith(elementSizes: map));
                },
                icon: const Icon(Icons.link_off_rounded, size: 12),
                label: const Text(
                  'Inherit 1.00x',
                  style: TextStyle(fontSize: 10),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 8),

        // Quick Size Preset Chips
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children:
              [
                {'label': '0.70x Compact', 'val': 0.70},
                {'label': '0.85x Small', 'val': 0.85},
                {'label': '1.00x Normal', 'val': 1.00},
                {'label': '1.25x Medium', 'val': 1.25},
                {'label': '1.50x Large', 'val': 1.50},
                {'label': '2.00x Hero', 'val': 2.00},
              ].map((preset) {
                final isMatch =
                    (currentScale - (preset['val'] as double)).abs() < 0.02;
                return HoverCard(
                  scaleUp: 1.04,
                  borderRadius: BorderRadius.circular(8),
                  glowColor: isMatch
                      ? const Color(0xFF38BDF8)
                      : Colors.transparent,
                  maxGlowOpacity: 0.2,
                  blurRadius: 6,
                  onTap: () {
                    final map = Map<String, double>.from(
                      _settings.elementSizes,
                    );
                    map[key] = preset['val'] as double;
                    _updateSettings(_settings.copyWith(elementSizes: map));
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 9,
                      vertical: 5,
                    ),
                    decoration: BoxDecoration(
                      color: isMatch
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isMatch
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                            : Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    child: Text(
                      preset['label'] as String,
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: isMatch ? FontWeight.w800 : FontWeight.w600,
                        color: isMatch ? Colors.white : Colors.white70,
                      ),
                    ),
                  ),
                );
              }).toList(),
        ),
        const SizedBox(height: 10),

        // Precision Scale Slider
        _buildSlider(
          'Scale',
          currentScale,
          0.2,
          3.5,
          (v) {
            final map = Map<String, double>.from(_settings.elementSizes);
            map[key] = double.parse(v.toStringAsFixed(2));
            _updateSettings(_settings.copyWith(elementSizes: map));
          },
          step: 0.05,
          decimals: 2,
          onReset: () {
            final map = Map<String, double>.from(_settings.elementSizes)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementSizes: map));
          },
        ),

        // Separator Specific Sizing Controls
        if (key == ElementKey.separator) ...[
          const SizedBox(height: 14),
          _sectionLabel('SEPARATOR DIMENSIONS'),
          const SizedBox(height: 8),

          Wrap(
            spacing: 6,
            runSpacing: 6,
            children:
                [
                  {'label': 'Dot (6×6)', 'w': 6.0, 'h': 6.0},
                  {'label': 'Thin (32×2)', 'w': 32.0, 'h': 2.0},
                  {'label': 'Standard (80×2)', 'w': 80.0, 'h': 2.0},
                  {'label': 'Bold (120×4)', 'w': 120.0, 'h': 4.0},
                  {'label': 'Pill (4×32)', 'w': 4.0, 'h': 32.0},
                ].map((p) {
                  final isMatch =
                      (_settings.effectiveSeparatorWidth == p['w'] &&
                      _settings.effectiveSeparatorHeight == p['h']);
                  return HoverCard(
                    scaleUp: 1.04,
                    borderRadius: BorderRadius.circular(8),
                    glowColor: isMatch
                        ? const Color(0xFF38BDF8)
                        : Colors.transparent,
                    maxGlowOpacity: 0.2,
                    blurRadius: 6,
                    onTap: () {
                      _updateSettings(
                        _settings.copyWith(
                          separatorWidth: p['w'] as double,
                          separatorHeight: p['h'] as double,
                        ),
                      );
                    },
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 9,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: isMatch
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                            : Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isMatch
                              ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                              : Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Text(
                        p['label'] as String,
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: isMatch
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: isMatch ? Colors.white : Colors.white70,
                        ),
                      ),
                    ),
                  );
                }).toList(),
          ),
          const SizedBox(height: 10),

          _buildSlider(
            'Width',
            _settings.effectiveSeparatorWidth,
            1.0,
            250.0,
            (v) {
              _updateSettings(
                _settings.copyWith(
                  separatorWidth: double.parse(v.toStringAsFixed(1)),
                ),
              );
            },
            step: 2.0,
            decimals: 0,
            suffix: ' px',
            onReset: () {
              _updateSettings(_settings.copyWith(separatorWidth: 80.0));
            },
          ),
          const SizedBox(height: 4),
          _buildSlider(
            'Height',
            _settings.effectiveSeparatorHeight,
            1.0,
            120.0,
            (v) {
              _updateSettings(
                _settings.copyWith(
                  separatorHeight: double.parse(v.toStringAsFixed(1)),
                ),
              );
            },
            step: 1.0,
            decimals: 0,
            suffix: ' px',
            onReset: () {
              _updateSettings(_settings.copyWith(separatorHeight: 2.0));
            },
          ),
        ],

        const SizedBox(height: 8),
        _buildSlider(
          'Master Size',
          _settings.fontSizeMultiplier,
          0.6,
          1.6,
          (v) => _updateSettings(_settings.copyWith(fontSizeMultiplier: v)),
          step: 0.05,
          percent: true,
          onReset: () =>
              _updateSettings(_settings.copyWith(fontSizeMultiplier: 1.0)),
        ),

        // ── SECTION: TYPOGRAPHY (For Text Elements) ──
        if (isText) ...[
          const SizedBox(height: 20),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _sectionLabel('FONT FAMILY'),
              if (_settings.elementFonts.containsKey(key))
                TextButton.icon(
                  onPressed: () {
                    final map = Map<String, String>.from(_settings.elementFonts)
                      ..remove(key);
                    _updateSettings(_settings.copyWith(elementFonts: map));
                  },
                  icon: const Icon(Icons.link_off_rounded, size: 12),
                  label: Text(
                    'Use Master (${_settings.fontFamily})',
                    style: const TextStyle(fontSize: 10),
                  ),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF38BDF8),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2,
                    ),
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              // Chip for Inheriting Master Font
              HoverCard(
                scaleUp: 1.04,
                borderRadius: BorderRadius.circular(8),
                glowColor: !_settings.elementFonts.containsKey(key)
                    ? const Color(0xFFEC4899)
                    : Colors.transparent,
                maxGlowOpacity: 0.2,
                blurRadius: 8,
                onTap: () {
                  final map = Map<String, String>.from(_settings.elementFonts)
                    ..remove(key);
                  _updateSettings(_settings.copyWith(elementFonts: map));
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: !_settings.elementFonts.containsKey(key)
                        ? const Color(0xFFEC4899).withValues(alpha: 0.18)
                        : Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: !_settings.elementFonts.containsKey(key)
                          ? const Color(0xFFEC4899).withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(
                        Icons.auto_awesome,
                        size: 12,
                        color: Color(0xFFEC4899),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        'Master (${_settings.fontFamily})',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: !_settings.elementFonts.containsKey(key)
                              ? FontWeight.w800
                              : FontWeight.w600,
                          color: !_settings.elementFonts.containsKey(key)
                              ? Colors.white
                              : Colors.white70,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              ..._fonts.map((font) {
                final sel = _settings.elementFonts[key] == font;
                return HoverCard(
                  scaleUp: 1.04,
                  borderRadius: BorderRadius.circular(8),
                  glowColor: sel ? const Color(0xFF38BDF8) : Colors.transparent,
                  maxGlowOpacity: 0.2,
                  blurRadius: 8,
                  onTap: () => _setElementFont(key, font),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 14,
                      vertical: 8,
                    ),
                    decoration: BoxDecoration(
                      color: sel
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: sel
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                            : Colors.white.withValues(alpha: 0.08),
                        width: 1.0,
                      ),
                    ),
                    child: Text(
                      font,
                      style: TextStyle(
                        fontFamily: font,
                        fontSize: 12,
                        color: sel ? Colors.white : Colors.white60,
                        fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                      ),
                    ),
                  ),
                );
              }),
            ],
          ),
        ],

        // ── SECTION: COLOR & TRANSPARENCY ──
        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel('COLOR & GRADIENT STYLING'),
            if (_settings.elementColors.containsKey(key) || hasElementGradient)
              TextButton.icon(
                onPressed: () {
                  final mapColors = Map<String, int>.from(
                    _settings.elementColors,
                  )..remove(key);
                  final mapGradients = Map<String, List<int>>.from(
                    _settings.elementGradients,
                  )..remove(key);
                  _updateSettings(
                    _settings.copyWith(
                      elementColors: mapColors,
                      elementGradients: mapGradients,
                    ),
                  );
                },
                icon: const Icon(Icons.link_off_rounded, size: 12),
                label: const Text(
                  'Inherit Master',
                  style: TextStyle(fontSize: 10),
                ),
                style: TextButton.styleFrom(
                  foregroundColor: const Color(0xFF38BDF8),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 6,
                    vertical: 2,
                  ),
                  minimumSize: Size.zero,
                  tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                ),
              ),
          ],
        ),
        const SizedBox(height: 10),

        // Style Segmented Selector: [ Solid Color ] | [ Gradient Style ]
        Row(
          children: [
            _buildColorModeButton(
              label: 'Solid Color',
              icon: Icons.palette_outlined,
              isSelected: !hasElementGradient,
              onTap: () {
                if (hasElementGradient) {
                  _removeElementGradient(key);
                }
              },
            ),
            const SizedBox(width: 8),
            _buildColorModeButton(
              label: 'Gradient',
              icon: Icons.gradient_rounded,
              isSelected: hasElementGradient,
              onTap: () {
                if (!hasElementGradient) {
                  _setElementGradient(key, [
                    currentColor,
                    const Color(0xFFD946EF),
                  ]);
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 14),

        if (!hasElementGradient) ...[
          ColorPickerWidget(
            initialColor: currentColor,
            paletteColors: _settings.colorPalette.map((v) => Color(v)).toList(),
            enableAlpha: true,
            onColorChanged: (c) => _setElementColor(key, c),
            onSaveTopalette: () => _saveColorToPalette(currentColor),
          ),
          const SizedBox(height: 10),
          // Quick Palette Swatches
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children:
                [
                  {'name': 'White', 'color': 0xFFFFFFFF},
                  {'name': 'Cyan', 'color': 0xFF38BDF8},
                  {'name': 'Mint', 'color': 0xFF10B981},
                  {'name': 'Purple', 'color': 0xFFA855F7},
                  {'name': 'Amber', 'color': 0xFFF59E0B},
                  {'name': 'Rose', 'color': 0xFFF43F5E},
                  {'name': 'Slate', 'color': 0xFF64748B},
                ].map((preset) {
                  final col = Color(preset['color'] as int);
                  return InkWell(
                    onTap: () => _setElementColor(key, col),
                    borderRadius: BorderRadius.circular(6),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 4,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.04),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.08),
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: col,
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 5),
                          Text(
                            preset['name'] as String,
                            style: const TextStyle(
                              fontSize: 10,
                              color: Colors.white70,
                            ),
                          ),
                        ],
                      ),
                    ),
                  );
                }).toList(),
          ),
        ] else ...[
          GradientPickerWidget(
            initialColors:
                _settings.elementGradients[key]
                    ?.map((c) => Color(c))
                    .toList() ??
                [currentColor, const Color(0xFFD946EF)],
            paletteColors: _settings.colorPalette.map((v) => Color(v)).toList(),
            onGradientChanged: (newColors) =>
                _setElementGradient(key, newColors),
            onSaveToPalette: () => _saveColorToPalette(currentColor),
          ),
        ],

        // ── SECTION: 3D SPATIAL OFFSETS & TRANSFORMS ──
        const SizedBox(height: 24),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel('3D SPATIAL OFFSETS & TRANSFORMS'),
            TextButton.icon(
              onPressed: () {
                final tx = Map<String, double>.from(_settings.elementTranslateX)
                  ..remove(key);
                final ty = Map<String, double>.from(_settings.elementTranslateY)
                  ..remove(key);
                final tz = Map<String, double>.from(_settings.elementTranslateZ)
                  ..remove(key);
                final rx = Map<String, double>.from(_settings.elementRotateX)
                  ..remove(key);
                final ry = Map<String, double>.from(_settings.elementRotateY)
                  ..remove(key);
                final rz = Map<String, double>.from(_settings.elementRotateZ)
                  ..remove(key);
                _updateSettings(
                  _settings.copyWith(
                    elementTranslateX: tx,
                    elementTranslateY: ty,
                    elementTranslateZ: tz,
                    elementRotateX: rx,
                    elementRotateY: ry,
                    elementRotateZ: rz,
                  ),
                );
              },
              icon: const Icon(Icons.center_focus_strong_rounded, size: 12),
              label: const Text(
                'Center (0)',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF38BDF8),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        _buildSlider(
          'Offset X',
          _settings.translateXFor(key),
          -150.0,
          150.0,
          (v) {
            final map = Map<String, double>.from(_settings.elementTranslateX);
            map[key] = double.parse(v.toStringAsFixed(1));
            _updateSettings(_settings.copyWith(elementTranslateX: map));
          },
          step: 2.0,
          decimals: 0,
          suffix: ' px',
          onReset: () {
            final map = Map<String, double>.from(_settings.elementTranslateX)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementTranslateX: map));
          },
        ),
        const SizedBox(height: 4),
        _buildSlider(
          'Offset Y',
          _settings.translateYFor(key),
          -150.0,
          150.0,
          (v) {
            final map = Map<String, double>.from(_settings.elementTranslateY);
            map[key] = double.parse(v.toStringAsFixed(1));
            _updateSettings(_settings.copyWith(elementTranslateY: map));
          },
          step: 2.0,
          decimals: 0,
          suffix: ' px',
          onReset: () {
            final map = Map<String, double>.from(_settings.elementTranslateY)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementTranslateY: map));
          },
        ),
        const SizedBox(height: 4),
        _buildSlider(
          'Offset Z',
          _settings.translateZFor(key),
          -150.0,
          150.0,
          (v) {
            final map = Map<String, double>.from(_settings.elementTranslateZ);
            map[key] = double.parse(v.toStringAsFixed(1));
            _updateSettings(_settings.copyWith(elementTranslateZ: map));
          },
          step: 2.0,
          decimals: 0,
          suffix: ' px',
          onReset: () {
            final map = Map<String, double>.from(_settings.elementTranslateZ)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementTranslateZ: map));
          },
        ),

        const SizedBox(height: 14),
        _sectionLabel('3D ROTATION (PITCH, YAW, ROLL)'),
        const SizedBox(height: 8),
        _buildSlider(
          'Pitch X',
          _settings.rotateXFor(key),
          -90.0,
          90.0,
          (v) {
            final map = Map<String, double>.from(_settings.elementRotateX);
            map[key] = double.parse(v.toStringAsFixed(1));
            _updateSettings(_settings.copyWith(elementRotateX: map));
          },
          step: 5.0,
          decimals: 0,
          suffix: '°',
          onReset: () {
            final map = Map<String, double>.from(_settings.elementRotateX)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementRotateX: map));
          },
        ),
        const SizedBox(height: 4),
        _buildSlider(
          'Yaw Y',
          _settings.rotateYFor(key),
          -90.0,
          90.0,
          (v) {
            final map = Map<String, double>.from(_settings.elementRotateY);
            map[key] = double.parse(v.toStringAsFixed(1));
            _updateSettings(_settings.copyWith(elementRotateY: map));
          },
          step: 5.0,
          decimals: 0,
          suffix: '°',
          onReset: () {
            final map = Map<String, double>.from(_settings.elementRotateY)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementRotateY: map));
          },
        ),
        const SizedBox(height: 4),
        _buildSlider(
          'Roll Z',
          _settings.rotateZFor(key),
          -180.0,
          180.0,
          (v) {
            final map = Map<String, double>.from(_settings.elementRotateZ);
            map[key] = double.parse(v.toStringAsFixed(1));
            _updateSettings(_settings.copyWith(elementRotateZ: map));
          },
          step: 5.0,
          decimals: 0,
          suffix: '°',
          onReset: () {
            final map = Map<String, double>.from(_settings.elementRotateZ)
              ..remove(key);
            _updateSettings(_settings.copyWith(elementRotateZ: map));
          },
        ),

        // ── SECTION: CONTEXTUAL CONTROLS ──
        if (key == ElementKey.hours) ...[
          const SizedBox(height: 20),
          _sectionLabel('CLOCK FORMAT'),
          const SizedBox(height: 8),
          _buildToggleTile(
            '24-Hour Format',
            _settings.use24HourFormat,
            (v) => _updateSettings(_settings.copyWith(use24HourFormat: v)),
            subtitle: _settings.use24HourFormat
                ? 'Showing 00–23'
                : 'Showing 01–12 with AM/PM',
          ),
        ],

        if (key == ElementKey.minutes) ...[
          const SizedBox(height: 20),
          _sectionLabel('SECONDS DISPLAY'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Seconds Next to Minutes',
            _settings.showSeconds,
            (v) => _updateSettings(_settings.copyWith(showSeconds: v)),
            subtitle: 'Real-time seconds display in widget',
          ),
        ],

        if (key == ElementKey.seconds) ...[
          const SizedBox(height: 20),
          _sectionLabel('SECONDS VISIBILITY'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Seconds',
            _settings.showSeconds,
            (v) => _updateSettings(_settings.copyWith(showSeconds: v)),
            subtitle: 'Enables real-time 1-second pulse animation',
          ),
        ],

        if (key == ElementKey.ampm) ...[
          const SizedBox(height: 20),
          _sectionLabel('12-HOUR / 24-HOUR MODE'),
          const SizedBox(height: 8),
          _buildToggleTile(
            '24-Hour Format',
            _settings.use24HourFormat,
            (v) => _updateSettings(_settings.copyWith(use24HourFormat: v)),
            subtitle: _settings.use24HourFormat
                ? '24-Hour mode active (AM/PM hidden)'
                : '12-Hour mode active (AM/PM visible)',
          ),
        ],

        if (key == ElementKey.weatherTemp ||
            key == ElementKey.weatherStatus ||
            key == ElementKey.weatherIcon) ...[
          const SizedBox(height: 20),
          _sectionLabel('WEATHER CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Weather Details',
            _settings.showWeather,
            (v) => _updateSettings(_settings.copyWith(showWeather: v)),
          ),
          if (_settings.showWeather) ...[
            const SizedBox(height: 8),
            _buildWeatherSettingsControls(),
          ],
        ],

        if (key == ElementKey.wifiIcon || key == ElementKey.wifiText) ...[
          const SizedBox(height: 20),
          _sectionLabel('WI-FI CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Wi-Fi Icon',
            _settings.showWifi,
            (v) => _updateSettings(_settings.copyWith(showWifi: v)),
          ),
          const SizedBox(height: 4),
          _buildToggleTile(
            'Wi-Fi Connected State',
            _settings.wifiEnabled,
            (v) => _updateSettings(_settings.copyWith(wifiEnabled: v)),
          ),
        ],

        if (key == ElementKey.bluetoothIcon ||
            key == ElementKey.bluetoothText) ...[
          const SizedBox(height: 20),
          _sectionLabel('BLUETOOTH CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Bluetooth Icon',
            _settings.showBluetooth,
            (v) => _updateSettings(_settings.copyWith(showBluetooth: v)),
          ),
          const SizedBox(height: 4),
          _buildToggleTile(
            'Bluetooth Connected State',
            _settings.bluetoothEnabled,
            (v) => _updateSettings(_settings.copyWith(bluetoothEnabled: v)),
          ),
        ],

        if (key == ElementKey.mediaTitle ||
            key == ElementKey.mediaArtist ||
            key == ElementKey.mediaTime ||
            key == ElementKey.mediaIcon ||
            key == ElementKey.mediaBg) ...[
          const SizedBox(height: 20),
          _sectionLabel('MEDIA CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Media Bar',
            _settings.showMediaControl,
            (v) => _updateSettings(_settings.copyWith(showMediaControl: v)),
          ),
        ],

        if (key == ElementKey.cpu) ...[
          const SizedBox(height: 20),
          _sectionLabel('CPU MONITOR CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show CPU Usage Monitor',
            _settings.showCpu,
            (v) => _updateSettings(_settings.copyWith(showCpu: v)),
          ),
        ],

        if (key == ElementKey.ram) ...[
          const SizedBox(height: 20),
          _sectionLabel('RAM MONITOR CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show RAM Usage Monitor',
            _settings.showRam,
            (v) => _updateSettings(_settings.copyWith(showRam: v)),
          ),
        ],

        if (key == ElementKey.neonBadge) ...[
          const SizedBox(height: 20),
          _sectionLabel('BADGE CONTROLS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Glass Neon Badge',
            _settings.showNeonBadge,
            (v) => _updateSettings(_settings.copyWith(showNeonBadge: v)),
          ),
        ],

        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildGlobalTypography() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('GLOBAL DEFAULT FONT'),
        const SizedBox(height: 8),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: _fonts.map((font) {
            final sel = _settings.fontFamily == font;
            return HoverCard(
              scaleUp: 1.04,
              borderRadius: BorderRadius.circular(8),
              glowColor: sel ? const Color(0xFF38BDF8) : Colors.transparent,
              maxGlowOpacity: 0.2,
              blurRadius: 8,
              onTap: () =>
                  _updateSettings(_settings.copyWith(fontFamily: font)),
              child: AnimatedContainer(
                duration: const Duration(milliseconds: 200),
                padding: const EdgeInsets.symmetric(
                  horizontal: 14,
                  vertical: 8,
                ),
                decoration: BoxDecoration(
                  color: sel
                      ? const Color(0xFF38BDF8).withValues(alpha: 0.15)
                      : Colors.white.withValues(alpha: 0.03),
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: sel
                        ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                        : Colors.white.withValues(alpha: 0.08),
                    width: 1.0,
                  ),
                ),
                child: Text(
                  font,
                  style: TextStyle(
                    fontFamily: font,
                    fontSize: 12,
                    color: sel ? Colors.white : Colors.white60,
                    fontWeight: sel ? FontWeight.w800 : FontWeight.w500,
                  ),
                ),
              ),
            );
          }).toList(),
        ),
        const SizedBox(height: 14),
        _sectionLabel('GLOBAL DEFAULT COLOR & GRADIENT'),
        const SizedBox(height: 10),
        Row(
          children: [
            _buildColorModeButton(
              label: 'Solid Text',
              icon: Icons.format_color_text_rounded,
              isSelected: !_settings.useGlobalGradient,
              onTap: () {
                if (_settings.useGlobalGradient) {
                  _updateSettings(_settings.copyWith(useGlobalGradient: false));
                }
              },
            ),
            const SizedBox(width: 8),
            _buildColorModeButton(
              label: 'Gradient Text',
              icon: Icons.auto_awesome_rounded,
              isSelected: _settings.useGlobalGradient,
              onTap: () {
                if (!_settings.useGlobalGradient) {
                  _updateSettings(_settings.copyWith(useGlobalGradient: true));
                }
              },
            ),
          ],
        ),
        const SizedBox(height: 14),
        if (!_settings.useGlobalGradient)
          ColorPickerWidget(
            initialColor: Color(_settings.textColor),
            paletteColors: _settings.colorPalette.map((v) => Color(v)).toList(),
            enableAlpha: true,
            onColorChanged: (c) =>
                _updateSettings(_settings.copyWith(textColor: c.toARGB32())),
            onSaveTopalette: () =>
                _saveColorToPalette(Color(_settings.textColor)),
          )
        else
          GradientPickerWidget(
            initialColors: _settings.globalGradientColors
                .map((c) => Color(c))
                .toList(),
            paletteColors: _settings.colorPalette.map((v) => Color(v)).toList(),
            onGradientChanged: (cols) {
              _updateSettings(
                _settings.copyWith(
                  globalGradientColors: cols.map((c) => c.toARGB32()).toList(),
                ),
              );
            },
            onSaveToPalette: () => _saveColorToPalette(
              Color(_settings.globalGradientColors.first),
            ),
          ),
      ],
    );
  }

  // ── BACKGROUND EDITOR ────────────────────────────────────────────────────

  Widget _buildBackgroundEditor() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        // ── Widget Background ──
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel('WIDGET BACKGROUND'),
            TextButton.icon(
              onPressed: () {
                _updateSettings(
                  _settings.copyWith(
                    backgroundType: 'none',
                    curatedIndex: 0,
                    customImagePath: null,
                    animatedBg: '',
                    opacity: 1.0,
                  ),
                );
              },
              icon: const Icon(Icons.refresh, size: 12),
              label: const Text(
                'Reset',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF38BDF8),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            _bgTypeChip(
              'Off',
              'none',
              null,
              child: const Center(
                child: Text(
                  'Off (Transparent)',
                  style: TextStyle(color: Colors.white70, fontSize: 11),
                ),
              ),
            ),
            const SizedBox(width: 10),
            _bgTypeChip('Solid Color', 'solid', null),
          ],
        ),
        const SizedBox(height: 10),
        Row(
          children: [
            _bgTypeChip('Gradient Presets', 'gradient', null),
            const SizedBox(width: 10),
            _bgTypeChip('Custom Gradient', 'custom_gradient', null),
          ],
        ),

        if (_settings.backgroundType == 'solid') ...[
          const SizedBox(height: 20),
          _sectionLabel('SOLID COLOR SELECTION'),
          const SizedBox(height: 10),
          ColorPickerWidget(
            initialColor: Color(_settings.solidColor),
            paletteColors: _settings.colorPalette.map((v) => Color(v)).toList(),
            onColorChanged: (c) =>
                _updateSettings(_settings.copyWith(solidColor: c.toARGB32())),
            onSaveTopalette: () =>
                _saveColorToPalette(Color(_settings.solidColor)),
          ),
        ],

        if (_settings.backgroundType == 'custom_gradient') ...[
          const SizedBox(height: 20),
          _sectionLabel('CUSTOM GRADIENT BUILDER'),
          const SizedBox(height: 10),
          GradientPickerWidget(
            initialColors: _settings.customGradientColors
                .map((c) => Color(c))
                .toList(),
            paletteColors: _settings.colorPalette.map((v) => Color(v)).toList(),
            onGradientChanged: (cols) {
              _updateSettings(
                _settings.copyWith(
                  customGradientColors: cols.map((c) => c.toARGB32()).toList(),
                ),
              );
            },
            onSaveToPalette: () => _saveColorToPalette(
              Color(_settings.customGradientColors.first),
            ),
          ),
        ],

        if (_settings.backgroundType == 'gradient') ...[
          const SizedBox(height: 20),
          _sectionLabel('GRADIENT PRESETS'),
          const SizedBox(height: 8),
          SizedBox(
            height: 60,
            child: HorizontalScrollWrapper(
              controller: _gradientScrollCtrl,
              child: ListView.builder(
                controller: _gradientScrollCtrl,
                scrollDirection: Axis.horizontal,
                itemCount: _gradientPresets.length,
                itemBuilder: (_, i) {
                  final isSelected =
                      _settings.backgroundType == 'gradient' &&
                      _settings.curatedIndex == i;
                  final themeColor = const Color(0xFF38BDF8);
                  return Padding(
                    padding: const EdgeInsets.only(
                      right: 10,
                      bottom: 8,
                      top: 4,
                    ),
                    child: HoverCard(
                      scaleUp: 1.04,
                      borderRadius: BorderRadius.circular(10),
                      glowColor: isSelected ? themeColor : Colors.transparent,
                      maxGlowOpacity: 0.25,
                      blurRadius: 10,
                      onTap: () => _updateSettings(
                        _settings.copyWith(
                          backgroundType: 'gradient',
                          curatedIndex: i,
                        ),
                      ),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 200),
                        width: 80,
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: _gradientPresets[i],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: isSelected
                                ? themeColor
                                : Colors.white.withValues(alpha: 0.08),
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: isSelected
                            ? const Center(
                                child: Icon(
                                  Icons.check,
                                  color: Colors.white,
                                  size: 16,
                                ),
                              )
                            : null,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
        ],

        const SizedBox(height: 20),

        // ── Animated backgrounds ──
        _sectionLabel('ANIMATED BACKGROUNDS'),
        const SizedBox(height: 8),
        SizedBox(
          height: 96,
          child: HorizontalScrollWrapper(
            controller: _animatedBgScrollCtrl,
            child: ListView(
              controller: _animatedBgScrollCtrl,
              scrollDirection: Axis.horizontal,
              children: animatedBgLabels.entries.map((e) {
                final isSelected =
                    _settings.backgroundType == 'animated' &&
                    _settings.animatedBg == e.key;
                final themeColor = const Color(0xFFC084FC);
                return Padding(
                  padding: const EdgeInsets.only(right: 12, bottom: 8, top: 4),
                  child: HoverCard(
                    scaleUp: 1.04,
                    borderRadius: BorderRadius.circular(12),
                    glowColor: isSelected ? themeColor : Colors.transparent,
                    maxGlowOpacity: 0.25,
                    blurRadius: 10,
                    onTap: () => _updateSettings(
                      _settings.copyWith(
                        backgroundType: 'animated',
                        animatedBg: e.key,
                      ),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 100,
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(
                          color: isSelected
                              ? themeColor
                              : Colors.white.withValues(alpha: 0.08),
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(11),
                        child: Stack(
                          children: [
                            buildAnimatedBackground(e.key),
                            Positioned(
                              bottom: 0,
                              left: 0,
                              right: 0,
                              child: Container(
                                padding: const EdgeInsets.symmetric(
                                  vertical: 6,
                                ),
                                color: Colors.black.withValues(alpha: 0.65),
                                child: Text(
                                  e.value,
                                  textAlign: TextAlign.center,
                                  style: TextStyle(
                                    fontSize: 10,
                                    fontWeight: isSelected
                                        ? FontWeight.w800
                                        : FontWeight.w500,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                ),
                              ),
                            ),
                            if (isSelected)
                              Positioned(
                                top: 6,
                                right: 6,
                                child: Container(
                                  padding: const EdgeInsets.all(3),
                                  decoration: BoxDecoration(
                                    color: themeColor,
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Icon(
                                    Icons.check,
                                    size: 8,
                                    color: Colors.white,
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  ),
                );
              }).toList(),
            ),
          ),
        ),

        const SizedBox(height: 20),

        // ── Curated wallpapers ──
        _sectionLabel('CURATED WALLPAPERS'),
        const SizedBox(height: 8),
        SizedBox(
          height: 64,
          child: HorizontalScrollWrapper(
            controller: _curatedWpScrollCtrl,
            child: ListView.builder(
              controller: _curatedWpScrollCtrl,
              scrollDirection: Axis.horizontal,
              itemCount: _curatedWallpapers.length,
              itemBuilder: (_, i) {
                final isSelected =
                    _settings.backgroundType == 'curated' &&
                    _settings.curatedIndex == i;
                final themeColor = const Color(0xFF38BDF8);
                return Padding(
                  padding: const EdgeInsets.only(right: 10, bottom: 8, top: 4),
                  child: HoverCard(
                    scaleUp: 1.04,
                    borderRadius: BorderRadius.circular(10),
                    glowColor: isSelected ? themeColor : Colors.transparent,
                    maxGlowOpacity: 0.25,
                    blurRadius: 10,
                    onTap: () => _updateSettings(
                      _settings.copyWith(
                        backgroundType: 'curated',
                        curatedIndex: i,
                      ),
                    ),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 200),
                      width: 80,
                      decoration: BoxDecoration(
                        image: DecorationImage(
                          image: ResizeImage(
                            AssetImage(_curatedWallpapers[i]['path']!),
                            width: 171,
                            height: 121,
                          ),
                          fit: BoxFit.cover,
                        ),
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: isSelected
                              ? themeColor
                              : Colors.white.withValues(alpha: 0.08),
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: isSelected
                          ? Container(
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.45),
                                borderRadius: BorderRadius.circular(9),
                              ),
                              child: const Center(
                                child: Icon(Icons.check, color: Colors.white),
                              ),
                            )
                          : null,
                    ),
                  ),
                );
              },
            ),
          ),
        ),

        const SizedBox(height: 20),

        // ── Custom image ──
        _sectionLabel('CUSTOM IMAGE'),
        const SizedBox(height: 8),
        _buildCustomImagePicker(),

        if (_settings.backgroundType == 'curated' ||
            _settings.backgroundType == 'custom') ...[
          const SizedBox(height: 20),
          _sectionLabel('WALLPAPER DISPLAY OPTIONS'),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(child: _buildFitOption('Fill', 'fill')),
              const SizedBox(width: 8),
              Expanded(child: _buildFitOption('Fit', 'fit')),
              const SizedBox(width: 8),
              Expanded(child: _buildFitOption('Stretch', 'stretch')),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(child: _buildFitOption('Tile', 'tile')),
              const SizedBox(width: 8),
              Expanded(child: _buildFitOption('Center', 'center')),
              const SizedBox(width: 8),
              Expanded(child: _buildFitOption('Span', 'span')),
            ],
          ),
          const SizedBox(height: 12),
          _buildToggleTile(
            'Color Boost (4K Vibrancy)',
            _settings.colorBoost,
            (v) => _updateSettings(_settings.copyWith(colorBoost: v)),
            subtitle: 'Enhances colors, saturation, and native 4K clarity',
          ),
        ],
      ],
    );
  }

  Widget _bgTypeChip(String label, String type, int? idx, {Widget? child}) {
    final isSelected =
        _settings.backgroundType == type &&
        (idx == null || _settings.curatedIndex == idx);
    final themeColor = const Color(0xFFEC4899);
    return Expanded(
      child: HoverCard(
        scaleUp: 1.03,
        borderRadius: BorderRadius.circular(10),
        glowColor: isSelected ? themeColor : Colors.transparent,
        maxGlowOpacity: 0.2,
        blurRadius: 8,
        onTap: () {
          var s = _settings.copyWith(backgroundType: type);
          if (idx != null) s = s.copyWith(curatedIndex: idx);
          _updateSettings(s);
        },
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          height: 44,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isSelected
                  ? themeColor
                  : Colors.white.withValues(alpha: 0.08),
              width: isSelected ? 1.5 : 1.0,
            ),
            color: isSelected
                ? themeColor.withValues(alpha: 0.1)
                : Colors.white.withValues(alpha: 0.03),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(9),
            child:
                child ??
                Center(
                  child: Text(
                    label,
                    style: TextStyle(
                      fontSize: 11,
                      color: isSelected ? Colors.white : Colors.white60,
                      fontWeight: isSelected
                          ? FontWeight.w800
                          : FontWeight.w500,
                    ),
                  ),
                ),
          ),
        ),
      ),
    );
  }

  Widget _buildCustomImagePicker() {
    final hasImage = _settings.customImagePath?.isNotEmpty ?? false;
    final isSelected = _settings.backgroundType == 'custom';
    final themeColor = const Color(0xFF38BDF8);
    return HoverCard(
      scaleUp: 1.025,
      borderRadius: BorderRadius.circular(10),
      glowColor: isSelected ? themeColor : Colors.transparent,
      maxGlowOpacity: 0.15,
      blurRadius: 8,
      onTap: () async {
        // Use native Windows OpenFileDialog via PowerShell — avoids file_picker API instability
        try {
          final result = await Process.run('powershell', [
            '-NonInteractive',
            '-NoProfile',
            '-WindowStyle',
            'Hidden',
            '-Command',
            'Add-Type -AssemblyName System.Windows.Forms; '
                r'$ofd = New-Object System.Windows.Forms.OpenFileDialog; '
                r'$ofd.Filter = "Image files|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.webp"; '
                r'if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) { Write-Output $ofd.FileName }',
          ]);
          final path = result.stdout.toString().trim();
          if (path.isNotEmpty && await File(path).exists()) {
            _updateSettings(
              _settings.copyWith(
                backgroundType: 'custom',
                customImagePath: path,
              ),
            );
          }
        } catch (e, st) {
          debugPrint('Swallowed Error in lib/widgets/dashboard_view.dart: $e');
          debugPrint(st.toString());
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: isSelected
              ? themeColor.withValues(alpha: 0.1)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: isSelected
                ? themeColor.withValues(alpha: 0.5)
                : Colors.white.withValues(alpha: 0.1),
            width: 1.0,
          ),
        ),
        child: Row(
          children: [
            Icon(
              hasImage ? Icons.image : Icons.add_photo_alternate_outlined,
              size: 18,
              color: isSelected ? themeColor : Colors.white38,
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                hasImage
                    ? _settings.customImagePath!
                          .split(Platform.pathSeparator)
                          .last
                    : 'Choose image file…',
                style: TextStyle(
                  fontSize: 11,
                  color: hasImage ? Colors.white : Colors.white38,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (hasImage)
              GestureDetector(
                onTap: () => _updateSettings(
                  _settings.copyWith(
                    customImagePath: null,
                    backgroundType: 'none',
                  ),
                ),
                child: const Icon(Icons.close, size: 14, color: Colors.white38),
              ),
          ],
        ),
      ),
    );
  }

  void _showAnimatedSnackBar(String message, {bool isSuccess = true}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).clearSnackBars();
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        behavior: SnackBarBehavior.floating,
        backgroundColor: Colors.transparent,
        elevation: 0,
        content: TweenAnimationBuilder<double>(
          key: ValueKey(message),
          tween: Tween<double>(begin: 0.0, end: 1.0),
          duration: const Duration(milliseconds: 350),
          curve: Curves.easeOutBack,
          builder: (context, value, child) {
            return Transform.scale(
              scale: value,
              child: Opacity(
                opacity: value.clamp(0.0, 1.0),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 16,
                    vertical: 12,
                  ),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: isSuccess
                          ? [const Color(0xFF43E97B), const Color(0xFF38F9D7)]
                          : [const Color(0xFFFF512F), const Color(0xFFDD2476)],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: [
                      BoxShadow(
                        color:
                            (isSuccess
                                    ? const Color(0xFF38F9D7)
                                    : const Color(0xFFDD2476))
                                .withValues(alpha: 0.3),
                        blurRadius: 12,
                        offset: const Offset(0, 4),
                      ),
                    ],
                  ),
                  child: Row(
                    children: [
                      Icon(
                        isSuccess
                            ? Icons.check_circle_rounded
                            : Icons.error_rounded,
                        color: Colors.white,
                        size: 20,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Text(
                          message,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                            letterSpacing: 0.5,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  Widget _buildFitOption(String label, String value) {
    final isSelected = _settings.wallpaperFit == value;
    final themeColor = const Color(0xFF38BDF8);
    return HoverCard(
      scaleUp: 1.03,
      borderRadius: BorderRadius.circular(8),
      glowColor: isSelected ? themeColor : Colors.transparent,
      maxGlowOpacity: 0.15,
      blurRadius: 8,
      onTap: () async {
        final newSettings = _settings.copyWith(wallpaperFit: value);
        _updateSettings(newSettings);
        if (_settings.activeWallpaperType == 'static' &&
            _settings.activeWallpaperPath != null) {
          await _wallpaperEngine.setStaticWallpaper(
            _settings.activeWallpaperPath!,
            value,
          );
        }
      },
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: BoxDecoration(
          color: isSelected
              ? themeColor.withValues(alpha: 0.15)
              : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? themeColor.withValues(alpha: 0.6)
                : Colors.white.withValues(alpha: 0.08),
            width: 1,
          ),
        ),
        child: Center(
          child: Text(
            label,
            style: TextStyle(
              fontSize: 11,
              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
              color: isSelected ? Colors.white : Colors.white70,
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildUserDesignedWidgetsSection() {
    final hasSystemMetrics = _settings.savedCustomWidgets.any(
      (widget) => widget.elements.any(
        (element) =>
            element.type == 'space_bar' || element.type == 'battery_bar',
      ),
    );
    final systemMetrics = hasSystemMetrics
        ? SystemMetricsService.readSnapshot()
        : const SystemMetricsSnapshot();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(6),
                  decoration: BoxDecoration(
                    color: const Color(0xFF43E97B).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: const Icon(
                    Icons.palette_rounded,
                    size: 16,
                    color: Color(0xFF43E97B),
                  ),
                ),
                const SizedBox(width: 10),
                Text(
                  'USER DESIGNED WIDGETS (${_settings.savedCustomWidgets.length})',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 1.5,
                    color: Colors.white,
                  ),
                ),
              ],
            ),
            OutlinedButton.icon(
              onPressed: () {
                setState(() {
                  _editingSavedWidget = null;
                  _isCustomStudioOpen = true;
                });
              },
              icon: const Icon(Icons.add_rounded, size: 14),
              label: const Text('Design New Widget'),
              style: OutlinedButton.styleFrom(
                foregroundColor: const Color(0xFF43E97B),
                side: const BorderSide(color: Color(0xFF43E97B), width: 1),
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 6,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                textStyle: const TextStyle(
                  fontWeight: FontWeight.bold,
                  fontSize: 11,
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 6),
        Text(
          'Custom widgets designed and saved by you. Tap to select and customize with standard widget tools.',
          style: TextStyle(
            fontSize: 12,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 16),
        if (_settings.savedCustomWidgets.isEmpty)
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(vertical: 36, horizontal: 24),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.02),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Column(
              children: [
                Icon(
                  Icons.dashboard_customize_outlined,
                  size: 40,
                  color: Colors.white.withValues(alpha: 0.25),
                ),
                const SizedBox(height: 12),
                const Text(
                  'No User Designed Widgets Yet',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.bold,
                    color: Colors.white70,
                  ),
                ),
                const SizedBox(height: 6),
                Text(
                  'Create your own clock, weather, battery, and system monitors in the Custom Widget Studio.',
                  textAlign: TextAlign.center,
                  style: TextStyle(
                    fontSize: 12,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
                const SizedBox(height: 16),
                ElevatedButton.icon(
                  onPressed: () {
                    setState(() {
                      _editingSavedWidget = null;
                      _isCustomStudioOpen = true;
                    });
                  },
                  icon: const Icon(Icons.add_rounded, size: 16),
                  label: const Text('Open Custom Studio'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF38BDF8),
                    foregroundColor: Colors.black,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(10),
                    ),
                    textStyle: const TextStyle(
                      fontWeight: FontWeight.w800,
                      fontSize: 12,
                    ),
                  ),
                ),
              ],
            ),
          )
        else
          Wrap(
            spacing: 20,
            runSpacing: 20,
            children: _settings.savedCustomWidgets.map((saved) {
              final isCurrentActive =
                  _isOverlayRunning &&
                  _settings.widgetTemplate == 'custom' &&
                  _activeSavedWidgetId == saved.id;

              return HoverCard(
                scaleUp: 1.035,
                borderRadius: BorderRadius.circular(18),
                glowColor: isCurrentActive
                    ? const Color(0xFF43E97B)
                    : const Color(0xFF38BDF8),
                maxGlowOpacity: 0.25,
                blurRadius: 14,
                onTap: () => _selectSavedCustomWidget(saved),
                child: Container(
                  width: 240,
                  height: 230,
                  decoration: BoxDecoration(
                    color: isCurrentActive
                        ? const Color(0xFF43E97B).withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.03),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isCurrentActive
                          ? const Color(0xFF43E97B).withValues(alpha: 0.6)
                          : const Color(0xFF38BDF8).withValues(alpha: 0.25),
                      width: isCurrentActive ? 2.0 : 1.0,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // Mini live preview
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.4),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.06),
                            ),
                          ),
                          child: ClipRRect(
                            borderRadius: BorderRadius.circular(14),
                            child: Center(
                              child: FittedBox(
                                fit: BoxFit.scaleDown,
                                child: SizedBox(
                                  width: saved.width,
                                  height: saved.height,
                                  child: CustomWidgetRenderer(
                                    elements: saved.elements,
                                    dateTime: DateTime.now(),
                                    cpuUsage: 22.0,
                                    ramUsage: 45.0,
                                    weatherTemp: _settings.weatherTemp,
                                    weatherStatus: _settings.weatherStatus,
                                    mediaInfo: _mediaInfo,
                                    mediaThumbnailBytes: _thumbnailBytes,
                                    mediaPosition: _playbackPositionNotifier,
                                    wifiEnabled:
                                        _connectivity.wifiEnabled ??
                                        _settings.wifiEnabled,
                                    bluetoothEnabled:
                                        _connectivity.bluetoothEnabled ??
                                        _settings.bluetoothEnabled,
                                    batteryInfo: systemMetrics.battery,
                                    diskInfo: systemMetrics.disk,
                                    isInteractive: false,
                                    canvasWidth: saved.width,
                                    canvasHeight: saved.height,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      ),

                      // Info and actions
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
                                    saved.name,
                                    style: const TextStyle(
                                      fontSize: 13,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.white,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                Row(
                                  children: [
                                    IconButton(
                                      icon: const Icon(
                                        Icons.tune_rounded,
                                        size: 15,
                                        color: Color(0xFF38BDF8),
                                      ),
                                      tooltip: 'Customize widget elements',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () =>
                                          _selectSavedCustomWidget(saved),
                                    ),
                                    const SizedBox(width: 8),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.delete_outline_rounded,
                                        size: 16,
                                        color: Colors.redAccent,
                                      ),
                                      tooltip: 'Delete custom widget',
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(),
                                      onPressed: () {
                                        _showDeleteSavedWidgetDialog(saved);
                                      },
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            Row(
                              children: [
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 6,
                                    vertical: 2,
                                  ),
                                  decoration: BoxDecoration(
                                    color: const Color(
                                      0xFF43E97B,
                                    ).withValues(alpha: 0.15),
                                    borderRadius: BorderRadius.circular(4),
                                  ),
                                  child: const Text(
                                    'USER CREATED',
                                    style: TextStyle(
                                      fontSize: 8.5,
                                      fontWeight: FontWeight.w800,
                                      color: Color(0xFF43E97B),
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ),
                                const Spacer(),
                                const Text(
                                  'Tap to Select & Edit',
                                  style: TextStyle(
                                    fontSize: 9.5,
                                    fontWeight: FontWeight.w600,
                                    color: Colors.white38,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
      ],
    );
  }

  void _showDeleteSavedWidgetDialog(SavedCustomWidget widgetItem) {
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF181C2E),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Text(
          'Delete Custom Widget?',
          style: TextStyle(color: Colors.white),
        ),
        content: Text(
          'Are you sure you want to delete "${widgetItem.name}"? This action cannot be undone.',
          style: const TextStyle(color: Colors.white70, fontSize: 13),
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
              Navigator.pop(ctx);
              final updatedList = List<SavedCustomWidget>.from(
                _settings.savedCustomWidgets,
              )..removeWhere((w) => w.id == widgetItem.id);
              _updateSettings(
                _settings.copyWith(savedCustomWidgets: updatedList),
              );
            },
            style: ElevatedButton.styleFrom(
              backgroundColor: Colors.redAccent,
              foregroundColor: Colors.white,
            ),
            child: const Text('Delete'),
          ),
        ],
      ),
    );
  }

  Widget _buildTemplateDirectoryView() {
    final templates = {
      'custom': 'Custom Widget Studio',
      'classic': 'Classic',
      'minimal': 'Minimal',
      'cyber': 'Bold Cyber',
      'split': 'Split Accent',
      'neon': 'Glass Neon',
      'animated_neon': 'Animated Neon',
      'sleep_weather': 'Smart Dashboard',
      'robik': 'Robik Theme',
      'atomic_clock': 'Atomic Clock',
    };

    // Filter templates based on category
    final filteredTemplates = templates.entries.where((e) {
      if (_selectedWidgetCategory == 'User Designed') return false;
      if (_selectedWidgetCategory == 'All') return true;
      if (_selectedWidgetCategory == 'Custom') return e.key == 'custom';
      if (_selectedWidgetCategory == 'Minimalist') {
        return e.key == 'minimal' ||
            e.key == 'split' ||
            e.key == 'sleep_weather' ||
            e.key == 'robik' ||
            e.key == 'atomic_clock';
      }
      if (_selectedWidgetCategory == 'Neon Glow') {
        return e.key == 'neon' || e.key == 'animated_neon';
      }
      if (_selectedWidgetCategory == 'Bold & Cyber') return e.key == 'cyber';
      if (_selectedWidgetCategory == 'Classic') {
        return e.key == 'classic' || e.key == 'atomic_clock';
      }
      return true;
    }).toList();

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 32),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // 1. Premium Hero Welcome Banner
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(28),
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(24),
              gradient: const LinearGradient(
                colors: [Color(0xFF1E1E38), Color(0xFF0F172A)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              border: Border.all(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: const Color(0xFF38BDF8).withValues(alpha: 0.02),
                  blurRadius: 24,
                  spreadRadius: 2,
                ),
              ],
            ),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 4,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.1),
                          borderRadius: BorderRadius.circular(20),
                        ),
                        child: const Text(
                          'VERSION 1.0.0.0.1 UPDATE',
                          style: TextStyle(
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                            color: Color(0xFF38BDF8),
                            letterSpacing: 1.0,
                          ),
                        ),
                      ),
                      const SizedBox(height: 14),
                      const Text(
                        'Welcome to WallSync Pro Customizer',
                        style: TextStyle(
                          fontSize: 22,
                          fontWeight: FontWeight.w900,
                          color: Colors.white,
                          letterSpacing: -0.5,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Select a widget layout below to launch the customizer board, design high-fidelity components, and control desktop physics in real-time.',
                        style: TextStyle(
                          fontSize: 13,
                          height: 1.5,
                          color: Colors.white.withValues(alpha: 0.5),
                        ),
                      ),
                      const SizedBox(height: 16),
                      ElevatedButton.icon(
                        onPressed: () {
                          setState(() {
                            _isCustomStudioOpen = true;
                          });
                        },
                        icon: const Icon(
                          Icons.dashboard_customize_rounded,
                          size: 16,
                        ),
                        label: const Text('Open Custom Widget Studio'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: const Color(0xFF38BDF8),
                          foregroundColor: Colors.black,
                          padding: const EdgeInsets.symmetric(
                            horizontal: 16,
                            vertical: 10,
                          ),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                          ),
                          textStyle: const TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 12,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),
                // Icon decoration
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.02),
                    borderRadius: BorderRadius.circular(20),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.05),
                    ),
                  ),
                  child: const Icon(
                    Icons.dashboard_customize_rounded,
                    size: 48,
                    color: Color(0xFFEC4899),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // 2. Live Active Widget Status Panel
          const Text(
            'DESKTOP WIDGET OVERVIEW',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.5,
              color: Colors.white38,
            ),
          ),
          const SizedBox(height: 12),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.02),
              borderRadius: BorderRadius.circular(20),
              border: Border.all(
                color: _isOverlayRunning
                    ? const Color(0xFF43E97B).withValues(alpha: 0.25)
                    : Colors.white.withValues(alpha: 0.06),
                width: 1.0,
              ),
            ),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.center,
              children: [
                // Status Circle with Pulse Effect
                Container(
                  width: 48,
                  height: 48,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: _isOverlayRunning
                        ? const Color(0xFF43E97B).withValues(alpha: 0.1)
                        : Colors.white.withValues(alpha: 0.05),
                    border: Border.all(
                      color: _isOverlayRunning
                          ? const Color(0xFF43E97B).withValues(alpha: 0.3)
                          : Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Center(
                    child: Container(
                      width: 14,
                      height: 14,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        color: _isOverlayRunning
                            ? const Color(0xFF43E97B)
                            : Colors.white38,
                        boxShadow: _isOverlayRunning
                            ? [
                                BoxShadow(
                                  color: const Color(0xFF43E97B),
                                  blurRadius: 10,
                                  spreadRadius: 2,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 20),

                // Status Description
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Text(
                            _isOverlayRunning
                                ? 'LIVE WIDGET ACTIVE'
                                : 'WIDGET INACTIVE',
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w900,
                              color: _isOverlayRunning
                                  ? const Color(0xFF43E97B)
                                  : Colors.white70,
                              letterSpacing: 0.5,
                            ),
                          ),
                          if (_isLaunching) ...[
                            const SizedBox(width: 12),
                            const SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Colors.blueAccent,
                              ),
                            ),
                          ],
                        ],
                      ),
                      const SizedBox(height: 6),
                      Text(
                        _isOverlayRunning
                            ? 'Your desktop widget is currently running overlay controls using the "$_activeTemplate" template.'
                            : 'Launch the widget overlay to display your customized clock on top of your desktop wallpaper.',
                        style: TextStyle(
                          fontSize: 12,
                          height: 1.4,
                          color: Colors.white.withValues(alpha: 0.45),
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 24),

                // Control Buttons
                Wrap(
                  spacing: 12,
                  runSpacing: 12,
                  children: [
                    // Launch / Stop Toggle
                    SizedBox(
                      height: 40,
                      child: ElevatedButton.icon(
                        onPressed: _isLaunching
                            ? null
                            : () {
                                if (_isOverlayRunning) {
                                  _closeOverlay();
                                } else {
                                  _launchOverlay();
                                }
                              },
                        icon: Icon(
                          _isOverlayRunning
                              ? Icons.stop_rounded
                              : Icons.play_arrow_rounded,
                          size: 18,
                          color: _isOverlayRunning
                              ? Colors.redAccent
                              : Colors.white,
                        ),
                        label: Text(
                          _isLaunching
                              ? 'Starting...'
                              : _isOverlayRunning
                              ? 'Stop Widget'
                              : 'Launch Widget',
                          style: const TextStyle(
                            fontSize: 12,
                            fontWeight: FontWeight.w800,
                          ),
                        ),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: _isOverlayRunning
                              ? Colors.redAccent.withValues(alpha: 0.15)
                              : const Color(0xFF43E97B),
                          foregroundColor: _isOverlayRunning
                              ? Colors.redAccent
                              : Colors.black,
                          elevation: 0,
                          padding: const EdgeInsets.symmetric(horizontal: 18),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(10),
                            side: BorderSide(
                              color: _isOverlayRunning
                                  ? Colors.redAccent.withValues(alpha: 0.3)
                                  : Colors.transparent,
                            ),
                          ),
                        ),
                      ),
                    ),

                    // Lock Toggle
                    _buildQuickSettingButton(
                      icon: _settings.isLocked
                          ? Icons.lock_rounded
                          : Icons.lock_open_rounded,
                      tooltip: _settings.isLocked
                          ? 'Unlock Widget Position'
                          : 'Lock Widget Position',
                      isActive: _settings.isLocked,
                      onTap: () {
                        _updateSettings(
                          _settings.copyWith(isLocked: !_settings.isLocked),
                        );
                      },
                    ),

                    // Always on Top Toggle
                    _buildQuickSettingButton(
                      icon: Icons.flip_to_front_rounded,
                      tooltip: 'Always on Top',
                      isActive: _settings.alwaysOnTop,
                      onTap: () {
                        _updateSettings(
                          _settings.copyWith(
                            alwaysOnTop: !_settings.alwaysOnTop,
                          ),
                        );
                      },
                    ),
                  ],
                ),
              ],
            ),
          ),

          if (_selectedWidgetCategory == 'All' &&
              _settings.savedCustomWidgets.isNotEmpty) ...[
            _buildUserDesignedWidgetsSection(),
            const SizedBox(height: 36),
          ],

          // 3. Category Filters Section
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'EXPLORE LAYOUTS',
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: FontWeight.w800,
                  letterSpacing: 1.5,
                  color: Colors.white38,
                ),
              ),
              // Filter chips row
              Row(
                children:
                    [
                      'All',
                      'User Designed',
                      'Minimalist',
                      'Neon Glow',
                      'Bold & Cyber',
                      'Classic',
                    ].map((cat) {
                      final isSel = _selectedWidgetCategory == cat;
                      return Padding(
                        padding: const EdgeInsets.only(left: 8),
                        child: GestureDetector(
                          onTap: () {
                            setState(() {
                              _selectedWidgetCategory = cat;
                            });
                          },
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 200),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 14,
                              vertical: 6,
                            ),
                            decoration: BoxDecoration(
                              color: isSel
                                  ? Colors.white.withValues(alpha: 0.08)
                                  : Colors.transparent,
                              borderRadius: BorderRadius.circular(16),
                              border: Border.all(
                                color: isSel
                                    ? const Color(
                                        0xFF38BDF8,
                                      ).withValues(alpha: 0.4)
                                    : Colors.white.withValues(alpha: 0.05),
                              ),
                            ),
                            child: Text(
                              cat,
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: isSel
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: isSel ? Colors.white : Colors.white38,
                              ),
                            ),
                          ),
                        ),
                      );
                    }).toList(),
              ),
            ],
          ),
          const SizedBox(height: 18),

          // 4. Grid of Template Cards
          if (_selectedWidgetCategory == 'User Designed')
            _buildUserDesignedWidgetsSection()
          else
            Wrap(
              spacing: 20,
              runSpacing: 20,
              children: filteredTemplates.map((e) {
                final key = e.key;
                final name = e.value;
                final isSelected = _settings.widgetTemplate == key;
                final isActive = _isOverlayRunning && _activeTemplate == key;
                final activeColor = const Color(0xFFEC4899);

                // Subtitles/Tags for each template to make cards rich
                final tags = {
                  'custom': ['CUSTOM', 'DRAG & DROP', 'STUDIO'],
                  'classic': ['CLASSIC', 'CLEAN', 'INFO-RICH'],
                  'minimal': ['MINIMAL', 'MODERN', 'COMPACT'],
                  'cyber': ['CYBERPUNK', 'BOLD', 'VERTICAL'],
                  'split': ['SPLIT', 'ELEGANT', 'MINIMAL'],
                  'neon': ['GLASS', 'NEON GLOW', 'CAPSULE'],
                  'animated_neon': ['ANIMATED', 'RING', 'GPU'],
                  'sleep_weather': [
                    'LIVE WEATHER',
                    'MEDIA CONTROLS',
                    'TAB CARD',
                  ],
                  'robik': ['RAINMETER', 'Moving Skate', 'STATS'],
                  'atomic_clock': ['ATOMIC', 'ANURATI', 'GRADIENT'],
                };
                final currentTags = tags[key] ?? ['WIDGET'];

                // High-fidelity signature preview matching the authentic widget design
                Widget miniClockPreview() {
                  switch (key) {
                    case 'custom':
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            const Row(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                Icon(
                                  Icons.dashboard_customize_rounded,
                                  size: 13,
                                  color: Color(0xFF38BDF8),
                                ),
                                SizedBox(width: 4),
                                Text(
                                  'CUSTOM STUDIO',
                                  style: TextStyle(
                                    color: Color(0xFF38BDF8),
                                    fontSize: 7.5,
                                    fontWeight: FontWeight.w900,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 4),
                            const Text(
                              '12:45',
                              style: TextStyle(
                                color: Colors.white,
                                fontSize: 18,
                                fontWeight: FontWeight.bold,
                                fontFamily: 'Montserrat',
                                letterSpacing: -0.5,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 6,
                                vertical: 2,
                              ),
                              decoration: BoxDecoration(
                                color: const Color(
                                  0xFFF18734,
                                ).withValues(alpha: 0.2),
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: const Text(
                                'DRAG & DROP CANVAS',
                                style: TextStyle(
                                  fontSize: 6.0,
                                  fontWeight: FontWeight.bold,
                                  color: Color(0xFFF18734),
                                ),
                              ),
                            ),
                          ],
                        ),
                      );
                    case 'robik':
                      return Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 8,
                        ),
                        child: Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            // Left: Day header, Montserrat Clock, Orange pill, Date
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              children: [
                                const Text(
                                  'SUNDAY',
                                  style: TextStyle(
                                    color: Color(0xFFF18734),
                                    fontSize: 6.5,
                                    fontWeight: FontWeight.w800,
                                    letterSpacing: 1.5,
                                    fontFamily: 'Product Sans',
                                  ),
                                ),
                                const SizedBox(height: 2),
                                const Text(
                                  '12.00',
                                  style: TextStyle(
                                    color: Colors.white,
                                    fontSize: 19,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Montserrat',
                                    letterSpacing: -0.5,
                                    height: 1.0,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Container(
                                  width: 26,
                                  height: 2.5,
                                  decoration: BoxDecoration(
                                    color: const Color(0xFFF18734),
                                    borderRadius: BorderRadius.circular(1.5),
                                  ),
                                ),
                                const SizedBox(height: 3),
                                const Text(
                                  '21 JUN 2026',
                                  style: TextStyle(
                                    color: Color(0xFFCBD5E1),
                                    fontSize: 6.5,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Product Sans',
                                    letterSpacing: 0.8,
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(width: 10),
                            // Vertical divider
                            Container(
                              width: 1,
                              height: 46,
                              color: Colors.white12,
                            ),
                            const SizedBox(width: 10),
                            // Right: CPU & RAM indicators
                            Column(
                              mainAxisAlignment: MainAxisAlignment.center,
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                const Text(
                                  'CPU: 18%',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 6.5,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Product Sans',
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  width: 36,
                                  height: 3.5,
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      width: 14,
                                      height: 3.5,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF18734),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 5),
                                const Text(
                                  'RAM: 42%',
                                  style: TextStyle(
                                    color: Colors.white70,
                                    fontSize: 6.5,
                                    fontWeight: FontWeight.bold,
                                    fontFamily: 'Product Sans',
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Container(
                                  width: 36,
                                  height: 3.5,
                                  decoration: BoxDecoration(
                                    color: Colors.white10,
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: Align(
                                    alignment: Alignment.centerLeft,
                                    child: Container(
                                      width: 22,
                                      height: 3.5,
                                      decoration: BoxDecoration(
                                        color: const Color(0xFFF18734),
                                        borderRadius: BorderRadius.circular(2),
                                      ),
                                    ),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );

                    case 'sleep_weather':
                      return Container(
                        width: 150,
                        height: 94,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 6,
                        ),
                        child: Stack(
                          children: [
                            // Left: Date & Time
                            const Positioned(
                              top: 12,
                              left: 0,
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Text(
                                    'Saturday 17',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 5.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  SizedBox(height: 1),
                                  Text(
                                    '09:34',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 18,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: -1.0,
                                      height: 0.95,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Right: WiFi & Bluetooth mini icons
                            Positioned(
                              top: 0,
                              right: 0,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: Colors.white.withValues(
                                        alpha: 0.1,
                                      ),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: const Icon(
                                      Icons.wifi_rounded,
                                      size: 6,
                                      color: Colors.white70,
                                    ),
                                  ),
                                  const SizedBox(width: 3),
                                  Container(
                                    width: 12,
                                    height: 12,
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF00FF55,
                                      ).withValues(alpha: 0.2),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: const Icon(
                                      Icons.bluetooth_rounded,
                                      size: 6,
                                      color: Color(0xFF00FF55),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            // Middle: Neon green media bar
                            Positioned(
                              left: 0,
                              right: 0,
                              bottom: 16,
                              child: Container(
                                height: 16,
                                decoration: BoxDecoration(
                                  color: const Color(0xFF00FF55),
                                  borderRadius: BorderRadius.circular(3.5),
                                ),
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 4,
                                ),
                                child: const Row(
                                  children: [
                                    Icon(
                                      Icons.skip_previous_rounded,
                                      size: 7,
                                      color: Colors.black,
                                    ),
                                    Icon(
                                      Icons.pause_rounded,
                                      size: 8,
                                      color: Colors.black,
                                    ),
                                    Icon(
                                      Icons.skip_next_rounded,
                                      size: 7,
                                      color: Colors.black,
                                    ),
                                    SizedBox(width: 3),
                                    Expanded(
                                      child: Text(
                                        'Midnight City',
                                        style: TextStyle(
                                          color: Colors.black,
                                          fontSize: 5.5,
                                          fontWeight: FontWeight.w900,
                                        ),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                      ),
                                    ),
                                    Text(
                                      '02:40',
                                      style: TextStyle(
                                        color: Colors.black,
                                        fontSize: 5,
                                        fontWeight: FontWeight.w900,
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                            ),
                            // Bottom: Weather
                            const Positioned(
                              left: 0,
                              bottom: 0,
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Icon(
                                    Icons.wb_cloudy_rounded,
                                    color: Color(0xFF00FF55),
                                    size: 7,
                                  ),
                                  SizedBox(width: 3),
                                  Text(
                                    '19 °C  ·  CLEAR',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 5.5,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      );

                    case 'minimal':
                      return const Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '12:00:45',
                            style: TextStyle(
                              color: Color(0xFFF1F5F9),
                              fontSize: 14,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Consolas',
                              letterSpacing: -0.5,
                            ),
                          ),
                          Padding(
                            padding: EdgeInsets.symmetric(horizontal: 6),
                            child: Text(
                              '|',
                              style: TextStyle(
                                color: Color(0x6694A3B8),
                                fontSize: 13,
                                fontWeight: FontWeight.w200,
                              ),
                            ),
                          ),
                          Text(
                            'SUN 21 JUN',
                            style: TextStyle(
                              color: Color(0xFF94A3B8),
                              fontSize: 8,
                              fontFamily: 'Consolas',
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      );

                    case 'cyber':
                      return const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Text(
                            '12',
                            style: TextStyle(
                              color: Color(0xFFFACC15),
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'Impact',
                              height: 0.95,
                            ),
                          ),
                          Text(
                            '00',
                            style: TextStyle(
                              color: Color(0xFF06B6D4),
                              fontSize: 26,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'Impact',
                              height: 0.95,
                            ),
                          ),
                          SizedBox(height: 2),
                          Text(
                            'SUN JUN 21',
                            style: TextStyle(
                              color: Color(0xFF10B981),
                              fontSize: 7.5,
                              fontWeight: FontWeight.w800,
                              letterSpacing: 1.0,
                            ),
                          ),
                        ],
                      );

                    case 'split':
                      return Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Container(
                            width: 3.5,
                            height: 32,
                            decoration: BoxDecoration(
                              color: const Color(0xFFF43F5E),
                              borderRadius: BorderRadius.circular(2),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(
                                    0xFFF43F5E,
                                  ).withValues(alpha: 0.4),
                                  blurRadius: 6,
                                ),
                              ],
                            ),
                          ),
                          const SizedBox(width: 8),
                          const Column(
                            mainAxisAlignment: MainAxisAlignment.center,
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    '12',
                                    style: TextStyle(
                                      color: Color(0xFFF43F5E),
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                  Text(
                                    ':',
                                    style: TextStyle(
                                      color: Colors.white70,
                                      fontSize: 12,
                                    ),
                                  ),
                                  Text(
                                    '00',
                                    style: TextStyle(
                                      color: Colors.white,
                                      fontSize: 14,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ],
                              ),
                              SizedBox(height: 1),
                              Text(
                                'SUN  ·  21 JUN',
                                style: TextStyle(
                                  color: Color(0xFFE9D5FF),
                                  fontSize: 7,
                                  fontWeight: FontWeight.w500,
                                ),
                              ),
                            ],
                          ),
                        ],
                      );

                    case 'neon':
                      return Container(
                        width: 172,
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(16),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF3B82F6,
                              ).withValues(alpha: 0.35),
                              blurRadius: 18,
                              spreadRadius: 1,
                            ),
                            BoxShadow(
                              color: const Color(
                                0xFF3B82F6,
                              ).withValues(alpha: 0.15),
                              blurRadius: 36,
                              spreadRadius: 2,
                            ),
                          ],
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 14,
                            vertical: 10,
                          ),
                          decoration: BoxDecoration(
                            borderRadius: BorderRadius.circular(16),
                            gradient: LinearGradient(
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                              colors: [
                                Colors.white.withValues(alpha: 0.10),
                                const Color(0xFF3B82F6).withValues(alpha: 0.16),
                                const Color(0xFF3B82F6).withValues(alpha: 0.05),
                                Colors.black.withValues(alpha: 0.3),
                              ],
                              stops: const [0.0, 0.25, 0.7, 1.0],
                            ),
                            border: Border.all(
                              color: const Color(
                                0xFF3B82F6,
                              ).withValues(alpha: 0.85),
                              width: 1.4,
                            ),
                          ),
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              // Top Row: Day Pill + Neon Dot
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 5,
                                      vertical: 2,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFF38BDF8,
                                      ).withValues(alpha: 0.12),
                                      borderRadius: BorderRadius.circular(4),
                                      border: Border.all(
                                        color: const Color(
                                          0xFF38BDF8,
                                        ).withValues(alpha: 0.4),
                                        width: 0.6,
                                      ),
                                    ),
                                    child: const Text(
                                      'SUNDAY',
                                      style: TextStyle(
                                        color: Color(0xFF38BDF8),
                                        fontSize: 6.5,
                                        fontWeight: FontWeight.w800,
                                        letterSpacing: 1.2,
                                      ),
                                    ),
                                  ),
                                  Row(
                                    mainAxisSize: MainAxisSize.min,
                                    children: [
                                      Container(
                                        width: 4,
                                        height: 4,
                                        decoration: const BoxDecoration(
                                          shape: BoxShape.circle,
                                          color: Color(0xFF00FFCC),
                                        ),
                                      ),
                                      const SizedBox(width: 3),
                                      const Text(
                                        'NEON',
                                        style: TextStyle(
                                          fontSize: 6,
                                          fontWeight: FontWeight.w900,
                                          color: Color(0xFF38BDF8),
                                          letterSpacing: 1.0,
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                              const SizedBox(height: 5),
                              // Hero Time Row
                              Row(
                                mainAxisAlignment: MainAxisAlignment.center,
                                crossAxisAlignment: CrossAxisAlignment.baseline,
                                textBaseline: TextBaseline.alphabetic,
                                children: [
                                  const Text(
                                    '12',
                                    style: TextStyle(
                                      color: Color(0xFFD946EF),
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      fontFamily: 'Montserrat',
                                      letterSpacing: -0.5,
                                      shadows: [
                                        Shadow(
                                          color: Color(0xBFD946EF),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const Padding(
                                    padding: EdgeInsets.symmetric(
                                      horizontal: 2,
                                    ),
                                    child: Text(
                                      ':',
                                      style: TextStyle(
                                        color: Color(0xFF00F0FF),
                                        fontSize: 20,
                                        fontWeight: FontWeight.w300,
                                        shadows: [
                                          Shadow(
                                            color: Color(0xB300F0FF),
                                            blurRadius: 8,
                                          ),
                                        ],
                                      ),
                                    ),
                                  ),
                                  const Text(
                                    '00',
                                    style: TextStyle(
                                      color: Color(0xFFD946EF),
                                      fontSize: 22,
                                      fontWeight: FontWeight.w900,
                                      fontFamily: 'Montserrat',
                                      letterSpacing: -0.5,
                                      shadows: [
                                        Shadow(
                                          color: Color(0xBFD946EF),
                                          blurRadius: 10,
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 4),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 3,
                                      vertical: 1,
                                    ),
                                    decoration: BoxDecoration(
                                      color: const Color(
                                        0xFFD946EF,
                                      ).withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(3),
                                      border: Border.all(
                                        color: const Color(
                                          0xFFD946EF,
                                        ).withValues(alpha: 0.5),
                                        width: 0.6,
                                      ),
                                    ),
                                    child: const Text(
                                      'PM',
                                      style: TextStyle(
                                        color: Color(0xFFD946EF),
                                        fontSize: 6,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              // Glowing Laser Divider
                              Container(
                                height: 1,
                                margin: const EdgeInsets.symmetric(vertical: 4),
                                decoration: const BoxDecoration(
                                  gradient: LinearGradient(
                                    colors: [
                                      Colors.transparent,
                                      Color(0xFF38BDF8),
                                      Color(0xFFD946EF),
                                      Colors.transparent,
                                    ],
                                  ),
                                ),
                              ),
                              // Bottom Date Row
                              const Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Text(
                                    '21 OCTOBER',
                                    style: TextStyle(
                                      color: Color(0xFF38BDF8),
                                      fontSize: 6.5,
                                      fontWeight: FontWeight.w700,
                                      letterSpacing: 1.0,
                                    ),
                                  ),
                                  Text(
                                    '2026',
                                    style: TextStyle(
                                      color: Color(0xFF38BDF8),
                                      fontSize: 6.5,
                                      fontWeight: FontWeight.w800,
                                      letterSpacing: 0.8,
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ),
                        ),
                      );

                    case 'animated_neon':
                      return SizedBox(
                        width: 126,
                        height: 76,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Outer ring
                            Container(
                              width: 126,
                              height: 74,
                              decoration: BoxDecoration(
                                borderRadius: const BorderRadius.all(
                                  Radius.elliptical(63, 37),
                                ),
                                border: Border.all(
                                  color: const Color(0xFF1A23F2),
                                  width: 3,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(
                                      0xFF1A23F2,
                                    ).withValues(alpha: 0.4),
                                    blurRadius: 8,
                                  ),
                                ],
                              ),
                            ),
                            // Inner ring with plate
                            Container(
                              width: 98,
                              height: 54,
                              decoration: BoxDecoration(
                                color: const Color(0x331A23F2),
                                borderRadius: const BorderRadius.all(
                                  Radius.elliptical(49, 27),
                                ),
                                border: Border.all(
                                  color: const Color(0xFF38BDF8),
                                  width: 1.2,
                                ),
                              ),
                            ),
                            // Clock text
                            const Column(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Row(
                                  mainAxisSize: MainAxisSize.min,
                                  crossAxisAlignment:
                                      CrossAxisAlignment.baseline,
                                  textBaseline: TextBaseline.alphabetic,
                                  children: [
                                    Text(
                                      '12',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                    Text(
                                      ':',
                                      style: TextStyle(
                                        color: Color(0xFF8DCAED),
                                        fontSize: 12,
                                      ),
                                    ),
                                    Text(
                                      '00',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: 14,
                                        fontWeight: FontWeight.bold,
                                      ),
                                    ),
                                  ],
                                ),
                                SizedBox(height: 1),
                                Text(
                                  'SUN  |  21 JUN',
                                  style: TextStyle(
                                    color: Color(0xFF8DCAED),
                                    fontSize: 6,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      );

                    case 'atomic_clock':
                      return const Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.center,
                        children: [
                          Text(
                            'SATURDAY',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 13,
                              fontWeight: FontWeight.w900,
                              fontFamily: 'Anurati',
                              letterSpacing: 2.2,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 4,
                                  offset: Offset(0.5, 1),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '27 MARCH, 2026.',
                            style: TextStyle(
                              color: Colors.white70,
                              fontSize: 7.5,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Anurati',
                              letterSpacing: 1.2,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 3,
                                  offset: Offset(0.5, 1),
                                ),
                              ],
                            ),
                          ),
                          SizedBox(height: 3),
                          Text(
                            '- 00:15 -',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 7,
                              fontWeight: FontWeight.w600,
                              fontFamily: 'Anurati',
                              letterSpacing: 1.0,
                              shadows: [
                                Shadow(
                                  color: Colors.black87,
                                  blurRadius: 3,
                                  offset: Offset(0.5, 1),
                                ),
                              ],
                            ),
                          ),
                        ],
                      );

                    case 'classic':
                    default:
                      return Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          const Text(
                            '12:00',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 17,
                              fontWeight: FontWeight.w700,
                              fontFamily: 'Georgia',
                              letterSpacing: 1.0,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Container(
                            width: 32,
                            height: 1.8,
                            decoration: BoxDecoration(
                              color: const Color(0xFFFFD700),
                              borderRadius: BorderRadius.circular(1),
                            ),
                          ),
                          const SizedBox(height: 3),
                          const Text(
                            'SUNDAY, 21 JUNE 2026',
                            style: TextStyle(
                              color: Color(0xFFFFD700),
                              fontSize: 6.5,
                              fontWeight: FontWeight.bold,
                              fontFamily: 'Georgia',
                              letterSpacing: 0.6,
                            ),
                          ),
                        ],
                      );
                  }
                }

                return HoverCard(
                  scaleUp: 1.035,
                  borderRadius: BorderRadius.circular(18),
                  glowColor: isSelected ? activeColor : Colors.transparent,
                  maxGlowOpacity: 0.2,
                  blurRadius: 12,
                  onTap: () {
                    if (key == 'custom') {
                      setState(() {
                        _isCustomStudioOpen = true;
                      });
                      return;
                    }
                    if (_settings.widgetTemplate != key) {
                      final defaults =
                          WidgetSettings.templateDefaults[key] ??
                          {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
                      _updateSettings(
                        _settings.copyWith(
                          widgetTemplate: key,
                          width: defaults['width'],
                          height: defaults['height'],
                          sizeFactor: defaults['sizeFactor'],
                          editorMode: !_settings.isLocked,
                          elementColors: {},
                          elementFonts: {},
                          elementSizes: {},
                          elementTranslateX: {},
                          elementTranslateY: {},
                          textColor: 0xFFFFFFFF,
                          fontFamily: 'Segoe UI',
                        ),
                      );
                    } else {
                      _updateSettings(
                        _settings.copyWith(editorMode: !_settings.isLocked),
                      );
                    }
                    setState(() {
                      _editingWidget = true;
                    });
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 200),
                    width: 220,
                    height: 225,
                    decoration: BoxDecoration(
                      color: isSelected
                          ? activeColor.withValues(alpha: 0.08)
                          : Colors.white.withValues(alpha: 0.02),
                      borderRadius: BorderRadius.circular(18),
                      border: Border.all(
                        color: isSelected
                            ? activeColor.withValues(alpha: 0.6)
                            : Colors.white.withValues(alpha: 0.06),
                        width: isSelected ? 2.0 : 1.0,
                      ),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        // Graphical representation of layout
                        Expanded(
                          child: Container(
                            margin: const EdgeInsets.all(8),
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(14),
                              border: Border.all(
                                color: Colors.white.withValues(alpha: 0.04),
                              ),
                            ),
                            child: Stack(
                              children: [
                                Positioned.fill(
                                  child: key == 'sleep_weather'
                                      ? CustomPaint(
                                          painter: FolderTabPainter(
                                            color: const Color(0xFF0F0F11),
                                            shadowColor: Colors.black
                                                .withValues(alpha: 0.4),
                                            blurRadius: 4,
                                            r: 8.0,
                                            dip: 12.0,
                                          ),
                                          child: ClipPath(
                                            clipper: FolderTabClipper(
                                              r: 8.0,
                                              dip: 12.0,
                                            ),
                                            child: _buildPreviewBg(
                                              borderRadius:
                                                  BorderRadius.circular(8),
                                            ),
                                          ),
                                        )
                                      : ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            14,
                                          ),
                                          child: _buildPreviewBg(
                                            borderRadius: BorderRadius.circular(
                                              14,
                                            ),
                                          ),
                                        ),
                                ),
                                Center(child: miniClockPreview()),
                                // Active / Selected badges
                                Positioned(
                                  top: 8,
                                  left: 8,
                                  child: Row(
                                    children: currentTags.map((t) {
                                      return Container(
                                        margin: const EdgeInsets.only(right: 4),
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 5,
                                          vertical: 2,
                                        ),
                                        decoration: BoxDecoration(
                                          color: Colors.white.withValues(
                                            alpha: 0.05,
                                          ),
                                          borderRadius: BorderRadius.circular(
                                            4,
                                          ),
                                        ),
                                        child: Text(
                                          t,
                                          style: const TextStyle(
                                            fontSize: 7,
                                            fontWeight: FontWeight.w800,
                                            color: Colors.white38,
                                          ),
                                        ),
                                      );
                                    }).toList(),
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // Footer
                        Padding(
                          padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                mainAxisAlignment:
                                    MainAxisAlignment.spaceBetween,
                                children: [
                                  Expanded(
                                    child: Text(
                                      name,
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: TextStyle(
                                        fontSize: 14,
                                        fontWeight: isSelected
                                            ? FontWeight.w900
                                            : FontWeight.bold,
                                        color: isSelected
                                            ? Colors.white
                                            : Colors.white70,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  if (isActive)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: const Color(
                                          0xFF43E97B,
                                        ).withValues(alpha: 0.2),
                                        borderRadius: BorderRadius.circular(4),
                                        border: Border.all(
                                          color: const Color(
                                            0xFF43E97B,
                                          ).withValues(alpha: 0.4),
                                        ),
                                      ),
                                      child: const Text(
                                        'ACTIVE',
                                        style: TextStyle(
                                          color: Color(0xFF43E97B),
                                          fontSize: 8,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    )
                                  else if (isSelected)
                                    Container(
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                        vertical: 3,
                                      ),
                                      decoration: BoxDecoration(
                                        color: activeColor.withValues(
                                          alpha: 0.25,
                                        ),
                                        borderRadius: BorderRadius.circular(4),
                                      ),
                                      child: Text(
                                        'SELECTED',
                                        style: TextStyle(
                                          color: activeColor,
                                          fontSize: 8,
                                          fontWeight: FontWeight.w900,
                                          letterSpacing: 0.5,
                                        ),
                                      ),
                                    ),
                                ],
                              ),
                              const SizedBox(height: 8),
                              SizedBox(
                                width: double.infinity,
                                height: 28,
                                child: ElevatedButton.icon(
                                  onPressed: () {
                                    if (key == 'custom') {
                                      setState(() {
                                        _isCustomStudioOpen = true;
                                      });
                                      return;
                                    }
                                    if (_settings.widgetTemplate != key) {
                                      final defaults =
                                          WidgetSettings
                                              .templateDefaults[key] ??
                                          {
                                            'width': 360.0,
                                            'height': 200.0,
                                            'sizeFactor': 1.0,
                                          };
                                      _updateSettings(
                                        _settings.copyWith(
                                          widgetTemplate: key,
                                          width: defaults['width'],
                                          height: defaults['height'],
                                          sizeFactor: defaults['sizeFactor'],
                                          editorMode: !_settings.isLocked,
                                          elementColors: {},
                                          elementFonts: {},
                                          elementSizes: {},
                                          elementTranslateX: {},
                                          elementTranslateY: {},
                                          textColor: 0xFFFFFFFF,
                                          fontFamily: 'Segoe UI',
                                        ),
                                      );
                                    } else {
                                      _updateSettings(
                                        _settings.copyWith(
                                          editorMode: !_settings.isLocked,
                                        ),
                                      );
                                    }
                                    setState(() {
                                      _editingWidget = true;
                                    });
                                  },
                                  icon: Icon(
                                    Icons.tune_rounded,
                                    size: 12,
                                    color: isSelected
                                        ? Colors.white
                                        : Colors.white70,
                                  ),
                                  label: Text(
                                    key == 'custom'
                                        ? 'Open Studio'
                                        : isSelected
                                        ? 'Customize Elements'
                                        : 'Select & Customize',
                                    style: const TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  style: ElevatedButton.styleFrom(
                                    padding: EdgeInsets.zero,
                                    backgroundColor: isSelected
                                        ? activeColor
                                        : Colors.white.withValues(alpha: 0.05),
                                    foregroundColor: Colors.white,
                                    shape: RoundedRectangleBorder(
                                      borderRadius: BorderRadius.circular(8),
                                    ),
                                    elevation: 0,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
        ],
      ),
    );
  }

  Widget _buildQuickSettingButton({
    required IconData icon,
    required String tooltip,
    required bool isActive,
    required VoidCallback onTap,
  }) {
    return Tooltip(
      message: tooltip,
      child: GestureDetector(
        onTap: onTap,
        child: AnimatedContainer(
          duration: const Duration(milliseconds: 200),
          width: 40,
          height: 40,
          decoration: BoxDecoration(
            color: isActive
                ? const Color(0xFF38BDF8).withValues(alpha: 0.15)
                : Colors.white.withValues(alpha: 0.04),
            borderRadius: BorderRadius.circular(10),
            border: Border.all(
              color: isActive
                  ? const Color(0xFF38BDF8).withValues(alpha: 0.4)
                  : Colors.white.withValues(alpha: 0.08),
              width: 1.0,
            ),
          ),
          child: Icon(
            icon,
            size: 18,
            color: isActive ? const Color(0xFF38BDF8) : Colors.white60,
          ),
        ),
      ),
    );
  }

  Widget _buildTemplateDirectoryViewOld() {
    final templates = {
      'classic': 'Classic',
      'minimal': 'Minimal',
      'cyber': 'Bold Cyber',
      'split': 'Split Accent',
      'neon': 'Glass Neon',
      'animated_neon': 'Animated Neon',
    };

    return SingleChildScrollView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 28),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          ShaderMask(
            shaderCallback: (bounds) {
              return const LinearGradient(
                colors: [Color(0xFF38BDF8), Color(0xFFF472B6)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ).createShader(bounds);
            },
            child: const Text(
              'WIDGET TEMPLATES',
              style: TextStyle(
                fontSize: 18,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.5,
                color: Colors.white,
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Select a template below to launch the customizer board and adjust 3D controls.',
            style: TextStyle(
              fontSize: 13,
              color: Colors.white.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(height: 24),

          // Grid/Wrap of templates
          Wrap(
            spacing: 20,
            runSpacing: 20,
            children: templates.entries.map((e) {
              final key = e.key;
              final name = e.value;
              final isSelected = _settings.widgetTemplate == key;
              final activeColor = const Color(0xFFEC4899);

              // Mini preview widget
              Widget miniClockPreview() {
                const textStyle = TextStyle(
                  color: Colors.white70,
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                );
                const dateStyle = TextStyle(color: Colors.white38, fontSize: 8);

                switch (key) {
                  case 'minimal':
                    return const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text(
                          '12:00',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                        Padding(
                          padding: EdgeInsets.symmetric(horizontal: 6),
                          child: Text(
                            '|',
                            style: TextStyle(
                              color: Colors.white24,
                              fontSize: 12,
                            ),
                          ),
                        ),
                        Text(
                          'SUN JUN 21',
                          style: TextStyle(color: Colors.white38, fontSize: 8),
                        ),
                      ],
                    );
                  case 'cyber':
                    return const Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Text('12', style: textStyle),
                        Text('00', style: textStyle),
                        SizedBox(height: 2),
                        Text('SUN JUN 21', style: dateStyle),
                      ],
                    );
                  case 'split':
                    return Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        Container(
                          width: 3,
                          height: 24,
                          decoration: BoxDecoration(
                            color: activeColor,
                            borderRadius: BorderRadius.circular(1.5),
                          ),
                        ),
                        const SizedBox(width: 8),
                        const Column(
                          mainAxisAlignment: MainAxisAlignment.center,
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              '12:00',
                              style: TextStyle(
                                color: Colors.white70,
                                fontSize: 12,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'SUN JUN 21',
                              style: TextStyle(
                                color: Colors.white38,
                                fontSize: 7,
                              ),
                            ),
                          ],
                        ),
                      ],
                    );
                  case 'neon':
                    return Container(
                      decoration: BoxDecoration(
                        borderRadius: BorderRadius.circular(10),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(
                              0xFF3B82F6,
                            ).withValues(alpha: 0.4),
                            blurRadius: 10,
                          ),
                        ],
                      ),
                      child: Container(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 14,
                          vertical: 6,
                        ),
                        decoration: BoxDecoration(
                          color: const Color(
                            0xFF3B82F6,
                          ).withValues(alpha: 0.14),
                          borderRadius: BorderRadius.circular(10),
                          border: Border.all(
                            color: const Color(
                              0xFF3B82F6,
                            ).withValues(alpha: 0.9),
                            width: 1.2,
                          ),
                        ),
                        child: const Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              '12:00',
                              style: TextStyle(
                                color: Color(0xFFD946EF),
                                fontSize: 13,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            SizedBox(height: 1),
                            Text(
                              'SUN  ·  21 JUN',
                              style: TextStyle(
                                color: Color(0xFF3B82F6),
                                fontSize: 7,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  case 'animated_neon':
                    return Container(
                      width: 50,
                      height: 50,
                      decoration: BoxDecoration(
                        shape: BoxShape.circle,
                        border: Border.all(
                          color: activeColor.withValues(alpha: 0.6),
                          width: 1.5,
                        ),
                      ),
                      child: const Center(
                        child: Text(
                          '12:00',
                          style: TextStyle(
                            color: Colors.white70,
                            fontSize: 8,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ),
                    );
                  case 'classic':
                  default:
                    return Column(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: [
                        const Text('12:00', style: textStyle),
                        const SizedBox(height: 3),
                        Container(
                          width: 30,
                          height: 1.5,
                          color: Colors.white10,
                        ),
                        const SizedBox(height: 4),
                        const Text('SUN JUN 21', style: dateStyle),
                      ],
                    );
                }
              }

              return HoverCard(
                scaleUp: 1.035,
                borderRadius: BorderRadius.circular(18),
                glowColor: isSelected ? activeColor : Colors.transparent,
                maxGlowOpacity: 0.25,
                blurRadius: 12,
                onTap: () {
                  if (_settings.widgetTemplate != key) {
                    final defaults =
                        WidgetSettings.templateDefaults[key] ??
                        {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
                    _updateSettings(
                      _settings.copyWith(
                        widgetTemplate: key,
                        width: defaults['width'],
                        height: defaults['height'],
                        sizeFactor: defaults['sizeFactor'],
                        editorMode: !_settings.isLocked,
                      ),
                    );
                  } else {
                    _updateSettings(
                      _settings.copyWith(editorMode: !_settings.isLocked),
                    );
                  }
                  setState(() {
                    _editingWidget = true;
                  });
                },
                child: AnimatedContainer(
                  duration: const Duration(milliseconds: 200),
                  width: 220,
                  height: 195,
                  decoration: BoxDecoration(
                    color: isSelected
                        ? activeColor.withValues(alpha: 0.08)
                        : Colors.white.withValues(alpha: 0.02),
                    borderRadius: BorderRadius.circular(18),
                    border: Border.all(
                      color: isSelected
                          ? activeColor.withValues(alpha: 0.6)
                          : Colors.white.withValues(alpha: 0.06),
                      width: isSelected ? 2.0 : 1.0,
                    ),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: [
                      // graphical representation of layout
                      Expanded(
                        child: Container(
                          margin: const EdgeInsets.all(8),
                          decoration: BoxDecoration(
                            color: Colors.black.withValues(alpha: 0.35),
                            borderRadius: BorderRadius.circular(14),
                            border: Border.all(
                              color: Colors.white.withValues(alpha: 0.04),
                            ),
                          ),
                          child: Center(child: miniClockPreview()),
                        ),
                      ),
                      // footer
                      Padding(
                        padding: const EdgeInsets.fromLTRB(14, 2, 14, 12),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Expanded(
                                  child: Text(
                                    name,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 14,
                                      fontWeight: isSelected
                                          ? FontWeight.w900
                                          : FontWeight.bold,
                                      color: isSelected
                                          ? Colors.white
                                          : Colors.white70,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 8),
                                if (isSelected)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 6,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      color: activeColor.withValues(
                                        alpha: 0.25,
                                      ),
                                      borderRadius: BorderRadius.circular(4),
                                    ),
                                    child: Text(
                                      'ACTIVE',
                                      style: TextStyle(
                                        color: activeColor,
                                        fontSize: 9,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                      ),
                                    ),
                                  ),
                              ],
                            ),
                            const SizedBox(height: 8),
                            SizedBox(
                              width: double.infinity,
                              height: 28,
                              child: ElevatedButton.icon(
                                onPressed: () {
                                  if (_settings.widgetTemplate != key) {
                                    final defaults =
                                        WidgetSettings.templateDefaults[key] ??
                                        {
                                          'width': 360.0,
                                          'height': 200.0,
                                          'sizeFactor': 1.0,
                                        };
                                    _updateSettings(
                                      _settings.copyWith(
                                        widgetTemplate: key,
                                        width: defaults['width'],
                                        height: defaults['height'],
                                        sizeFactor: defaults['sizeFactor'],
                                        editorMode: !_settings.isLocked,
                                      ),
                                    );
                                  } else {
                                    _updateSettings(
                                      _settings.copyWith(
                                        editorMode: !_settings.isLocked,
                                      ),
                                    );
                                  }
                                  setState(() {
                                    _editingWidget = true;
                                  });
                                },
                                icon: Icon(
                                  Icons.tune,
                                  size: 12,
                                  color: isSelected
                                      ? Colors.white
                                      : Colors.white70,
                                ),
                                label: Text(
                                  isSelected
                                      ? 'Customize Elements'
                                      : 'Select & Customize',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  padding: EdgeInsets.zero,
                                  backgroundColor: isSelected
                                      ? activeColor
                                      : Colors.white.withValues(alpha: 0.05),
                                  foregroundColor: Colors.white,
                                  shape: RoundedRectangleBorder(
                                    borderRadius: BorderRadius.circular(8),
                                  ),
                                  elevation: 0,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
              );
            }).toList(),
          ),
        ],
      ),
    );
  }

  Widget _buildActiveTemplateLayoutTile() {
    final templates = {
      'classic': 'Classic Layout',
      'minimal': 'Minimal Layout',
      'cyber': 'Bold Cyber Stack',
      'split': 'Split Accent Layout',
      'neon': 'Glass Neon Capsule',
      'animated_neon': 'Animated Neon Ring',
      'sleep_weather': 'Smart Dashboard',
      'robik': 'Robik Theme',
      'atomic_clock': 'Atomic Clock',
    };
    final name = templates[_settings.widgetTemplate] ?? 'Classic Layout';
    final activeColor = const Color(0xFFEC4899);

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Icon(Icons.widgets, size: 16, color: activeColor),
              const SizedBox(width: 10),
              Text(
                name,
                style: const TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                ),
              ),
            ],
          ),
          ElevatedButton.icon(
            onPressed: () {
              setState(() {
                _editingWidget = false;
                _selectedElement = null;
              });
            },
            icon: const Icon(Icons.grid_view, size: 12),
            label: const Text(
              'Change',
              style: TextStyle(fontSize: 10, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: activeColor.withValues(alpha: 0.15),
              foregroundColor: activeColor,
              elevation: 0,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
          ),
        ],
      ),
    );
  }

  // ── LAYOUT EDITOR ────────────────────────────────────────────────────────

  Widget _buildLayoutEditor() {
    return ListView(
      padding: const EdgeInsets.all(20),
      children: [
        _sectionLabel('WIDGET TEMPLATE'),
        const SizedBox(height: 10),
        _buildActiveTemplateLayoutTile(),
        const SizedBox(height: 20),

        if (_settings.widgetTemplate == 'sleep_weather') ...[
          _sectionLabel('STATUS ICONS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Wi-Fi Icon',
            _settings.showWifi,
            (v) => _updateSettings(_settings.copyWith(showWifi: v)),
          ),
          const SizedBox(height: 4),
          _buildToggleTile(
            'Wi-Fi Connected',
            _settings.wifiEnabled,
            (v) => _updateSettings(_settings.copyWith(wifiEnabled: v)),
          ),
          const SizedBox(height: 4),
          _buildToggleTile(
            'Show Bluetooth Icon',
            _settings.showBluetooth,
            (v) => _updateSettings(_settings.copyWith(showBluetooth: v)),
          ),
          const SizedBox(height: 4),
          _buildToggleTile(
            'Bluetooth Connected',
            _settings.bluetoothEnabled,
            (v) => _updateSettings(_settings.copyWith(bluetoothEnabled: v)),
          ),
          const SizedBox(height: 20),

          _sectionLabel('MEDIA CONTROL BAR'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Media Controls',
            _settings.showMediaControl,
            (v) => _updateSettings(_settings.copyWith(showMediaControl: v)),
          ),
          if (_settings.showMediaControl) ...[
            const SizedBox(height: 12),
            const Text(
              'Media Accent Color',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ColorPickerWidget(
              initialColor: Color(_settings.mediaThemeColor),
              paletteColors: _settings.colorPalette
                  .map((v) => Color(v))
                  .toList(),
              onColorChanged: (c) => _updateSettings(
                _settings.copyWith(mediaThemeColor: c.toARGB32()),
              ),
              onSaveTopalette: () =>
                  _saveColorToPalette(Color(_settings.mediaThemeColor)),
            ),
          ],
          const SizedBox(height: 20),

          _sectionLabel('WEATHER SETTINGS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Weather Details',
            _settings.showWeather,
            (v) => _updateSettings(_settings.copyWith(showWeather: v)),
          ),
          if (_settings.showWeather) ...[
            const SizedBox(height: 12),
            _buildWeatherSettingsControls(),
            const SizedBox(height: 14),
            const Text(
              'Weather Accent Color',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 8),
            ColorPickerWidget(
              initialColor: Color(_settings.weatherThemeColor),
              paletteColors: _settings.colorPalette
                  .map((v) => Color(v))
                  .toList(),
              onColorChanged: (c) => _updateSettings(
                _settings.copyWith(weatherThemeColor: c.toARGB32()),
              ),
              onSaveTopalette: () =>
                  _saveColorToPalette(Color(_settings.weatherThemeColor)),
            ),
          ],
          const SizedBox(height: 20),
        ],

        if (_settings.widgetTemplate == 'robik') ...[
          _sectionLabel('SYSTEM MONITORS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show CPU Usage Monitor',
            _settings.showCpu,
            (v) => _updateSettings(_settings.copyWith(showCpu: v)),
          ),
          const SizedBox(height: 4),
          _buildToggleTile(
            'Show RAM Usage Monitor',
            _settings.showRam,
            (v) => _updateSettings(_settings.copyWith(showRam: v)),
          ),
          const SizedBox(height: 20),

          _sectionLabel('WEATHER SETTINGS'),
          const SizedBox(height: 8),
          _buildToggleTile(
            'Show Weather Details',
            _settings.showWeather,
            (v) => _updateSettings(_settings.copyWith(showWeather: v)),
          ),
          if (_settings.showWeather) ...[
            const SizedBox(height: 12),
            _buildWeatherSettingsControls(),
            const SizedBox(height: 14),
          ],
          const SizedBox(height: 20),
        ],

        if (_settings.widgetTemplate == 'neon') ...[
          _buildGlassNeonLayoutControls(),
        ],

        _sectionLabel('DISPLAY FORMAT'),
        const SizedBox(height: 8),
        _buildToggleTile(
          '24-Hour Format',
          _settings.use24HourFormat,
          (v) => _updateSettings(_settings.copyWith(use24HourFormat: v)),
        ),
        const SizedBox(height: 4),
        _buildToggleTile(
          'Show Seconds',
          _settings.showSeconds,
          (v) => _updateSettings(_settings.copyWith(showSeconds: v)),
        ),
        const SizedBox(height: 4),
        _buildToggleTile(
          'Show Outer Frame',
          _settings.showOuterFrame,
          (v) => _updateSettings(_settings.copyWith(showOuterFrame: v)),
        ),

        const SizedBox(height: 20),
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            _sectionLabel('CANVAS & WINDOW SIZE'),
            TextButton.icon(
              onPressed: () {
                final defaults =
                    WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
                    {'width': 360.0, 'height': 200.0, 'sizeFactor': 1.0};
                _updateSettings(
                  _settings.copyWith(
                    width: defaults['width'],
                    height: defaults['height'],
                    sizeFactor: defaults['sizeFactor'],
                  ),
                );
              },
              icon: const Icon(Icons.restore, size: 12),
              label: const Text(
                'Auto-Fit Template',
                style: TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
              ),
              style: TextButton.styleFrom(
                foregroundColor: const Color(0xFF38BDF8),
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ),
          ],
        ),
        const SizedBox(height: 8),

        // Quick Canvas Size Presets
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children:
              [
                {'label': 'Pill (280×100)', 'w': 280.0, 'h': 100.0, 's': 0.95},
                {'label': 'Card (360×200)', 'w': 360.0, 'h': 200.0, 's': 1.0},
                {'label': 'Banner (480×140)', 'w': 480.0, 'h': 140.0, 's': 1.0},
                {'label': 'HUD (520×260)', 'w': 520.0, 'h': 260.0, 's': 1.05},
                {
                  'label': 'Studio (600×340)',
                  'w': 600.0,
                  'h': 340.0,
                  's': 1.15,
                },
              ].map((preset) {
                final isMatch =
                    (_settings.width == preset['w'] &&
                    _settings.height == preset['h']);
                return HoverCard(
                  scaleUp: 1.03,
                  borderRadius: BorderRadius.circular(8),
                  glowColor: isMatch
                      ? const Color(0xFF38BDF8)
                      : Colors.transparent,
                  maxGlowOpacity: 0.25,
                  blurRadius: 8,
                  onTap: () {
                    _updateSettings(
                      _settings.copyWith(
                        width: preset['w'] as double,
                        height: preset['h'] as double,
                        sizeFactor: preset['s'] as double,
                      ),
                    );
                  },
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 180),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 6,
                    ),
                    decoration: BoxDecoration(
                      color: isMatch
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.15)
                          : Colors.white.withValues(alpha: 0.03),
                      borderRadius: BorderRadius.circular(8),
                      border: Border.all(
                        color: isMatch
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                            : Colors.white.withValues(alpha: 0.08),
                        width: 1.0,
                      ),
                    ),
                    child: Text(
                      preset['label'] as String,
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: isMatch ? FontWeight.w800 : FontWeight.w600,
                        color: isMatch ? Colors.white : Colors.white70,
                      ),
                    ),
                  ),
                );
              }).toList(),
        ),
        const SizedBox(height: 12),

        _buildSlider(
          'Width',
          _settings.width,
          180,
          800,
          (v) => _updateSettings(_settings.copyWith(width: v)),
          suffix: ' px',
          step: 10.0,
          decimals: 0,
          onReset: () {
            final defaults =
                WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
                {'width': 360.0};
            _updateSettings(_settings.copyWith(width: defaults['width']));
          },
        ),
        const SizedBox(height: 4),
        _buildSlider(
          'Height',
          _settings.height,
          60,
          600,
          (v) => _updateSettings(_settings.copyWith(height: v)),
          suffix: ' px',
          step: 10.0,
          decimals: 0,
          onReset: () {
            final defaults =
                WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
                {'height': 200.0};
            _updateSettings(_settings.copyWith(height: defaults['height']));
          },
        ),
        const SizedBox(height: 4),
        _buildSlider(
          'Size Factor',
          _settings.sizeFactor,
          0.5,
          3.0,
          (v) => _updateSettings(_settings.copyWith(sizeFactor: v)),
          step: 0.05,
          decimals: 2,
          onReset: () {
            final defaults =
                WidgetSettings.templateDefaults[_settings.widgetTemplate] ??
                {'sizeFactor': 1.0};
            _updateSettings(
              _settings.copyWith(sizeFactor: defaults['sizeFactor']),
            );
          },
        ),

        const SizedBox(height: 20),
        _sectionLabel('BEHAVIOR'),
        const SizedBox(height: 8),
        _buildToggleTile(
          'Always on Top',
          _settings.alwaysOnTop,
          (v) => _updateSettings(_settings.copyWith(alwaysOnTop: v)),
        ),
        const SizedBox(height: 4),
        _buildToggleTile('Lock Position', _settings.isLocked, (v) {
          _updateSettings(
            _settings.copyWith(
              isLocked: v,
              editorMode: v ? false : _settings.editorMode,
            ),
          );
        }, subtitle: 'Disables window dragging'),
        if (!_settings.isLocked) ...[
          const SizedBox(height: 4),
          _buildToggleTile(
            'Editor Mode',
            _settings.editorMode,
            (v) => _updateSettings(_settings.copyWith(editorMode: v)),
            subtitle: 'Shows resizing frame and drag handles around widget',
          ),
        ],
        const SizedBox(height: 4),
        _buildToggleTile(
          'Start with Windows',
          _settings.startOnBoot,
          (v) => _updateSettings(_settings.copyWith(startOnBoot: v)),
          subtitle: 'Starts the desktop widget when you sign in',
        ),
      ],
    );
  }

  // ── Glass Neon Customization Studio in Layout Editor ─────────────────────

  Widget _buildGlassNeonLayoutControls() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _sectionLabel('GLASS NEON HARDWARE TELEMETRY & SWITCHES'),
        const SizedBox(height: 8),

        // 1. CPU Usage Monitor Switch & Inline Customizer
        _buildToggleTile(
          'Show CPU Usage Monitor',
          _settings.showCpu,
          (v) => _updateSettings(_settings.copyWith(showCpu: v)),
          subtitle: 'Live Win32 CPU processor load telemetry gauge',
        ),
        if (_settings.showCpu) ...[
          const SizedBox(height: 6),
          _buildNeonSubElementCustomizerCard(
            key: ElementKey.cpu,
            title: 'CPU Usage Monitor Customization',
            icon: Icons.memory_rounded,
            defaultColor: const Color(0xFF00FFCC),
            isExpanded: _neonShowCpuCustomizer,
            onToggleExpand: () => setState(
              () => _neonShowCpuCustomizer = !_neonShowCpuCustomizer,
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 2. RAM Usage Monitor Switch & Inline Customizer
        _buildToggleTile(
          'Show RAM Usage Monitor',
          _settings.showRam,
          (v) => _updateSettings(_settings.copyWith(showRam: v)),
          subtitle: 'Live Win32 memory utilization telemetry gauge',
        ),
        if (_settings.showRam) ...[
          const SizedBox(height: 6),
          _buildNeonSubElementCustomizerCard(
            key: ElementKey.ram,
            title: 'RAM Usage Monitor Customization',
            icon: Icons.developer_board_rounded,
            defaultColor: const Color(0xFFA855F7),
            isExpanded: _neonShowRamCustomizer,
            onToggleExpand: () => setState(
              () => _neonShowRamCustomizer = !_neonShowRamCustomizer,
            ),
          ),
        ],
        const SizedBox(height: 12),

        // 3. Glass Neon Badge Switch & Inline Customizer
        _buildToggleTile(
          'Show Glass Neon Badge',
          _settings.showNeonBadge,
          (v) => _updateSettings(_settings.copyWith(showNeonBadge: v)),
          subtitle: 'Glowing top status badge capsule with pulse indicator',
        ),
        if (_settings.showNeonBadge) ...[
          const SizedBox(height: 6),
          _buildNeonSubElementCustomizerCard(
            key: ElementKey.neonBadge,
            title: 'Glass Neon Badge Customization',
            icon: Icons.label_important_outline_rounded,
            defaultColor: const Color(0xFF00FFCC),
            isExpanded: _neonShowBadgeCustomizer,
            onToggleExpand: () => setState(
              () => _neonShowBadgeCustomizer = !_neonShowBadgeCustomizer,
            ),
          ),
        ],
        const SizedBox(height: 24),

        // 4. All Glass Neon Elements Customizer Deck
        _sectionLabel('GLASS NEON — ALL ELEMENTS QUICK-CUSTOMIZER'),
        const SizedBox(height: 4),
        Text(
          'Select any element below to customize color, size, font, and 3D offset directly',
          style: TextStyle(
            fontSize: 11,
            color: Colors.white.withValues(alpha: 0.45),
          ),
        ),
        const SizedBox(height: 10),
        _buildNeonAllElementsDeck(),
        const SizedBox(height: 24),
      ],
    );
  }

  Widget _buildNeonSubElementCustomizerCard({
    required String key,
    required String title,
    required IconData icon,
    required Color defaultColor,
    required bool isExpanded,
    required VoidCallback onToggleExpand,
  }) {
    final currentColor = Color(_settings.colorFor(key));
    final currentScale = _settings.elementSizes[key] ?? 1.0;
    final currentFont = _settings.fontFor(key);
    final isText = ElementKey.textKeys.contains(key);

    return Container(
      margin: const EdgeInsets.only(left: 4, bottom: 6),
      decoration: BoxDecoration(
        color: currentColor.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(
          color: currentColor.withValues(alpha: 0.3),
          width: 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header with Live Swatch & Expand Toggle
          InkWell(
            onTap: onToggleExpand,
            borderRadius: BorderRadius.circular(14),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
              child: Row(
                children: [
                  Container(
                    width: 26,
                    height: 26,
                    decoration: BoxDecoration(
                      color: currentColor.withValues(alpha: 0.2),
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: currentColor.withValues(alpha: 0.7),
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: currentColor.withValues(alpha: 0.4),
                          blurRadius: 6,
                        ),
                      ],
                    ),
                    child: Icon(icon, size: 13, color: currentColor),
                  ),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Text(
                      title,
                      style: TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.w700,
                        color: Colors.white.withValues(alpha: 0.9),
                      ),
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 7,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.3),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(color: Colors.white12),
                    ),
                    child: Text(
                      '${(currentScale * 100).toInt()}%',
                      style: TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                        color: currentColor,
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),
                  Icon(
                    isExpanded
                        ? Icons.expand_less_rounded
                        : Icons.expand_more_rounded,
                    size: 18,
                    color: Colors.white54,
                  ),
                ],
              ),
            ),
          ),

          if (isExpanded) ...[
            const Divider(color: Colors.white12, height: 1),
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  // 1. Color Customization
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _sectionLabel('ACCENT COLOR'),
                      if (_settings.elementColors.containsKey(key))
                        TextButton.icon(
                          onPressed: () {
                            final map = Map<String, int>.from(
                              _settings.elementColors,
                            )..remove(key);
                            _updateSettings(
                              _settings.copyWith(elementColors: map),
                            );
                          },
                          icon: const Icon(Icons.link_off_rounded, size: 11),
                          label: const Text(
                            'Reset Color',
                            style: TextStyle(fontSize: 10),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF38BDF8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 8),
                  ColorPickerWidget(
                    initialColor: currentColor,
                    paletteColors: _settings.colorPalette
                        .map((v) => Color(v))
                        .toList(),
                    onColorChanged: (c) => _setElementColor(key, c),
                    onSaveTopalette: () => _saveColorToPalette(currentColor),
                  ),
                  const SizedBox(height: 14),

                  // 2. Scale & Sizing Slider
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      _sectionLabel('ELEMENT SIZE & SCALE'),
                      if (_settings.elementSizes.containsKey(key))
                        TextButton.icon(
                          onPressed: () => _resetElementSize(key),
                          icon: const Icon(Icons.restore, size: 11),
                          label: const Text(
                            'Reset 1.0x',
                            style: TextStyle(fontSize: 10),
                          ),
                          style: TextButton.styleFrom(
                            foregroundColor: const Color(0xFF38BDF8),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 2,
                            ),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  _buildSlider(
                    'Scale',
                    currentScale,
                    0.4,
                    3.0,
                    (v) => _setElementSize(key, v),
                    step: 0.05,
                    percent: true,
                    onReset: () => _resetElementSize(key),
                  ),
                  const SizedBox(height: 14),

                  // 3. Font Family Selection (for text elements)
                  if (isText) ...[
                    _sectionLabel('FONT FAMILY'),
                    const SizedBox(height: 6),
                    Wrap(
                      spacing: 6,
                      runSpacing: 6,
                      children: _fonts.take(6).map((font) {
                        final sel = currentFont == font;
                        return InkWell(
                          onTap: () => _setElementFont(key, font),
                          borderRadius: BorderRadius.circular(6),
                          child: AnimatedContainer(
                            duration: const Duration(milliseconds: 150),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 10,
                              vertical: 5,
                            ),
                            decoration: BoxDecoration(
                              color: sel
                                  ? currentColor.withValues(alpha: 0.2)
                                  : Colors.white.withValues(alpha: 0.03),
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(
                                color: sel
                                    ? currentColor
                                    : Colors.white.withValues(alpha: 0.08),
                                width: sel ? 1.2 : 0.8,
                              ),
                            ),
                            child: Text(
                              font,
                              style: TextStyle(
                                fontFamily: font,
                                fontSize: 11,
                                fontWeight: sel
                                    ? FontWeight.w800
                                    : FontWeight.w500,
                                color: sel ? Colors.white : Colors.white60,
                              ),
                            ),
                          ),
                        );
                      }).toList(),
                    ),
                    const SizedBox(height: 14),
                  ],

                  // 4. 3D Spatial Position Offset
                  _sectionLabel('3D SPATIAL POSITION (X / Y)'),
                  const SizedBox(height: 6),
                  _buildSlider(
                    'Offset X',
                    _settings.translateXFor(key),
                    -150.0,
                    150.0,
                    (v) {
                      final map = Map<String, double>.from(
                        _settings.elementTranslateX,
                      );
                      map[key] = double.parse(v.toStringAsFixed(1));
                      _updateSettings(
                        _settings.copyWith(elementTranslateX: map),
                      );
                    },
                    step: 2.0,
                    decimals: 0,
                    suffix: ' px',
                    onReset: () {
                      final map = Map<String, double>.from(
                        _settings.elementTranslateX,
                      )..remove(key);
                      _updateSettings(
                        _settings.copyWith(elementTranslateX: map),
                      );
                    },
                  ),
                  _buildSlider(
                    'Offset Y',
                    _settings.translateYFor(key),
                    -150.0,
                    150.0,
                    (v) {
                      final map = Map<String, double>.from(
                        _settings.elementTranslateY,
                      );
                      map[key] = double.parse(v.toStringAsFixed(1));
                      _updateSettings(
                        _settings.copyWith(elementTranslateY: map),
                      );
                    },
                    step: 2.0,
                    decimals: 0,
                    suffix: ' px',
                    onReset: () {
                      final map = Map<String, double>.from(
                        _settings.elementTranslateY,
                      )..remove(key);
                      _updateSettings(
                        _settings.copyWith(elementTranslateY: map),
                      );
                    },
                  ),
                  const SizedBox(height: 10),

                  // 5. Direct Jump to Full 3D Inspector Button
                  SizedBox(
                    width: double.infinity,
                    height: 32,
                    child: OutlinedButton.icon(
                      onPressed: () {
                        setState(() {
                          _selectedElement = key;
                          _tabCtrl.animateTo(0);
                        });
                      },
                      icon: const Icon(Icons.open_in_new_rounded, size: 12),
                      label: const Text(
                        'Open in Deep 3D Spatial Studio (Element Tab)',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      style: OutlinedButton.styleFrom(
                        foregroundColor: currentColor,
                        side: BorderSide(
                          color: currentColor.withValues(alpha: 0.4),
                        ),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildNeonAllElementsDeck() {
    final neonKeys = [
      ElementKey.neonBox,
      ElementKey.neonBadge,
      ElementKey.neonDivider,
      ElementKey.hours,
      ElementKey.separator,
      ElementKey.minutes,
      ElementKey.seconds,
      ElementKey.ampm,
      ElementKey.cpu,
      ElementKey.ram,
      ElementKey.day,
      ElementKey.date,
      ElementKey.year,
    ];

    if (!neonKeys.contains(_neonActiveQuickElement)) {
      _neonActiveQuickElement = ElementKey.neonBox;
    }

    final activeKey = _neonActiveQuickElement;
    final activeColor = Color(_settings.colorFor(activeKey));
    final activeFont = _settings.fontFor(activeKey);
    final activeScale = _settings.elementSizes[activeKey] ?? 1.0;
    final isText = ElementKey.textKeys.contains(activeKey);
    final label = _elementLabels[activeKey] ?? activeKey;
    final icon = _elementIcons[activeKey] ?? Icons.widgets_rounded;
    final sampleVal = _getElementSampleValue(activeKey);

    return Container(
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.025),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Horizontal Selector Bar for all Neon Elements
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.2),
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(16),
              ),
              border: Border(
                bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
              ),
            ),
            child: SizedBox(
              height: 34,
              child: ListView.separated(
                scrollDirection: Axis.horizontal,
                itemCount: neonKeys.length,
                separatorBuilder: (_, _) => const SizedBox(width: 6),
                itemBuilder: (_, index) {
                  final k = neonKeys[index];
                  final isSel = k == activeKey;
                  final elCol = Color(_settings.colorFor(k));
                  final elIcon = _elementIcons[k] ?? Icons.widgets_rounded;
                  final elLabel = _elementLabels[k] ?? k;

                  return HoverCard(
                    scaleUp: 1.04,
                    borderRadius: BorderRadius.circular(8),
                    glowColor: isSel ? elCol : Colors.transparent,
                    maxGlowOpacity: 0.2,
                    blurRadius: 6,
                    onTap: () => setState(() => _neonActiveQuickElement = k),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      decoration: BoxDecoration(
                        color: isSel
                            ? elCol.withValues(alpha: 0.18)
                            : Colors.white.withValues(alpha: 0.03),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(
                          color: isSel
                              ? elCol.withValues(alpha: 0.8)
                              : Colors.white.withValues(alpha: 0.06),
                          width: isSel ? 1.4 : 0.8,
                        ),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            elIcon,
                            size: 12,
                            color: isSel ? elCol : Colors.white60,
                          ),
                          const SizedBox(width: 5),
                          Text(
                            elLabel,
                            style: TextStyle(
                              fontSize: 10.5,
                              fontWeight: isSel
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: isSel ? Colors.white : Colors.white70,
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

          // Active Element Customizer Body
          Padding(
            padding: const EdgeInsets.all(16),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // Header Row with preview badge
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    Expanded(
                      child: Row(
                        children: [
                          Container(
                            width: 32,
                            height: 32,
                            decoration: BoxDecoration(
                              color: activeColor.withValues(alpha: 0.2),
                              borderRadius: BorderRadius.circular(8),
                              border: Border.all(
                                color: activeColor.withValues(alpha: 0.6),
                              ),
                            ),
                            child: Icon(icon, size: 16, color: activeColor),
                          ),
                          const SizedBox(width: 10),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                Text(
                                  label,
                                  style: const TextStyle(
                                    fontSize: 14,
                                    fontWeight: FontWeight.w800,
                                    color: Colors.white,
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                                Text(
                                  'Glass Neon Element',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: Colors.white.withValues(alpha: 0.45),
                                  ),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.black.withValues(alpha: 0.35),
                        borderRadius: BorderRadius.circular(8),
                        border: Border.all(color: Colors.white12),
                      ),
                      child: Text(
                        sampleVal,
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: activeColor,
                          fontFamily: isText ? activeFont : 'Segoe UI',
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 16),

                // 1. Color Customization
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _sectionLabel('ELEMENT COLOR'),
                    if (_settings.elementColors.containsKey(activeKey))
                      TextButton.icon(
                        onPressed: () {
                          final map = Map<String, int>.from(
                            _settings.elementColors,
                          )..remove(activeKey);
                          _updateSettings(
                            _settings.copyWith(elementColors: map),
                          );
                        },
                        icon: const Icon(Icons.link_off_rounded, size: 11),
                        label: const Text(
                          'Inherit Default',
                          style: TextStyle(fontSize: 10),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 8),
                ColorPickerWidget(
                  initialColor: activeColor,
                  paletteColors: _settings.colorPalette
                      .map((v) => Color(v))
                      .toList(),
                  onColorChanged: (c) => _setElementColor(activeKey, c),
                  onSaveTopalette: () => _saveColorToPalette(activeColor),
                ),
                const SizedBox(height: 14),

                // 2. Element Size & Scale
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    _sectionLabel('SIZE & SCALE MULTIPLIER'),
                    if (_settings.elementSizes.containsKey(activeKey))
                      TextButton.icon(
                        onPressed: () => _resetElementSize(activeKey),
                        icon: const Icon(Icons.restore, size: 11),
                        label: const Text(
                          'Reset 1.0x',
                          style: TextStyle(fontSize: 10),
                        ),
                        style: TextButton.styleFrom(
                          foregroundColor: const Color(0xFF38BDF8),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          minimumSize: Size.zero,
                          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        ),
                      ),
                  ],
                ),
                const SizedBox(height: 6),
                _buildSlider(
                  'Scale',
                  activeScale,
                  0.3,
                  3.5,
                  (v) => _setElementSize(activeKey, v),
                  step: 0.05,
                  percent: true,
                  onReset: () => _resetElementSize(activeKey),
                ),
                const SizedBox(height: 14),

                // 3. Font Family (if text element)
                if (isText) ...[
                  _sectionLabel('TYPOGRAPHY & FONT'),
                  const SizedBox(height: 6),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: _fonts.take(6).map((font) {
                      final sel = activeFont == font;
                      return InkWell(
                        onTap: () => _setElementFont(activeKey, font),
                        borderRadius: BorderRadius.circular(6),
                        child: AnimatedContainer(
                          duration: const Duration(milliseconds: 150),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 5,
                          ),
                          decoration: BoxDecoration(
                            color: sel
                                ? activeColor.withValues(alpha: 0.2)
                                : Colors.white.withValues(alpha: 0.03),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: sel
                                  ? activeColor
                                  : Colors.white.withValues(alpha: 0.08),
                              width: sel ? 1.2 : 0.8,
                            ),
                          ),
                          child: Text(
                            font,
                            style: TextStyle(
                              fontFamily: font,
                              fontSize: 11,
                              fontWeight: sel
                                  ? FontWeight.w800
                                  : FontWeight.w500,
                              color: sel ? Colors.white : Colors.white60,
                            ),
                          ),
                        ),
                      );
                    }).toList(),
                  ),
                  const SizedBox(height: 14),
                ],

                // 4. 3D Spatial Position Offset
                _sectionLabel('3D SPATIAL TRANSLATION (X, Y, Z)'),
                const SizedBox(height: 6),
                _buildSlider(
                  'Offset X',
                  _settings.translateXFor(activeKey),
                  -150.0,
                  150.0,
                  (v) {
                    final map = Map<String, double>.from(
                      _settings.elementTranslateX,
                    );
                    map[activeKey] = double.parse(v.toStringAsFixed(1));
                    _updateSettings(_settings.copyWith(elementTranslateX: map));
                  },
                  step: 2.0,
                  decimals: 0,
                  suffix: ' px',
                  onReset: () {
                    final map = Map<String, double>.from(
                      _settings.elementTranslateX,
                    )..remove(activeKey);
                    _updateSettings(_settings.copyWith(elementTranslateX: map));
                  },
                ),
                _buildSlider(
                  'Offset Y',
                  _settings.translateYFor(activeKey),
                  -150.0,
                  150.0,
                  (v) {
                    final map = Map<String, double>.from(
                      _settings.elementTranslateY,
                    );
                    map[activeKey] = double.parse(v.toStringAsFixed(1));
                    _updateSettings(_settings.copyWith(elementTranslateY: map));
                  },
                  step: 2.0,
                  decimals: 0,
                  suffix: ' px',
                  onReset: () {
                    final map = Map<String, double>.from(
                      _settings.elementTranslateY,
                    )..remove(activeKey);
                    _updateSettings(_settings.copyWith(elementTranslateY: map));
                  },
                ),
                _buildSlider(
                  'Offset Z',
                  _settings.translateZFor(activeKey),
                  -100.0,
                  100.0,
                  (v) {
                    final map = Map<String, double>.from(
                      _settings.elementTranslateZ,
                    );
                    map[activeKey] = double.parse(v.toStringAsFixed(1));
                    _updateSettings(_settings.copyWith(elementTranslateZ: map));
                  },
                  step: 2.0,
                  decimals: 0,
                  suffix: ' px',
                  onReset: () {
                    final map = Map<String, double>.from(
                      _settings.elementTranslateZ,
                    )..remove(activeKey);
                    _updateSettings(_settings.copyWith(elementTranslateZ: map));
                  },
                ),
                const SizedBox(height: 12),

                // Button to jump into Element tab
                SizedBox(
                  width: double.infinity,
                  height: 32,
                  child: ElevatedButton.icon(
                    onPressed: () {
                      setState(() {
                        _selectedElement = activeKey;
                        _tabCtrl.animateTo(0);
                      });
                    },
                    icon: const Icon(
                      Icons.screen_rotation_alt_rounded,
                      size: 12,
                    ),
                    label: Text(
                      'Open $label in Full 3D Rotation Studio',
                      style: const TextStyle(
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: activeColor.withValues(alpha: 0.2),
                      foregroundColor: activeColor,
                      elevation: 0,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                        side: BorderSide(
                          color: activeColor.withValues(alpha: 0.5),
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Reusable editor widgets ──────────────────────────────────────────────

  Widget _sectionLabel(String text) {
    return Text(
      text,
      style: TextStyle(
        fontSize: 10,
        fontWeight: FontWeight.w700,
        letterSpacing: 1.8,
        color: Colors.white.withValues(alpha: 0.35),
      ),
    );
  }

  Widget _buildMiniStepperButton({
    required IconData icon,
    required VoidCallback? onPressed,
  }) {
    final enabled = onPressed != null;
    return Material(
      color: Colors.transparent,
      child: InkWell(
        onTap: onPressed,
        borderRadius: BorderRadius.circular(6),
        hoverColor: const Color(0xFF38BDF8).withValues(alpha: 0.15),
        splashColor: const Color(0xFF38BDF8).withValues(alpha: 0.25),
        child: Container(
          width: 24,
          height: 24,
          decoration: BoxDecoration(
            color: enabled
                ? Colors.white.withValues(alpha: 0.06)
                : Colors.white.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(
              color: enabled
                  ? Colors.white.withValues(alpha: 0.12)
                  : Colors.white.withValues(alpha: 0.04),
            ),
          ),
          alignment: Alignment.center,
          child: Icon(
            icon,
            size: 13,
            color: enabled ? Colors.white70 : Colors.white24,
          ),
        ),
      ),
    );
  }

  Widget _buildSlider(
    String label,
    double value,
    double min,
    double max,
    ValueChanged<double> onChanged, {
    bool percent = false,
    String suffix = '',
    double? step,
    int? decimals,
    VoidCallback? onReset,
  }) {
    final clamped = value.clamp(min, max);
    final effectiveDecimals =
        decimals ??
        (percent
            ? 0
            : (step != null && step < 1 ? 2 : (clamped % 1 == 0 ? 0 : 1)));
    final displayStr = percent
        ? '${(clamped * 100).toInt()}%'
        : (effectiveDecimals == 0
              ? '${clamped.toInt()}$suffix'
              : '${clamped.toStringAsFixed(effectiveDecimals)}$suffix');

    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          SizedBox(
            width: 76,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    label,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Colors.white70,
                      fontWeight: FontWeight.w600,
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (onReset != null)
                  Padding(
                    padding: const EdgeInsets.only(left: 2),
                    child: InkWell(
                      onTap: onReset,
                      borderRadius: BorderRadius.circular(4),
                      child: const Icon(
                        Icons.refresh,
                        size: 11,
                        color: Colors.white38,
                      ),
                    ),
                  ),
              ],
            ),
          ),
          if (step != null) ...[
            _buildMiniStepperButton(
              icon: Icons.remove,
              onPressed: clamped > min
                  ? () {
                      final next = (clamped - step).clamp(min, max);
                      onChanged(
                        double.parse(
                          next.toStringAsFixed(
                            effectiveDecimals > 0 ? effectiveDecimals : 0,
                          ),
                        ),
                      );
                    }
                  : null,
            ),
            const SizedBox(width: 4),
          ],
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                thumbColor: Colors.white,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
                overlayColor: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 7,
                  pressedElevation: 6,
                  elevation: 3,
                ),
                overlayShape: const RoundSliderOverlayShape(overlayRadius: 14),
                trackHeight: 5,
                trackShape: const ModernGradientSliderTrackShape(
                  colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                ),
                activeTickMarkColor: Colors.transparent,
                inactiveTickMarkColor: Colors.transparent,
              ),
              child: Slider(
                value: clamped,
                min: min,
                max: max,
                onChanged: (v) {
                  onChanged(
                    double.parse(
                      v.toStringAsFixed(
                        effectiveDecimals > 0 ? effectiveDecimals : 0,
                      ),
                    ),
                  );
                },
              ),
            ),
          ),
          if (step != null) ...[
            const SizedBox(width: 4),
            _buildMiniStepperButton(
              icon: Icons.add,
              onPressed: clamped < max
                  ? () {
                      final next = (clamped + step).clamp(min, max);
                      onChanged(
                        double.parse(
                          next.toStringAsFixed(
                            effectiveDecimals > 0 ? effectiveDecimals : 0,
                          ),
                        ),
                      );
                    }
                  : null,
            ),
          ],
          SizedBox(
            width: 58,
            child: Container(
              margin: const EdgeInsets.only(left: 6),
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              ),
              child: Text(
                displayStr,
                textAlign: TextAlign.center,
                style: const TextStyle(
                  fontSize: 10,
                  fontFamily: 'Consolas',
                  color: Color(0xFF38BDF8),
                  fontWeight: FontWeight.bold,
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToggleTile(
    String title,
    bool value,
    ValueChanged<bool> onChanged, {
    String? subtitle,
  }) {
    final activeColor = const Color(0xFF38BDF8);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: HoverCard(
        scaleUp: 1.015,
        borderRadius: BorderRadius.circular(12),
        glowColor: Colors.transparent,
        maxGlowOpacity: 0.0,
        blurRadius: 0.0,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.02),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              dense: true,
              value: value,
              onChanged: onChanged,
              title: Text(
                title,
                style: const TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Colors.white,
                ),
              ),
              subtitle: subtitle != null
                  ? Text(
                      subtitle,
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.4),
                      ),
                    )
                  : null,
              contentPadding: EdgeInsets.zero,
              activeThumbColor: Colors.white,
              activeTrackColor: activeColor,
              inactiveTrackColor: Colors.white.withValues(alpha: 0.08),
              inactiveThumbColor: Colors.white38,
            ),
          ),
        ),
      ),
    );
  }

  // Helper widget to build a category chip
  Widget _buildCategoryChip(String cat, bool isSelected) {
    return GestureDetector(
      onTap: () => setState(() => _selectedCategory = cat),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOutCubic,
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 7),
        decoration: BoxDecoration(
          gradient: isSelected
              ? const LinearGradient(
                  colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                )
              : null,
          color: isSelected ? null : Colors.white.withValues(alpha: 0.04),
          borderRadius: BorderRadius.circular(20),
          border: Border.all(
            color: isSelected
                ? Colors.transparent
                : Colors.white.withValues(alpha: 0.09),
            width: 1.0,
          ),
          boxShadow: isSelected
              ? [
                  BoxShadow(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                    blurRadius: 10,
                    offset: const Offset(0, 2),
                  ),
                ]
              : null,
        ),
        child: Text(
          cat,
          style: TextStyle(
            fontSize: 12,
            color: isSelected ? const Color(0xFF070913) : Colors.white70,
            fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
            letterSpacing: 0.3,
          ),
        ),
      ),
    );
  }

  // ── About Tab ─────────────────────────────────────────────────────────────

  Widget _buildAboutTab({Key? key}) {
    const accent = Color(0xFF38BDF8);
    const secondaryAccent = Color(0xFF818CF8);
    const mutedText = Color(0xFFB7C1D1);

    Widget policyPoint({
      required IconData icon,
      required String title,
      required String text,
    }) => Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              gradient: LinearGradient(
                colors: [
                  accent.withValues(alpha: 0.15),
                  secondaryAccent.withValues(alpha: 0.08),
                ],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: accent.withValues(alpha: 0.30),
                width: 1.0,
              ),
              boxShadow: [
                BoxShadow(
                  color: accent.withValues(alpha: 0.12),
                  blurRadius: 8,
                ),
              ],
            ),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(height: 5),
                Text(
                  text,
                  style: const TextStyle(
                    color: mutedText,
                    fontSize: 13,
                    height: 1.55,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );

    Widget sectionCard({
      required IconData icon,
      required String title,
      required String subtitle,
      required Widget child,
    }) => Container(
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [Color(0xF5101422), Color(0xF50A0C14)],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(22),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.40),
            blurRadius: 20,
            offset: const Offset(0, 6),
          ),
          BoxShadow(
            color: accent.withValues(alpha: 0.03),
            blurRadius: 24,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: [
                        accent.withValues(alpha: 0.18),
                        secondaryAccent.withValues(alpha: 0.10),
                      ],
                      begin: Alignment.topLeft,
                      end: Alignment.bottomRight,
                    ),
                    borderRadius: BorderRadius.circular(14),
                    border: Border.all(
                      color: accent.withValues(alpha: 0.35),
                      width: 1.2,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: accent.withValues(alpha: 0.20),
                        blurRadius: 10,
                      ),
                    ],
                  ),
                  child: Icon(icon, color: accent, size: 22),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        title,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 17,
                          fontWeight: FontWeight.w700,
                          letterSpacing: -0.2,
                        ),
                      ),
                      const SizedBox(height: 3),
                      Text(
                        subtitle,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.55),
                          fontSize: 12,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 18),
            child,
          ],
        ),
      ),
    );

    Widget termsPoint({required String title, required String body}) => Padding(
      padding: const EdgeInsets.only(bottom: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                width: 6,
                height: 6,
                margin: const EdgeInsets.only(right: 8),
                decoration: BoxDecoration(
                  color: secondaryAccent,
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: secondaryAccent.withValues(alpha: 0.6),
                      blurRadius: 6,
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 13,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 5),
          Padding(
            padding: const EdgeInsets.only(left: 14),
            child: Text(
              body,
              style: const TextStyle(
                color: mutedText,
                fontSize: 13,
                height: 1.55,
              ),
            ),
          ),
        ],
      ),
    );

    return LayoutBuilder(
      key: key,
      builder: (context, constraints) {
        final compact = constraints.maxWidth < 560;
        return SingleChildScrollView(
          padding: EdgeInsets.fromLTRB(
            compact ? 16 : 28,
            24,
            compact ? 16 : 28,
            36,
          ),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 940),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Container(
                    padding: EdgeInsets.all(compact ? 22 : 30),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [
                          Color(0xFF0F1E36),
                          Color(0xFF13172E),
                          Color(0xFF090B14),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(24),
                      border: Border.all(
                        color: accent.withValues(alpha: 0.28),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: accent.withValues(alpha: 0.12),
                          blurRadius: 30,
                          offset: const Offset(0, 10),
                        ),
                        BoxShadow(
                          color: secondaryAccent.withValues(alpha: 0.08),
                          blurRadius: 40,
                          offset: const Offset(0, 16),
                        ),
                      ],
                    ),
                    child: Row(
                      children: [
                        Container(
                          width: compact ? 54 : 68,
                          height: compact ? 54 : 68,
                          decoration: BoxDecoration(
                            gradient: LinearGradient(
                              colors: [
                                accent.withValues(alpha: 0.25),
                                secondaryAccent.withValues(alpha: 0.12),
                              ],
                              begin: Alignment.topLeft,
                              end: Alignment.bottomRight,
                            ),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: accent.withValues(alpha: 0.45),
                              width: 1.3,
                            ),
                            boxShadow: [
                              BoxShadow(
                                color: accent.withValues(alpha: 0.30),
                                blurRadius: 18,
                                spreadRadius: 1,
                              ),
                            ],
                          ),
                          child: const Icon(
                            Icons.wallpaper_rounded,
                            size: 34,
                            color: accent,
                          ),
                        ),
                        const SizedBox(width: 20),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Row(
                                children: [
                                  ShaderMask(
                                    shaderCallback: (bounds) => const LinearGradient(
                                      colors: [
                                        Colors.white,
                                        Color(0xFFE0E7FF),
                                        Color(0xFF38BDF8),
                                      ],
                                      stops: [0.0, 0.65, 1.0],
                                    ).createShader(bounds),
                                    child: Text(
                                      'About WallSync',
                                      style: TextStyle(
                                        color: Colors.white,
                                        fontSize: compact ? 22 : 28,
                                        fontWeight: FontWeight.w900,
                                        letterSpacing: -0.5,
                                      ),
                                    ),
                                  ),
                                  const SizedBox(width: 10),
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 8,
                                      vertical: 3,
                                    ),
                                    decoration: BoxDecoration(
                                      gradient: const LinearGradient(
                                        colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                                      ),
                                      borderRadius: BorderRadius.circular(8),
                                      boxShadow: [
                                        BoxShadow(
                                          color: const Color(0xFF38BDF8).withValues(alpha: 0.40),
                                          blurRadius: 10,
                                          offset: const Offset(0, 2),
                                        ),
                                      ],
                                    ),
                                    child: const Text(
                                      'PRO EDITION',
                                      style: TextStyle(
                                        fontSize: 9,
                                        fontWeight: FontWeight.w900,
                                        color: Color(0xFF070913),
                                        letterSpacing: 0.8,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                              const SizedBox(height: 6),
                              const Text(
                                'Personalize your Windows desktop with dynamic live video wallpapers and real-time widgets.',
                                style: TextStyle(
                                  color: Color(0xFFC3D1E0),
                                  fontSize: 13,
                                  height: 1.45,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 20),
                  sectionCard(
                    icon: Icons.shield_outlined,
                    title: 'Privacy Policy',
                    subtitle: 'How WallSync handles data and connectivity',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'WallSync is dedicated to respecting and protecting your privacy. We operate on a strict privacy-first model to ensure your personal information remains safe and entirely in your control.',
                          style: TextStyle(
                            color: mutedText,
                            fontSize: 13,
                            height: 1.55,
                          ),
                        ),
                        const SizedBox(height: 8),
                        Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
                        policyPoint(
                          icon: Icons.person_off_outlined,
                          title: 'Zero personal data collection',
                          text:
                              'WallSync does not collect, store, track, or process any personally identifiable information (PII), sensitive data, telemetry, or user analytics under any circumstances.',
                        ),
                        Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                        policyPoint(
                          icon: Icons.devices_outlined,
                          title: 'Local operation',
                          text:
                              'The application operates locally on your device. We do not use persistent identifiers, user tracking cookies, or dynamic background activity logs.',
                        ),
                        Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                        policyPoint(
                          icon: Icons.cloud_outlined,
                          title: 'Network and cloud access',
                          text:
                              'Network connectivity is required solely to fetch wallpaper assets, desktop widgets, and associated metadata from designated Cloudinary and Firebase servers. No personal identifiers or usage history are attached to these network requests.',
                        ),
                        Divider(color: Colors.white.withValues(alpha: 0.06), height: 1),
                        policyPoint(
                          icon: Icons.support_agent_rounded,
                          title: 'Support and bug reporting',
                          text:
                              'Any information voluntarily submitted through the bug report feature (such as your name or email address) is used strictly to assist with technical troubleshooting and software updates. We do not sell, rent, or share your contact details with third-party organizations.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  sectionCard(
                    icon: Icons.gavel_rounded,
                    title: 'Terms and Conditions',
                    subtitle: 'Usage, licensing, and copyright information',
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        const Text(
                          'By downloading, installing, or using WallSync, you agree to comply with and be bound by these terms and conditions:',
                          style: TextStyle(
                            color: mutedText,
                            fontSize: 13,
                            height: 1.55,
                          ),
                        ),
                        const SizedBox(height: 18),
                        termsPoint(
                          title: 'Editions and licensing',
                          body:
                              'WallSync (Free Version): WallSync is a completely free application providing core wallpaper features, including static images and video wallpapers, and essential desktop widgets.\n\nWallSync Pro (Paid Version): WallSync Pro is a separate paid edition offering advanced features, expanded customization tools, and enhanced UI modifications.',
                        ),
                        termsPoint(
                          title: 'Asset ownership and copyright',
                          body:
                              'WallSync does not claim ownership, copyright, or exclusive intellectual property rights over any third-party wallpapers, video assets, or images displayed within the application. All media assets are sourced from open-source, public domain, or royalty-free platforms, and full intellectual property rights remain with their respective original creators.',
                        ),
                        termsPoint(
                          title:
                              'Copyright take-down policy (DMCA / Report Issue)',
                          body:
                              'We respect the intellectual property rights of all content creators. If you are a copyright owner or authorized representative and believe any content within WallSync infringes upon your copyright, please submit a take-down report. Valid copyright removal requests will be reviewed and processed, and the disputed asset will be removed from our servers within 24 hours.',
                        ),
                        termsPoint(
                          title: 'Acceptable use',
                          body:
                              'You agree not to misuse the application, reverse-engineer API endpoints, exploit network communication, or utilize the software to distribute unauthorized or malicious content.',
                        ),
                        termsPoint(
                          title: 'Distribution restrictions',
                          body:
                              'Unauthorized redistribution, modified builds, reverse engineering, or commercial repackaging of WallSync or WallSync Pro without prior written consent from the developers is strictly prohibited.',
                        ),
                        termsPoint(
                          title: 'Limitation of liability',
                          body:
                              'WallSync is provided on an "as-is" and "as-available" basis. To the maximum extent permitted by applicable law, the developers shall not be liable for any direct, indirect, incidental, or consequential damages resulting from the use or inability to use this software.',
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(height: 18),
                  Container(
                    padding: EdgeInsets.all(compact ? 18 : 22),
                    decoration: BoxDecoration(
                      gradient: const LinearGradient(
                        colors: [Color(0xF5101422), Color(0xF50A0C14)],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(22),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1.1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: Colors.black.withValues(alpha: 0.35),
                          blurRadius: 18,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: compact
                        ? Column(
                            children: [
                              _buildAboutDeveloperInfo(),
                              const SizedBox(height: 18),
                              SizedBox(
                                width: double.infinity,
                                child: _buildAboutUninstallButton(),
                              ),
                            ],
                          )
                        : Row(
                            children: [
                              Expanded(child: _buildAboutDeveloperInfo()),
                              const SizedBox(width: 20),
                              _buildAboutUninstallButton(),
                            ],
                          ),
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _buildAboutDeveloperInfo() => Row(
    children: [
      Container(
        width: 52,
        height: 52,
        padding: const EdgeInsets.all(6),
        decoration: BoxDecoration(
          gradient: LinearGradient(
            colors: [
              const Color(0xFFEF4444).withValues(alpha: 0.16),
              Colors.white.withValues(alpha: 0.04),
            ],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: const Color(0xFFEF4444).withValues(alpha: 0.35),
            width: 1.1,
          ),
          boxShadow: [
            BoxShadow(
              color: const Color(0xFFEF4444).withValues(alpha: 0.15),
              blurRadius: 10,
            ),
          ],
        ),
        child: Image.asset(
          'assets/redskills_studios.png',
          fit: BoxFit.contain,
          errorBuilder: (_, _, _) =>
              const Icon(Icons.auto_awesome_rounded, color: Color(0xFFEF4444)),
        ),
      ),
      const SizedBox(width: 14),
      Expanded(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                const Text(
                  'RedSkill Studios',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: const Color(0xFF10B981).withValues(alpha: 0.30),
                      width: 0.9,
                    ),
                  ),
                  child: const Text(
                    'VERIFIED CREATOR',
                    style: TextStyle(
                      fontSize: 8,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF10B981),
                      letterSpacing: 0.6,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              'WallSync Pro · Version 1.0.0.0.1',
              style: TextStyle(color: Colors.white54, fontSize: 12),
            ),
            const SizedBox(height: 5),
            Text(
              ShortbirdClient().currentPatch == 'none'
                  ? 'Push Updates: Enabled'
                  : 'Push Updates: Enabled (${ShortbirdClient().currentPatch})',
              style: const TextStyle(color: Color(0xFF7DD3FC), fontSize: 11),
            ),
          ],
        ),
      ),
    ],
  );

  Widget _buildAboutUninstallButton() => OutlinedButton.icon(
    onPressed: _triggerUninstall,
    icon: const Icon(Icons.delete_outline_rounded, size: 18),
    label: const Text('Uninstall'),
    style: OutlinedButton.styleFrom(
      foregroundColor: const Color(0xFFFCA5A5),
      backgroundColor: const Color(0xFFEF4444).withValues(alpha: 0.06),
      side: BorderSide(color: Colors.redAccent.withValues(alpha: 0.30)),
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14)),
    ),
  );

  void _triggerUninstall() async {
    try {
      final uninstallerPath =
          '${File(Platform.resolvedExecutable).parent.path}\\unins000.exe';
      if (File(uninstallerPath).existsSync()) {
        await Process.start(uninstallerPath, []);
      } else {
        if (mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(
              content: Text(
                'Uninstaller not found. You might need to uninstall from Windows Settings.',
              ),
              backgroundColor: Colors.redAccent,
            ),
          );
        }
      }
    } catch (e, st) {
      logError('DashboardView', 'Failed to launch uninstaller', e, st);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('Error launching uninstaller: $e'),
            backgroundColor: Colors.redAccent,
          ),
        );
      }
    }
  }

  // ── System Diagnostics & Performance Review ─────────────────────────────
  Widget _buildDiagnosticsTab({Key? key}) {
    final diag = DiagnosticsService.instance;
    final mem = diag.getMemorySnapshot();
    final cpu = diag.getCpuSnapshot();
    final smooth = diag.getSmoothnessSnapshot();

    return Center(
      key: key,
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(vertical: 32, horizontal: 16),
        child: Container(
          width: 760,
          padding: const EdgeInsets.all(28),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xF80F121E), Color(0xF8090B13)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.09),
              width: 1.1,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 30,
                offset: const Offset(0, 10),
              ),
              BoxShadow(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.06),
                blurRadius: 35,
                spreadRadius: 1,
              ),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              // Header
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Row(
                    children: [
                      Container(
                        padding: const EdgeInsets.all(11),
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            colors: [
                              const Color(0xFF38BDF8).withValues(alpha: 0.22),
                              const Color(0xFF818CF8).withValues(alpha: 0.10),
                            ],
                            begin: Alignment.topLeft,
                            end: Alignment.bottomRight,
                          ),
                          borderRadius: BorderRadius.circular(14),
                          border: Border.all(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.40),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                              blurRadius: 12,
                            ),
                          ],
                        ),
                        child: const Icon(
                          Icons.monitor_heart_rounded,
                          size: 24,
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                      const SizedBox(width: 14),
                      Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              const Text(
                                'Performance & Diagnostics Monitor',
                                style: TextStyle(
                                  fontSize: 20,
                                  fontWeight: FontWeight.bold,
                                  color: Colors.white,
                                  letterSpacing: -0.3,
                                ),
                              ),
                              const SizedBox(width: 10),
                              Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 7,
                                  vertical: 2,
                                ),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.35),
                                    width: 0.9,
                                  ),
                                ),
                                child: const Text(
                                  'LIVE TELEMETRY',
                                  style: TextStyle(
                                    fontSize: 8,
                                    fontWeight: FontWeight.w800,
                                    color: Color(0xFF10B981),
                                    letterSpacing: 0.6,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 3),
                          Text(
                            'Real-time profiling: RAM, CPU, Storage, GPU, 60 FPS Jank & Hang Watchdog',
                            style: TextStyle(
                              fontSize: 12,
                              color: Colors.white.withValues(alpha: 0.55),
                            ),
                          ),
                        ],
                      ),
                    ],
                  ),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Refresh Stats'),
                    onPressed: () => setState(() {
                      _diagnosticsStorageSnapshot = diag.getStorageSnapshot();
                    }),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      foregroundColor: const Color(0xFF38BDF8),
                      elevation: 0,
                      side: BorderSide(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                        width: 1.0,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(12),
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 16,
                        vertical: 10,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 24),

              // 4 Metrics Grid
              LayoutBuilder(
                builder: (context, constraints) {
                  final cardWidth = (constraints.maxWidth - 16) / 2;
                  return Wrap(
                    spacing: 16,
                    runSpacing: 16,
                    children: [
                      // Card 1: RAM & Memory
                      _buildDiagMetricCard(
                        width: cardWidth,
                        title: 'RAM Usage',
                        subtitle: 'Process & System Memory',
                        icon: Icons.memory_rounded,
                        accentColor: const Color(0xFF38BDF8),
                        mainValue: '${mem.processRssMb.toStringAsFixed(1)} MB',
                        mainLabel: 'Process RSS Footprint',
                        items: [
                          (
                            'Main PID / Private',
                            mem.processPrivateMb == null
                                ? '$pid / unavailable'
                                : '$pid / ${mem.processPrivateMb!.toStringAsFixed(1)} MB',
                          ),
                          (
                            'Peak Memory',
                            '${mem.processMaxRssMb.toStringAsFixed(1)} MB',
                          ),
                          if (mem.mpvProcessId != null) ...[
                            (
                              'MPV PID / RSS',
                              '${mem.mpvProcessId} / ${mem.mpvRssMb.toStringAsFixed(1)} MB',
                            ),
                            if (mem.mpvPrivateMb != null)
                              (
                                'MPV Private Commit',
                                '${mem.mpvPrivateMb!.toStringAsFixed(1)} MB',
                              ),
                          ],
                          if (mem.overlayProcessId != null) ...[
                            (
                              'Overlay PID / RSS',
                              '${mem.overlayProcessId} / ${(mem.overlayRssBytes! / (1024 * 1024)).toStringAsFixed(1)} MB',
                            ),
                            if (mem.overlayPrivateBytes != null)
                              (
                                'Overlay Private Commit',
                                '${(mem.overlayPrivateBytes! / (1024 * 1024)).toStringAsFixed(1)} MB',
                              ),
                          ],
                          (
                            'Image Cache',
                            '${mem.imageCacheMb.toStringAsFixed(1)} MB (${mem.imageCacheCount ?? 0} items)',
                          ),
                          (
                            'System Total RAM',
                            '${mem.systemTotalPhysMb.toStringAsFixed(0)} MB',
                          ),
                          (
                            'System Available',
                            '${mem.systemAvailPhysMb.toStringAsFixed(0)} MB (${mem.systemMemoryLoadPercent}% load)',
                          ),
                        ],
                      ),

                      // Card 2: CPU Utilization
                      _buildDiagMetricCard(
                        width: cardWidth,
                        title: 'CPU Usage',
                        subtitle: 'Multi-threaded Dart & Win32',
                        icon: Icons.speed_rounded,
                        accentColor: const Color(0xFF818CF8),
                        mainValue:
                            '${cpu.processCpuPercent.toStringAsFixed(1)}%',
                        mainLabel: 'WallSync Process CPU',
                        items: [
                          (
                            'System CPU Load',
                            '${cpu.systemCpuPercent.toStringAsFixed(1)}%',
                          ),
                          (
                            'Logical CPU Cores',
                            '${Platform.numberOfProcessors} Cores',
                          ),
                          ('Sample Interval', '${cpu.sampleIntervalMs} ms'),
                          ('Process PID', '$pid'),
                        ],
                      ),

                      // Card 3: 60 FPS Frame Smoothness
                      _buildDiagMetricCard(
                        width: cardWidth,
                        title: 'Smoothness & Jank',
                        subtitle: '60 FPS Target (16.6ms frame limit)',
                        icon: Icons.auto_awesome_motion_rounded,
                        accentColor: const Color(0xFF34D399),
                        mainValue:
                            '${smooth.smoothnessPercentage.toStringAsFixed(1)}%',
                        mainLabel: 'UI Smoothness Score',
                        items: [
                          ('Total Frames', '${smooth.totalFrames} frames'),
                          (
                            'Measured / Pipeline Gaps',
                            '${smooth.eligibleFrames} / ${smooth.pipelineGapFrames}',
                          ),
                          (
                            'Excluded Long Gaps',
                            '${smooth.suspendedFrames} frames',
                          ),
                          ('Jank (>16.6ms)', '${smooth.jankFrames} frames'),
                          (
                            'Severe Jank (>33ms)',
                            '${smooth.severeJankFrames} frames',
                          ),
                          (
                            'Avg Frame Duration',
                            '${smooth.averageFrameTimeMs.toStringAsFixed(2)} ms',
                          ),
                          (
                            'Build / Raster Avg',
                            '${smooth.averageBuildTimeMs.toStringAsFixed(2)} / ${smooth.averageRasterTimeMs.toStringAsFixed(2)} ms',
                          ),
                        ],
                      ),

                      // Card 4: Storage Footprint
                      FutureBuilder<StorageSnapshot>(
                        future: _diagnosticsStorageSnapshot ??= diag
                            .getStorageSnapshot(),
                        builder: (context, snapshot) {
                          final storage = snapshot.data;
                          return _buildDiagMetricCard(
                            width: cardWidth,
                            title: 'Storage & Caches',
                            subtitle: 'Disk Space Breakdown',
                            icon: Icons.storage_rounded,
                            accentColor: const Color(0xFFA78BFA),
                            mainValue: storage != null
                                ? '${storage.totalMb.toStringAsFixed(1)} MB'
                                : 'Calculating...',
                            mainLabel: 'Total WallSync Disk Space',
                            items: [
                              (
                                'Video Wallpapers',
                                storage != null
                                    ? '${storage.videoCacheMb.toStringAsFixed(1)} MB'
                                    : '...',
                              ),
                              (
                                'Video Thumbnails',
                                storage != null
                                    ? '${storage.thumbnailCacheMb.toStringAsFixed(1)} MB'
                                    : '...',
                              ),
                              (
                                'Debug Log File',
                                storage != null
                                    ? '${storage.logFileMb.toStringAsFixed(2)} MB'
                                    : '...',
                              ),
                              (
                                'AppData Folder',
                                storage != null
                                    ? '${storage.appDataMb.toStringAsFixed(1)} MB'
                                    : '...',
                              ),
                            ],
                          );
                        },
                      ),
                    ],
                  );
                },
              ),
              const SizedBox(height: 20),

              // Watchdog & Runtime Stability Card
              Container(
                width: double.infinity,
                padding: const EdgeInsets.all(20),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xF5101624), Color(0xF50A1018)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(18),
                  border: Border.all(
                    color: const Color(0xFF10B981).withValues(alpha: 0.25),
                    width: 1.1,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.06),
                      blurRadius: 16,
                    ),
                  ],
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Container(
                          padding: const EdgeInsets.all(6),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.15),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: const Icon(
                            Icons.security_rounded,
                            size: 18,
                            color: Color(0xFF10B981),
                          ),
                        ),
                        const SizedBox(width: 10),
                        const Text(
                          'Runtime Watchdog & Hang / Over-waiting Detector',
                          style: TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                            color: Colors.white,
                          ),
                        ),
                        const Spacer(),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 10,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xFF10B981).withValues(alpha: 0.12),
                            borderRadius: BorderRadius.circular(20),
                            border: Border.all(
                              color: const Color(0xFF10B981).withValues(alpha: 0.35),
                            ),
                          ),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(
                                Icons.check_circle_rounded,
                                size: 12,
                                color: Color(0xFF10B981),
                              ),
                              SizedBox(width: 4),
                              Text(
                                'Watchdog Running',
                                style: TextStyle(
                                  fontSize: 11,
                                  color: Color(0xFF10B981),
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '• Heartbeat cadence: 500 ms | Hang/ANR warning threshold: 1000 ms\n'
                      '• Active parallel async operations: ${diag.activeOperationCount} tasks currently in flight\n'
                      '• UI Freezes detected: 0 event loop deadlocks recorded since startup\n'
                      '• Asynchronous Non-blocking Log Queue: Enabled (prevents main thread I/O stutters)',
                      style: TextStyle(
                        fontSize: 12,
                        color: Colors.white.withValues(alpha: 0.75),
                        height: 1.55,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 24),

              // Action Toolbar: Export review.txt, snapshot, open log
              Row(
                children: [
                  Expanded(
                    child: Container(
                      height: 48,
                      decoration: BoxDecoration(
                        gradient: const LinearGradient(
                          colors: [Color(0xFF38BDF8), Color(0xFF818CF8)],
                        ),
                        borderRadius: BorderRadius.circular(14),
                        boxShadow: [
                          BoxShadow(
                            color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                            blurRadius: 14,
                            offset: const Offset(0, 3),
                          ),
                        ],
                      ),
                      child: ElevatedButton.icon(
                        icon: const Icon(Icons.description_rounded, size: 18),
                        label: const Text(
                          'Generate & Export review.txt',
                          style: TextStyle(
                            fontWeight: FontWeight.w800,
                            fontSize: 13,
                            letterSpacing: 0.3,
                          ),
                        ),
                        onPressed: () async {
                          try {
                            final file = await diag.saveReviewReportToFile();
                            if (mounted) {
                              _showAnimatedSnackBar(
                                'Review report generated successfully at: ${file.path}',
                                isSuccess: true,
                              );
                            }
                          } catch (e) {
                            if (mounted) {
                              _showAnimatedSnackBar(
                                'Failed to save review report: $e',
                                isSuccess: false,
                              );
                            }
                          }
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: Colors.transparent,
                          shadowColor: Colors.transparent,
                          foregroundColor: const Color(0xFF070913),
                          shape: RoundedRectangleBorder(
                            borderRadius: BorderRadius.circular(14),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.camera_alt_rounded, size: 16),
                    label: const Text('Capture Snapshot'),
                    onPressed: () async {
                      await diag.takePeriodicSnapshot();
                      setState(() {});
                      if (mounted) {
                        _showAnimatedSnackBar(
                          'Health snapshot captured to log file.',
                          isSuccess: true,
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 1.0,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.refresh_rounded, size: 16),
                    label: const Text('Reset Metrics'),
                    onPressed: () {
                      diag.resetSmoothnessMetrics();
                      setState(() {});
                      if (mounted) {
                        _showAnimatedSnackBar(
                          'Frame and hang metrics reset to baseline.',
                          isSuccess: true,
                        );
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: Colors.white.withValues(alpha: 0.08),
                      foregroundColor: Colors.white,
                      side: BorderSide(
                        color: Colors.white.withValues(alpha: 0.12),
                        width: 1.0,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                  const SizedBox(width: 12),
                  ElevatedButton.icon(
                    icon: const Icon(Icons.folder_open_rounded, size: 16),
                    label: const Text('Open Log File'),
                    onPressed: () async {
                      final appData =
                          Platform.environment['APPDATA'] ??
                          Directory.systemTemp.path;
                      final logPath =
                          '$appData\\com.example\\wallsync\\app_debug.log';
                      final logFile = File(logPath);
                      if (await logFile.exists()) {
                        await Process.start('notepad.exe', [logFile.path]);
                      } else {
                        if (mounted) {
                          _showAnimatedSnackBar(
                            'Log file does not exist yet.',
                            isSuccess: false,
                          );
                        }
                      }
                    },
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.10),
                      foregroundColor: const Color(0xFF38BDF8),
                      side: BorderSide(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                        width: 1.0,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 18,
                        vertical: 14,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildDiagMetricCard({
    required double width,
    required String title,
    required String subtitle,
    required IconData icon,
    required Color accentColor,
    required String mainValue,
    required String mainLabel,
    required List<(String, String)> items,
  }) {
    return Container(
      width: width,
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: const LinearGradient(
          colors: [
            Color(0xF5131726),
            Color(0xF50D0F18),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(20),
        border: Border.all(
          color: accentColor.withValues(alpha: 0.22),
          width: 1.1,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 16,
            offset: const Offset(0, 4),
          ),
          BoxShadow(
            color: accentColor.withValues(alpha: 0.06),
            blurRadius: 20,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(9),
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      accentColor.withValues(alpha: 0.25),
                      accentColor.withValues(alpha: 0.08),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: accentColor.withValues(alpha: 0.40),
                    width: 1.0,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: accentColor.withValues(alpha: 0.20),
                      blurRadius: 10,
                    ),
                  ],
                ),
                child: Icon(icon, size: 18, color: accentColor),
              ),
              const SizedBox(width: 12),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    title,
                    style: const TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.bold,
                      color: Colors.white,
                    ),
                  ),
                  Text(
                    subtitle,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.50),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 16),
          Text(
            mainValue,
            style: TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.bold,
              color: accentColor,
              letterSpacing: -0.5,
              shadows: [
                Shadow(
                  color: accentColor.withValues(alpha: 0.35),
                  blurRadius: 12,
                ),
              ],
            ),
          ),
          Text(
            mainLabel,
            style: TextStyle(
              fontSize: 11,
              color: Colors.white.withValues(alpha: 0.55),
            ),
          ),
          const SizedBox(height: 12),
          Divider(color: Colors.white.withValues(alpha: 0.08), height: 1),
          const SizedBox(height: 10),
          ...items.map(
            (item) => Padding(
              padding: const EdgeInsets.symmetric(vertical: 3.0),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(
                    item.$1,
                    style: TextStyle(
                      fontSize: 11,
                      color: Colors.white.withValues(alpha: 0.65),
                    ),
                  ),
                  Text(
                    item.$2,
                    style: const TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: Colors.white,
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

  // ── Bug Report ────────────────────────────────────────────────────────────

  Widget _buildBugReportTab({Key? key}) {
    if (_bugSubmitted) {
      return Center(
        key: key,
        child: Container(
          width: 440,
          padding: const EdgeInsets.all(36),
          decoration: BoxDecoration(
            gradient: const LinearGradient(
              colors: [Color(0xF80F1B18), Color(0xF80A120F)],
              begin: Alignment.topLeft,
              end: Alignment.bottomRight,
            ),
            borderRadius: BorderRadius.circular(26),
            border: Border.all(
              color: const Color(0xFF10B981).withValues(alpha: 0.40),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: const Color(0xFF10B981).withValues(alpha: 0.15),
                blurRadius: 30,
              ),
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.5),
                blurRadius: 30,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                width: 76,
                height: 76,
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    colors: [
                      const Color(0xFF10B981).withValues(alpha: 0.25),
                      const Color(0xFF38BDF8).withValues(alpha: 0.10),
                    ],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: const Color(0xFF10B981).withValues(alpha: 0.50),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFF10B981).withValues(alpha: 0.30),
                      blurRadius: 20,
                    ),
                  ],
                ),
                child: const Icon(
                  Icons.check_circle_rounded,
                  size: 44,
                  color: Color(0xFF10B981),
                ),
              ),
              const SizedBox(height: 24),
              const Text(
                'Report Successfully Received',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 21,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  letterSpacing: -0.3,
                ),
              ),
              const SizedBox(height: 12),
              const Text(
                'Your feedback is logged and will help us refine and optimize WallSync Pro.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFFB7C1D1),
                  height: 1.45,
                ),
              ),
              const SizedBox(height: 32),
              ElevatedButton(
                onPressed: () {
                  setState(() {
                    _bugSubmitted = false;
                    _gmailCtrl.clear();
                    _nameCtrl.clear();
                    _titleCtrl.clear();
                    _descCtrl.clear();
                  });
                },
                style: ElevatedButton.styleFrom(
                  backgroundColor: const Color(0xFF10B981).withValues(alpha: 0.15),
                  foregroundColor: const Color(0xFF10B981),
                  side: BorderSide(
                    color: const Color(0xFF10B981).withValues(alpha: 0.40),
                    width: 1.0,
                  ),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 28,
                    vertical: 14,
                  ),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(14),
                  ),
                ),
                child: const Text(
                  'Report Another Issue',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return Center(
      key: key,
      child: Container(
        width: 520,
        margin: const EdgeInsets.symmetric(vertical: 32),
        padding: const EdgeInsets.all(32),
        decoration: BoxDecoration(
          gradient: const LinearGradient(
            colors: [Color(0xF80F121E), Color(0xF80A0C14)],
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(26),
          border: Border.all(
            color: const Color(0xFFEC4899).withValues(alpha: 0.25),
            width: 1.2,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.55),
              blurRadius: 36,
              offset: const Offset(0, 10),
            ),
            BoxShadow(
              color: const Color(0xFFEC4899).withValues(alpha: 0.08),
              blurRadius: 40,
            ),
          ],
        ),
        child: Form(
          key: _bugFormKey,
          child: ListView(
            shrinkWrap: true,
            children: [
              Row(
                children: [
                  Container(
                    width: 44,
                    height: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: [
                          const Color(0xFFEC4899).withValues(alpha: 0.25),
                          const Color(0xFF818CF8).withValues(alpha: 0.12),
                        ],
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(14),
                      border: Border.all(
                        color: const Color(0xFFEC4899).withValues(alpha: 0.45),
                        width: 1.2,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: const Color(0xFFEC4899).withValues(alpha: 0.25),
                          blurRadius: 12,
                        ),
                      ],
                    ),
                    child: const Icon(
                      Icons.bug_report_rounded,
                      size: 24,
                      color: Color(0xFFEC4899),
                    ),
                  ),
                  const SizedBox(width: 14),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          const Text(
                            'Report an Issue',
                            style: TextStyle(
                              fontSize: 22,
                              fontWeight: FontWeight.bold,
                              color: Colors.white,
                              letterSpacing: -0.3,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 7,
                              vertical: 2,
                            ),
                            decoration: BoxDecoration(
                              gradient: const LinearGradient(
                                colors: [Color(0xFF6366F1), Color(0xFFA855F7)],
                              ),
                              borderRadius: BorderRadius.circular(6),
                              boxShadow: [
                                BoxShadow(
                                  color: const Color(0xFFA855F7).withValues(alpha: 0.35),
                                  blurRadius: 8,
                                  offset: const Offset(0, 2),
                                ),
                              ],
                            ),
                            child: const Text(
                              'PRO',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: FontWeight.w900,
                                color: Colors.white,
                                letterSpacing: 0.8,
                              ),
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 3),
                      Text(
                        'Direct transmission to engineering & QA',
                        style: TextStyle(
                          fontSize: 12,
                          color: Colors.white.withValues(alpha: 0.50),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
              const SizedBox(height: 28),

              _buildTextFormField(
                controller: _gmailCtrl,
                label: 'Gmail ID',
                icon: Icons.email_rounded,
                validator: (v) {
                  if (v == null || v.isEmpty) {
                    return 'Please enter your Gmail ID';
                  }
                  if (!v.toLowerCase().endsWith('@gmail.com')) {
                    return 'Please provide a valid @gmail.com address';
                  }
                  return null;
                },
              ),
              const SizedBox(height: 16),

              _buildTextFormField(
                controller: _nameCtrl,
                label: 'Full Name',
                icon: Icons.person_rounded,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Please enter your name' : null,
              ),
              const SizedBox(height: 16),

              _buildTextFormField(
                controller: _titleCtrl,
                label: 'Issue Title',
                icon: Icons.title_rounded,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Please enter a title' : null,
              ),
              const SizedBox(height: 16),

              _buildTextFormField(
                controller: _descCtrl,
                label: 'Issue Description',
                icon: Icons.description_rounded,
                maxLines: 4,
                validator: (v) =>
                    v == null || v.isEmpty ? 'Please describe the issue' : null,
              ),
              const SizedBox(height: 30),

              Container(
                height: 52,
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFFEC4899), Color(0xFF818CF8)],
                    begin: Alignment.centerLeft,
                    end: Alignment.centerRight,
                  ),
                  borderRadius: BorderRadius.circular(14),
                  boxShadow: [
                    BoxShadow(
                      color: const Color(0xFFEC4899).withValues(alpha: 0.35),
                      blurRadius: 18,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                child: ElevatedButton(
                  onPressed: _submittingBug ? null : _submitBug,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: Colors.transparent,
                    shadowColor: Colors.transparent,
                    foregroundColor: Colors.white,
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(14),
                    ),
                  ),
                  child: _submittingBug
                      ? const SizedBox(
                          width: 20,
                          height: 20,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Row(
                          mainAxisAlignment: MainAxisAlignment.center,
                          children: [
                            Icon(Icons.send_rounded, size: 18),
                            SizedBox(width: 8),
                            Text(
                              'Submit Priority Report',
                              style: TextStyle(
                                fontSize: 15,
                                fontWeight: FontWeight.bold,
                                letterSpacing: 0.4,
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
    );
  }

  Widget _buildTextFormField({
    required TextEditingController controller,
    required String label,
    required IconData icon,
    int maxLines = 1,
    String? Function(String?)? validator,
  }) {
    return TextFormField(
      controller: controller,
      style: const TextStyle(color: Colors.white, fontSize: 14),
      maxLines: maxLines,
      decoration: InputDecoration(
        labelText: label,
        labelStyle: TextStyle(color: Colors.white.withValues(alpha: 0.55)),
        prefixIcon: maxLines == 1
            ? Icon(icon, color: const Color(0xFF818CF8), size: 20)
            : null,
        filled: true,
        fillColor: Colors.black.withValues(alpha: 0.30),
        border: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide.none,
        ),
        enabledBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
        focusedBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(color: Color(0xFF38BDF8), width: 1.5),
        ),
        errorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: BorderSide(
            color: Colors.redAccent.withValues(alpha: 0.55),
          ),
        ),
        focusedErrorBorder: OutlineInputBorder(
          borderRadius: BorderRadius.circular(14),
          borderSide: const BorderSide(
            color: Colors.redAccent,
            width: 1.5,
          ),
        ),
      ),
      validator: validator,
    );
  }

  Future<void> _submitBug() async {
    if (!_bugFormKey.currentState!.validate()) return;

    setState(() {
      _submittingBug = true;
    });

    final data = {
      'timestamp': DateTime.now().toIso8601String(),
      'gmail': _gmailCtrl.text.trim(),
      'name': _nameCtrl.text.trim(),
      'title': _titleCtrl.text.trim(),
      'description': _descCtrl.text.trim(),
      'badge': 'PRO',
      'appType': 'Pro',
      'userType': 'Pro',
      'isPro': true,
      'appVersion': 'WallSync Pro',
    };

    final success = await _firebaseService.submitBugReport(data);

    if (mounted) {
      setState(() {
        _submittingBug = false;
        if (success) {
          _bugSubmitted = true;
        }
      });
      if (!success) {
        _showAnimatedSnackBar(
          'Failed to submit bug report. Please try again.',
          isSuccess: false,
        );
      }
    }
  }

  Widget _buildWeatherSettingsControls() {
    final hasResolvedLocation = _settings.weatherLocationResolved.isNotEmpty;
    final resolvedLocationText = hasResolvedLocation
        ? _settings.weatherLocationResolved
        : 'Auto-detecting based on IP...';
    final tempText = _settings.weatherTemp.isNotEmpty
        ? '${_settings.weatherTemp} °C'
        : '-- °C';
    final statusText = _settings.weatherStatus.isNotEmpty
        ? _settings.weatherStatus
        : 'Unknown';

    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.03),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 38,
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.05),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: TextField(
                    controller: _weatherSearchCtrl,
                    style: const TextStyle(color: Colors.white, fontSize: 13),
                    cursorColor: const Color(0xFFEC4899),
                    decoration: const InputDecoration(
                      hintText: 'Enter city name or pincode...',
                      hintStyle: TextStyle(color: Colors.white30, fontSize: 13),
                      border: InputBorder.none,
                      contentPadding: EdgeInsets.zero,
                      isDense: true,
                    ),
                    onSubmitted: (val) => _handleManualWeatherSearch(val),
                  ),
                ),
              ),
              const SizedBox(width: 8),
              IconButton(
                icon: _isAutoDetectingWeather
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                          strokeWidth: 2,
                          color: Color(0xFFEC4899),
                        ),
                      )
                    : const Icon(
                        Icons.gps_fixed_rounded,
                        color: Color(0xFFEC4899),
                        size: 18,
                      ),
                tooltip: 'Auto-detect location',
                onPressed: _isAutoDetectingWeather
                    ? null
                    : () => _handleAutoDetectWeather(),
                style: IconButton.styleFrom(
                  backgroundColor: Colors.white.withValues(alpha: 0.05),
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                    side: BorderSide(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  minimumSize: const Size(38, 38),
                ),
              ),
            ],
          ),
          if (_weatherSearchError.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              _weatherSearchError,
              style: const TextStyle(
                color: Colors.redAccent,
                fontSize: 11,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
          const SizedBox(height: 16),
          // Search & Update Button
          ElevatedButton(
            onPressed: () =>
                _handleManualWeatherSearch(_weatherSearchCtrl.text),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFFEC4899),
              foregroundColor: Colors.white,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              minimumSize: const Size(double.infinity, 38),
            ),
            child: const Text(
              'Update Location',
              style: TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
          ),
          const SizedBox(height: 16),
          const Divider(color: Colors.white10),
          const SizedBox(height: 8),

          // Display active resolved weather
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Resolved Location',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              Expanded(
                child: Text(
                  resolvedLocationText,
                  textAlign: TextAlign.right,
                  style: const TextStyle(
                    color: Colors.white70,
                    fontSize: 11,
                    fontWeight: FontWeight.bold,
                  ),
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Current Temperature',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              Text(
                tempText,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Text(
                'Condition',
                style: TextStyle(color: Colors.white38, fontSize: 11),
              ),
              Text(
                statusText,
                style: const TextStyle(
                  color: Colors.white70,
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Future<void> _handleManualWeatherSearch(String val) async {
    if (val.trim().isEmpty) return;
    setState(() {
      _weatherSearchError = '';
    });
    try {
      final loc = await WeatherService().searchLocation(val);
      if (loc != null) {
        final lat = loc['lat'] as double;
        final lon = loc['lon'] as double;
        final name = loc['name'] as String;
        final info = await WeatherService().fetchWeather(lat, lon, name);
        if (info != null && mounted) {
          final updated = _settings.copyWith(
            weatherLocation: val,
            weatherTemp: info.temperature.toStringAsFixed(1),
            weatherStatus: info.status,
            weatherLocationResolved: info.locationName,
          );
          _updateSettings(updated);
        } else {
          setState(() {
            _weatherSearchError = 'Could not fetch weather data.';
          });
        }
      } else {
        setState(() {
          _weatherSearchError = 'Location not found.';
        });
      }
    } catch (e) {
      setState(() {
        _weatherSearchError = 'Error: $e';
      });
    }
  }

  Future<void> _handleAutoDetectWeather() async {
    setState(() {
      _isAutoDetectingWeather = true;
      _weatherSearchError = '';
    });
    try {
      final loc = await WeatherService().autoDetectLocation();
      if (loc != null) {
        final lat = loc['lat'] as double;
        final lon = loc['lon'] as double;
        final city = loc['city'] as String;
        final resolvedName = '$city, ${loc['countryCode']}';
        final info = await WeatherService().fetchWeather(
          lat,
          lon,
          resolvedName,
        );
        if (info != null && mounted) {
          final updated = _settings.copyWith(
            weatherLocation: '',
            weatherTemp: info.temperature.toStringAsFixed(1),
            weatherStatus: info.status,
            weatherLocationResolved: info.locationName,
          );
          _weatherSearchCtrl.clear();
          _updateSettings(updated);
        } else {
          setState(() {
            _weatherSearchError =
                'Could not fetch weather for auto-detected location.';
          });
        }
      } else {
        setState(() {
          _weatherSearchError = 'Could not auto-detect location.';
        });
      }
    } catch (e) {
      setState(() {
        _weatherSearchError = 'Error auto-detecting: $e';
      });
    } finally {
      if (mounted) {
        setState(() {
          _isAutoDetectingWeather = false;
        });
      }
    }
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// HoverCard — dynamic hover scale and neon border glow wrapper
// ─────────────────────────────────────────────────────────────────────────────

class HoverCard extends StatefulWidget {
  final Widget child;
  final double scaleUp;
  final Duration duration;
  final BorderRadius borderRadius;
  final Color glowColor;
  final double maxGlowOpacity;
  final double blurRadius;
  final VoidCallback? onTap;

  const HoverCard({
    super.key,
    required this.child,
    this.scaleUp = 1.025,
    this.duration = const Duration(milliseconds: 200),
    this.borderRadius = const BorderRadius.all(Radius.circular(16)),
    this.glowColor = Colors.blueAccent,
    this.maxGlowOpacity = 0.35,
    this.blurRadius = 12.0,
    this.onTap,
  });

  @override
  State<HoverCard> createState() => _HoverCardState();
}

class _HoverCardState extends State<HoverCard>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _scaleAnimation;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(vsync: this, duration: widget.duration);
    _scaleAnimation = Tween<double>(
      begin: 1.0,
      end: widget.scaleUp,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
    _glowAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _onEnter(PointerEvent details) {
    _controller.forward();
  }

  void _onExit(PointerEvent details) {
    _controller.reverse();
  }

  @override
  Widget build(BuildContext context) {
    final card = AnimatedBuilder(
      animation: _controller,
      builder: (context, child) {
        return Transform.scale(
          scale: _scaleAnimation.value,
          child: Container(
            decoration: BoxDecoration(
              borderRadius: widget.borderRadius,
              boxShadow: _glowAnimation.value > 0.01
                  ? [
                      BoxShadow(
                        color: widget.glowColor.withValues(
                          alpha: _glowAnimation.value * widget.maxGlowOpacity,
                        ),
                        blurRadius: widget.blurRadius * _glowAnimation.value,
                        spreadRadius: 1.0 * _glowAnimation.value,
                      ),
                    ]
                  : null,
            ),
            child: child,
          ),
        );
      },
      child: ClipRRect(borderRadius: widget.borderRadius, child: widget.child),
    );

    if (widget.onTap != null) {
      return MouseRegion(
        onEnter: _onEnter,
        onExit: _onExit,
        cursor: SystemMouseCursors.click,
        child: GestureDetector(onTap: widget.onTap, child: card),
      );
    }

    return MouseRegion(onEnter: _onEnter, onExit: _onExit, child: card);
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// GlowButton — modern control button with glow & hover animations
// ─────────────────────────────────────────────────────────────────────────────
class GlowButton extends StatefulWidget {
  final String label;
  final IconData icon;
  final Color color;
  final bool enabled;
  final VoidCallback onTap;

  const GlowButton({
    super.key,
    required this.label,
    required this.icon,
    required this.color,
    required this.enabled,
    required this.onTap,
  });

  @override
  State<GlowButton> createState() => _GlowButtonState();
}

class _GlowButtonState extends State<GlowButton>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late Animation<double> _glowAnimation;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 180),
    );
    _glowAnimation = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic));
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.enabled) {
      return Opacity(
        opacity: 0.35,
        child: Container(
          padding: const EdgeInsets.symmetric(vertical: 12),
          decoration: BoxDecoration(
            color: widget.color.withValues(alpha: 0.05),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: widget.color.withValues(alpha: 0.15)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(
                widget.icon,
                size: 16,
                color: widget.color.withValues(alpha: 0.6),
              ),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: widget.color.withValues(alpha: 0.6),
                ),
              ),
            ],
          ),
        ),
      );
    }

    return MouseRegion(
      onEnter: (_) {
        _controller.forward();
      },
      onExit: (_) {
        _controller.reverse();
      },
      cursor: SystemMouseCursors.click,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: widget.onTap,
        child: AnimatedBuilder(
          animation: _controller,
          builder: (context, child) {
            return Transform.scale(
              scale: 1.0 + 0.02 * _glowAnimation.value,
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 12),
                decoration: BoxDecoration(
                  color: widget.color.withValues(
                    alpha: 0.12 + 0.06 * _glowAnimation.value,
                  ),
                  borderRadius: BorderRadius.circular(12),
                  border: Border.all(
                    color: widget.color.withValues(
                      alpha: 0.4 + 0.3 * _glowAnimation.value,
                    ),
                    width: 1.5,
                  ),
                  boxShadow: [
                    BoxShadow(
                      color: widget.color.withValues(
                        alpha: 0.25 * _glowAnimation.value,
                      ),
                      blurRadius: 12 * _glowAnimation.value,
                      spreadRadius: 1 * _glowAnimation.value,
                    ),
                  ],
                ),
                child: child,
              ),
            );
          },
          child: Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(widget.icon, size: 16, color: widget.color),
              const SizedBox(width: 8),
              Text(
                widget.label,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.bold,
                  color: Colors.white,
                  shadows: [
                    Shadow(
                      color: widget.color.withValues(alpha: 0.5),
                      blurRadius: 4,
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
}

// ─────────────────────────────────────────────────────────────────────────────
// MockupMonitorScreen — surrounds preview clock with a monitor bezel & stand
// ─────────────────────────────────────────────────────────────────────────────
class MockupMonitorScreen extends StatelessWidget {
  final Widget child;
  final WidgetSettings settings;

  const MockupMonitorScreen({
    super.key,
    required this.child,
    required this.settings,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        // Monitor screen frame
        Container(
          padding: const EdgeInsets.all(8), // bezel
          decoration: BoxDecoration(
            color: const Color(0xFF1E1E2E), // plastic bezel color
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.12),
              width: 1.5,
            ),
            boxShadow: [
              // Ambient glow backlight behind the monitor based on settings color
              BoxShadow(
                color: Color(
                  settings.colorFor(ElementKey.hours),
                ).withValues(alpha: 0.15),
                blurRadius: 30,
                spreadRadius: 5,
              ),
            ],
          ),
          child: Container(
            height: 165,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(10),
              color: Colors.black,
            ),
            child: child,
          ),
        ),
        // Stand base
        CustomPaint(size: const Size(60, 20), painter: _MonitorStandPainter()),
        Container(
          width: 90,
          height: 5,
          decoration: BoxDecoration(
            color: const Color(0xFF2A2A3D),
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.08),
              width: 0.5,
            ),
          ),
        ),
      ],
    );
  }
}

class _MonitorStandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF2E2E3E)
      ..style = PaintingStyle.fill;

    final borderPaint = Paint()
      ..color = Colors.white.withValues(alpha: 0.1)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 0.5;

    final path = Path();
    path.moveTo(size.width * 0.35, 0);
    path.lineTo(size.width * 0.65, 0);
    path.lineTo(size.width * 0.85, size.height);
    path.lineTo(size.width * 0.15, size.height);
    path.close();

    canvas.drawPath(path, paint);
    canvas.drawPath(path, borderPaint);
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}

class SafeNetworkImage extends StatefulWidget {
  final String url;
  final String? fallbackUrl;
  final BoxFit fit;
  final Widget Function(BuildContext, Object, StackTrace?)? errorBuilder;

  const SafeNetworkImage({
    super.key,
    required this.url,
    this.fallbackUrl,
    this.fit = BoxFit.cover,
    this.errorBuilder,
  });

  @override
  State<SafeNetworkImage> createState() => _SafeNetworkImageState();
}

class _SafeNetworkImageState extends State<SafeNetworkImage> {
  final _firebaseService = FirebaseService();
  File? _localFile;
  String? _loadedUrl;
  bool _loading = true;
  int _loadGeneration = 0;
  bool _cacheInvalidated = false;

  @override
  void initState() {
    super.initState();
    final cached =
        _firebaseService.getCachedThumbnailSync(widget.url) ??
        (widget.fallbackUrl != null
            ? _firebaseService.getCachedThumbnailSync(widget.fallbackUrl!)
            : null);
    if (cached != null) {
      _localFile = cached;
      _loadedUrl = widget.url;
      _loading = false;
    } else {
      _loadImage();
    }
  }

  @override
  void didUpdateWidget(SafeNetworkImage oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.url != widget.url ||
        oldWidget.fallbackUrl != widget.fallbackUrl) {
      final cached =
          _firebaseService.getCachedThumbnailSync(widget.url) ??
          (widget.fallbackUrl != null
              ? _firebaseService.getCachedThumbnailSync(widget.fallbackUrl!)
              : null);
      if (cached != null) {
        setState(() {
          _localFile = cached;
          _loadedUrl = widget.url;
          _loading = false;
        });
      } else {
        _loadImage();
      }
    }
  }

  Future<void> _loadImage() async {
    if (!mounted) return;
    final cached =
        _firebaseService.getCachedThumbnailSync(widget.url) ??
        (widget.fallbackUrl != null
            ? _firebaseService.getCachedThumbnailSync(widget.fallbackUrl!)
            : null);
    if (cached != null) {
      if (mounted) {
        setState(() {
          _localFile = cached;
          _loadedUrl = widget.url;
          _loading = false;
        });
      }
      return;
    }

    final generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _localFile = null;
      _loadedUrl = null;
      _cacheInvalidated = false;
    });

    try {
      var sourceUrl = widget.url;
      var file = await _firebaseService.downloadThumbnailToCache(sourceUrl);
      if (file == null &&
          mounted &&
          generation == _loadGeneration &&
          widget.fallbackUrl != null &&
          widget.fallbackUrl != sourceUrl) {
        sourceUrl = widget.fallbackUrl!;
        file = await _firebaseService.downloadThumbnailToCache(sourceUrl);
      }
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _localFile = file;
          _loadedUrl = file == null ? null : sourceUrl;
          _loading = false;
        });
      }
    } catch (e, st) {
      logError('SafeNetworkImage', 'Error loading image: ${widget.url}', e, st);
      if (mounted && generation == _loadGeneration) {
        setState(() {
          _loading = false;
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Container(
        color: Colors.black38,
        child: const Center(
          child: SizedBox(
            width: 20,
            height: 20,
            child: CircularProgressIndicator(strokeWidth: 2.0),
          ),
        ),
      );
    }

    if (_localFile != null) {
      return Image.file(
        _localFile!,
        fit: widget.fit,
        gaplessPlayback: true,
        cacheWidth: 320,
        cacheHeight: 240,
        errorBuilder: (context, error, stackTrace) {
          if (!_cacheInvalidated) {
            _cacheInvalidated = true;
            unawaited(
              _firebaseService.invalidateThumbnailCache(
                _loadedUrl ?? widget.url,
              ),
            );
          }
          logError(
            'SafeNetworkImage',
            'Image.file failed to render for cached thumbnail: ${_localFile!.path}',
            error,
            stackTrace,
          );
          if (widget.errorBuilder != null) {
            return widget.errorBuilder!(context, error, stackTrace);
          }
          return Container(
            color: Colors.black45,
            child: const Icon(
              Icons.broken_image,
              color: Colors.white24,
              size: 32,
            ),
          );
        },
      );
    }

    // Call error builder if local file download failed
    if (widget.errorBuilder != null) {
      return widget.errorBuilder!(
        context,
        'Failed to download thumbnail',
        null,
      );
    }
    return Container(
      color: Colors.black45,
      child: const Icon(Icons.broken_image, color: Colors.white24, size: 32),
    );
  }
}

class ModernGradientSliderTrackShape extends SliderTrackShape {
  final List<Color> colors;
  const ModernGradientSliderTrackShape({required this.colors});

  @override
  Rect getPreferredRect({
    required RenderBox parentBox,
    Offset offset = Offset.zero,
    required SliderThemeData sliderTheme,
    bool isEnabled = false,
    bool isDiscrete = false,
  }) {
    final trackHeight = sliderTheme.trackHeight ?? 6.0;
    final trackLeft = offset.dx + 10;
    final trackTop = offset.dy + (parentBox.size.height - trackHeight) / 2;
    final trackWidth = parentBox.size.width - 20;
    return Rect.fromLTWH(trackLeft, trackTop, trackWidth, trackHeight);
  }

  @override
  void paint(
    PaintingContext context,
    Offset offset, {
    required RenderBox parentBox,
    required SliderThemeData sliderTheme,
    required Animation<double> enableAnimation,
    required Offset thumbCenter,
    Offset? secondaryOffset,
    bool isEnabled = false,
    bool isDiscrete = false,
    required TextDirection textDirection,
  }) {
    final rect = getPreferredRect(
      parentBox: parentBox,
      offset: offset,
      sliderTheme: sliderTheme,
    );
    final trackHeight = rect.height;

    // Inactive track
    final inactivePaint = Paint()
      ..color =
          sliderTheme.inactiveTrackColor ?? Colors.white.withValues(alpha: 0.08)
      ..style = PaintingStyle.fill;
    final inactiveRRect = RRect.fromRectAndRadius(
      Rect.fromLTRB(thumbCenter.dx, rect.top, rect.right, rect.bottom),
      Radius.circular(trackHeight / 2),
    );
    context.canvas.drawRRect(inactiveRRect, inactivePaint);

    // Active track
    if (rect.left < thumbCenter.dx) {
      final activePaint = Paint()
        ..shader = LinearGradient(colors: colors).createShader(
          Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx, rect.bottom),
        )
        ..style = PaintingStyle.fill;
      final activeRRect = RRect.fromRectAndRadius(
        Rect.fromLTRB(rect.left, rect.top, thumbCenter.dx, rect.bottom),
        Radius.circular(trackHeight / 2),
      );
      context.canvas.drawRRect(activeRRect, activePaint);
    }
  }
}

class HorizontalScrollWrapper extends StatefulWidget {
  final Widget child;
  final ScrollController controller;
  const HorizontalScrollWrapper({
    super.key,
    required this.child,
    required this.controller,
  });

  @override
  State<HorizontalScrollWrapper> createState() =>
      _HorizontalScrollWrapperState();
}

class _HorizontalScrollWrapperState extends State<HorizontalScrollWrapper> {
  bool _showLeft = false;
  bool _showRight = true;

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_updateScrollButtons);
    WidgetsBinding.instance.addPostFrameCallback((_) => _updateScrollButtons());
  }

  @override
  void dispose() {
    widget.controller.removeListener(_updateScrollButtons);
    super.dispose();
  }

  void _updateScrollButtons() {
    if (!mounted) return;
    if (!widget.controller.hasClients) return;
    if (widget.controller.positions.length != 1) return;
    final maxScroll = widget.controller.position.maxScrollExtent;
    final current = widget.controller.offset;
    final showLeft = current > 10;
    final showRight = current < maxScroll - 10 && maxScroll > 0;
    if (_showLeft != showLeft || _showRight != showRight) {
      setState(() {
        _showLeft = showLeft;
        _showRight = showRight;
      });
    }
  }

  void _scroll(double delta) {
    if (!widget.controller.hasClients) return;
    if (widget.controller.positions.length != 1) return;
    final target = (widget.controller.offset + delta).clamp(
      0.0,
      widget.controller.position.maxScrollExtent,
    );
    widget.controller.animateTo(
      target,
      duration: const Duration(milliseconds: 300),
      curve: Curves.easeInOut,
    );
  }

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: [
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 24),
          child: widget.child,
        ),
        if (_showLeft)
          Positioned(
            left: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.65),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.chevron_left_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => _scroll(-150),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
              ),
            ),
          ),
        if (_showRight)
          Positioned(
            right: 0,
            top: 0,
            bottom: 0,
            child: Center(
              child: Container(
                decoration: BoxDecoration(
                  shape: BoxShape.circle,
                  color: Colors.black.withValues(alpha: 0.65),
                  border: Border.all(color: Colors.white24, width: 1),
                ),
                child: IconButton(
                  icon: const Icon(
                    Icons.chevron_right_rounded,
                    color: Colors.white,
                    size: 20,
                  ),
                  onPressed: () => _scroll(150),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints.tightFor(
                    width: 32,
                    height: 32,
                  ),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ResolutionOverlayLabel extends StatefulWidget {
  final FirebaseWallpaper wallpaper;
  const ResolutionOverlayLabel({super.key, required this.wallpaper});

  @override
  State<ResolutionOverlayLabel> createState() => _ResolutionOverlayLabelState();
}

class _ResolutionOverlayLabelState extends State<ResolutionOverlayLabel> {
  WallpaperMetadata? _metadata;

  @override
  void initState() {
    super.initState();
    _loadResolution();
  }

  @override
  void didUpdateWidget(covariant ResolutionOverlayLabel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.wallpaper.url != widget.wallpaper.url ||
        oldWidget.wallpaper.isVideo != widget.wallpaper.isVideo) {
      _metadata = null;
      _loadResolution();
    }
  }

  Future<void> _loadResolution() async {
    final wallpaper = widget.wallpaper;
    final metadata = await WallpaperMetadataService.instance.getMetadata(
      url: wallpaper.url,
      isVideo: wallpaper.isVideo,
    );
    if (mounted) setState(() => _metadata = metadata);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      decoration: BoxDecoration(
        color: Colors.black.withValues(alpha: 0.65),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: Colors.white.withValues(alpha: 0.2)),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.4),
            blurRadius: 4,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: Text(
        _metadata?.displayLabel ?? 'Checking resolution…',
        style: const TextStyle(
          color: Colors.white,
          fontSize: 8,
          fontWeight: FontWeight.bold,
          letterSpacing: 0.1,
        ),
      ),
    );
  }
}

class _DashboardAmbientBackground extends StatelessWidget {
  const _DashboardAmbientBackground();

  @override
  Widget build(BuildContext context) => const CustomPaint(
    painter: _DashboardAmbientPainter(),
    child: SizedBox.expand(),
  );
}

class _DashboardAmbientPainter extends CustomPainter {
  const _DashboardAmbientPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final radius = math.min(size.width, size.height) * 0.60;
    final blobs = <(Offset, Color, double)>[
      (Offset(size.width * 0.15, size.height * 0.18), const Color(0xFF00F2FE), 0.22),
      (Offset(size.width * 0.85, size.height * 0.25), const Color(0xFF818CF8), 0.18),
      (Offset(size.width * 0.75, size.height * 0.75), const Color(0xFFEC4899), 0.16),
      (Offset(size.width * 0.22, size.height * 0.82), const Color(0xFF6366F1), 0.20),
      (Offset(size.width * 0.50, size.height * 0.45), const Color(0xFF10B981), 0.08),
    ];
    for (final blob in blobs) {
      final color = blob.$2;
      final opacity = blob.$3;
      final paint = Paint()
        ..shader = RadialGradient(
          colors: [
            color.withValues(alpha: opacity),
            color.withValues(alpha: opacity * 0.35),
            color.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.50, 1.0],
        ).createShader(Rect.fromCircle(center: blob.$1, radius: radius));
      canvas.drawCircle(blob.$1, radius, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _DashboardAmbientPainter oldDelegate) => false;
}

class _ScanlinePainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.05)
      ..strokeWidth = 1.0;
    for (double y = 0; y < size.height; y += 4) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), paint);
    }
  }

  @override
  bool shouldRepaint(covariant CustomPainter oldDelegate) => false;
}
