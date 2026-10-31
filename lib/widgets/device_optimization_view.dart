import 'dart:async';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import '../services/device_optimization_service.dart';
import '../services/settings_service.dart';
import '../services/system_optimizer_service.dart';

class DeviceOptimizationView extends StatefulWidget {
  final WidgetSettings settings;
  final SettingsService settingsService;
  final Function(WidgetSettings) onSettingsChanged;

  const DeviceOptimizationView({
    super.key,
    required this.settings,
    required this.settingsService,
    required this.onSettingsChanged,
  });

  @override
  State<DeviceOptimizationView> createState() => _DeviceOptimizationViewState();
}

class _DeviceOptimizationViewState extends State<DeviceOptimizationView> {
  final SystemOptimizerService _optimizer = SystemOptimizerService.instance;
  final DeviceOptimizationService _devOpt = DeviceOptimizationService.instance;

  Timer? _refreshTimer;
  NativePerformanceMetrics? _metrics;
  NativeGpuAndDisplayInfo? _gpuInfo;
  WindowsVersionInfo? _winVer;
  List<WindowsProcessInfo> _processes = [];

  bool _isOptimizing = false;
  OptimizationResult? _lastResult;
  String _processFilter = 'all'; // 'all' | 'wallsync'
  String _processSearchQuery = '';

  @override
  void initState() {
    super.initState();
    _fetchHardwareAndMetrics();
    _refreshTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (mounted) _pollMetrics();
    });
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _fetchHardwareAndMetrics() async {
    final ver = await _optimizer.getWindowsVersionInfo();
    final gpu = await _optimizer.getGpuAndDisplayInfo();
    final met = await _optimizer.getPerformanceMetrics();
    final procs = await _optimizer.getProcessList();

    if (mounted) {
      setState(() {
        _winVer = ver;
        _gpuInfo = gpu;
        _metrics = met;
        _processes = procs;
      });
    }
  }

  Future<void> _pollMetrics() async {
    final met = await _optimizer.getPerformanceMetrics();
    final procs = await _optimizer.getProcessList();
    if (mounted) {
      setState(() {
        _metrics = met;
        _processes = procs;
      });
    }
  }

  Future<void> _runOverallOptimization() async {
    if (_isOptimizing) return;
    setState(() => _isOptimizing = true);
    try {
      final res = await _devOpt.optimizeOverallPerformance(
        currentSettings: widget.settings,
        settingsService: widget.settingsService,
      );
      final refreshed = await widget.settingsService.loadSettings();
      widget.onSettingsChanged(refreshed);
      if (mounted) {
        setState(() {
          _lastResult = res;
        });
        await _pollMetrics();
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            backgroundColor: const Color(0xFF10B981),
            behavior: SnackBarBehavior.floating,
            content: Row(
              children: [
                const Icon(Icons.check_circle_rounded, color: Colors.white),
                const SizedBox(width: 10),
                Text(
                  res.workingSetFreedMb > 0
                      ? 'Optimization complete! Working Set: ${res.workingSetFreedMb.toStringAsFixed(1)} MB trimmed'
                          '${res.privateBytesFreedMb > 0 ? " • Private: ${res.privateBytesFreedMb.toStringAsFixed(1)} MB freed" : ""}'
                      : 'Optimization complete! Memory stabilized at ${res.workingSetAfterMb.toStringAsFixed(1)} MB (heaps compacted, cache purged)',
                  style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold),
                ),
              ],
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _isOptimizing = false);
    }
  }

  Future<void> _selectProfile(String profileId) async {
    final updated = await _devOpt.applyProfile(
      profileId: profileId,
      currentSettings: widget.settings,
      settingsService: widget.settingsService,
    );
    widget.onSettingsChanged(updated);
    setState(() {});
  }

  Future<void> _restoreDefaults() async {
    final updated = await _devOpt.restoreDefaults(
      settingsService: widget.settingsService,
    );
    widget.onSettingsChanged(updated);
    setState(() {});
    if (mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          backgroundColor: Color(0xFF38BDF8),
          behavior: SnackBarBehavior.floating,
          content: Text('Restored Balanced performance defaults.'),
        ),
      );
    }
  }

  Future<void> _undoLastOptimization() async {
    final updated = await _devOpt.undoLastOptimization(
      currentSettings: widget.settings,
      settingsService: widget.settingsService,
    );
    if (updated != null) {
      widget.onSettingsChanged(updated);
      setState(() {});
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            backgroundColor: Color(0xFF818CF8),
            behavior: SnackBarBehavior.floating,
            content: Text('Reverted last optimization adjustments.'),
          ),
        );
      }
    }
  }

  void _showOptimizationHistory() {
    final history = widget.settings.optimizationHistory;
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: const Color(0xFF161822),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(16),
          side: BorderSide(color: Colors.white.withValues(alpha: 0.1)),
        ),
        title: const Row(
          children: [
            Icon(Icons.history_rounded, color: Color(0xFF38BDF8)),
            SizedBox(width: 10),
            Text(
              'Optimization History',
              style: TextStyle(color: Colors.white, fontSize: 17, fontWeight: FontWeight.bold),
            ),
          ],
        ),
        content: SizedBox(
          width: 500,
          height: 380,
          child: history.isEmpty
              ? const Center(
                  child: Text(
                    'No optimization runs recorded yet.\nClick "Optimize Overall Performance" to run your first pass.',
                    textAlign: TextAlign.center,
                    style: TextStyle(color: Colors.white54, height: 1.5),
                  ),
                )
              : ListView.separated(
                  itemCount: history.length,
                  separatorBuilder: (_, _) => Divider(color: Colors.white.withValues(alpha: 0.08)),
                  itemBuilder: (ctx, i) {
                    final item = history[i];
                    final dateStr = item['timestamp'] as String? ?? '';
                    final dt = DateTime.tryParse(dateStr) ?? DateTime.now();
                    final freed = (item['workingSetFreedMb'] as num?)?.toDouble() ??
                        (item['ramFreedMb'] as num?)?.toDouble() ??
                        0.0;
                    final privFreed =
                        (item['privateBytesFreedMb'] as num?)?.toDouble() ?? 0.0;
                    final actions = (item['actionsTaken'] as List?)?.whereType<String>().toList() ?? [];

                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 6),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                DateFormat('MMM dd, yyyy - hh:mm:ss a').format(dt),
                                style: const TextStyle(color: Colors.white70, fontSize: 12),
                              ),
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                                decoration: BoxDecoration(
                                  color: const Color(0xFF10B981).withValues(alpha: 0.15),
                                  borderRadius: BorderRadius.circular(6),
                                  border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                                ),
                                child: Text(
                                  freed > 0 || privFreed > 0
                                      ? (privFreed > 0
                                          ? '-${freed.toStringAsFixed(1)} MB WS | -${privFreed.toStringAsFixed(1)} MB Priv'
                                          : '-${freed.toStringAsFixed(1)} MB RAM')
                                      : 'Stabilized (${(item['workingSetAfterMb'] as num?)?.toStringAsFixed(0) ?? "Stable"} MB)',
                                  style: const TextStyle(
                                    color: Color(0xFF10B981),
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                  ),
                                ),
                              ),
                            ],
                          ),
                          if (actions.isNotEmpty) ...[
                            const SizedBox(height: 4),
                            Text(
                              actions.join(' • '),
                              style: const TextStyle(color: Colors.white38, fontSize: 11),
                            ),
                          ],
                        ],
                      ),
                    );
                  },
                ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('Close', style: TextStyle(color: Color(0xFF38BDF8))),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: const Color(0xFF080A10),
      child: ListView(
        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 24),
        children: [
          _buildHeader(),
          const SizedBox(height: 22),
          _buildSectionADeviceOverview(),
          const SizedBox(height: 24),
          _buildSectionBOverallOptimizationAction(),
          const SizedBox(height: 24),
          _buildSectionDPerformanceProfiles(),
          const SizedBox(height: 24),
          _buildSectionEAdvancedControls(),
          const SizedBox(height: 24),
          _buildSectionCApplicationOptimizer(),
          const SizedBox(height: 24),
          _buildSectionFRecovery(),
          const SizedBox(height: 40),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              children: [
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: const Color(0xFF38BDF8).withValues(alpha: 0.12),
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.3)),
                  ),
                  child: const Icon(Icons.speed_rounded, color: Color(0xFF38BDF8), size: 22),
                ),
                const SizedBox(width: 14),
                const Text(
                  'Device Optimization',
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w900,
                    letterSpacing: 0.5,
                    color: Colors.white,
                  ),
                ),
                const SizedBox(width: 10),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                  decoration: BoxDecoration(
                    color: const Color(0xFF10B981).withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(8),
                    border: Border.all(color: const Color(0xFF10B981).withValues(alpha: 0.3)),
                  ),
                  child: Text(
                    (_winVer?.isWindows11 ?? true) ? 'WINDOWS 11 TUNED' : 'WINDOWS 10 TUNED',
                    style: const TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w800,
                      color: Color(0xFF10B981),
                      letterSpacing: 0.8,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            const Text(
              'Real-time Windows kernel diagnostics, native memory trimming, and hardware-accelerated profiles.',
              style: TextStyle(fontSize: 13, color: Colors.white54),
            ),
          ],
        ),
      ],
    );
  }

  // ── SECTION A: Device Performance Overview ────────────────────────────────
  Widget _buildSectionADeviceOverview() {
    final cpuPercent = _metrics?.cpuPercent ?? 0.0;
    final totalPhysMb = _metrics?.totalPhysMb ?? 8192.0;
    final availPhysMb = _metrics?.availPhysMb ?? 4096.0;
    final usedPhysMb = totalPhysMb > availPhysMb ? (totalPhysMb - availPhysMb) : 0.0;
    final ramLoadPercent = _metrics?.ramLoadPercent ?? ((usedPhysMb / totalPhysMb) * 100);

    final appWorkingSet = _metrics?.processWorkingSetMb ?? 0.0;
    final mpvWorkingSet = _metrics?.mpvWorkingSetMb ?? 0.0;
    final totalAppRam = appWorkingSet + mpvWorkingSet;

    final gpuName = _gpuInfo?.gpuName ?? 'Hardware Direct3D 11 / Vulkan';
    final dedicatedVram = _gpuInfo?.dedicatedVramMb ?? 0.0;
    final refreshRate = _gpuInfo?.refreshRateHz ?? 60;
    final screenRes = _gpuInfo?.screenWidth != null
        ? '${_gpuInfo!.screenWidth}x${_gpuInfo!.screenHeight}'
        : 'Primary Display';

    final activeOverlaysCount = widget.settings.activeWidgetIds.length;
    final wallpaperMode = widget.settings.activeWallpaperType.toUpperCase();

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'DEVICE PERFORMANCE OVERVIEW',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: Color(0xFF38BDF8),
          ),
        ),
        const SizedBox(height: 12),
        Row(
          children: [
            // CPU Card
            Expanded(
              child: _buildMetricCard(
                icon: Icons.memory_rounded,
                title: 'CPU Utilization',
                value: '${cpuPercent.toStringAsFixed(1)}%',
                subtitle: '${_winVer?.processorCount ?? 8} Hardware Cores Available',
                accentColor: cpuPercent > 80
                    ? const Color(0xFFF43F5E)
                    : cpuPercent > 45
                        ? Colors.amberAccent
                        : const Color(0xFF10B981),
                progress: (cpuPercent / 100).clamp(0.0, 1.0),
              ),
            ),
            const SizedBox(width: 14),
            // RAM Card
            Expanded(
              child: _buildMetricCard(
                icon: Icons.storage_rounded,
                title: 'System Memory (RAM)',
                value: '${ramLoadPercent.toStringAsFixed(0)}% Used',
                subtitle:
                    '${(usedPhysMb / 1024).toStringAsFixed(1)} GB / ${(totalPhysMb / 1024).toStringAsFixed(1)} GB Total',
                accentColor: ramLoadPercent > 85
                    ? const Color(0xFFF43F5E)
                    : const Color(0xFF38BDF8),
                progress: (ramLoadPercent / 100).clamp(0.0, 1.0),
              ),
            ),
            const SizedBox(width: 14),
            // WallSync Footprint Card
            Expanded(
              child: _buildMetricCard(
                icon: Icons.widgets_rounded,
                title: 'WallSync Working Set',
                value: '${totalAppRam.toStringAsFixed(1)} MB',
                subtitle: mpvWorkingSet > 0
                    ? 'Main: ${appWorkingSet.toStringAsFixed(0)}MB • MPV: ${mpvWorkingSet.toStringAsFixed(0)}MB'
                    : 'Main UI Process + Child Workers',
                accentColor: totalAppRam > 300
                    ? Colors.amberAccent
                    : const Color(0xFF818CF8),
                progress: (totalAppRam / 500).clamp(0.0, 1.0),
              ),
            ),
            const SizedBox(width: 14),
            // GPU & Display Card
            Expanded(
              child: _buildMetricCard(
                icon: Icons.tv_rounded,
                title: 'GPU & Display',
                value: '${refreshRate}Hz @ $screenRes',
                subtitle: dedicatedVram > 0
                    ? '$gpuName (${(dedicatedVram / 1024).toStringAsFixed(1)}GB VRAM)'
                    : gpuName,
                accentColor: const Color(0xFF10B981),
                progress: 1.0,
              ),
            ),
          ],
        ),
        const SizedBox(height: 12),
        // Live App Status Strip
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
          decoration: BoxDecoration(
            color: const Color(0xFF12141D),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
          ),
          child: Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              _buildStatusPill(
                Icons.layers_rounded,
                'Active Overlays',
                '$activeOverlaysCount Running',
                const Color(0xFF38BDF8),
              ),
              _buildStatusPill(
                Icons.wallpaper_rounded,
                'Wallpaper Engine',
                wallpaperMode,
                wallpaperMode == 'VIDEO' ? const Color(0xFFEC4899) : const Color(0xFF10B981),
              ),
              _buildStatusPill(
                Icons.eco_rounded,
                'EcoQoS Throttling',
                widget.settings.performanceProfile == 'power_saver' ? 'Enabled' : 'Disabled',
                widget.settings.performanceProfile == 'power_saver'
                    ? const Color(0xFF10B981)
                    : Colors.white54,
              ),
              _buildStatusPill(
                Icons.tune_rounded,
                'Active Profile',
                widget.settings.performanceProfile.toUpperCase(),
                const Color(0xFF818CF8),
              ),
            ],
          ),
        ),
      ],
    );
  }

  Widget _buildMetricCard({
    required IconData icon,
    required String title,
    required String value,
    required String subtitle,
    required Color accentColor,
    required double progress,
  }) {
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: const Color(0xFF12141D),
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 18, color: accentColor),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  title,
                  style: const TextStyle(fontSize: 12, color: Colors.white60, fontWeight: FontWeight.w500),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            value,
            style: const TextStyle(
              fontSize: 19,
              fontWeight: FontWeight.w800,
              color: Colors.white,
              letterSpacing: 0.3,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            subtitle,
            style: const TextStyle(fontSize: 11, color: Colors.white38),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(3),
            child: LinearProgressIndicator(
              value: progress,
              backgroundColor: Colors.white.withValues(alpha: 0.06),
              valueColor: AlwaysStoppedAnimation(accentColor),
              minHeight: 4,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildStatusPill(IconData icon, String label, String value, Color color) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(icon, size: 16, color: color),
        const SizedBox(width: 8),
        Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(label, style: const TextStyle(fontSize: 10.5, color: Colors.white38)),
            Text(value, style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold, color: color)),
          ],
        ),
      ],
    );
  }

  // ── SECTION B: Overall Performance Optimization ───────────────────────────
  Widget _buildSectionBOverallOptimizationAction() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: [
            const Color(0xFF38BDF8).withValues(alpha: 0.08),
            const Color(0xFF161824),
          ],
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
        ),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: const Color(0xFF38BDF8).withValues(alpha: 0.2)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    const Icon(Icons.bolt_rounded, color: Color(0xFF38BDF8), size: 24),
                    const SizedBox(width: 8),
                    const Text(
                      'Overall Performance Optimization',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.bold,
                        color: Colors.white,
                      ),
                    ),
                    const SizedBox(width: 10),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                      decoration: BoxDecoration(
                        color: const Color(0xFF10B981).withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(6),
                      ),
                      child: const Text(
                        'READY',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.bold,
                          color: Color(0xFF10B981),
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
                const Text(
                  'Instantly trims unused virtual memory pages across WallSync and MPV, compacts native heaps, flushes image decode buffers, and frees RAM with 0 visual glitching.',
                  style: TextStyle(fontSize: 13, color: Colors.white70, height: 1.4),
                ),
                if (_lastResult != null) ...[
                  const SizedBox(height: 10),
                  Text(
                    'Last run: Trimmed ${_lastResult!.workingSetFreedMb.toStringAsFixed(1)} MB Working Set'
                    '${_lastResult!.privateBytesFreedMb > 0 ? " • ${_lastResult!.privateBytesFreedMb.toStringAsFixed(1)} MB Private Commit" : ""} '
                    '(${_lastResult!.actionsTaken.length} actions completed).',
                    style: const TextStyle(fontSize: 12, color: Color(0xFF10B981), fontWeight: FontWeight.w600),
                  ),
                ],
              ],
            ),
          ),
          const SizedBox(width: 24),
          ElevatedButton.icon(
            onPressed: _isOptimizing ? null : _runOverallOptimization,
            icon: _isOptimizing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2, color: Colors.black),
                  )
                : const Icon(Icons.rocket_launch_rounded, size: 18),
            label: Text(
              _isOptimizing ? 'Optimizing...' : 'Optimize Overall Performance',
              style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13),
            ),
            style: ElevatedButton.styleFrom(
              backgroundColor: const Color(0xFF38BDF8),
              foregroundColor: const Color(0xFF070913),
              padding: const EdgeInsets.symmetric(horizontal: 22, vertical: 16),
              shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
              elevation: 4,
            ),
          ),
        ],
      ),
    );
  }

  // ── SECTION D: Performance Profiles ───────────────────────────────────────
  Widget _buildSectionDPerformanceProfiles() {
    final currentProfile = widget.settings.performanceProfile;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text(
          'PERFORMANCE PROFILES',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w800,
            letterSpacing: 1.2,
            color: Color(0xFF38BDF8),
          ),
        ),
        const SizedBox(height: 6),
        const Text(
          'Select a tuned performance profile or fine-tune individual engine parameters below.',
          style: TextStyle(fontSize: 13, color: Colors.white54),
        ),
        const SizedBox(height: 14),
        LayoutBuilder(
          builder: (context, constraints) {
            final cardWidth = constraints.maxWidth > 900
                ? (constraints.maxWidth - 48) / 5
                : (constraints.maxWidth - 12) / 2;
            return Wrap(
              spacing: 12,
              runSpacing: 12,
              children: PerformanceProfileConfig.profiles.values.map((prof) {
                final isSelected = currentProfile == prof.id;
                return SizedBox(
                  width: cardWidth,
                  child: InkWell(
                    onTap: () => _selectProfile(prof.id),
                    borderRadius: BorderRadius.circular(14),
                    child: Container(
                      padding: const EdgeInsets.all(16),
                      decoration: BoxDecoration(
                        color: isSelected
                            ? const Color(0xFF38BDF8).withValues(alpha: 0.12)
                            : const Color(0xFF12141D),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: isSelected
                              ? const Color(0xFF38BDF8)
                              : Colors.white.withValues(alpha: 0.08),
                          width: isSelected ? 1.5 : 1.0,
                        ),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            mainAxisAlignment: MainAxisAlignment.spaceBetween,
                            children: [
                              Text(
                                prof.label,
                                style: TextStyle(
                                  fontSize: 15,
                                  fontWeight: FontWeight.bold,
                                  color: isSelected ? const Color(0xFF38BDF8) : Colors.white,
                                ),
                              ),
                              if (isSelected)
                                const Icon(Icons.check_circle_rounded, color: Color(0xFF38BDF8), size: 18),
                            ],
                          ),
                          const SizedBox(height: 8),
                          Text(
                            prof.description,
                            style: const TextStyle(fontSize: 11.5, color: Colors.white54, height: 1.35),
                            maxLines: 3,
                            overflow: TextOverflow.ellipsis,
                          ),
                          const SizedBox(height: 12),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            children: [
                              _buildProfileBadge('${prof.wallpaperFpsLimit} FPS'),
                              _buildProfileBadge('${prof.widgetRefreshIntervalMs}ms Refresh'),
                              _buildProfileBadge('${prof.imageCacheLimitMb}MB Cache'),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ),
                );
              }).toList(),
            );
          },
        ),
      ],
    );
  }

  Widget _buildProfileBadge(String text) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.05),
        borderRadius: BorderRadius.circular(5),
      ),
      child: Text(text, style: const TextStyle(fontSize: 9.5, color: Colors.white70)),
    );
  }

  // ── SECTION E: Advanced Optimization Controls ─────────────────────────────
  Widget _buildSectionEAdvancedControls() {
    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF12141D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            'ADVANCED OPTIMIZATION CONTROLS',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              letterSpacing: 1.2,
              color: Color(0xFF38BDF8),
            ),
          ),
          const SizedBox(height: 16),
          // Wallpaper FPS slider
          _buildSliderRow(
            label: 'Wallpaper Frame Rate Cap',
            valueText: '${widget.settings.wallpaperFpsLimit} FPS',
            value: widget.settings.wallpaperFpsLimit.toDouble(),
            min: 15,
            max: 120,
            divisions: 7,
            onChanged: (val) async {
              final updated = await widget.settingsService.updateSettings(
                (c) => c.copyWith(
                  wallpaperFpsLimit: val.round(),
                  performanceProfile: 'custom',
                ),
              );
              widget.onSettingsChanged(updated);
              setState(() {});
            },
          ),
          const Divider(color: Colors.white12, height: 24),
          // Widget Refresh Interval
          _buildSliderRow(
            label: 'Widget Data Refresh Interval',
            valueText: '${widget.settings.widgetRefreshIntervalMs} ms',
            value: widget.settings.widgetRefreshIntervalMs.toDouble(),
            min: 250,
            max: 5000,
            divisions: 19,
            onChanged: (val) async {
              final updated = await widget.settingsService.updateSettings(
                (c) => c.copyWith(
                  widgetRefreshIntervalMs: val.round(),
                  performanceProfile: 'custom',
                ),
              );
              widget.onSettingsChanged(updated);
              setState(() {});
            },
          ),
          const Divider(color: Colors.white12, height: 24),
          // Image cache size limit
          _buildSliderRow(
            label: 'Decoded Image Cache Boundary',
            valueText: '${widget.settings.imageCacheLimitMb} MB',
            value: widget.settings.imageCacheLimitMb.toDouble(),
            min: 8,
            max: 64,
            divisions: 7,
            onChanged: (val) async {
              final updated = await widget.settingsService.updateSettings(
                (c) => c.copyWith(
                  imageCacheLimitMb: val.round(),
                  performanceProfile: 'custom',
                ),
              );
              PaintingBinding.instance.imageCache.maximumSizeBytes =
                  val.round() * 1024 * 1024;
              widget.onSettingsChanged(updated);
              setState(() {});
            },
          ),
          const Divider(color: Colors.white12, height: 24),
          // Switches
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Auto-Pause Inactive Background Animations', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('Suspends animation loops when dashboard or overlay is unfocused or obscured by games.', style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: widget.settings.pauseInactiveAnimations,
              activeThumbColor: const Color(0xFF38BDF8),
              onChanged: (val) async {
                final updated = await widget.settingsService.updateSettings(
                  (c) => c.copyWith(pauseInactiveAnimations: val, performanceProfile: 'custom'),
                );
                widget.onSettingsChanged(updated);
                setState(() {});
              },
            ),
          ),
          Material(
            type: MaterialType.transparency,
            child: SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Automatic Widget Sizing (Default ON)', style: TextStyle(color: Colors.white, fontSize: 14)),
              subtitle: const Text('Automatically adapts widget window dimensions to content length and Windows display DPI.', style: TextStyle(color: Colors.white54, fontSize: 12)),
              value: widget.settings.autoSizing,
              activeThumbColor: const Color(0xFF10B981),
              onChanged: (val) async {
                final updated = await widget.settingsService.updateSettings(
                  (c) => c.copyWith(autoSizing: val),
                );
                widget.onSettingsChanged(updated);
                setState(() {});
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSliderRow({
    required String label,
    required String valueText,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required ValueChanged<double> onChanged,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(label, style: const TextStyle(color: Colors.white, fontSize: 13.5)),
            Text(valueText, style: const TextStyle(color: Color(0xFF38BDF8), fontWeight: FontWeight.bold, fontSize: 13.5)),
          ],
        ),
        Slider(
          value: value.clamp(min, max),
          min: min,
          max: max,
          divisions: divisions,
          activeColor: const Color(0xFF38BDF8),
          inactiveColor: Colors.white.withValues(alpha: 0.1),
          onChanged: onChanged,
        ),
      ],
    );
  }

  // ── SECTION C: Application Optimizer ──────────────────────────────────────
  Widget _buildSectionCApplicationOptimizer() {
    final filtered = _processes.where((p) {
      if (_processFilter == 'wallsync' && !p.isWallSync) return false;
      if (_processSearchQuery.isNotEmpty &&
          !p.name.toLowerCase().contains(_processSearchQuery.toLowerCase())) {
        return false;
      }
      return true;
    }).toList();

    return Container(
      padding: const EdgeInsets.all(20),
      decoration: BoxDecoration(
        color: const Color(0xFF12141D),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'APPLICATION OPTIMIZER & PROCESS MONITOR',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 1.2,
                      color: Color(0xFF38BDF8),
                    ),
                  ),
                  SizedBox(height: 4),
                  Text(
                    'Inspect active WallSync components and running Windows processes with safe memory trim controls.',
                    style: TextStyle(fontSize: 12, color: Colors.white54),
                  ),
                ],
              ),
              Row(
                children: [
                  // Filter toggle
                  SegmentedButton<String>(
                    segments: const [
                      ButtonSegment(value: 'all', label: Text('All Processes')),
                      ButtonSegment(value: 'wallsync', label: Text('WallSync Only')),
                    ],
                    selected: {_processFilter},
                    onSelectionChanged: (set) => setState(() => _processFilter = set.first),
                    style: ButtonStyle(
                      textStyle: WidgetStateProperty.all(const TextStyle(fontSize: 11)),
                    ),
                  ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 14),
          // Search box
          TextField(
            onChanged: (val) => setState(() => _processSearchQuery = val),
            style: const TextStyle(color: Colors.white, fontSize: 13),
            decoration: InputDecoration(
              hintText: 'Search processes by name or PID...',
              hintStyle: const TextStyle(color: Colors.white38, fontSize: 13),
              prefixIcon: const Icon(Icons.search_rounded, color: Colors.white38, size: 18),
              isDense: true,
              filled: true,
              fillColor: Colors.black.withValues(alpha: 0.25),
              border: OutlineInputBorder(
                borderRadius: BorderRadius.circular(10),
                borderSide: BorderSide.none,
              ),
            ),
          ),
          const SizedBox(height: 14),
          // Process Table
          Container(
            constraints: const BoxConstraints(maxHeight: 260),
            decoration: BoxDecoration(
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
              borderRadius: BorderRadius.circular(10),
            ),
            child: ListView.separated(
              itemCount: filtered.length,
              separatorBuilder: (_, _) => Divider(color: Colors.white.withValues(alpha: 0.04), height: 1),
              itemBuilder: (ctx, i) {
                final proc = filtered[i];
                return Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                  child: Row(
                    children: [
                      Icon(
                        proc.isWallSync ? Icons.widgets_rounded : Icons.apps_rounded,
                        size: 16,
                        color: proc.isWallSync ? const Color(0xFF38BDF8) : Colors.white38,
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        flex: 3,
                        child: Text(
                          proc.name,
                          style: TextStyle(
                            color: proc.isWallSync ? const Color(0xFF38BDF8) : Colors.white,
                            fontSize: 12.5,
                            fontWeight: proc.isWallSync ? FontWeight.bold : FontWeight.normal,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Expanded(
                        flex: 1,
                        child: Text(
                          'PID: ${proc.pid}',
                          style: const TextStyle(color: Colors.white38, fontSize: 11),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          '${proc.workingSetMb.toStringAsFixed(1)} MB',
                          style: const TextStyle(color: Colors.white70, fontSize: 12),
                        ),
                      ),
                      if (proc.isWallSync)
                        TextButton(
                          onPressed: () async {
                            final ok = await _optimizer.trimProcessMemory(proc.pid);
                            if (ok) {
                              await _pollMetrics();
                              if (mounted) {
                                ScaffoldMessenger.of(context).showSnackBar(
                                  SnackBar(
                                    backgroundColor: const Color(0xFF10B981),
                                    content: Text('Trimmed memory for ${proc.name} (PID ${proc.pid})'),
                                    duration: const Duration(seconds: 1),
                                  ),
                                );
                              }
                            }
                          },
                          style: TextButton.styleFrom(
                            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                            minimumSize: Size.zero,
                            tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                          ),
                          child: const Text('Trim RAM', style: TextStyle(fontSize: 11, color: Color(0xFF38BDF8))),
                        ),
                    ],
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  // ── SECTION F: Safe Recovery & History ────────────────────────────────────
  Widget _buildSectionFRecovery() {
    return Row(
      mainAxisAlignment: MainAxisAlignment.spaceBetween,
      children: [
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _restoreDefaults,
              icon: const Icon(Icons.settings_backup_restore_rounded, size: 16),
              label: const Text('Restore Balanced Defaults', style: TextStyle(fontSize: 12.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
            const SizedBox(width: 12),
            OutlinedButton.icon(
              onPressed: _undoLastOptimization,
              icon: const Icon(Icons.undo_rounded, size: 16),
              label: const Text('Undo Last Optimization', style: TextStyle(fontSize: 12.5)),
              style: OutlinedButton.styleFrom(
                foregroundColor: Colors.white70,
                side: BorderSide(color: Colors.white.withValues(alpha: 0.15)),
                padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
              ),
            ),
          ],
        ),
        TextButton.icon(
          onPressed: _showOptimizationHistory,
          icon: const Icon(Icons.history_rounded, size: 16, color: Color(0xFF38BDF8)),
          label: const Text(
            'View Optimization History',
            style: TextStyle(color: Color(0xFF38BDF8), fontSize: 13, fontWeight: FontWeight.bold),
          ),
        ),
      ],
    );
  }
}
