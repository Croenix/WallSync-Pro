import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';

class AnimatedSplashScreen extends StatefulWidget {
  const AnimatedSplashScreen({super.key, required this.onComplete});

  final VoidCallback onComplete;

  @override
  State<AnimatedSplashScreen> createState() => _AnimatedSplashScreenState();
}

class _AnimatedSplashScreenState extends State<AnimatedSplashScreen>
    with TickerProviderStateMixin {
  late final AnimationController _entranceController;
  late final AnimationController _motionController;
  late final AnimationController _progressController;
  late final AnimationController _skipController;
  late final AnimationController _exitController;
  Timer? _completionTimer;
  Timer? _skipTimer;
  bool _skipInteractive = false;
  bool _isFinishing = false;

  @override
  void initState() {
    super.initState();
    _entranceController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..forward();
    _motionController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 14),
    )..repeat();
    _progressController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    )..repeat();
    _skipController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 350),
    );
    _exitController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 450),
      value: 1,
    );

    _skipTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted && !_isFinishing) {
        setState(() => _skipInteractive = true);
        _skipController.forward();
      }
    });
    _completionTimer = Timer(const Duration(milliseconds: 6800), _finish);
  }

  @override
  void dispose() {
    _completionTimer?.cancel();
    _skipTimer?.cancel();
    _entranceController.dispose();
    _motionController.dispose();
    _progressController.dispose();
    _skipController.dispose();
    _exitController.dispose();
    super.dispose();
  }

  Future<void> _finish() async {
    if (_isFinishing || !mounted) return;
    _isFinishing = true;
    _completionTimer?.cancel();
    _skipTimer?.cancel();
    await _exitController.reverse();
    if (mounted) widget.onComplete();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _exitController,
      builder: (context, child) =>
          Opacity(opacity: _exitController.value, child: child),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final size = Size(constraints.maxWidth, constraints.maxHeight);
          final scale = math
              .min(1.0, math.min(size.width / 1200, size.height / 760))
              .clamp(0.55, 1.0)
              .toDouble();
          final showCards = size.width >= 820 && size.height >= 560;

          return Stack(
            fit: StackFit.expand,
            children: [
              const DecoratedBox(
                decoration: BoxDecoration(
                  gradient: LinearGradient(
                    begin: Alignment.topLeft,
                    end: Alignment.bottomRight,
                    colors: [
                      Color(0xFF080D1C),
                      Color(0xFF101126),
                      Color(0xFF080B17),
                    ],
                  ),
                ),
              ),
              const RepaintBoundary(
                child: CustomPaint(painter: _DotFieldPainter()),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  key: const ValueKey('splash-atmosphere'),
                  painter: _AtmospherePainter(_motionController),
                ),
              ),
              RepaintBoundary(
                child: CustomPaint(
                  painter: _NeonRibbonsPainter(_motionController),
                ),
              ),
              if (showCards) ..._buildFloatingCards(size, scale),
              _buildBrand(size, scale),
              _buildLaunchIndicator(size, scale),
              Positioned(
                top: 24 * scale,
                right: 28 * scale,
                child: FadeTransition(
                  opacity: _skipController,
                  child: AnimatedBuilder(
                    animation: _skipController,
                    builder: (context, child) => IgnorePointer(
                      ignoring: !_skipInteractive || _isFinishing,
                      child: child,
                    ),
                    child: TextButton(
                      onPressed: _finish,
                      style: TextButton.styleFrom(
                        foregroundColor: Colors.white.withValues(alpha: 0.78),
                        padding: EdgeInsets.symmetric(
                          horizontal: 14 * scale,
                          vertical: 9 * scale,
                        ),
                        side: BorderSide(
                          color: Colors.white.withValues(alpha: 0.22),
                        ),
                        shape: const StadiumBorder(),
                      ),
                      child: Text(
                        'SKIP  ›',
                        style: TextStyle(
                          fontSize: 10 * scale,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.4,
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBrand(Size size, double scale) {
    final logoWidth = math.min(300 * scale, size.width * 0.31).toDouble();
    final orbitSize = math.min(410 * scale, size.width * 0.44).toDouble();

    return Center(
      child: Transform.translate(
        offset: Offset(0, -20 * scale),
        child: SizedBox(
          width: orbitSize,
          height: orbitSize,
          child: Stack(
            alignment: Alignment.center,
            children: [
              RepaintBoundary(
                child: CustomPaint(
                  size: Size.square(orbitSize),
                  painter: _OrbitPainter(_motionController),
                ),
              ),
              FadeTransition(
                opacity: CurvedAnimation(
                  parent: _entranceController,
                  curve: const Interval(0.05, 0.9, curve: Curves.easeOut),
                ),
                child: ScaleTransition(
                  scale: Tween<double>(begin: 0.86, end: 1).animate(
                    CurvedAnimation(
                      parent: _entranceController,
                      curve: Curves.easeOutBack,
                    ),
                  ),
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          boxShadow: [
                            BoxShadow(
                              color: const Color(
                                0xFF10DFFF,
                              ).withValues(alpha: 0.18),
                              blurRadius: 38 * scale,
                              spreadRadius: 1 * scale,
                            ),
                            BoxShadow(
                              color: const Color(
                                0xFFB343FF,
                              ).withValues(alpha: 0.13),
                              blurRadius: 48 * scale,
                              spreadRadius: 2 * scale,
                            ),
                          ],
                        ),
                        child: Image.asset(
                          'assets/wallsync_logo.png',
                          width: logoWidth,
                          height: logoWidth,
                          fit: BoxFit.contain,
                          cacheWidth: 360,
                          cacheHeight: 360,
                          filterQuality: FilterQuality.medium,
                        ),
                      ),
                      SizedBox(height: 1 * scale),
                      Text(
                        'WALLPAPERS  ·  WIDGETS  ·  YOUR STYLE',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: const Color(
                            0xFFC9D2E8,
                          ).withValues(alpha: 0.82),
                          fontSize: 9 * scale,
                          fontWeight: FontWeight.w600,
                          letterSpacing: 2.2 * scale,
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

  List<Widget> _buildFloatingCards(Size size, double scale) {
    final cardWidth = math.min(190 * scale, size.width * 0.17).toDouble();
    final cardHeight = cardWidth * 0.66;

    return [
      _positionCard(
        size,
        cardWidth,
        cardHeight,
        left: size.width * 0.075,
        top: size.height * 0.16,
        phase: 0,
        child: _photoCard(
          asset: 'assets/cyberpunk.png',
          title: 'CYBERPUNK SKYLINE',
          accent: const Color(0xFF27D8FF),
          scale: scale,
        ),
      ),
      _positionCard(
        size,
        cardWidth,
        cardHeight,
        left: size.width * 0.115,
        top: size.height * 0.43,
        phase: math.pi * 0.7,
        child: _photoCard(
          asset: 'assets/aurora.png',
          title: 'AURORA BOREALIS',
          accent: const Color(0xFF51E6C1),
          scale: scale,
        ),
      ),
      _positionCard(
        size,
        cardWidth,
        cardHeight,
        left: size.width * 0.075,
        top: size.height * 0.69,
        phase: math.pi * 1.25,
        child: _photoCard(
          asset: 'assets/forest.png',
          title: 'MYSTIC FOREST',
          accent: const Color(0xFF9B80FF),
          scale: scale,
        ),
      ),
      _positionCard(
        size,
        cardWidth,
        cardHeight,
        left: size.width * 0.785,
        top: size.height * 0.145,
        phase: math.pi * 1.5,
        child: _clockCard(scale),
      ),
      _positionCard(
        size,
        cardWidth,
        cardHeight,
        left: size.width * 0.755,
        top: size.height * 0.40,
        phase: math.pi * 0.3,
        child: _paletteCard(scale),
      ),
      _positionCard(
        size,
        cardWidth,
        cardHeight,
        left: size.width * 0.785,
        top: size.height * 0.65,
        phase: math.pi * 0.95,
        child: _controlsCard(scale),
      ),
    ];
  }

  Widget _positionCard(
    Size size,
    double width,
    double height, {
    required double left,
    required double top,
    required double phase,
    required Widget child,
  }) {
    return AnimatedBuilder(
      animation: Listenable.merge([_entranceController, _motionController]),
      builder: (context, _) {
        final entrance = Curves.easeOutCubic.transform(
          _entranceController.value,
        );
        final time = _motionController.value * math.pi * 2;
        final driftX = 4 * math.sin(time + phase);
        final driftY = 7 * math.cos(time + phase);

        return Positioned(
          left: left + (1 - entrance) * (left < size.width / 2 ? -26 : 26),
          top: top + driftY + (1 - entrance) * 18,
          child: Opacity(
            opacity: entrance,
            child: Transform.translate(
              offset: Offset(driftX, 0),
              child: Transform.rotate(
                angle: 0.018 * math.sin(time + phase),
                child: SizedBox(width: width, height: height, child: child),
              ),
            ),
          ),
        );
      },
    );
  }

  Widget _photoCard({
    required String asset,
    required String title,
    required Color accent,
    required double scale,
  }) {
    return _glassCard(
      accent: accent,
      scale: scale,
      child: ClipRRect(
        borderRadius: BorderRadius.circular(13 * scale),
        child: Stack(
          fit: StackFit.expand,
          children: [
            Image.asset(
              asset,
              fit: BoxFit.cover,
              cacheWidth: 400,
              cacheHeight: 270,
              filterQuality: FilterQuality.medium,
            ),
            DecoratedBox(
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  begin: Alignment.topCenter,
                  end: Alignment.bottomCenter,
                  colors: [
                    Colors.transparent,
                    Colors.black.withValues(alpha: 0.78),
                  ],
                  stops: const [0.35, 1],
                ),
              ),
            ),
            Positioned(
              left: 10 * scale,
              right: 7 * scale,
              bottom: 8 * scale,
              child: Row(
                children: [
                  Icon(
                    Icons.wallpaper_rounded,
                    color: accent,
                    size: 12 * scale,
                  ),
                  SizedBox(width: 6 * scale),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 8 * scale,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.8 * scale,
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
  }

  Widget _clockCard(double scale) {
    return _glassCard(
      accent: const Color(0xFF25DFFF),
      scale: scale,
      child: Padding(
        padding: EdgeInsets.all(12 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _cardHeading('CLOCK WIDGET', const Color(0xFF25DFFF), scale),
            const Spacer(),
            Text(
              '10:42',
              style: TextStyle(
                color: Colors.white,
                fontSize: 29 * scale,
                height: 1,
                fontWeight: FontWeight.w300,
                letterSpacing: 1.2 * scale,
              ),
            ),
            SizedBox(height: 5 * scale),
            Text(
              'SUNDAY  ·  JUNE 21',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.62),
                fontSize: 7 * scale,
                letterSpacing: 1.2 * scale,
              ),
            ),
            const Spacer(),
          ],
        ),
      ),
    );
  }

  Widget _paletteCard(double scale) {
    const colors = [
      Color(0xFF28C7FA),
      Color(0xFFB477FF),
      Color(0xFFF568B5),
      Color(0xFF51E6C1),
      Color(0xFFFFC857),
      Color(0xFFFF746F),
    ];
    return _glassCard(
      accent: const Color(0xFFDA72FF),
      scale: scale,
      child: Padding(
        padding: EdgeInsets.all(12 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _cardHeading('COLOR PALETTE', const Color(0xFFDA72FF), scale),
            SizedBox(height: 13 * scale),
            Wrap(
              spacing: 9 * scale,
              runSpacing: 8 * scale,
              children: [
                for (final color in colors)
                  Container(
                    width: 19 * scale,
                    height: 19 * scale,
                    decoration: BoxDecoration(
                      color: color,
                      shape: BoxShape.circle,
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.5),
                        width: 1,
                      ),
                      boxShadow: [
                        BoxShadow(
                          color: color.withValues(alpha: 0.4),
                          blurRadius: 9 * scale,
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
  }

  Widget _controlsCard(double scale) {
    return _glassCard(
      accent: const Color(0xFFB477FF),
      scale: scale,
      child: Padding(
        padding: EdgeInsets.all(12 * scale),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            _cardHeading('WIDGET CONTROLS', const Color(0xFFB477FF), scale),
            SizedBox(height: 12 * scale),
            _controlRow('Opacity', 0.82, const Color(0xFF28C7FA), scale),
            SizedBox(height: 9 * scale),
            _controlRow('Blur', 0.54, const Color(0xFFB477FF), scale),
          ],
        ),
      ),
    );
  }

  Widget _controlRow(String label, double value, Color color, double scale) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.75),
                fontSize: 8 * scale,
              ),
            ),
            Text(
              '${(value * 100).round()}%',
              style: TextStyle(
                color: color,
                fontSize: 7 * scale,
                fontWeight: FontWeight.w700,
              ),
            ),
          ],
        ),
        SizedBox(height: 4 * scale),
        ClipRRect(
          borderRadius: BorderRadius.circular(3 * scale),
          child: LinearProgressIndicator(
            value: value,
            minHeight: 4 * scale,
            backgroundColor: Colors.white.withValues(alpha: 0.12),
            valueColor: AlwaysStoppedAnimation<Color>(color),
          ),
        ),
      ],
    );
  }

  Widget _cardHeading(String text, Color color, double scale) {
    return Row(
      children: [
        Container(
          width: 5 * scale,
          height: 5 * scale,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        SizedBox(width: 6 * scale),
        Text(
          text,
          style: TextStyle(
            color: Colors.white.withValues(alpha: 0.68),
            fontSize: 7 * scale,
            fontWeight: FontWeight.w700,
            letterSpacing: 1.2 * scale,
          ),
        ),
      ],
    );
  }

  Widget _glassCard({
    required Widget child,
    required Color accent,
    required double scale,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xCC111627),
        borderRadius: BorderRadius.circular(15 * scale),
        border: Border.all(color: accent.withValues(alpha: 0.55), width: 1),
        boxShadow: [
          BoxShadow(
            color: accent.withValues(alpha: 0.12),
            blurRadius: 20 * scale,
            spreadRadius: 1 * scale,
          ),
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.38),
            blurRadius: 20 * scale,
            offset: Offset(0, 9 * scale),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(14 * scale),
        child: child,
      ),
    );
  }

  Widget _buildLaunchIndicator(Size size, double scale) {
    return Positioned(
      left: size.width * 0.5 - 170 * scale,
      bottom: 94 * scale,
      width: 340 * scale,
      child: FadeTransition(
        opacity: CurvedAnimation(
          parent: _entranceController,
          curve: const Interval(0.35, 1, curve: Curves.easeOut),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text(
              'PREPARING YOUR DESKTOP',
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 9 * scale,
                fontWeight: FontWeight.w700,
                letterSpacing: 2 * scale,
              ),
            ),
            SizedBox(height: 12 * scale),
            SizedBox(
              height: 5 * scale,
              child: RepaintBoundary(
                child: CustomPaint(
                  painter: _LaunchIndicatorPainter(_progressController),
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _DotFieldPainter extends CustomPainter {
  const _DotFieldPainter();

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = const Color(0xFF8790B5).withValues(alpha: 0.14);
    for (double y = 16; y < size.height; y += 24) {
      for (double x = 16; x < size.width; x += 24) {
        final edgeFade = math
            .min(1.0, math.min(x / 180, (size.width - x) / 180))
            .toDouble();
        canvas.drawCircle(
          Offset(x, y),
          0.7,
          paint
            ..color = const Color(
              0xFF8790B5,
            ).withValues(alpha: 0.11 * edgeFade),
        );
      }
    }
  }

  @override
  bool shouldRepaint(covariant _DotFieldPainter oldDelegate) => false;
}

class _AtmospherePainter extends CustomPainter {
  _AtmospherePainter(Animation<double> animation)
    : animation = animation,
      super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final time = animation.value * math.pi * 2;
    final shortestSide = size.shortestSide;
    final auroraBlobs = [
      (
        Offset(
          size.width * (0.18 + 0.035 * math.sin(time)),
          size.height * (0.28 + 0.045 * math.cos(time * 0.8)),
        ),
        shortestSide * 0.42,
        const Color(0xFF00D9FF),
        0.10,
      ),
      (
        Offset(
          size.width * (0.83 + 0.04 * math.cos(time * 0.7)),
          size.height * (0.72 + 0.035 * math.sin(time)),
        ),
        shortestSide * 0.38,
        const Color(0xFF9B4DFF),
        0.09,
      ),
      (
        Offset(
          size.width * (0.53 + 0.035 * math.sin(time * 0.6 + 1)),
          size.height * (0.12 + 0.025 * math.cos(time)),
        ),
        shortestSide * 0.30,
        const Color(0xFFFF3F9B),
        0.055,
      ),
    ];

    for (final (center, radius, color, opacity) in auroraBlobs) {
      final rect = Rect.fromCircle(center: center, radius: radius);
      canvas.drawCircle(
        center,
        radius,
        Paint()
          ..shader = RadialGradient(
            colors: [
              color.withValues(alpha: opacity),
              color.withValues(alpha: opacity * 0.34),
              color.withValues(alpha: 0),
            ],
            stops: const [0, 0.52, 1],
          ).createShader(rect),
      );
    }

    for (var index = 0; index < 64; index++) {
      final seed = index.toDouble();
      final baseX = _fraction(math.sin(seed * 127.1 + 4.7) * 43758.5453);
      final baseY = _fraction(math.sin(seed * 311.7 + 2.3) * 24634.6345);
      final drift = time * (0.018 + (index % 5) * 0.004);
      final x = (baseX + drift) % 1 * size.width;
      final y = (baseY + math.sin(time + seed) * 0.008) * size.height;
      final twinkle = (0.5 + 0.5 * math.sin(time * 1.7 + seed * 2.1));
      final radius = 0.65 + (index % 3) * 0.34;
      final color = index.isEven
          ? const Color(0xFF5BE7FF)
          : const Color(0xFFC887FF);
      canvas.drawCircle(
        Offset(x, y),
        radius,
        Paint()..color = color.withValues(alpha: 0.08 + twinkle * 0.32),
      );
    }

    _paintShootingStar(canvas, size, time, seed: 0.13, height: 0.19);
    _paintShootingStar(canvas, size, time, seed: 0.62, height: 0.62);
  }

  double _fraction(double value) => value - value.floorToDouble();

  void _paintShootingStar(
    Canvas canvas,
    Size size,
    double time, {
    required double seed,
    required double height,
  }) {
    final cycle = (time / (math.pi * 2) * 2.4 + seed) % 1;
    if (cycle > 0.24) return;

    final progress = cycle / 0.24;
    final x = (progress * 1.25 - 0.12) * size.width;
    final y = size.height * height + progress * size.height * 0.10;
    final opacity = math.sin(progress * math.pi).clamp(0.0, 1.0).toDouble();
    final start = Offset(x, y);
    final end = Offset(x - size.width * 0.065, y - size.height * 0.045);

    canvas.drawLine(
      start,
      end,
      Paint()
        ..strokeWidth = 2.2
        ..strokeCap = StrokeCap.round
        ..color = const Color(0xFF92F5FF).withValues(alpha: opacity * 0.65)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5),
    );
    canvas.drawCircle(
      start,
      1.8,
      Paint()..color = Colors.white.withValues(alpha: opacity * 0.85),
    );
  }

  @override
  bool shouldRepaint(covariant _AtmospherePainter oldDelegate) => false;
}

class _NeonRibbonsPainter extends CustomPainter {
  _NeonRibbonsPainter(Animation<double> animation)
    : animation = animation,
      super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value * math.pi * 2;
    final paths = [
      (
        Path()
          ..moveTo(-size.width * 0.08, size.height * 0.36)
          ..cubicTo(
            size.width * 0.27,
            size.height * (0.50 + 0.025 * math.sin(progress)),
            size.width * 0.48,
            size.height * (0.20 + 0.02 * math.cos(progress)),
            size.width * 0.68,
            size.height * 0.34,
          )
          ..cubicTo(
            size.width * 0.84,
            size.height * 0.46,
            size.width * 0.92,
            size.height * 0.30,
            size.width * 1.08,
            size.height * 0.23,
          ),
        const Color(0xFF08CFFF),
      ),
      (
        Path()
          ..moveTo(-size.width * 0.08, size.height * 0.40)
          ..cubicTo(
            size.width * 0.26,
            size.height * (0.54 + 0.02 * math.cos(progress)),
            size.width * 0.49,
            size.height * (0.24 + 0.025 * math.sin(progress)),
            size.width * 0.70,
            size.height * 0.38,
          )
          ..cubicTo(
            size.width * 0.86,
            size.height * 0.49,
            size.width * 0.96,
            size.height * 0.34,
            size.width * 1.08,
            size.height * 0.27,
          ),
        const Color(0xFFB642FF),
      ),
      (
        Path()
          ..moveTo(-size.width * 0.08, size.height * 0.44)
          ..cubicTo(
            size.width * 0.26,
            size.height * (0.58 + 0.02 * math.sin(progress + 1)),
            size.width * 0.50,
            size.height * (0.28 + 0.02 * math.cos(progress + 1)),
            size.width * 0.72,
            size.height * 0.42,
          )
          ..cubicTo(
            size.width * 0.88,
            size.height * 0.52,
            size.width * 0.98,
            size.height * 0.38,
            size.width * 1.08,
            size.height * 0.31,
          ),
        const Color(0xFFFF48AE),
      ),
    ];

    for (final (path, color) in paths) {
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 9
        ..color = color.withValues(alpha: 0.16)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 12);
      canvas.drawPath(path, glowPaint);
      canvas.drawPath(
        path,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = 1.4
          ..color = color.withValues(alpha: 0.68),
      );
    }

    _paintCornerWave(canvas, size, progress, top: true);
    _paintCornerWave(canvas, size, progress, top: false);
  }

  void _paintCornerWave(
    Canvas canvas,
    Size size,
    double progress, {
    required bool top,
  }) {
    final direction = top ? 1.0 : -1.0;
    final startY = top ? -size.height * 0.05 : size.height * 1.05;
    final path = Path()
      ..moveTo(size.width * 0.57, startY)
      ..cubicTo(
        size.width * 0.73,
        startY + direction * size.height * 0.17,
        size.width * (0.9 + 0.012 * math.sin(progress)),
        startY + direction * size.height * 0.2,
        size.width * 1.05,
        startY + direction * size.height * 0.05,
      );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 7
        ..color = const Color(0xFF06D7FF).withValues(alpha: 0.17)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 10),
    );
    canvas.drawPath(
      path,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1
        ..color = const Color(0xFFFF55B8).withValues(alpha: 0.62),
    );
  }

  @override
  bool shouldRepaint(covariant _NeonRibbonsPainter oldDelegate) => false;
}

class _OrbitPainter extends CustomPainter {
  _OrbitPainter(Animation<double> animation)
    : animation = animation,
      super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final center = Offset(size.width / 2, size.height / 2);
    final radius = size.shortestSide * 0.43;

    for (final factor in [1.0, 0.88]) {
      canvas.drawCircle(
        center,
        radius * factor,
        Paint()
          ..style = PaintingStyle.stroke
          ..strokeWidth = factor == 1 ? 1.2 : 0.7
          ..color = const Color(
            0xFF83CFFF,
          ).withValues(alpha: factor == 1 ? 0.17 : 0.12),
      );
    }

    canvas.save();
    canvas.translate(center.dx, center.dy);
    canvas.rotate(animation.value * math.pi * 2);
    canvas.translate(-center.dx, -center.dy);
    final arcRect = Rect.fromCircle(center: center, radius: radius);
    canvas.drawArc(
      arcRect,
      -math.pi * 0.2,
      math.pi * 0.66,
      false,
      Paint()
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round
        ..strokeWidth = 2.2
        ..shader = const SweepGradient(
          colors: [
            Color(0x002CDFFF),
            Color(0xFF22DFFF),
            Color(0xFFCE55FF),
            Color(0x00CE55FF),
          ],
        ).createShader(arcRect),
    );
    canvas.drawCircle(
      Offset(center.dx, center.dy - radius),
      3,
      Paint()..color = const Color(0xFF31E6FF),
    );
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _OrbitPainter oldDelegate) => false;
}

class _LaunchIndicatorPainter extends CustomPainter {
  _LaunchIndicatorPainter(Animation<double> animation)
    : animation = animation,
      super(repaint: animation);

  final Animation<double> animation;

  @override
  void paint(Canvas canvas, Size size) {
    final progress = animation.value;
    final track = RRect.fromRectAndRadius(
      Offset.zero & size,
      Radius.circular(size.height),
    );
    canvas.drawRRect(
      track,
      Paint()..color = Colors.white.withValues(alpha: 0.12),
    );

    final segmentWidth = size.width * 0.28;
    final left = progress * (size.width + segmentWidth) - segmentWidth;
    final segment = RRect.fromRectAndRadius(
      Rect.fromLTWH(left, 0, segmentWidth, size.height),
      Radius.circular(size.height),
    );
    final gradientRect = Rect.fromLTWH(left, 0, segmentWidth, size.height);
    canvas.drawRRect(
      segment,
      Paint()
        ..shader = const LinearGradient(
          colors: [
            Color(0x0024DFFF),
            Color(0xFF26DFFF),
            Color(0xFFCE59FF),
            Color(0x00CE59FF),
          ],
        ).createShader(gradientRect),
    );
  }

  @override
  bool shouldRepaint(covariant _LaunchIndicatorPainter oldDelegate) => false;
}
