import 'dart:async';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_svg/flutter_svg.dart';
import '../services/custom_font_service.dart';
import '../services/custom_asset_service.dart';

/// Studio tabs available in the unified Cloud Studio dialog.
enum CloudStudioTab {
  fonts,
  gifs,
  icons,
}

/// Full-featured Cloud Studio, Asset Downloader, and Live Preview modal for:
/// 1. Google Fonts & Typography
/// 2. Animating GIF Icons (from Croenix/Font Gifs folder)
/// 3. Static & Vector Icons PNG/SVG (from Croenix/Font Icons folder)
class FontDownloadDialog extends StatefulWidget {
  /// Optional callback invoked when the user selects a font to apply to their widget.
  final void Function(String fontFamily)? onSelectFont;

  /// Optional callback invoked when the user selects a downloaded GIF or Icon asset.
  final void Function(String assetPath)? onSelectAsset;

  /// Currently active font family name (for highlighting).
  final String? currentFont;

  /// Initial tab to display upon opening.
  final CloudStudioTab initialTab;

  const FontDownloadDialog({
    super.key,
    this.onSelectFont,
    this.onSelectAsset,
    this.currentFont,
    this.initialTab = CloudStudioTab.fonts,
  });

  /// Static helper to display the dialog cleanly from any view or inspector.
  static Future<String?> show(
    BuildContext context, {
    String? currentFont,
    CloudStudioTab initialTab = CloudStudioTab.fonts,
    void Function(String fontFamily)? onSelectFont,
    void Function(String assetPath)? onSelectAsset,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: FontDownloadDialog(
          currentFont: currentFont,
          initialTab: initialTab,
          onSelectFont: onSelectFont,
          onSelectAsset: onSelectAsset,
        ),
      ),
    );
  }

  @override
  State<FontDownloadDialog> createState() => _FontDownloadDialogState();
}

class _FontDownloadDialogState extends State<FontDownloadDialog> {
  final CustomFontService _fontService = CustomFontService.instance;
  final CustomAssetService _assetService = CustomAssetService.instance;

  late CloudStudioTab _activeTab;

  // ── Fonts Tab State ────────────────────────────────────────────────────────
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _previewTextController = TextEditingController(
    text: '12:45 PM • WallSync 2026',
  );
  String _searchQuery = '';
  String _selectedCategory = 'All';
  double _previewFontSize = 26.0;
  bool _filterOnlyDownloaded = false;
  final Set<String> _singleDownloadingFamilies = <String>{};

  // ── Assets (Gifs & Icons) Tab State ────────────────────────────────────────
  final TextEditingController _assetSearchController = TextEditingController();
  String _assetSearchQuery = '';
  String _selectedAssetCategory = 'All';
  bool _filterOnlyDownloadedAssets = false;
  final Set<String> _singleDownloadingAssets = <String>{};

  static const List<String> _previewPresets = [
    '12:45 PM • WallSync 2026',
    '24°C Cyberpunk • 1013 hPa',
    '0123456789 • TIME',
    'The quick brown fox jumps',
    'NEON DOCK HUD',
  ];

  @override
  void initState() {
    super.initState();
    _activeTab = widget.initialTab;

    _fontService.addListener(_onServiceUpdate);
    _assetService.addListener(_onServiceUpdate);

    if (!_fontService.isInitialized) {
      _fontService.init();
    } else {
      unawaited(_fontService.checkForUpdates(silent: true));
    }

    if (!_assetService.isInitialized) {
      _assetService.init();
    } else {
      unawaited(_assetService.checkForUpdates(silent: true));
    }
  }

  @override
  void dispose() {
    _fontService.removeListener(_onServiceUpdate);
    _assetService.removeListener(_onServiceUpdate);
    _searchController.dispose();
    _previewTextController.dispose();
    _assetSearchController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  // ── Filtering Logic ────────────────────────────────────────────────────────
  List<FontFamilyItem> _getFilteredFamilies() {
    return _fontService.families.where((fam) {
      if (_selectedCategory != 'All' && fam.category != _selectedCategory) {
        return false;
      }
      if (_filterOnlyDownloaded && !fam.isDownloaded) {
        return false;
      }
      if (_searchQuery.trim().isNotEmpty) {
        final query = _searchQuery.toLowerCase().trim();
        final matchName = fam.familyName.toLowerCase().contains(query);
        final matchDesigner = fam.displayDesigner.toLowerCase().contains(query);
        final matchCategory = fam.category.toLowerCase().contains(query);
        final matchFile = fam.mainFontFile.toLowerCase().contains(query);
        if (!matchName && !matchDesigner && !matchCategory && !matchFile) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  List<CloudAssetItem> _getFilteredAssets(CloudAssetType type) {
    final list = type == CloudAssetType.gif
        ? _assetService.getGifs()
        : _assetService.getIcons();

    return list.where((asset) {
      if (_selectedAssetCategory != 'All' &&
          asset.category != _selectedAssetCategory) {
        return false;
      }
      if (_filterOnlyDownloadedAssets && !asset.isDownloaded) {
        return false;
      }
      if (_assetSearchQuery.trim().isNotEmpty) {
        final query = _assetSearchQuery.toLowerCase().trim();
        final matchName = asset.displayName.toLowerCase().contains(query);
        final matchFile = asset.fileName.toLowerCase().contains(query);
        final matchCat = asset.category.toLowerCase().contains(query);
        if (!matchName && !matchFile && !matchCat) {
          return false;
        }
      }
      return true;
    }).toList();
  }

  @override
  Widget build(BuildContext context) {
    final filteredFamilies = _getFilteredFamilies();
    final fontCategories = [
      'All',
      ...{for (var f in _fontService.families) f.category},
    ];

    final downloadedFonts =
        _fontService.families.where((f) => f.isDownloaded).length;
    final totalFonts = _fontService.families.length;

    final gifs = _assetService.getGifs();
    final downloadedGifs = gifs.where((g) => g.isDownloaded).length;
    final totalGifs = gifs.length;

    final icons = _assetService.getIcons();
    final downloadedIcons = icons.where((i) => i.isDownloaded).length;
    final totalIcons = icons.length;

    return Container(
      width: 1080,
      height: 740,
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF0F131F),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
          width: 1.2,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.7),
            blurRadius: 32,
            offset: const Offset(0, 8),
          ),
        ],
      ),
      child: Column(
        children: [
          // ── Top Header Bar with Tab Navigation ──────────────────────────
          _buildHeader(
            downloadedFonts: downloadedFonts,
            totalFonts: totalFonts,
            downloadedGifs: downloadedGifs,
            totalGifs: totalGifs,
            downloadedIcons: downloadedIcons,
            totalIcons: totalIcons,
          ),

          // ── Tab Body Content ─────────────────────────────────────────────
          Expanded(
            child: switch (_activeTab) {
              CloudStudioTab.fonts => _buildFontsView(
                  filteredFamilies: filteredFamilies,
                  fontCategories: fontCategories,
                  totalCount: totalFonts,
                ),
              CloudStudioTab.gifs => _buildGifsView(
                  filteredGifs: _getFilteredAssets(CloudAssetType.gif),
                  totalCount: totalGifs,
                ),
              CloudStudioTab.icons => _buildIconsView(
                  filteredIcons: _getFilteredAssets(CloudAssetType.icon),
                  totalCount: totalIcons,
                ),
            },
          ),
        ],
      ),
    );
  }

  // ── Sub-component: Header Bar with Tab Switcher ──────────────────────────
  Widget _buildHeader({
    required int downloadedFonts,
    required int totalFonts,
    required int downloadedGifs,
    required int totalGifs,
    required int downloadedIcons,
    required int totalIcons,
  }) {
    final fontBatch = _fontService.batchProgress;
    final assetBatch = _assetService.batchProgress;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
      decoration: BoxDecoration(
        color: const Color(0xFF161B2E),
        border: Border(
          bottom: BorderSide(
            color: Colors.white.withValues(alpha: 0.08),
          ),
        ),
      ),
      child: Row(
        children: [
          // Logo & Title
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.all(7),
                decoration: BoxDecoration(
                  gradient: const LinearGradient(
                    colors: [Color(0xFF38BDF8), Color(0xFFA855F7)],
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                  ),
                  borderRadius: BorderRadius.circular(9),
                ),
                child: const Icon(
                  Icons.auto_awesome_motion_rounded,
                  color: Colors.white,
                  size: 18,
                ),
              ),
              const SizedBox(width: 10),
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: const [
                  Text(
                    'Cloud Studio',
                    style: TextStyle(
                      color: Colors.white,
                      fontSize: 14.5,
                      fontWeight: FontWeight.bold,
                      letterSpacing: 0.3,
                    ),
                  ),
                  Text(
                    'Croenix/Font Repository',
                    style: TextStyle(
                      color: Colors.white54,
                      fontSize: 10,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(width: 16),

          // Centered Segmented Tab Selector (Flexible & scrollable so it never overflows)
          Expanded(
            child: Center(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Container(
                  padding: const EdgeInsets.all(3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF0B0E17),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.08),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      _buildTabPill(
                        tab: CloudStudioTab.fonts,
                        label: 'Fonts',
                        countStr: '$downloadedFonts/$totalFonts',
                        icon: Icons.font_download_rounded,
                      ),
                      const SizedBox(width: 4),
                      _buildTabPill(
                        tab: CloudStudioTab.gifs,
                        label: 'Animated GIFs',
                        countStr: '$downloadedGifs/$totalGifs',
                        icon: Icons.animation_rounded,
                      ),
                      const SizedBox(width: 4),
                      _buildTabPill(
                        tab: CloudStudioTab.icons,
                        label: 'Icons PNG/SVG',
                        countStr: '$downloadedIcons/$totalIcons',
                        icon: Icons.image_outlined,
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),

          // Actions Row (Download All + Close)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (_activeTab == CloudStudioTab.fonts)
                ElevatedButton.icon(
                  icon: fontBatch.isDownloading
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_download_rounded, size: 15),
                  label: Text(
                    fontBatch.isDownloading ? 'Downloading...' : 'Download All Fonts',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF0284C7),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: fontBatch.isDownloading
                      ? null
                      : () => _fontService.downloadAllFonts(),
                )
              else if (_activeTab == CloudStudioTab.gifs)
                ElevatedButton.icon(
                  icon: assetBatch.isDownloading
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_download_rounded, size: 15),
                  label: Text(
                    assetBatch.isDownloading ? 'Downloading...' : 'Download All GIFs',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF8B5CF6),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: assetBatch.isDownloading
                      ? null
                      : () => _assetService.downloadAllAssets(type: CloudAssetType.gif),
                )
              else
                ElevatedButton.icon(
                  icon: assetBatch.isDownloading
                      ? const SizedBox(
                          width: 13,
                          height: 13,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        )
                      : const Icon(Icons.cloud_download_rounded, size: 15),
                  label: Text(
                    assetBatch.isDownloading ? 'Downloading...' : 'Download All Icons',
                    style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFF10B981),
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                    ),
                  ),
                  onPressed: assetBatch.isDownloading
                      ? null
                      : () => _assetService.downloadAllAssets(type: CloudAssetType.icon),
                ),
              const SizedBox(width: 8),
              IconButton(
                icon: const Icon(Icons.close_rounded, color: Colors.white70, size: 20),
                tooltip: 'Close Studio',
                onPressed: () => Navigator.of(context).pop(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTabPill({
    required CloudStudioTab tab,
    required String label,
    required String countStr,
    required IconData icon,
  }) {
    final isSelected = _activeTab == tab;

    return InkWell(
      key: ValueKey('tab_${tab.name}'),
      onTap: () {
        setState(() {
          _activeTab = tab;
          _selectedAssetCategory = 'All';
          _assetSearchQuery = '';
          _assetSearchController.clear();
        });
      },
      borderRadius: BorderRadius.circular(8),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 180),
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: isSelected
              ? const Color(0xFF38BDF8).withValues(alpha: 0.18)
              : Colors.transparent,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF38BDF8).withValues(alpha: 0.6)
                : Colors.transparent,
            width: 1,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              icon,
              size: 14,
              color: isSelected ? const Color(0xFF38BDF8) : Colors.white60,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                color: isSelected ? Colors.white : Colors.white70,
                fontSize: 11.5,
                fontWeight: isSelected ? FontWeight.bold : FontWeight.w500,
              ),
            ),
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
              decoration: BoxDecoration(
                color: isSelected
                    ? const Color(0xFF38BDF8).withValues(alpha: 0.3)
                    : Colors.white.withValues(alpha: 0.08),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Text(
                countStr,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF38BDF8) : Colors.white54,
                  fontSize: 9.5,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // ── VIEW 1: FONTS & TYPOGRAPHY STUDIO ──────────────────────────────────────
  // ═════════════════════════════════════════════════════════════════════════════
  Widget _buildFontsView({
    required List<FontFamilyItem> filteredFamilies,
    required List<String> fontCategories,
    required int totalCount,
  }) {
    final progress = _fontService.batchProgress;
    final isBatchDownloading = progress.isDownloading;

    return Column(
      children: [
        if (isBatchDownloading) _buildBatchProgressBar(progress),
        _buildFontRepositoryStatusBar(),
        _buildFontToolbar(fontCategories),
        Expanded(
          child: _buildFontGrid(filteredFamilies, isBatchDownloading),
        ),
        _buildFooter(
          visibleCount: filteredFamilies.length,
          totalCount: totalCount,
          unitName: 'font families',
        ),
      ],
    );
  }

  Widget _buildBatchProgressBar(FontDownloadBatchProgress progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      color: const Color(0xFF1E293B),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.sync_rounded, color: Color(0xFF38BDF8), size: 15),
              const SizedBox(width: 8),
              Text(
                'Downloading: ${progress.currentFileName}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              Text(
                '${progress.completedFiles} of ${progress.totalFiles} (${(progress.fraction * 100).toInt()}%)',
                style: const TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => _fontService.cancelDownload(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: const Text('Cancel', style: TextStyle(fontSize: 10.5)),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.fraction.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFontRepositoryStatusBar() {
    final hasUpdate = _fontService.hasUpdateAvailable;
    final isChecking = _fontService.isCheckingUpdates;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      color: hasUpdate ? const Color(0xFF0F291E) : const Color(0xFF131728),
      child: Row(
        children: [
          Icon(
            hasUpdate
                ? Icons.auto_awesome_rounded
                : Icons.check_circle_outline_rounded,
            size: 14,
            color: hasUpdate ? const Color(0xFF10B981) : Colors.white38,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasUpdate
                  ? '⚡ New font updates available in GitHub repo (${_fontService.newFontsCount} new/updated)'
                  : 'Repository synchronized • Checked: ${_formatCheckedTime(_fontService.lastCheckedAt)}',
              style: TextStyle(
                fontSize: 11,
                color: hasUpdate ? const Color(0xFF10B981) : Colors.white54,
                fontWeight: hasUpdate ? FontWeight.bold : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: isChecking
                ? const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.refresh_rounded, size: 12),
            label: Text(
              isChecking ? 'Checking...' : 'Check for Changes',
              style: const TextStyle(fontSize: 10.5),
            ),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF38BDF8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            ),
            onPressed: isChecking
                ? null
                : () => _fontService.checkForUpdates(silent: false),
          ),
        ],
      ),
    );
  }

  Widget _buildFontToolbar(List<String> categories) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121727),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                flex: 2,
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _searchController,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Search fonts by name, designer, or category...',
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: Color(0xFF38BDF8),
                        size: 18,
                      ),
                      suffixIcon: _searchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear_rounded,
                                size: 14,
                                color: Colors.white38,
                              ),
                              onPressed: () {
                                _searchController.clear();
                                setState(() => _searchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: EdgeInsets.zero,
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
                        borderSide: const BorderSide(
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                    ),
                    onChanged: (val) => setState(() => _searchQuery = val),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _previewTextController,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Type sample text to preview fonts live...',
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(
                        Icons.text_fields_rounded,
                        color: Color(0xFFA855F7),
                        size: 18,
                      ),
                      suffixIcon: PopupMenuButton<String>(
                        icon: const Icon(
                          Icons.arrow_drop_down_rounded,
                          color: Colors.white54,
                        ),
                        tooltip: 'Preview presets',
                        onSelected: (text) {
                          _previewTextController.text = text;
                          setState(() {});
                        },
                        itemBuilder: (ctx) => _previewPresets.map((preset) {
                          return PopupMenuItem<String>(
                            value: preset,
                            child: Text(
                              preset,
                              style: const TextStyle(fontSize: 12),
                            ),
                          );
                        }).toList(),
                      ),
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: EdgeInsets.zero,
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
                        borderSide: const BorderSide(
                          color: Color(0xFFA855F7),
                        ),
                      ),
                    ),
                    onChanged: (val) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  const Text('Size: ', style: TextStyle(color: Colors.white54, fontSize: 11)),
                  SizedBox(
                    width: 90,
                    child: SliderTheme(
                      data: SliderTheme.of(context).copyWith(
                        trackHeight: 2,
                        thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
                      ),
                      child: Slider(
                        value: _previewFontSize,
                        min: 16.0,
                        max: 48.0,
                        activeColor: const Color(0xFF38BDF8),
                        inactiveColor: Colors.white12,
                        onChanged: (v) => setState(() => _previewFontSize = v),
                      ),
                    ),
                  ),
                  Text(
                    '${_previewFontSize.toInt()}px',
                    style: const TextStyle(
                      color: Color(0xFF38BDF8),
                      fontSize: 11,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 28,
                  child: ListView.separated(
                    scrollDirection: Axis.horizontal,
                    itemCount: categories.length,
                    separatorBuilder: (context, index) => const SizedBox(width: 6),
                    itemBuilder: (context, idx) {
                      final cat = categories[idx];
                      final isSelected = _selectedCategory == cat;
                      return InkWell(
                        onTap: () => setState(() => _selectedCategory = cat),
                        borderRadius: BorderRadius.circular(6),
                        child: Container(
                          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                          decoration: BoxDecoration(
                            color: isSelected
                                ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                                : Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: isSelected
                                  ? const Color(0xFF38BDF8)
                                  : Colors.white.withValues(alpha: 0.08),
                              width: 1,
                            ),
                          ),
                          child: Text(
                            cat,
                            style: TextStyle(
                              color: isSelected ? const Color(0xFF38BDF8) : Colors.white70,
                              fontSize: 11,
                              fontWeight: isSelected ? FontWeight.bold : FontWeight.normal,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ),
              const SizedBox(width: 14),
              InkWell(
                onTap: () => setState(() => _filterOnlyDownloaded = !_filterOnlyDownloaded),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _filterOnlyDownloaded,
                        activeColor: const Color(0xFF10B981),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => setState(() => _filterOnlyDownloaded = v ?? false),
                      ),
                      const Text(
                        'Installed Only',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildFontGrid(List<FontFamilyItem> families, bool isBatchDownloading) {
    if (families.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.search_off_rounded, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              _searchQuery.isNotEmpty
                  ? 'No fonts match "$_searchQuery"'
                  : 'No fonts found in category "$_selectedCategory"',
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      );
    }

    final previewText = _previewTextController.text.trim().isNotEmpty
        ? _previewTextController.text
        : '12:45 PM • WallSync 2026';

    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        childAspectRatio: 2.15,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: families.length,
      itemBuilder: (context, idx) {
        final fam = families[idx];
        return _buildFontCard(fam, previewText, isBatchDownloading);
      },
    );
  }

  Widget _buildFontCard(
    FontFamilyItem fam,
    String previewText,
    bool isBatchDownloading,
  ) {
    final isDownloaded = fam.isDownloaded;
    final isLoaded = fam.isLoaded;
    final isCurrent = widget.currentFont != null &&
        widget.currentFont!.toLowerCase() == fam.familyName.toLowerCase();
    final isDownloadingThis =
        _singleDownloadingFamilies.contains(fam.familyName);

    if (!isLoaded && !_fontService.isFamilyPreviewLoading(fam.familyName)) {
      _fontService.ensurePreviewLoaded(fam);
    }

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF131728),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isCurrent
              ? const Color(0xFF10B981)
              : (isDownloaded
                  ? const Color(0xFF38BDF8).withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.08)),
          width: isCurrent ? 2 : 1,
        ),
        boxShadow: isCurrent
            ? [
                BoxShadow(
                  color: const Color(0xFF10B981).withValues(alpha: 0.25),
                  blurRadius: 12,
                )
              ]
            : null,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Card Header
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
            color: Colors.white.withValues(alpha: 0.03),
            child: Row(
              children: [
                Expanded(
                  child: Row(
                    children: [
                      Flexible(
                        child: Text(
                          fam.familyName,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 13,
                            fontWeight: FontWeight.bold,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: _getCategoryColor(fam.category).withValues(alpha: 0.15),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(
                            color: _getCategoryColor(fam.category).withValues(alpha: 0.3),
                          ),
                        ),
                        child: Text(
                          fam.category,
                          style: TextStyle(
                            color: _getCategoryColor(fam.category),
                            fontSize: 9.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
                if (isDownloaded)
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                    decoration: BoxDecoration(
                      color: const Color(0xFF10B981).withValues(alpha: 0.15),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.check_circle_rounded, size: 10, color: Color(0xFF10B981)),
                        SizedBox(width: 4),
                        Text(
                          'Installed',
                          style: TextStyle(
                            color: Color(0xFF10B981),
                            fontSize: 9.5,
                            fontWeight: FontWeight.bold,
                          ),
                        ),
                      ],
                    ),
                  )
                else
                  const Text(
                    'Preview Only',
                    style: TextStyle(
                      color: Color(0xFFF59E0B),
                      fontSize: 9.5,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
              ],
            ),
          ),

          // Live Font Preview Area
          Expanded(
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Text(
                  previewText,
                  style: TextStyle(
                    fontFamily: fam.familyName,
                    fontSize: _previewFontSize,
                    color: Colors.white,
                    letterSpacing: 0.5,
                  ),
                ),
              ),
            ),
          ),

          // Card Footer: Designer & Action Buttons
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.02),
              border: Border(
                top: BorderSide(color: Colors.white.withValues(alpha: 0.04)),
              ),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    fam.displayDesigner.isNotEmpty
                        ? 'by ${fam.displayDesigner} • ${fam.variants.length} variant${fam.variants.length > 1 ? 's' : ''}'
                        : '${fam.variants.length} variant${fam.variants.length > 1 ? 's' : ''} • ${fam.mainFontFile}',
                    style: const TextStyle(fontSize: 10, color: Colors.white38),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
                if (isDownloaded) ...[
                  ElevatedButton.icon(
                    icon: const Icon(Icons.check_rounded, size: 12),
                    label: Text(
                      isCurrent ? 'Selected' : 'Use in Widget',
                      style: const TextStyle(fontSize: 11, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: isCurrent
                          ? const Color(0xFF10B981)
                          : const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: () {
                      widget.onSelectFont?.call(fam.familyName);
                      Navigator.of(context).pop(fam.familyName);
                    },
                  ),
                  const SizedBox(width: 4),
                  IconButton(
                    icon: const Icon(Icons.delete_outline_rounded, size: 14, color: Colors.white38),
                    tooltip: 'Uninstall font files',
                    visualDensity: VisualDensity.compact,
                    onPressed: () => _fontService.deleteFontFamily(fam),
                  ),
                ] else ...[
                  ElevatedButton.icon(
                    icon: isDownloadingThis
                        ? const SizedBox(
                            width: 10,
                            height: 10,
                            child: CircularProgressIndicator(
                              strokeWidth: 1.5,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.download_rounded, size: 12),
                    label: Text(
                      isDownloadingThis ? 'Downloading...' : '⬇ Download to Use',
                      style: const TextStyle(fontSize: 10.5, fontWeight: FontWeight.bold),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF38BDF8).withValues(alpha: 0.25),
                      foregroundColor: const Color(0xFF38BDF8),
                      side: BorderSide(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.5),
                      ),
                      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                      visualDensity: VisualDensity.compact,
                    ),
                    onPressed: isDownloadingThis || isBatchDownloading
                        ? null
                        : () => _downloadSingleFamily(fam),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // ── VIEW 2: ANIMATED GIFS STUDIO ───────────────────────────────────────────
  // ═════════════════════════════════════════════════════════════════════════════
  Widget _buildGifsView({
    required List<CloudAssetItem> filteredGifs,
    required int totalCount,
  }) {
    final batch = _assetService.batchProgress;
    final isBatchDownloading = batch.isDownloading;

    final categories = [
      'All',
      'Clouds & Skies',
      'Rain & Weather',
      'Celestial & Night',
      'Atmosphere & Nature',
    ];

    return Column(
      children: [
        if (isBatchDownloading) _buildAssetBatchProgressBar(batch),
        _buildAssetRepositoryStatusBar('Gifs'),
        _buildAssetToolbar(
          categories: categories,
          hintText: 'Search animated GIFs by name or category...',
          type: CloudAssetType.gif,
        ),
        Expanded(
          child: _buildGifsGrid(filteredGifs, isBatchDownloading),
        ),
        _buildFooter(
          visibleCount: filteredGifs.length,
          totalCount: totalCount,
          unitName: 'animated GIF icons',
        ),
      ],
    );
  }

  Widget _buildGifsGrid(
    List<CloudAssetItem> items,
    bool isBatchDownloading,
  ) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.animation_rounded, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              _assetSearchQuery.isNotEmpty
                  ? 'No GIFs match "$_assetSearchQuery"'
                  : 'No GIFs found in category "$_selectedAssetCategory"',
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        childAspectRatio: 0.96,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, idx) {
        final item = items[idx];
        return _buildGifCard(item, isBatchDownloading);
      },
    );
  }

  Widget _buildGifCard(CloudAssetItem item, bool isBatchDownloading) {
    final isDownloaded = item.isDownloaded;
    final isDownloadingThis =
        _singleDownloadingAssets.contains(item.fileName);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF131728),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDownloaded
              ? const Color(0xFF8B5CF6).withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.08),
          width: 1.1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Live Animated Preview Box ────────────────────────────────────
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: const Color(0xFF0B0E17),
                    alignment: Alignment.center,
                    child: isDownloaded && item.localPath != null
                        ? Image.file(
                            File(item.localPath!),
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                          )
                        : Image.network(
                            item.downloadUrl,
                            fit: BoxFit.contain,
                            gaplessPlayback: true,
                            loadingBuilder: (ctx, child, chunk) {
                              if (chunk == null) return child;
                              return Center(
                                child: SizedBox(
                                  width: 24,
                                  height: 24,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 2,
                                    value: chunk.expectedTotalBytes != null
                                        ? chunk.cumulativeBytesLoaded /
                                            chunk.expectedTotalBytes!
                                        : null,
                                    color: const Color(0xFF8B5CF6),
                                  ),
                                ),
                              );
                            },
                            errorBuilder: (ctx, err, stack) => const Center(
                              child: Icon(
                                Icons.broken_image_rounded,
                                color: Colors.white24,
                                size: 36,
                              ),
                            ),
                          ),
                  ),
                ),

                // Top Badge: GIF Tag
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: const Color(0xFF8B5CF6).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(Icons.animation_rounded, size: 10, color: Colors.white),
                        SizedBox(width: 3),
                        Text(
                          'GIF',
                          style: TextStyle(
                            color: Colors.white,
                            fontSize: 9,
                            fontWeight: FontWeight.w900,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),

                // Top-Right Badge: Download status
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 2.5,
                    ),
                    decoration: BoxDecoration(
                      color: isDownloaded
                          ? const Color(0xFF10B981).withValues(alpha: 0.9)
                          : const Color(0xFFF59E0B).withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isDownloaded ? '✓ In Library' : 'Download Needed',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Details & Usability Actions ──────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            color: const Color(0xFF161B2E),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      item.formattedSize,
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 10.5,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 3),
                Text(
                  item.category,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10.5,
                  ),
                ),
                const SizedBox(height: 8),

                // Action Button: Download to Use OR Use in Widget
                Row(
                  children: [
                    Expanded(
                      child: isDownloaded
                          ? ElevatedButton.icon(
                              icon: const Icon(Icons.check_circle_rounded, size: 13),
                              label: const Text(
                                'Use in Widget',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 6),
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () {
                                if (item.localPath != null) {
                                  widget.onSelectAsset?.call(item.localPath!);
                                  Navigator.of(context).pop(item.localPath);
                                }
                              },
                            )
                          : Tooltip(
                              message:
                                  'Download this GIF to your local library before adding to widgets',
                              child: ElevatedButton.icon(
                                icon: isDownloadingThis
                                    ? const SizedBox(
                                        width: 11,
                                        height: 11,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.download_rounded, size: 13),
                                label: Text(
                                  isDownloadingThis
                                      ? 'Downloading...'
                                      : '⬇ Download to Use',
                                  style: const TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color(0xFF8B5CF6).withValues(alpha: 0.25),
                                  foregroundColor: const Color(0xFFA78BFA),
                                  side: BorderSide(
                                    color: const Color(0xFF8B5CF6).withValues(alpha: 0.5),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 6),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: isDownloadingThis || isBatchDownloading
                                    ? null
                                    : () => _downloadSingleAsset(item),
                              ),
                            ),
                    ),
                    if (isDownloaded) ...[
                      const SizedBox(width: 6),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 15,
                          color: Colors.white38,
                        ),
                        tooltip: 'Delete downloaded GIF',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _assetService.deleteAsset(item),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // ── VIEW 3: ICONS (PNG & SVG) STUDIO ───────────────────────────────────────
  // ═════════════════════════════════════════════════════════════════════════════
  Widget _buildIconsView({
    required List<CloudAssetItem> filteredIcons,
    required int totalCount,
  }) {
    final batch = _assetService.batchProgress;
    final isBatchDownloading = batch.isDownloading;

    final categories = [
      'All',
      'Rain & Weather',
      'Sun & Daylight',
      'Storm & Lightning',
      'Wind & Air',
    ];

    return Column(
      children: [
        if (isBatchDownloading) _buildAssetBatchProgressBar(batch),
        _buildAssetRepositoryStatusBar('Icons'),
        _buildAssetToolbar(
          categories: categories,
          hintText: 'Search PNG / SVG icons by name or category...',
          type: CloudAssetType.icon,
        ),
        Expanded(
          child: _buildIconsGrid(filteredIcons, isBatchDownloading),
        ),
        _buildFooter(
          visibleCount: filteredIcons.length,
          totalCount: totalCount,
          unitName: 'icons (PNG / SVG)',
        ),
      ],
    );
  }

  Widget _buildIconsGrid(
    List<CloudAssetItem> items,
    bool isBatchDownloading,
  ) {
    if (items.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.image_outlined, size: 48, color: Colors.white24),
            const SizedBox(height: 12),
            Text(
              _assetSearchQuery.isNotEmpty
                  ? 'No icons match "$_assetSearchQuery"'
                  : 'No icons found in category "$_selectedAssetCategory"',
              style: const TextStyle(color: Colors.white60, fontSize: 13),
            ),
          ],
        ),
      );
    }

    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 4,
        childAspectRatio: 0.94,
        crossAxisSpacing: 16,
        mainAxisSpacing: 16,
      ),
      itemCount: items.length,
      itemBuilder: (context, idx) {
        final item = items[idx];
        return _buildIconCard(item, isBatchDownloading);
      },
    );
  }

  Widget _buildIconCard(CloudAssetItem item, bool isBatchDownloading) {
    final isDownloaded = item.isDownloaded;
    final isDownloadingThis =
        _singleDownloadingAssets.contains(item.fileName);

    return Container(
      clipBehavior: Clip.antiAlias,
      decoration: BoxDecoration(
        color: const Color(0xFF131728),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isDownloaded
              ? const Color(0xFF10B981).withValues(alpha: 0.45)
              : Colors.white.withValues(alpha: 0.08),
          width: 1.1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── Icon Preview Box ─────────────────────────────────────────────
          Expanded(
            child: Stack(
              children: [
                Positioned.fill(
                  child: Container(
                    color: const Color(0xFF0B0E17),
                    alignment: Alignment.center,
                    padding: const EdgeInsets.all(16),
                    child: _buildIconPreview(item),
                  ),
                ),

                // Format badge
                Positioned(
                  top: 8,
                  left: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: item.isSvg
                          ? const Color(0xFFF59E0B).withValues(alpha: 0.85)
                          : const Color(0xFF38BDF8).withValues(alpha: 0.85),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      item.isSvg ? 'SVG' : 'PNG',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.w900,
                      ),
                    ),
                  ),
                ),

                // Status badge
                Positioned(
                  top: 8,
                  right: 8,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 5,
                      vertical: 2,
                    ),
                    decoration: BoxDecoration(
                      color: isDownloaded
                          ? const Color(0xFF10B981).withValues(alpha: 0.9)
                          : const Color(0xFFF59E0B).withValues(alpha: 0.9),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      isDownloaded ? '✓ Local' : 'Remote',
                      style: const TextStyle(
                        color: Colors.white,
                        fontSize: 8.5,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),

          // ── Details & Actions ────────────────────────────────────────────
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            color: const Color(0xFF161B2E),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        item.displayName,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.bold,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    Text(
                      item.formattedSize,
                      style: const TextStyle(
                        color: Color(0xFF38BDF8),
                        fontSize: 10,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                Text(
                  item.category,
                  style: const TextStyle(
                    color: Colors.white54,
                    fontSize: 10,
                  ),
                ),
                const SizedBox(height: 6),

                // Button: Use in Widget OR Download to Use
                Row(
                  children: [
                    Expanded(
                      child: isDownloaded
                          ? ElevatedButton.icon(
                              icon: const Icon(Icons.check_circle_rounded, size: 12),
                              label: const Text(
                                'Use in Widget',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              style: ElevatedButton.styleFrom(
                                backgroundColor: const Color(0xFF10B981),
                                foregroundColor: Colors.white,
                                padding: const EdgeInsets.symmetric(vertical: 5),
                                visualDensity: VisualDensity.compact,
                              ),
                              onPressed: () {
                                if (item.localPath != null) {
                                  widget.onSelectAsset?.call(item.localPath!);
                                  Navigator.of(context).pop(item.localPath);
                                }
                              },
                            )
                          : Tooltip(
                              message:
                                  'Download this icon to your local library before adding to widgets',
                              child: ElevatedButton.icon(
                                icon: isDownloadingThis
                                    ? const SizedBox(
                                        width: 10,
                                        height: 10,
                                        child: CircularProgressIndicator(
                                          strokeWidth: 1.5,
                                          color: Colors.white,
                                        ),
                                      )
                                    : const Icon(Icons.download_rounded, size: 12),
                                label: Text(
                                  isDownloadingThis
                                      ? 'Downloading...'
                                      : '⬇ Download to Use',
                                  style: const TextStyle(
                                    fontSize: 10.5,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                                style: ElevatedButton.styleFrom(
                                  backgroundColor:
                                      const Color(0xFF10B981).withValues(alpha: 0.2),
                                  foregroundColor: const Color(0xFF34D399),
                                  side: BorderSide(
                                    color: const Color(0xFF10B981).withValues(alpha: 0.45),
                                  ),
                                  padding: const EdgeInsets.symmetric(vertical: 5),
                                  visualDensity: VisualDensity.compact,
                                ),
                                onPressed: isDownloadingThis || isBatchDownloading
                                    ? null
                                    : () => _downloadSingleAsset(item),
                              ),
                            ),
                    ),
                    if (isDownloaded) ...[
                      const SizedBox(width: 4),
                      IconButton(
                        icon: const Icon(
                          Icons.delete_outline_rounded,
                          size: 14,
                          color: Colors.white38,
                        ),
                        tooltip: 'Delete downloaded icon',
                        visualDensity: VisualDensity.compact,
                        onPressed: () => _assetService.deleteAsset(item),
                      ),
                    ],
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildIconPreview(CloudAssetItem item) {
    if (item.isDownloaded && item.localPath != null) {
      final file = File(item.localPath!);
      if (item.isSvg) {
        return SvgPicture.file(
          file,
          width: 52,
          height: 52,
          fit: BoxFit.contain,
        );
      }
      return Image.file(
        file,
        width: 52,
        height: 52,
        fit: BoxFit.contain,
      );
    }

    // Remote network preview
    if (item.isSvg) {
      return SvgPicture.network(
        item.downloadUrl,
        width: 52,
        height: 52,
        fit: BoxFit.contain,
        placeholderBuilder: (ctx) => const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        ),
      );
    }
    return Image.network(
      item.downloadUrl,
      width: 52,
      height: 52,
      fit: BoxFit.contain,
      loadingBuilder: (ctx, child, progress) {
        if (progress == null) return child;
        return const SizedBox(
          width: 20,
          height: 20,
          child: CircularProgressIndicator(strokeWidth: 2),
        );
      },
      errorBuilder: (ctx, err, stack) => const Icon(
        Icons.broken_image_rounded,
        size: 36,
        color: Colors.white24,
      ),
    );
  }

  // ═════════════════════════════════════════════════════════════════════════════
  // ── SHARED SUB-COMPONENTS FOR ASSETS (GIFS & ICONS) ────────────────────────
  // ═════════════════════════════════════════════════════════════════════════════
  Widget _buildAssetBatchProgressBar(CloudAssetBatchProgress progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 8),
      color: const Color(0xFF1E293B),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(Icons.sync_rounded, color: Color(0xFF38BDF8), size: 15),
              const SizedBox(width: 8),
              Text(
                'Downloading: ${progress.currentFileName}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 11.5,
                  fontWeight: FontWeight.w600,
                ),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              ),
              const Spacer(),
              Text(
                '${progress.completedFiles} of ${progress.totalFiles} (${(progress.fraction * 100).toInt()}%)',
                style: const TextStyle(
                  color: Color(0xFF38BDF8),
                  fontSize: 11,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 10),
              TextButton(
                onPressed: () => _assetService.cancelBatchDownload(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                ),
                child: const Text('Cancel', style: TextStyle(fontSize: 10.5)),
              ),
            ],
          ),
          const SizedBox(height: 5),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.fraction.clamp(0.0, 1.0),
              minHeight: 5,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildAssetRepositoryStatusBar(String folder) {
    final hasUpdate = _assetService.hasUpdateAvailable;
    final isChecking = _assetService.isCheckingUpdates;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      color: hasUpdate ? const Color(0xFF0F291E) : const Color(0xFF131728),
      child: Row(
        children: [
          Icon(
            hasUpdate
                ? Icons.auto_awesome_rounded
                : Icons.check_circle_outline_rounded,
            size: 14,
            color: hasUpdate ? const Color(0xFF10B981) : Colors.white38,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              hasUpdate
                  ? '⚡ New assets available in Croenix/Font repository (${_assetService.newAssetsCount} new items)'
                  : 'Folder "$folder/" synchronized with Croenix/Font • Checked: ${_formatCheckedTime(_assetService.lastCheckedAt)}',
              style: TextStyle(
                fontSize: 11,
                color: hasUpdate ? const Color(0xFF10B981) : Colors.white54,
                fontWeight: hasUpdate ? FontWeight.bold : FontWeight.normal,
              ),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
          TextButton.icon(
            icon: isChecking
                ? const SizedBox(
                    width: 10,
                    height: 10,
                    child: CircularProgressIndicator(strokeWidth: 1.5),
                  )
                : const Icon(Icons.refresh_rounded, size: 12),
            label: Text(
              isChecking ? 'Checking...' : 'Check for Asset Changes',
              style: const TextStyle(fontSize: 10.5),
            ),
            style: TextButton.styleFrom(
              foregroundColor: const Color(0xFF38BDF8),
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
            ),
            onPressed: isChecking
                ? null
                : () => _assetService.checkForUpdates(silent: false),
          ),
        ],
      ),
    );
  }

  Widget _buildAssetToolbar({
    required List<String> categories,
    required String hintText,
    required CloudAssetType type,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF121727),
        border: Border(
          bottom: BorderSide(color: Colors.white.withValues(alpha: 0.06)),
        ),
      ),
      child: Column(
        children: [
          Row(
            children: [
              Expanded(
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _assetSearchController,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: hintText,
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(
                        Icons.search_rounded,
                        color: Color(0xFF38BDF8),
                        size: 18,
                      ),
                      suffixIcon: _assetSearchQuery.isNotEmpty
                          ? IconButton(
                              icon: const Icon(
                                Icons.clear_rounded,
                                size: 14,
                                color: Colors.white38,
                              ),
                              onPressed: () {
                                _assetSearchController.clear();
                                setState(() => _assetSearchQuery = '');
                              },
                            )
                          : null,
                      filled: true,
                      fillColor: Colors.white.withValues(alpha: 0.05),
                      contentPadding: EdgeInsets.zero,
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
                        borderSide: const BorderSide(
                          color: Color(0xFF38BDF8),
                        ),
                      ),
                    ),
                    onChanged: (val) => setState(() => _assetSearchQuery = val),
                  ),
                ),
              ),
              const SizedBox(width: 14),
              InkWell(
                onTap: () => setState(
                    () => _filterOnlyDownloadedAssets = !_filterOnlyDownloadedAssets),
                borderRadius: BorderRadius.circular(6),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    children: [
                      Checkbox(
                        value: _filterOnlyDownloadedAssets,
                        activeColor: const Color(0xFF10B981),
                        materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        visualDensity: VisualDensity.compact,
                        onChanged: (v) => setState(
                            () => _filterOnlyDownloadedAssets = v ?? false),
                      ),
                      const Text(
                        'Downloaded Only',
                        style: TextStyle(color: Colors.white70, fontSize: 11),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          SizedBox(
            height: 28,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: categories.length,
              separatorBuilder: (context, index) => const SizedBox(width: 6),
              itemBuilder: (context, idx) {
                final cat = categories[idx];
                final isSelected = _selectedAssetCategory == cat;
                return InkWell(
                  onTap: () => setState(() => _selectedAssetCategory = cat),
                  borderRadius: BorderRadius.circular(6),
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 10,
                      vertical: 4,
                    ),
                    decoration: BoxDecoration(
                      color: isSelected
                          ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                          : Colors.white.withValues(alpha: 0.04),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: isSelected
                            ? const Color(0xFF38BDF8)
                            : Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                    child: Text(
                      cat,
                      style: TextStyle(
                        color:
                            isSelected ? const Color(0xFF38BDF8) : Colors.white70,
                        fontSize: 11,
                        fontWeight:
                            isSelected ? FontWeight.bold : FontWeight.normal,
                      ),
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── Sub-component: Shared Footer ─────────────────────────────────────────
  Widget _buildFooter({
    required int visibleCount,
    required int totalCount,
    required String unitName,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      decoration: BoxDecoration(
        color: const Color(0xFF161B2E),
        border: Border(
          top: BorderSide(color: Colors.white.withValues(alpha: 0.08)),
        ),
      ),
      child: Row(
        children: [
          Text(
            'Showing $visibleCount of $totalCount $unitName',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const SizedBox(width: 16),
          const Expanded(
            child: Text(
              '• Important: Assets must be downloaded to local library before adding to widgets',
              style: TextStyle(color: Color(0xFF38BDF8), fontSize: 10.5),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
            ),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(),
            style: TextButton.styleFrom(
              foregroundColor: Colors.white70,
              padding: const EdgeInsets.symmetric(horizontal: 16),
            ),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  // ── Helper: Download Single Asset ────────────────────────────────────────
  Future<bool> _downloadSingleAsset(CloudAssetItem item) async {
    setState(() => _singleDownloadingAssets.add(item.fileName));
    try {
      final success = await _assetService.downloadAsset(item);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚡ ${item.displayName} downloaded to local library!'),
            backgroundColor: const Color(0xFF1E293B),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return success;
    } finally {
      if (mounted) {
        setState(() => _singleDownloadingAssets.remove(item.fileName));
      }
    }
  }

  // ── Helper: Download Single Family ───────────────────────────────────────
  Future<bool> _downloadSingleFamily(FontFamilyItem fam) async {
    setState(() => _singleDownloadingFamilies.add(fam.familyName));
    try {
      final success = await _fontService.downloadFontFamily(fam);
      if (success && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('⚡ ${fam.familyName} installed and ready to use!'),
            backgroundColor: const Color(0xFF1E293B),
            duration: const Duration(seconds: 2),
          ),
        );
      }
      return success;
    } finally {
      if (mounted) {
        setState(() => _singleDownloadingFamilies.remove(fam.familyName));
      }
    }
  }

  // ── Helper: Format category color ────────────────────────────────────────
  Color _getCategoryColor(String category) {
    return switch (category) {
      'Serif' => const Color(0xFF38BDF8),
      'Sans-Serif' => const Color(0xFF60A5FA),
      'Display / Decorative' => const Color(0xFFA855F7),
      'Handwriting / Script' => const Color(0xFFF43F5E),
      'Symbol / Icon' => const Color(0xFFFACC15),
      'Monospace' => const Color(0xFF10B981),
      _ => const Color(0xFF94A3B8),
    };
  }

  // ── Helper: Format checked timestamp ─────────────────────────────────────
  String _formatCheckedTime(DateTime? dt) {
    if (dt == null) return 'Never';
    final now = DateTime.now();
    final diff = now.difference(dt);
    if (diff.inMinutes < 1) return 'Just now';
    if (diff.inHours < 1) return '${diff.inMinutes}m ago';
    if (diff.inDays < 1) return '${diff.inHours}h ago';
    return '${diff.inDays}d ago';
  }
}
