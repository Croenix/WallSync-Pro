import 'dart:async';
import 'package:flutter/material.dart';
import '../services/custom_font_service.dart';

/// Full-featured Font Studio, Asset Downloader, and Visual Font Design Preview modal.
class FontDownloadDialog extends StatefulWidget {
  /// Optional callback invoked when the user selects a font to apply to their widget.
  final void Function(String fontFamily)? onSelectFont;

  /// Currently active font family name (for highlighting).
  final String? currentFont;

  const FontDownloadDialog({
    super.key,
    this.onSelectFont,
    this.currentFont,
  });

  /// Static helper to display the dialog cleanly from any view or inspector.
  static Future<String?> show(
    BuildContext context, {
    String? currentFont,
    void Function(String fontFamily)? onSelectFont,
  }) {
    return showDialog<String>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => Dialog(
        backgroundColor: Colors.transparent,
        insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 32),
        child: FontDownloadDialog(
          currentFont: currentFont,
          onSelectFont: onSelectFont,
        ),
      ),
    );
  }

  @override
  State<FontDownloadDialog> createState() => _FontDownloadDialogState();
}

class _FontDownloadDialogState extends State<FontDownloadDialog> {
  final CustomFontService _fontService = CustomFontService.instance;
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _previewTextController = TextEditingController(
    text: '12:45 PM • WallSync 2026',
  );

  String _searchQuery = '';
  String _selectedCategory = 'All';
  double _previewFontSize = 26.0;
  bool _filterOnlyDownloaded = false;

  final Set<String> _singleDownloadingFamilies = <String>{};

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
    _fontService.addListener(_onServiceUpdate);
    // Trigger update check if not checked yet
    if (!_fontService.isInitialized) {
      _fontService.init();
    } else {
      unawaited(_fontService.checkForUpdates(silent: true));
    }
  }

  @override
  void dispose() {
    _fontService.removeListener(_onServiceUpdate);
    _searchController.dispose();
    _previewTextController.dispose();
    super.dispose();
  }

  void _onServiceUpdate() {
    if (mounted) setState(() {});
  }

  List<FontFamilyItem> _getFilteredFamilies() {
    return _fontService.families.where((fam) {
      // Category filter
      if (_selectedCategory != 'All' && fam.category != _selectedCategory) {
        return false;
      }

      // Downloaded only filter
      if (_filterOnlyDownloaded && !fam.isDownloaded) {
        return false;
      }

      // Search query filter
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

  @override
  Widget build(BuildContext context) {
    final filteredFamilies = _getFilteredFamilies();
    final categories = [
      'All',
      ...{for (var f in _fontService.families) f.category},
    ];

    final progress = _fontService.batchProgress;
    final isBatchDownloading = progress.isDownloading;

    final downloadedCount =
        _fontService.families.where((f) => f.isDownloaded).length;
    final totalCount = _fontService.families.length;

    return Container(
      width: 1040,
      height: 720,
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
          // ── Top Header Bar ───────────────────────────────────────────────
          _buildHeader(downloadedCount, totalCount),

          // ── Batch Download Progress (if active) ──────────────────────────
          if (isBatchDownloading) _buildBatchProgressBar(progress),

          // ── Repository Status / Update Banner ────────────────────────────
          _buildRepositoryStatusBar(),

          // ── Toolbar: Search, Category Chips & Live Preview Controls ──────
          _buildToolbar(categories),

          // ── Live Font Design Preview Grid ────────────────────────────────
          Expanded(
            child: _buildFontGrid(filteredFamilies, isBatchDownloading),
          ),

          // ── Footer Bar: Selection & Close Actions ────────────────────────
          _buildFooter(filteredFamilies.length, totalCount),
        ],
      ),
    );
  }

  // ── Sub-component: Header ────────────────────────────────────────────────
  Widget _buildHeader(int downloaded, int total) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 14),
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
          Container(
            padding: const EdgeInsets.all(8),
            decoration: BoxDecoration(
              gradient: const LinearGradient(
                colors: [Color(0xFF38BDF8), Color(0xFFA855F7)],
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
              ),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Icon(
              Icons.font_download_rounded,
              color: Colors.white,
              size: 20,
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
                      'Font Cloud Studio & Assets Downloader',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 16,
                        fontWeight: FontWeight.bold,
                        letterSpacing: 0.3,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(6),
                        border: Border.all(
                          color: const Color(0xFF38BDF8).withValues(alpha: 0.3),
                        ),
                      ),
                      child: Text(
                        '$downloaded / $total Installed',
                        style: const TextStyle(
                          color: Color(0xFF38BDF8),
                          fontSize: 10.5,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 2),
                const Text(
                  'Connected to Croenix/Font GitHub repository • Live categorized fonts for custom desktop widgets',
                  style: TextStyle(
                    color: Colors.white54,
                    fontSize: 11,
                  ),
                ),
              ],
            ),
          ),

          // Download All Button
          ElevatedButton.icon(
            icon: _fontService.batchProgress.isDownloading
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.cloud_download_rounded, size: 16),
            label: Text(
              _fontService.batchProgress.isDownloading
                  ? 'Downloading All...'
                  : 'Download All Fonts',
              style: const TextStyle(fontSize: 12, fontWeight: FontWeight.bold),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF0284C7),
              foregroundColor: Colors.white,
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
            ),
            onPressed: _fontService.batchProgress.isDownloading
                ? null
                : () => _fontService.downloadAllFonts(),
          ),
          const SizedBox(width: 10),

          // Close button
          IconButton(
            icon: const Icon(Icons.close_rounded, color: Colors.white70),
            tooltip: 'Close Font Studio',
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  // ── Sub-component: Batch Progress Bar ────────────────────────────────────
  Widget _buildBatchProgressBar(FontDownloadBatchProgress progress) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 10),
      color: const Color(0xFF1E293B),
      child: Column(
        children: [
          Row(
            children: [
              const Icon(
                Icons.sync_rounded,
                color: Color(0xFF38BDF8),
                size: 16,
              ),
              const SizedBox(width: 8),
              Text(
                'Downloading: ${progress.currentFileName}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 12,
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
                  fontSize: 11.5,
                  fontWeight: FontWeight.bold,
                ),
              ),
              const SizedBox(width: 12),
              TextButton(
                onPressed: () => _fontService.cancelDownload(),
                style: TextButton.styleFrom(
                  foregroundColor: Colors.redAccent,
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                ),
                child: const Text('Cancel', style: TextStyle(fontSize: 11)),
              ),
            ],
          ),
          const SizedBox(height: 6),
          ClipRRect(
            borderRadius: BorderRadius.circular(4),
            child: LinearProgressIndicator(
              value: progress.fraction.clamp(0.0, 1.0),
              minHeight: 6,
              backgroundColor: Colors.white10,
              valueColor: const AlwaysStoppedAnimation<Color>(Color(0xFF38BDF8)),
            ),
          ),
        ],
      ),
    );
  }

  // ── Sub-component: Repository Status Bar ─────────────────────────────────
  Widget _buildRepositoryStatusBar() {
    final hasUpdate = _fontService.hasUpdateAvailable;
    final isChecking = _fontService.isCheckingUpdates;

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      color: hasUpdate
          ? const Color(0xFF0F291E)
          : const Color(0xFF131728),
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
          Text(
            hasUpdate
                ? '⚡ New font updates available in GitHub repo (${_fontService.newFontsCount} new/updated)'
                : 'Repository synchronized • Checked: ${_formatCheckedTime(_fontService.lastCheckedAt)}',
            style: TextStyle(
              fontSize: 11,
              color: hasUpdate ? const Color(0xFF10B981) : Colors.white54,
              fontWeight: hasUpdate ? FontWeight.bold : FontWeight.normal,
            ),
          ),
          const Spacer(),
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

  // ── Sub-component: Toolbar & Visual Preview Controls ─────────────────────
  Widget _buildToolbar(List<String> categories) {
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
          // Row 1: Search bar & Live custom preview text input
          Row(
            children: [
              // Search input
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

              // Custom Preview Text Field
              Expanded(
                flex: 3,
                child: SizedBox(
                  height: 36,
                  child: TextField(
                    controller: _previewTextController,
                    style: const TextStyle(color: Colors.white, fontSize: 12.5),
                    decoration: InputDecoration(
                      hintText: 'Type custom design preview text...',
                      hintStyle: const TextStyle(
                        color: Colors.white38,
                        fontSize: 12,
                      ),
                      prefixIcon: const Icon(
                        Icons.text_fields_rounded,
                        color: Color(0xFFA855F7),
                        size: 18,
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
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
              const SizedBox(width: 14),

              // Preview Font Size Slider
              const Text(
                'Size:',
                style: TextStyle(fontSize: 11, color: Colors.white54),
              ),
              SizedBox(
                width: 90,
                child: Slider(
                  value: _previewFontSize,
                  min: 16.0,
                  max: 48.0,
                  activeColor: const Color(0xFF38BDF8),
                  onChanged: (val) => setState(() => _previewFontSize = val),
                ),
              ),
              Text(
                '${_previewFontSize.round()}px',
                style: const TextStyle(
                  fontSize: 10.5,
                  fontWeight: FontWeight.bold,
                  color: Colors.white70,
                ),
              ),
            ],
          ),
          const SizedBox(height: 8),

          // Row 2: Category chips & Preset chips & Filter toggle
          Row(
            children: [
              // Categories horizontal list
              Expanded(
                child: SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: Row(
                    children: [
                      ...categories.map((cat) {
                        final isSel = _selectedCategory == cat;
                        return Padding(
                          padding: const EdgeInsets.only(right: 6),
                          child: InkWell(
                            borderRadius: BorderRadius.circular(6),
                            onTap: () => setState(() => _selectedCategory = cat),
                            child: Container(
                              padding: const EdgeInsets.symmetric(
                                horizontal: 10,
                                vertical: 4,
                              ),
                              decoration: BoxDecoration(
                                color: isSel
                                    ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                                    : Colors.white.withValues(alpha: 0.04),
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(
                                  color: isSel
                                      ? const Color(0xFF38BDF8)
                                      : Colors.white.withValues(alpha: 0.08),
                                ),
                              ),
                              child: Text(
                                cat,
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: isSel
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: isSel
                                      ? const Color(0xFF38BDF8)
                                      : Colors.white70,
                                ),
                              ),
                            ),
                          ),
                        );
                      }),
                      const SizedBox(width: 8),
                      // Filter Only Downloaded Switch Chip
                      InkWell(
                        borderRadius: BorderRadius.circular(6),
                        onTap: () => setState(
                          () => _filterOnlyDownloaded = !_filterOnlyDownloaded,
                        ),
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 8,
                            vertical: 4,
                          ),
                          decoration: BoxDecoration(
                            color: _filterOnlyDownloaded
                                ? const Color(0xFF10B981).withValues(alpha: 0.2)
                                : Colors.white.withValues(alpha: 0.04),
                            borderRadius: BorderRadius.circular(6),
                            border: Border.all(
                              color: _filterOnlyDownloaded
                                  ? const Color(0xFF10B981)
                                  : Colors.white.withValues(alpha: 0.08),
                            ),
                          ),
                          child: Row(
                            children: [
                              Icon(
                                _filterOnlyDownloaded
                                    ? Icons.check_box_rounded
                                    : Icons.check_box_outline_blank_rounded,
                                size: 12,
                                color: _filterOnlyDownloaded
                                    ? const Color(0xFF10B981)
                                    : Colors.white38,
                              ),
                              const SizedBox(width: 4),
                              Text(
                                'Downloaded Only',
                                style: TextStyle(
                                  fontSize: 10.5,
                                  fontWeight: _filterOnlyDownloaded
                                      ? FontWeight.bold
                                      : FontWeight.normal,
                                  color: _filterOnlyDownloaded
                                      ? const Color(0xFF10B981)
                                      : Colors.white60,
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
              const SizedBox(width: 12),

              // Preview Presets Popup Menu
              PopupMenuButton<String>(
                tooltip: 'Preview text presets',
                color: const Color(0xFF1E2235),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 4,
                  ),
                  decoration: BoxDecoration(
                    color: Colors.white.withValues(alpha: 0.04),
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(
                      color: Colors.white.withValues(alpha: 0.1),
                    ),
                  ),
                  child: const Row(
                    children: [
                      Icon(Icons.style_rounded, size: 12, color: Colors.white60),
                      SizedBox(width: 4),
                      Text(
                        'Presets',
                        style: TextStyle(fontSize: 10.5, color: Colors.white70),
                      ),
                      Icon(Icons.arrow_drop_down, size: 14, color: Colors.white60),
                    ],
                  ),
                ),
                onSelected: (preset) {
                  _previewTextController.text = preset;
                  setState(() {});
                },
                itemBuilder: (ctx) => _previewPresets.map((p) {
                  return PopupMenuItem(
                    value: p,
                    height: 32,
                    child: Text(
                      p,
                      style: const TextStyle(fontSize: 11, color: Colors.white),
                    ),
                  );
                }).toList(),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Sub-component: Font Grid ─────────────────────────────────────────────
  Widget _buildFontGrid(
    List<FontFamilyItem> families,
    bool isBatchDownloading,
  ) {
    if (families.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.search_off_rounded,
              size: 48,
              color: Colors.white.withValues(alpha: 0.2),
            ),
            const SizedBox(height: 12),
            const Text(
              'No fonts match your search criteria',
              style: TextStyle(
                color: Colors.white70,
                fontSize: 14,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 6),
            const Text(
              'Try adjusting the search query or category filter',
              style: TextStyle(color: Colors.white38, fontSize: 11),
            ),
          ],
        ),
      );
    }

    final previewText = _previewTextController.text.trim().isNotEmpty
        ? _previewTextController.text.trim()
        : 'WallSync 2026';

    // Preload previews in background so all fonts show their real typography
    _fontService.preloadVisiblePreviews(families);

    return GridView.builder(
      padding: const EdgeInsets.all(20),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        mainAxisSpacing: 14,
        crossAxisSpacing: 14,
        childAspectRatio: 2.1,
      ),
      itemCount: families.length,
      itemBuilder: (context, index) {
        final fam = families[index];
        return _buildFontCard(fam, previewText, isBatchDownloading);
      },
    );
  }

  // ── Sub-component: Single Font Card ──────────────────────────────────────
  Widget _buildFontCard(
    FontFamilyItem fam,
    String previewText,
    bool isBatchDownloading,
  ) {
    final isSelected = widget.currentFont != null &&
        widget.currentFont!.toLowerCase() == fam.familyName.toLowerCase();
    final isDownloaded = fam.isDownloaded;
    final isLoaded = fam.isLoaded;
    final isSingleDownloading =
        _singleDownloadingFamilies.contains(fam.familyName);

    // On-demand typography preview loading before download
    if (!isLoaded && !_fontService.isFamilyPreviewLoading(fam.familyName)) {
      unawaited(_fontService.ensurePreviewLoaded(fam));
    }

    return Container(
      decoration: BoxDecoration(
        color: isSelected
            ? const Color(0xFF1A2744)
            : const Color(0xFF14192B),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: isSelected
              ? const Color(0xFF38BDF8)
              : isDownloaded
                  ? const Color(0xFF10B981).withValues(alpha: 0.35)
                  : Colors.white.withValues(alpha: 0.08),
          width: isSelected ? 1.5 : 1.0,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Card Header: Family Name, Category badge, Preview/Installed badge, Download/Apply Actions
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 10, 14, 0),
            child: Row(
              children: [
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
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
                            padding: const EdgeInsets.symmetric(
                              horizontal: 6,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: _getCategoryColor(fam.category)
                                  .withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              fam.category.toUpperCase(),
                              style: TextStyle(
                                fontSize: 8.5,
                                fontWeight: FontWeight.w900,
                                color: _getCategoryColor(fam.category),
                              ),
                            ),
                          ),
                          const SizedBox(width: 6),
                          Container(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 5,
                              vertical: 1.5,
                            ),
                            decoration: BoxDecoration(
                              color: isDownloaded
                                  ? const Color(0xFF10B981).withValues(alpha: 0.15)
                                  : const Color(0xFFF59E0B).withValues(alpha: 0.15),
                              borderRadius: BorderRadius.circular(4),
                            ),
                            child: Text(
                              isDownloaded ? 'INSTALLED' : 'PREVIEW',
                              style: TextStyle(
                                fontSize: 8.0,
                                fontWeight: FontWeight.w900,
                                color: isDownloaded
                                    ? const Color(0xFF10B981)
                                    : const Color(0xFFF59E0B),
                                letterSpacing: 0.4,
                              ),
                            ),
                          ),
                        ],
                      ),
                      if (fam.displayDesigner.isNotEmpty)
                        Text(
                          'by ${fam.displayDesigner}',
                          style: const TextStyle(
                            fontSize: 9.5,
                            color: Colors.white38,
                          ),
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),

                // Card Actions: ONLY usable when downloaded
                if (isDownloaded) ...[
                  // Apply to Widget button (Available because font IS downloaded)
                  if (widget.onSelectFont != null)
                    ElevatedButton(
                      style: ElevatedButton.styleFrom(
                        backgroundColor: isSelected
                            ? const Color(0xFF10B981)
                            : const Color(0xFF38BDF8),
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 6,
                        ),
                        minimumSize: Size.zero,
                        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(6),
                        ),
                      ),
                      onPressed: () {
                        widget.onSelectFont!(fam.familyName);
                        Navigator.of(context).pop(fam.familyName);
                      },
                      child: Text(
                        isSelected ? 'Active ✓' : 'Use Font',
                        style: const TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                    )
                  else
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: const Row(
                        children: [
                          Icon(
                            Icons.check_circle_rounded,
                            size: 11,
                            color: Color(0xFF10B981),
                          ),
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
                    ),
                ] else ...[
                  // Font NOT downloaded yet: MUST download before it can be used!
                  ElevatedButton.icon(
                    icon: isSingleDownloading
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
                      isSingleDownloading
                          ? 'Downloading...'
                          : (widget.onSelectFont != null
                              ? 'Download to Use'
                              : 'Download'),
                      style: const TextStyle(
                        fontSize: 10,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    style: ElevatedButton.styleFrom(
                      backgroundColor: const Color(0xFF0284C7),
                      foregroundColor: Colors.white,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 6,
                      ),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(6),
                      ),
                    ),
                    onPressed: isSingleDownloading || isBatchDownloading
                        ? null
                        : () async {
                            final success = await _downloadSingleFamily(fam);
                            if (success && widget.onSelectFont != null && mounted) {
                              widget.onSelectFont!(fam.familyName);
                              Navigator.of(context).pop(fam.familyName);
                            }
                          },
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(height: 6),

          // Card Body: Large Live Font Visual Preview (Renders in actual font typography before download)
          Expanded(
            child: Container(
              margin: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              alignment: Alignment.centerLeft,
              decoration: BoxDecoration(
                color: Colors.black.withValues(alpha: 0.25),
                borderRadius: BorderRadius.circular(8),
              ),
              child: isLoaded
                  ? SingleChildScrollView(
                      scrollDirection: Axis.horizontal,
                      child: Text(
                        previewText,
                        style: TextStyle(
                          fontFamily: fam.familyName,
                          fontSize: _previewFontSize,
                          color: Colors.white,
                          fontWeight: FontWeight.normal,
                        ),
                      ),
                    )
                  : (_fontService.isFamilyPreviewLoading(fam.familyName)
                      ? const Row(
                          children: [
                            SizedBox(
                              width: 12,
                              height: 12,
                              child: CircularProgressIndicator(
                                strokeWidth: 1.5,
                                color: Color(0xFF38BDF8),
                              ),
                            ),
                            SizedBox(width: 8),
                            Text(
                              'Loading typography preview...',
                              style: TextStyle(
                                fontSize: 11,
                                color: Colors.white38,
                              ),
                            ),
                          ],
                        )
                      : SingleChildScrollView(
                          scrollDirection: Axis.horizontal,
                          child: Text(
                            previewText,
                            style: TextStyle(
                              fontSize: _previewFontSize,
                              color: Colors.white.withValues(alpha: 0.35),
                              fontWeight: FontWeight.normal,
                            ),
                          ),
                        )),
            ),
          ),

          // Card Footer Details (variant count, file name, download requirement note)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 8),
            child: Row(
              children: [
                Text(
                  fam.variants.isNotEmpty
                      ? '${fam.variants.length} variant${fam.variants.length > 1 ? "s" : ""}'
                      : fam.mainFontFile,
                  style: const TextStyle(fontSize: 9.5, color: Colors.white30),
                ),
                const Spacer(),
                if (isDownloaded)
                  const Text(
                    '✓ Installed • Usable in widgets',
                    style: TextStyle(
                      fontSize: 8.5,
                      color: Color(0xFF10B981),
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else if (isLoaded)
                  const Text(
                    '⚡ Live Preview • Download to use in widgets',
                    style: TextStyle(
                      fontSize: 8.5,
                      color: Color(0xFFF59E0B),
                      fontWeight: FontWeight.w600,
                    ),
                  )
                else
                  const Text(
                    'Fetching live font preview...',
                    style: TextStyle(fontSize: 8.5, color: Colors.white24),
                  ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  // ── Sub-component: Footer ────────────────────────────────────────────────
  Widget _buildFooter(int visibleCount, int totalCount) {
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
            'Showing $visibleCount of $totalCount font families',
            style: const TextStyle(color: Colors.white54, fontSize: 11),
          ),
          const Spacer(),
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

