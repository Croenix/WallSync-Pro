import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// A modern, intuitive HSV color picker widget with full Alpha / Opacity support.
/// Featuring:
///  - Rectangular SV box selector
///  - Horizontal linear Hue slider
///  - Horizontal linear Alpha (opacity) slider with checkerboard track
///  - Hex text input (supporting 6-char RRGGBB and 8-char AARRGGBB)
///  - Real-time opacity percentage indicator
///  - Checkerboard-backed swatch preview for transparency clarity
///  - Built-in curated presets & saved palette swatches
class ColorPickerWidget extends StatefulWidget {
  final Color initialColor;
  final List<Color> paletteColors;
  final ValueChanged<Color> onColorChanged;
  final VoidCallback? onSaveTopalette;
  final bool enableAlpha;

  const ColorPickerWidget({
    super.key,
    required this.initialColor,
    required this.paletteColors,
    required this.onColorChanged,
    this.onSaveTopalette,
    this.enableAlpha = true,
  });

  @override
  State<ColorPickerWidget> createState() => _ColorPickerWidgetState();
}

class _ColorPickerWidgetState extends State<ColorPickerWidget> {
  late HSVColor _hsv;
  late TextEditingController _hexCtrl;
  bool _suppressHexUpdate = false;

  @override
  void initState() {
    super.initState();
    _hsv = HSVColor.fromColor(widget.initialColor);
    _hexCtrl = TextEditingController(text: _colorToHex(widget.initialColor));
  }

  @override
  void didUpdateWidget(ColorPickerWidget old) {
    super.didUpdateWidget(old);
    if (old.initialColor.toARGB32() != widget.initialColor.toARGB32()) {
      _hsv = HSVColor.fromColor(widget.initialColor);
      if (!_suppressHexUpdate) {
        _hexCtrl.text = _colorToHex(widget.initialColor);
      }
    }
  }

  @override
  void dispose() {
    _hexCtrl.dispose();
    super.dispose();
  }

  String _colorToHex(Color c) {
    final argb = c.toARGB32();
    final hex8 = argb.toRadixString(16).padLeft(8, '0').toUpperCase();
    if (widget.enableAlpha && c.a < 0.999) {
      return hex8; // AARRGGBB
    }
    return hex8.substring(2); // RRGGBB
  }

  void _emit(HSVColor hsv) {
    setState(() => _hsv = hsv);
    final color = hsv.toColor();
    _suppressHexUpdate = true;
    _hexCtrl.text = _colorToHex(color);
    _suppressHexUpdate = false;
    widget.onColorChanged(color);
  }

  void _onHexInput(String hex) {
    final clean = hex.replaceAll('#', '').trim().toUpperCase();
    if (clean.length == 6) {
      final value = int.tryParse(clean, radix: 16);
      if (value != null) {
        final currentAlphaInt = (_hsv.alpha * 255).round().clamp(0, 255);
        final argb = (currentAlphaInt << 24) | value;
        final color = Color(argb);
        setState(() => _hsv = HSVColor.fromColor(color));
        widget.onColorChanged(color);
      }
    } else if (clean.length == 8) {
      final value = int.tryParse(clean, radix: 16);
      if (value != null) {
        final color = Color(value);
        setState(() => _hsv = HSVColor.fromColor(color));
        widget.onColorChanged(color);
      }
    }
  }

  void _updateHue(double dx, double maxWidth) {
    if (maxWidth <= 0) return;
    final hue = ((dx / maxWidth) * 360.0).clamp(0.0, 360.0);
    _emit(_hsv.withHue(hue));
  }

  void _updateAlpha(double dx, double maxWidth) {
    if (maxWidth <= 0) return;
    final alpha = (dx / maxWidth).clamp(0.0, 1.0);
    _emit(_hsv.withAlpha(alpha));
  }

  void _updateSv(Offset localPos, Size size) {
    if (size.width <= 0 || size.height <= 0) return;
    final s = (localPos.dx / size.width).clamp(0.0, 1.0);
    final v = (1.0 - (localPos.dy / size.height)).clamp(0.0, 1.0);
    _emit(_hsv.withSaturation(s).withValue(v));
  }

  @override
  Widget build(BuildContext context) {
    final current = _hsv.toColor();
    final opaqueColor = _hsv.withAlpha(1.0).toColor();
    final opacityPercent = (_hsv.alpha * 100).round();

    return Align(
      alignment: Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 320),
        padding: const EdgeInsets.all(16),
        decoration: BoxDecoration(
          color: Colors.white.withValues(alpha: 0.02),
          borderRadius: BorderRadius.circular(16),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.06),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 14,
              offset: const Offset(0, 4),
            ),
          ],
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 1. SV Box (Saturation & Value) ──
            AspectRatio(
              aspectRatio: 2.2,
              child: LayoutBuilder(
                builder: (context, constraints) {
                  final size = Size(
                    constraints.maxWidth,
                    constraints.maxHeight,
                  );
                  return GestureDetector(
                    onPanStart: (d) => _updateSv(d.localPosition, size),
                    onPanUpdate: (d) => _updateSv(d.localPosition, size),
                    onTapDown: (d) => _updateSv(d.localPosition, size),
                    child: ClipRRect(
                      borderRadius: BorderRadius.circular(12),
                      child: CustomPaint(painter: _SvBoxPainter(_hsv)),
                    ),
                  );
                },
              ),
            ),

            const SizedBox(height: 14),

            // ── 2. Hue Slider ──
            LayoutBuilder(
              builder: (context, constraints) {
                final trackWidth = constraints.maxWidth;
                final thumbLeft = (_hsv.hue / 360.0) * trackWidth;
                return GestureDetector(
                  onPanStart: (d) => _updateHue(d.localPosition.dx, trackWidth),
                  onPanUpdate: (d) => _updateHue(d.localPosition.dx, trackWidth),
                  onTapDown: (d) => _updateHue(d.localPosition.dx, trackWidth),
                  child: MouseRegion(
                    cursor: SystemMouseCursors.click,
                    child: SizedBox(
                      height: 24,
                      child: Stack(
                        alignment: Alignment.center,
                        children: [
                          // Rainbow Track
                          Container(
                            height: 12,
                            decoration: BoxDecoration(
                              borderRadius: BorderRadius.circular(6),
                              border: Border.all(color: Colors.white10),
                              boxShadow: const [
                                BoxShadow(
                                  color: Colors.black26,
                                  blurRadius: 4,
                                  offset: Offset(0, 2),
                                ),
                              ],
                            ),
                            child: ClipRRect(
                              borderRadius: BorderRadius.circular(6),
                              child: CustomPaint(
                                painter: _HueSliderTrackPainter(),
                                child: Container(),
                              ),
                            ),
                          ),
                          // Thumb Selector
                          Positioned(
                            left: (thumbLeft - 10).clamp(0.0, trackWidth - 20),
                            child: Container(
                              width: 20,
                              height: 20,
                              decoration: BoxDecoration(
                                color: Colors.white,
                                shape: BoxShape.circle,
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black45,
                                    blurRadius: 4,
                                    spreadRadius: 0.5,
                                  ),
                                ],
                                border: Border.all(
                                  color: opaqueColor,
                                  width: 3.5,
                                ),
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

            // ── 3. Alpha / Opacity Slider ──
            if (widget.enableAlpha) ...[
              const SizedBox(height: 10),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Text(
                    'OPACITY',
                    style: TextStyle(
                      color: Colors.white38,
                      fontSize: 9,
                      fontWeight: FontWeight.w900,
                      letterSpacing: 1.2,
                    ),
                  ),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.06),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '$opacityPercent%',
                      style: const TextStyle(
                        color: Colors.white70,
                        fontSize: 9.5,
                        fontWeight: FontWeight.w800,
                        fontFamily: 'Consolas',
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              LayoutBuilder(
                builder: (context, constraints) {
                  final trackWidth = constraints.maxWidth;
                  final thumbLeft = _hsv.alpha * trackWidth;
                  return GestureDetector(
                    onPanStart: (d) => _updateAlpha(d.localPosition.dx, trackWidth),
                    onPanUpdate: (d) => _updateAlpha(d.localPosition.dx, trackWidth),
                    onTapDown: (d) => _updateAlpha(d.localPosition.dx, trackWidth),
                    child: MouseRegion(
                      cursor: SystemMouseCursors.click,
                      child: SizedBox(
                        height: 24,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Checkerboard + Alpha gradient track
                            Container(
                              height: 12,
                              decoration: BoxDecoration(
                                borderRadius: BorderRadius.circular(6),
                                border: Border.all(color: Colors.white10),
                                boxShadow: const [
                                  BoxShadow(
                                    color: Colors.black26,
                                    blurRadius: 4,
                                    offset: Offset(0, 2),
                                  ),
                                ],
                              ),
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(6),
                                child: CustomPaint(
                                  painter: _AlphaSliderTrackPainter(opaqueColor),
                                  child: Container(),
                                ),
                              ),
                            ),
                            // Thumb Selector
                            Positioned(
                              left: (thumbLeft - 10).clamp(0.0, trackWidth - 20),
                              child: Container(
                                width: 20,
                                height: 20,
                                decoration: BoxDecoration(
                                  color: Colors.white,
                                  shape: BoxShape.circle,
                                  boxShadow: const [
                                    BoxShadow(
                                      color: Colors.black45,
                                      blurRadius: 4,
                                      spreadRadius: 0.5,
                                    ),
                                  ],
                                  border: Border.all(
                                    color: current,
                                    width: 3.5,
                                  ),
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
            ],

            const SizedBox(height: 14),

            // ── 4. Hex Input and Checkerboard Swatch Preview ──
            Row(
              children: [
                // Checkerboard-backed Swatch Preview
                Container(
                  width: 42,
                  height: 42,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(10),
                    border: Border.all(color: Colors.white24, width: 1.5),
                    boxShadow: [
                      BoxShadow(
                        color: current.withValues(alpha: 0.35),
                        blurRadius: 10,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(8.5),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: CustomPaint(
                            painter: _CheckerboardPainter(),
                          ),
                        ),
                        Positioned.fill(
                          child: Container(color: current),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Container(
                    height: 42,
                    decoration: BoxDecoration(
                      color: Colors.white.withValues(alpha: 0.05),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                      ),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    child: Center(
                      child: TextField(
                        controller: _hexCtrl,
                        style: const TextStyle(
                          color: Colors.white,
                          fontFamily: 'Consolas',
                          fontSize: 14,
                          fontWeight: FontWeight.bold,
                        ),
                        decoration: const InputDecoration(
                          prefixText: '#  ',
                          prefixStyle: TextStyle(
                            color: Colors.white30,
                            fontSize: 14,
                            fontWeight: FontWeight.bold,
                          ),
                          border: InputBorder.none,
                          contentPadding: EdgeInsets.zero,
                          isDense: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(
                            RegExp(r'[0-9A-Fa-f]'),
                          ),
                          LengthLimitingTextInputFormatter(8),
                        ],
                        onChanged: _onHexInput,
                      ),
                    ),
                  ),
                ),
                if (widget.onSaveTopalette != null) ...[
                  const SizedBox(width: 10),
                  Tooltip(
                    message: 'Save to palette',
                    child: IconButton(
                      icon: const Icon(
                        Icons.bookmark_add_outlined,
                        size: 20,
                        color: Colors.white70,
                      ),
                      onPressed: widget.onSaveTopalette,
                      style: IconButton.styleFrom(
                        backgroundColor: Colors.white.withValues(alpha: 0.05),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(
                            color: Colors.white.withValues(alpha: 0.08),
                          ),
                        ),
                        minimumSize: const Size(42, 42),
                      ),
                    ),
                  ),
                ],
              ],
            ),

            const SizedBox(height: 16),

            // ── 5. Presets ──
            const Text(
              'PRESETS',
              style: TextStyle(
                color: Colors.white38,
                fontSize: 9,
                fontWeight: FontWeight.w900,
                letterSpacing: 1.2,
              ),
            ),
            const SizedBox(height: 8),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: const [
                Color(0xFFFF5252), // Red
                Color(0xFFFF7A00), // Orange
                Color(0xFFFFD700), // Yellow
                Color(0xFF4CAF50), // Green
                Color(0xFF00E5FF), // Cyan
                Color(0xFF2979FF), // Blue
                Color(0xFF7C4DFF), // Purple
                Color(0xFFE040FB), // Magenta
                Color(0xFFFFFFFF), // White
                Color(0xFFB0BEC5), // Slate Gray
                Color(0xFF37474F), // Dark Gray
                Color(0xFF000000), // Black
              ].map((c) {
                final isSelected = (c.toARGB32() == current.toARGB32());
                return GestureDetector(
                  onTap: () => _emit(HSVColor.fromColor(c.withValues(alpha: _hsv.alpha))),
                  child: AnimatedContainer(
                    duration: const Duration(milliseconds: 150),
                    width: 24,
                    height: 24,
                    decoration: BoxDecoration(
                      color: c,
                      shape: BoxShape.circle,
                      border: isSelected
                          ? Border.all(color: Colors.white, width: 2.5)
                          : Border.all(color: Colors.white24, width: 1),
                      boxShadow: isSelected
                          ? [
                              BoxShadow(
                                color: c.withValues(alpha: 0.5),
                                blurRadius: 8,
                              ),
                            ]
                          : null,
                    ),
                  ),
                );
              }).toList(),
            ),

            // ── 6. Saved Colors Palette ──
            if (widget.paletteColors.isNotEmpty) ...[
              const SizedBox(height: 16),
              const Text(
                'SAVED PALETTE',
                style: TextStyle(
                  color: Colors.white38,
                  fontSize: 9,
                  fontWeight: FontWeight.w900,
                  letterSpacing: 1.2,
                ),
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: widget.paletteColors.map((c) {
                  final isSelected = (c.toARGB32() == current.toARGB32());
                  return GestureDetector(
                    onTap: () => _emit(HSVColor.fromColor(c)),
                    child: AnimatedContainer(
                      duration: const Duration(milliseconds: 150),
                      width: 24,
                      height: 24,
                      decoration: BoxDecoration(
                        color: c,
                        shape: BoxShape.circle,
                        border: isSelected
                            ? Border.all(color: Colors.white, width: 2.5)
                            : Border.all(color: Colors.white24, width: 1),
                        boxShadow: isSelected
                            ? [
                                BoxShadow(
                                  color: c.withValues(alpha: 0.5),
                                  blurRadius: 8,
                                ),
                              ]
                            : null,
                      ),
                    ),
                  );
                }).toList(),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class _SvBoxPainter extends CustomPainter {
  final HSVColor hsv;
  _SvBoxPainter(this.hsv);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(10));

    // Draw base hue color
    final baseColor = HSVColor.fromAHSV(1.0, hsv.hue, 1.0, 1.0).toColor();
    final basePaint = Paint()
      ..color = baseColor
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, basePaint);

    // Draw horizontal saturation gradient (white to transparent)
    final satPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Colors.white, Colors.transparent],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(rect);
    canvas.drawRRect(rrect, satPaint);

    // Draw vertical value gradient (transparent to black)
    final valPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Colors.transparent, Colors.black],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(rect);
    canvas.drawRRect(rrect, valPaint);

    // Draw border line
    final borderPaint = Paint()
      ..color = Colors.white24
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.0;
    canvas.drawRRect(rrect, borderPaint);

    // Draw selector dot
    final selectorX = hsv.saturation * size.width;
    final selectorY = (1.0 - hsv.value) * size.height;
    final selectorPos = Offset(selectorX, selectorY);

    canvas.drawCircle(
      selectorPos,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      selectorPos,
      5,
      Paint()
        ..color = hsv.withAlpha(1.0).toColor()
        ..style = PaintingStyle.fill,
    );
    canvas.drawCircle(
      selectorPos,
      8,
      Paint()
        ..color = Colors.white
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_SvBoxPainter old) =>
      old.hsv.hue != hsv.hue ||
      old.hsv.saturation != hsv.saturation ||
      old.hsv.value != hsv.value;
}

class _HueSliderTrackPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));
    final gradientColors = [
      for (int i = 0; i <= 360; i += 15)
        HSVColor.fromAHSV(1.0, i.toDouble(), 1.0, 1.0).toColor(),
    ];
    final paint = Paint()
      ..shader = LinearGradient(colors: gradientColors).createShader(rect)
      ..style = PaintingStyle.fill;
    canvas.drawRRect(rrect, paint);
  }

  @override
  bool shouldRepaint(CustomPainter oldDelegate) => false;
}

class _AlphaSliderTrackPainter extends CustomPainter {
  final Color opaqueColor;
  _AlphaSliderTrackPainter(this.opaqueColor);

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    final rrect = RRect.fromRectAndRadius(rect, const Radius.circular(6));

    canvas.save();
    canvas.clipRRect(rrect);

    // 1. Checkerboard background pattern
    const double cellSize = 6.0;
    final paintDark = Paint()..color = const Color(0xFF22262E);
    final paintLight = Paint()..color = const Color(0xFF38404E);

    for (double y = 0; y < size.height; y += cellSize) {
      for (double x = 0; x < size.width; x += cellSize) {
        final isEven = (((x / cellSize).floor() + (y / cellSize).floor()) % 2 == 0);
        canvas.drawRect(
          Rect.fromLTWH(x, y, cellSize, cellSize),
          isEven ? paintLight : paintDark,
        );
      }
    }

    // 2. Alpha gradient from transparent to opaqueColor
    final gradPaint = Paint()
      ..shader = LinearGradient(
        colors: [opaqueColor.withValues(alpha: 0.0), opaqueColor],
        begin: Alignment.centerLeft,
        end: Alignment.centerRight,
      ).createShader(rect);
    canvas.drawRect(rect, gradPaint);

    canvas.restore();
  }

  @override
  bool shouldRepaint(_AlphaSliderTrackPainter old) =>
      old.opaqueColor.toARGB32() != opaqueColor.toARGB32();
}

class _CheckerboardPainter extends CustomPainter {
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
