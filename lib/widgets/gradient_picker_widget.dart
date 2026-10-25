import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'color_picker_widget.dart';

/// A rich, state-of-the-art interactive gradient designer and color stop picker.
/// Features:
///  - Real-time interactive gradient preview
///  - Multi-stop color management (Add, Remove, Select, Reverse stops)
///  - Full Alpha/Opacity color picker for individual stops
///  - Procedural "Generate Gradient" engine with harmonic color algorithms
///  - Curated library of 18 designer preset gradients
class GradientPickerWidget extends StatefulWidget {
  final List<Color> initialColors;
  final ValueChanged<List<Color>> onGradientChanged;
  final List<Color>? paletteColors;
  final VoidCallback? onSaveToPalette;

  const GradientPickerWidget({
    super.key,
    required this.initialColors,
    required this.onGradientChanged,
    this.paletteColors,
    this.onSaveToPalette,
  });

  @override
  State<GradientPickerWidget> createState() => _GradientPickerWidgetState();
}

class _GradientPickerWidgetState extends State<GradientPickerWidget> {
  late List<Color> _stops;
  int _activeStopIndex = 0;

  // Curated Designer Presets
  static const List<List<Color>> _presets = [
    [Color(0xFF00F0FF), Color(0xFFD946EF)], // Cyberpunk Neon
    [Color(0xFF00F260), Color(0xFF0575E6)], // Aurora Borealis
    [Color(0xFFFF416C), Color(0xFFFF4B2B)], // Sunset Ember
    [Color(0xFFF72585), Color(0xFF7209B7), Color(0xFF3F37C9)], // Cosmic Nebula
    [Color(0xFF8E2DE2), Color(0xFF4A00E0)], // Deep Violet
    [Color(0xFF02AAB0), Color(0xFF00CDAC)], // Mint to Azure
    [Color(0xFFFFD700), Color(0xFFFF6A00)], // Solar Gold
    [Color(0xFF38BDF8), Color(0xFFA855F7), Color(0xFFEC4899)], // Holographic
    [Color(0xFF10B981), Color(0xFF06B6D4)], // Emerald Coast
    [Color(0xFFFA709A), Color(0xFFFEE140)], // Peach Sorbet
    [Color(0xFF30CFD0), Color(0xFF330867)], // Dark Cyan Void
    [Color(0xFF43E97B), Color(0xFF38F9D7)], // Tropical Lagoon
    [Color(0xFFF857A6), Color(0xFFFF5858)], // Neon Flamingo
    [Color(0xFF00C6FF), Color(0xFF0072FF)], // Electric Blue
    [Color(0xFF667EEA), Color(0xFF764BA2)], // Royal Plum
    [Color(0xFFF12711), Color(0xFFF5AF19)], // Flame Forge
    [Color(0xFF13547A), Color(0xFF80D0C7)], // Sea Breeze
    [Color(0xFFF355DA), Color(0xFF7E0DF2), Color(0xFF1AE3F2)], // Synthwave Glow
  ];

  @override
  void initState() {
    super.initState();
    _stops = widget.initialColors.length >= 2
        ? List<Color>.from(widget.initialColors)
        : [const Color(0xFF00F0FF), const Color(0xFFD946EF)];
    _activeStopIndex = 0;
  }

  @override
  void didUpdateWidget(GradientPickerWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_areGradientsDifferent(oldWidget.initialColors, widget.initialColors)) {
      _stops = widget.initialColors.length >= 2
          ? List<Color>.from(widget.initialColors)
          : [const Color(0xFF00F0FF), const Color(0xFFD946EF)];
      if (_activeStopIndex >= _stops.length) {
        _activeStopIndex = 0;
      }
    }
  }

  bool _areGradientsDifferent(List<Color> a, List<Color> b) {
    if (a.length != b.length) return true;
    for (int i = 0; i < a.length; i++) {
      if (a[i].toARGB32() != b[i].toARGB32()) return true;
    }
    return false;
  }

  void _notifyChange() {
    widget.onGradientChanged(List<Color>.unmodifiable(_stops));
  }

  void _addStop() {
    if (_stops.length >= 6) return;
    final last = _stops.last;
    final secondLast = _stops[_stops.length - 2];
    final interpolated = Color.lerp(secondLast, last, 0.5) ?? last;

    setState(() {
      _stops.add(interpolated);
      _activeStopIndex = _stops.length - 1;
    });
    _notifyChange();
  }

  void _removeActiveStop() {
    if (_stops.length <= 2) return;
    setState(() {
      _stops.removeAt(_activeStopIndex);
      if (_activeStopIndex >= _stops.length) {
        _activeStopIndex = _stops.length - 1;
      }
    });
    _notifyChange();
  }

  void _reverseGradient() {
    setState(() {
      _stops = _stops.reversed.toList();
      _activeStopIndex = (_stops.length - 1 - _activeStopIndex).clamp(0, _stops.length - 1);
    });
    _notifyChange();
  }

  void _generateHarmonicGradient() {
    final rng = math.Random();
    // 35% chance to pick a curated preset, 65% chance to procedurally synthesize
    if (rng.nextDouble() < 0.35) {
      final preset = _presets[rng.nextInt(_presets.length)];
      setState(() {
        _stops = List<Color>.from(preset);
        _activeStopIndex = 0;
      });
      _notifyChange();
      return;
    }

    // Procedural harmonic generation:
    final baseHue = rng.nextDouble() * 360.0;
    final count = rng.nextBool() ? 2 : 3;
    final List<Color> newStops = [];

    final schemeType = rng.nextInt(3);
    if (schemeType == 0) {
      // Analogous (smooth, elegant color drift)
      final step = 35.0 + rng.nextDouble() * 25.0;
      for (int i = 0; i < count; i++) {
        final h = (baseHue + (i * step)) % 360.0;
        final s = 0.75 + rng.nextDouble() * 0.25;
        final v = 0.85 + rng.nextDouble() * 0.15;
        newStops.add(HSVColor.fromAHSV(1.0, h, s, v).toColor());
      }
    } else if (schemeType == 1) {
      // High-Contrast Cyberpunk / Complementary
      final h1 = baseHue;
      final h2 = (baseHue + 140.0 + rng.nextDouble() * 60.0) % 360.0;
      newStops.add(HSVColor.fromAHSV(1.0, h1, 0.85, 0.95).toColor());
      if (count == 3) {
        final hMid = (baseHue + 60.0) % 360.0;
        newStops.add(HSVColor.fromAHSV(1.0, hMid, 0.80, 0.95).toColor());
      }
      newStops.add(HSVColor.fromAHSV(1.0, h2, 0.90, 0.95).toColor());
    } else {
      // Triadic Vibrant
      for (int i = 0; i < count; i++) {
        final h = (baseHue + (i * 120.0)) % 360.0;
        newStops.add(HSVColor.fromAHSV(1.0, h, 0.85, 0.95).toColor());
      }
    }

    setState(() {
      _stops = newStops;
      _activeStopIndex = 0;
    });
    _notifyChange();
  }

  void _applyPreset(List<Color> preset) {
    setState(() {
      _stops = List<Color>.from(preset);
      _activeStopIndex = 0;
    });
    _notifyChange();
  }

  void _updateActiveStopColor(Color newColor) {
    setState(() {
      _stops[_activeStopIndex] = newColor;
    });
    _notifyChange();
  }

  @override
  Widget build(BuildContext context) {
    final activeColor = _stops[_activeStopIndex];

    return Container(
      constraints: const BoxConstraints(maxWidth: 320),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        mainAxisSize: MainAxisSize.min,
        children: [
          // ── 1. Live Gradient Preview Banner ──
          Container(
            height: 48,
            decoration: BoxDecoration(
              borderRadius: BorderRadius.circular(12),
              border: Border.all(
                color: Colors.white.withValues(alpha: 0.18),
                width: 1.2,
              ),
              boxShadow: [
                BoxShadow(
                  color: _stops.first.withValues(alpha: 0.25),
                  blurRadius: 16,
                  offset: const Offset(0, 4),
                ),
              ],
            ),
            child: ClipRRect(
              borderRadius: BorderRadius.circular(10.8),
              child: Stack(
                children: [
                  Positioned.fill(
                    child: CustomPaint(
                      painter: _GradientCheckerboardPainter(),
                    ),
                  ),
                  Positioned.fill(
                    child: Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          colors: _stops,
                          begin: Alignment.centerLeft,
                          end: Alignment.centerRight,
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),

          const SizedBox(height: 12),

          // ── 2. Stop Chips & Control Toolbar ──
          Row(
            children: [
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 6,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  children: List.generate(_stops.length, (index) {
                    final isSelected = index == _activeStopIndex;
                    final stopColor = _stops[index];
                    return GestureDetector(
                      onTap: () => setState(() => _activeStopIndex = index),
                      child: AnimatedContainer(
                        duration: const Duration(milliseconds: 150),
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        decoration: BoxDecoration(
                          color: isSelected
                              ? const Color(0xFF38BDF8).withValues(alpha: 0.2)
                              : Colors.white.withValues(alpha: 0.04),
                          borderRadius: BorderRadius.circular(8),
                          border: Border.all(
                            color: isSelected
                                ? const Color(0xFF38BDF8)
                                : Colors.white.withValues(alpha: 0.1),
                            width: isSelected ? 1.5 : 1.0,
                          ),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: stopColor,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: Colors.white,
                                  width: 1.2,
                                ),
                                boxShadow: [
                                  BoxShadow(
                                    color: stopColor.withValues(alpha: 0.4),
                                    blurRadius: 4,
                                  ),
                                ],
                              ),
                            ),
                            const SizedBox(width: 5),
                            Text(
                              '#${index + 1}',
                              style: TextStyle(
                                fontSize: 10,
                                fontWeight: isSelected ? FontWeight.w800 : FontWeight.w600,
                                color: isSelected ? Colors.white : Colors.white70,
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  }),
                ),
              ),

              // Action Buttons: Add, Remove, Reverse
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  if (_stops.length < 6)
                    Tooltip(
                      message: 'Add Color Stop',
                      child: IconButton(
                        icon: const Icon(Icons.add_rounded, size: 16),
                        onPressed: _addStop,
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.05),
                          foregroundColor: const Color(0xFF38BDF8),
                          padding: const EdgeInsets.all(6),
                          minimumSize: const Size(28, 28),
                        ),
                      ),
                    ),
                  if (_stops.length > 2) ...[
                    const SizedBox(width: 4),
                    Tooltip(
                      message: 'Remove Active Stop',
                      child: IconButton(
                        icon: const Icon(Icons.delete_outline_rounded, size: 16),
                        onPressed: _removeActiveStop,
                        visualDensity: VisualDensity.compact,
                        style: IconButton.styleFrom(
                          backgroundColor: Colors.white.withValues(alpha: 0.05),
                          foregroundColor: Colors.redAccent,
                          padding: const EdgeInsets.all(6),
                          minimumSize: const Size(28, 28),
                        ),
                      ),
                    ),
                  ],
                  const SizedBox(width: 4),
                  Tooltip(
                    message: 'Reverse Gradient Order',
                    child: IconButton(
                      icon: const Icon(Icons.swap_horiz_rounded, size: 16),
                      onPressed: _reverseGradient,
                      visualDensity: VisualDensity.compact,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.05),
                        foregroundColor: Colors.white70,
                        padding: const EdgeInsets.all(6),
                        minimumSize: const Size(28, 28),
                      ),
                    ),
                  ),
                ],
              ),
            ],
          ),

          const SizedBox(height: 12),

          // ── 3. "Generate Gradient" & Quick Preset Library ──
          Row(
            children: [
              Expanded(
                child: ElevatedButton.icon(
                  onPressed: _generateHarmonicGradient,
                  icon: const Icon(Icons.auto_awesome_rounded, size: 14),
                  label: const Text(
                    'Generate Gradient',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w800,
                      letterSpacing: 0.4,
                    ),
                  ),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: const Color(0xFFEC4899).withValues(alpha: 0.2),
                    foregroundColor: const Color(0xFFEC4899),
                    elevation: 0,
                    padding: const EdgeInsets.symmetric(vertical: 9, horizontal: 10),
                    shape: RoundedRectangleBorder(
                      borderRadius: BorderRadius.circular(8),
                      side: BorderSide(
                        color: const Color(0xFFEC4899).withValues(alpha: 0.4),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          ),

          const SizedBox(height: 14),

          // ── 4. Preset Gradients Horizontal Strip ──
          const Text(
            'GRADIENT PRESETS',
            style: TextStyle(
              color: Colors.white38,
              fontSize: 9,
              fontWeight: FontWeight.w900,
              letterSpacing: 1.2,
            ),
          ),
          const SizedBox(height: 6),
          SizedBox(
            height: 32,
            child: ListView.separated(
              scrollDirection: Axis.horizontal,
              itemCount: _presets.length,
              separatorBuilder: (_, _) => const SizedBox(width: 6),
              itemBuilder: (context, i) {
                final preset = _presets[i];
                return GestureDetector(
                  onTap: () => _applyPreset(preset),
                  child: Container(
                    width: 44,
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        colors: preset,
                        begin: Alignment.topLeft,
                        end: Alignment.bottomRight,
                      ),
                      borderRadius: BorderRadius.circular(6),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.15),
                        width: 1.0,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: preset.first.withValues(alpha: 0.2),
                          blurRadius: 4,
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),

          const SizedBox(height: 14),

          // ── 5. Active Stop Color & Alpha Editor ──
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.03),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Colors.white.withValues(alpha: 0.06)),
            ),
            child: Row(
              children: [
                Icon(
                  Icons.colorize_rounded,
                  size: 13,
                  color: const Color(0xFF38BDF8),
                ),
                const SizedBox(width: 6),
                Text(
                  'EDIT STOP #${_activeStopIndex + 1} COLOR & ALPHA',
                  style: const TextStyle(
                    fontSize: 9.5,
                    fontWeight: FontWeight.w800,
                    letterSpacing: 0.8,
                    color: Color(0xFF38BDF8),
                  ),
                ),
              ],
            ),
          ),

          const SizedBox(height: 10),

          // Embedded ColorPickerWidget for selected stop
          ColorPickerWidget(
            initialColor: activeColor,
            paletteColors: widget.paletteColors ?? const [],
            enableAlpha: true,
            onColorChanged: _updateActiveStopColor,
            onSaveTopalette: widget.onSaveToPalette,
          ),
        ],
      ),
    );
  }
}

class _GradientCheckerboardPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    const double cellSize = 6.0;
    final paintDark = Paint()..color = const Color(0xFF1E232B);
    final paintLight = Paint()..color = const Color(0xFF343B48);

    for (double y = 0; y < size.height; y += cellSize) {
      for (double x = 0; x < size.width; x += cellSize) {
        final isEven = (((x / cellSize).floor() + (y / cellSize).floor()) % 2 == 0);
        canvas.drawRect(
          Rect.fromLTWH(x, y, cellSize, cellSize),
          isEven ? paintLight : paintDark,
        );
      }
    }
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}
