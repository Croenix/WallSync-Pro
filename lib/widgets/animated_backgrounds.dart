import 'dart:math';
import 'package:flutter/material.dart';

// ─────────────────────────────────────────────────────────────────────────────
// 1. MATRIX BACKGROUND — falling green character rain
// ─────────────────────────────────────────────────────────────────────────────
class MatrixBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const MatrixBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<MatrixBackground> createState() => _MatrixBackgroundState();
}

class _MatrixBackgroundState extends State<MatrixBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _controller;
  late List<_MatrixColumn> _columns;
  final Random _rng = Random();
  Size _lastSize = Size.zero;
  final Map<String, Map<int, TextPainter>> _painterCache = {};

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    for (final map in _painterCache.values) {
      for (final tp in map.values) {
        tp.dispose();
      }
    }
    _painterCache.clear();
    _controller.dispose();
    super.dispose();
  }

  void _initColumns(Size size) {
    if (size == _lastSize) return;
    _lastSize = size;
    const colW = 14.0;
    final count = (size.width / colW).ceil() + 2;
    _columns = List.generate(
      count,
      (i) => _MatrixColumn(
        x: i * colW,
        speed: 1.5 + _rng.nextDouble() * 3.0,
        length: 8 + _rng.nextInt(12),
        offset: _rng.nextDouble() * size.height,
        chars: List.generate(24, (_) => _randomChar(_rng)),
        rng: _rng,
        maxHeight: size.height,
      ),
    );
  }

  static String _randomChar(Random r) {
    const pool =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@#\$%&*<>{}[]|';
    return pool[r.nextInt(pool.length)];
  }

  TextPainter _getTextPainter(String char, int index) {
    var charMap = _painterCache[char];
    if (charMap == null) {
      charMap = {};
      _painterCache[char] = charMap;
    }
    var tp = charMap[index];
    if (tp == null) {
      final alpha = index == 0 ? 1.0 : (1.0 - index / 24).clamp(0.0, 1.0);
      final color = index == 0
          ? Color.fromARGB((alpha * 255).toInt(), 200, 255, 200)
          : Color.fromARGB((alpha * 180).toInt(), 0, 200, 70);

      tp = TextPainter(
        text: TextSpan(
          text: char,
          style: TextStyle(
            color: color,
            fontSize: 12,
            fontFamily: 'Consolas',
            fontWeight: FontWeight.bold,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      charMap[index] = tp;
    }
    return tp;
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            _initColumns(size);
            return AnimatedBuilder(
              animation: _controller,
              builder: (_, _) {
                for (final col in _columns) {
                  col.tick();
                }
                return CustomPaint(
                  size: size,
                  painter: _MatrixPainter(_columns, _getTextPainter),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _MatrixColumn {
  final double x;
  final double speed;
  final int length;
  final Random rng;
  final double maxHeight;
  double offset;
  List<String> chars;
  int frame = 0;

  _MatrixColumn({
    required this.x,
    required this.speed,
    required this.length,
    required this.offset,
    required this.chars,
    required this.rng,
    required this.maxHeight,
  });

  void tick() {
    offset += speed;
    frame++;
    if (offset > maxHeight + length * 14) {
      offset = -length * 14.0;
    }
    // Randomly mutate a character
    if (frame % 3 == 0) {
      const pool =
          'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789@#\$%&*<>{}[]|';
      chars[rng.nextInt(chars.length)] = pool[rng.nextInt(pool.length)];
    }
  }
}

class _MatrixPainter extends CustomPainter {
  final List<_MatrixColumn> columns;
  final TextPainter Function(String char, int index) getPainter;
  _MatrixPainter(this.columns, this.getPainter);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF000000),
    );

    const charH = 14.0;
    for (final col in columns) {
      for (int i = 0; i < col.chars.length; i++) {
        final y = col.offset - i * charH;
        if (y < -charH || y > size.height + charH) continue;
        final tp = getPainter(col.chars[i], i);
        tp.paint(canvas, Offset(col.x, y));
      }
    }
  }

  @override
  bool shouldRepaint(_MatrixPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 2. PARTICLES BACKGROUND — floating glowing orbs
// ─────────────────────────────────────────────────────────────────────────────
class ParticlesBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const ParticlesBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<ParticlesBackground> createState() => _ParticlesBackgroundState();
}

class _Particle {
  double x, y, vx, vy, radius;
  Color color;
  double phase;
  _Particle(
    this.x,
    this.y,
    this.vx,
    this.vy,
    this.radius,
    this.color,
    this.phase,
  );
}

class _ParticlesBackgroundState extends State<ParticlesBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  List<_Particle> _particles = [];
  Size _lastSize = Size.zero;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _init(Size size) {
    if (size == _lastSize) return;
    _lastSize = size;
    final colors = [
      const Color(0xFF7B2FBE),
      const Color(0xFF00C6FF),
      const Color(0xFFFF6B6B),
      const Color(0xFF43E97B),
      const Color(0xFFFFD700),
    ];
    _particles = List.generate(45, (i) {
      return _Particle(
        _rng.nextDouble() * size.width,
        _rng.nextDouble() * size.height,
        (_rng.nextDouble() - 0.5) * 0.6,
        (_rng.nextDouble() - 0.5) * 0.6,
        3 + _rng.nextDouble() * 5,
        colors[i % colors.length].withValues(
          alpha: 0.6 + _rng.nextDouble() * 0.4,
        ),
        _rng.nextDouble() * 2 * pi,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            _init(size);
            return AnimatedBuilder(
              animation: _ctrl,
              builder: (_, _) {
                for (final p in _particles) {
                  p.x = (p.x + p.vx + size.width) % size.width;
                  p.y = (p.y + p.vy + size.height) % size.height;
                  p.phase += 0.03;
                }
                return CustomPaint(
                  size: size,
                  painter: _ParticlesPainter(_particles),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _ParticlesPainter extends CustomPainter {
  final List<_Particle> particles;
  static final Paint _bgPaint = Paint()..color = const Color(0xFF0A0A1A);
  static final Paint _solidPaint = Paint();
  _ParticlesPainter(this.particles);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      _bgPaint,
    );

    for (final p in particles) {
      final pulse = 0.7 + 0.3 * sin(p.phase);
      final r = p.radius * pulse;
      final paint = Paint()
        ..shader =
            RadialGradient(
              colors: [
                p.color.withValues(alpha: 0.9 * pulse),
                p.color.withValues(alpha: 0.0),
              ],
            ).createShader(
              Rect.fromCircle(center: Offset(p.x, p.y), radius: r * 3.5),
            )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 6);
      canvas.drawCircle(Offset(p.x, p.y), r * 3.5, paint);
      _solidPaint.color = p.color.withValues(alpha: pulse);
      canvas.drawCircle(
        Offset(p.x, p.y),
        r,
        _solidPaint,
      );
    }
  }

  @override
  bool shouldRepaint(_ParticlesPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 3. AURORA BACKGROUND — slow sweeping colored blobs
// ─────────────────────────────────────────────────────────────────────────────
class AuroraBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const AuroraBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<AuroraBackground> createState() => _AuroraBackgroundState();
}

class _AuroraBackgroundState extends State<AuroraBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) {
            final t = _ctrl.value * 2 * pi;
            return CustomPaint(painter: _AuroraPainter(t), child: Container());
          },
        ),
      ),
    );
  }
}

class _AuroraPainter extends CustomPainter {
  final double t;
  _AuroraPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF020510),
    );

    final blobs = [
      _Blob(
        cx: size.width * (0.3 + 0.25 * sin(t * 0.7)),
        cy: size.height * (0.35 + 0.2 * cos(t * 0.5)),
        rx: size.width * 0.55,
        ry: size.height * 0.45,
        color: const Color(0xFF00FFCC).withValues(alpha: 0.22),
      ),
      _Blob(
        cx: size.width * (0.7 + 0.2 * cos(t * 0.4)),
        cy: size.height * (0.5 + 0.25 * sin(t * 0.6)),
        rx: size.width * 0.6,
        ry: size.height * 0.5,
        color: const Color(0xFF7B2FBE).withValues(alpha: 0.25),
      ),
      _Blob(
        cx: size.width * (0.5 + 0.3 * sin(t * 0.3 + 1.2)),
        cy: size.height * (0.2 + 0.15 * cos(t * 0.8)),
        rx: size.width * 0.4,
        ry: size.height * 0.35,
        color: const Color(0xFF0066FF).withValues(alpha: 0.18),
      ),
    ];

    for (final blob in blobs) {
      final paint = Paint()
        ..shader =
            RadialGradient(
              colors: [blob.color, blob.color.withValues(alpha: 0.0)],
            ).createShader(
              Rect.fromCenter(
                center: Offset(blob.cx, blob.cy),
                width: blob.rx * 2,
                height: blob.ry * 2,
              ),
            )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 40);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(blob.cx, blob.cy),
          width: blob.rx * 2,
          height: blob.ry * 2,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_AuroraPainter old) => true;
}

class _Blob {
  final double cx, cy, rx, ry;
  final Color color;
  _Blob({
    required this.cx,
    required this.cy,
    required this.rx,
    required this.ry,
    required this.color,
  });
}

// ─────────────────────────────────────────────────────────────────────────────
// 4. WAVES BACKGROUND — animated sine waves
// ─────────────────────────────────────────────────────────────────────────────
class WavesBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const WavesBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<WavesBackground> createState() => _WavesBackgroundState();
}

class _WavesBackgroundState extends State<WavesBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) => CustomPaint(
            painter: _WavesPainter(_ctrl.value * 2 * pi),
            child: Container(),
          ),
        ),
      ),
    );
  }
}

class _WavesPainter extends CustomPainter {
  final double phase;
  _WavesPainter(this.phase);

  @override
  void paint(Canvas canvas, Size size) {
    // Deep ocean base
    final bg = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF001733), Color(0xFF002855)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bg);

    // Draw 4 wave layers
    final waves = [
      _WaveConfig(0.35, 0.08, const Color(0xFF0066CC), 0.55),
      _WaveConfig(0.50, 0.06, const Color(0xFF0088FF), 0.45),
      _WaveConfig(0.65, 0.05, const Color(0xFF00AAFF), 0.35),
      _WaveConfig(0.80, 0.04, const Color(0xFF80D4FF), 0.25),
    ];

    for (final w in waves) {
      _drawWave(canvas, size, w, phase);
    }
  }

  void _drawWave(Canvas canvas, Size size, _WaveConfig cfg, double phase) {
    final path = Path();
    path.moveTo(0, size.height);
    for (double x = 0; x <= size.width; x += 2) {
      final y =
          size.height * cfg.yFraction +
          sin(x / size.width * 2 * pi * 2.5 + phase) *
              size.height *
              cfg.amplitude +
          cos(x / size.width * 2 * pi * 1.3 - phase * 0.7) *
              size.height *
              cfg.amplitude *
              0.5;
      if (x == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
    }
    path.lineTo(size.width, size.height);
    path.close();

    canvas.drawPath(
      path,
      Paint()
        ..color = cfg.color.withValues(alpha: cfg.alpha)
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 3),
    );
  }

  @override
  bool shouldRepaint(_WavesPainter old) => true;
}

class _WaveConfig {
  final double yFraction, amplitude, alpha;
  final Color color;
  _WaveConfig(this.yFraction, this.amplitude, this.color, this.alpha);
}

// ─────────────────────────────────────────────────────────────────────────────
// 5. NEON PULSE BACKGROUND — pulsing neon border with hue rotation
// ─────────────────────────────────────────────────────────────────────────────
class NeonPulseBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const NeonPulseBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<NeonPulseBackground> createState() => _NeonPulseBackgroundState();
}

class _NeonPulseBackgroundState extends State<NeonPulseBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 3),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) => CustomPaint(
            painter: _NeonPulsePainter(_ctrl.value, widget.borderRadius),
            child: Container(),
          ),
        ),
      ),
    );
  }
}

class _NeonPulsePainter extends CustomPainter {
  final double t;
  final BorderRadius borderRadius;
  _NeonPulsePainter(this.t, this.borderRadius);

  @override
  void paint(Canvas canvas, Size size) {
    // Dark background
    final rRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, size.width, size.height),
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    canvas.drawRRect(rRect, Paint()..color = const Color(0xFF080010));

    // Hue cycle
    final hue = (t * 360) % 360;
    final color1 = HSVColor.fromAHSV(1.0, hue, 1.0, 1.0).toColor();
    final color2 = HSVColor.fromAHSV(
      1.0,
      (hue + 120) % 360,
      1.0,
      1.0,
    ).toColor();
    final color3 = HSVColor.fromAHSV(
      1.0,
      (hue + 240) % 360,
      1.0,
      1.0,
    ).toColor();

    // Pulsing glow border
    final pulse = 0.5 + 0.5 * sin(t * 2 * pi);
    for (int i = 3; i >= 0; i--) {
      final spread = (6 + i * 6.0) * (0.5 + pulse * 0.5);
      canvas.drawRRect(
        rRect,
        Paint()
          ..color = Colors.transparent
          ..style = PaintingStyle.stroke
          ..strokeWidth = spread
          ..shader = SweepGradient(
            colors: [color1, color2, color3, color1],
            startAngle: t * 2 * pi,
          ).createShader(Rect.fromLTWH(0, 0, size.width, size.height))
          ..maskFilter = MaskFilter.blur(BlurStyle.normal, spread * 1.5),
      );
    }

    // Interior subtle grid
    final linePaint = Paint()
      ..color = color1.withValues(alpha: 0.04)
      ..strokeWidth = 0.5;
    for (double x = 0; x < size.width; x += 24) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), linePaint);
    }
    for (double y = 0; y < size.height; y += 24) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), linePaint);
    }
  }

  @override
  bool shouldRepaint(_NeonPulsePainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 6. FIREFLIES BACKGROUND — floating golden/amber warm orbs
// ─────────────────────────────────────────────────────────────────────────────
class FirefliesBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const FirefliesBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<FirefliesBackground> createState() => _FirefliesBackgroundState();
}

class _Firefly {
  double x, y, vx, vy, radius, phase, speed;
  _Firefly(
    this.x,
    this.y,
    this.vx,
    this.vy,
    this.radius,
    this.phase,
    this.speed,
  );
}

class _FirefliesBackgroundState extends State<FirefliesBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  List<_Firefly> _fireflies = [];
  Size _lastSize = Size.zero;
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _init(Size size) {
    if (size == _lastSize) return;
    _lastSize = size;
    _fireflies = List.generate(30, (i) {
      return _Firefly(
        _rng.nextDouble() * size.width,
        _rng.nextDouble() * size.height,
        (_rng.nextDouble() - 0.5) * 0.4,
        (_rng.nextDouble() - 0.5) * 0.4,
        2 + _rng.nextDouble() * 3,
        _rng.nextDouble() * 2 * pi,
        0.01 + _rng.nextDouble() * 0.03,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            _init(size);
            return AnimatedBuilder(
              animation: _ctrl,
              builder: (_, _) {
                for (final f in _fireflies) {
                  f.x = (f.x + f.vx + size.width) % size.width;
                  f.y = (f.y + f.vy + size.height) % size.height;
                  f.phase += f.speed;
                }
                return CustomPaint(
                  size: size,
                  painter: _FirefliesPainter(_fireflies),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _FirefliesPainter extends CustomPainter {
  final List<_Firefly> fireflies;
  _FirefliesPainter(this.fireflies);

  @override
  void paint(Canvas canvas, Size size) {
    // Deep forest night base gradient
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF040B04), Color(0xFF0C1A0C)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    for (final f in fireflies) {
      final glowIntensity = (sin(f.phase) + 1.0) / 2.0; // 0.0 to 1.0
      final alpha = (0.2 + 0.8 * glowIntensity).clamp(0.0, 1.0);
      final r = f.radius * (1.0 + 0.4 * glowIntensity);

      // Warm amber firefly color
      final color = const Color(0xFFFFCC33).withValues(alpha: alpha);
      final paintGlow = Paint()
        ..shader = RadialGradient(
          colors: [color, color.withValues(alpha: 0.0)],
        ).createShader(Rect.fromCircle(center: Offset(f.x, f.y), radius: r * 4))
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 5);

      canvas.drawCircle(Offset(f.x, f.y), r * 4, paintGlow);
      canvas.drawCircle(Offset(f.x, f.y), r, Paint()..color = color);
    }
  }

  @override
  bool shouldRepaint(_FirefliesPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 7. STARFIELD BACKGROUND — flying forward through space
// ─────────────────────────────────────────────────────────────────────────────
class StarfieldBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const StarfieldBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<StarfieldBackground> createState() => _StarfieldBackgroundState();
}

class _Star {
  double x, y, z, size;
  _Star(this.x, this.y, this.z, this.size);
}

class _StarfieldBackgroundState extends State<StarfieldBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  List<_Star> _stars = [];
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 1),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  void _init() {
    _stars = List.generate(80, (i) {
      return _Star(
        (_rng.nextDouble() - 0.5) * 1000,
        (_rng.nextDouble() - 0.5) * 1000,
        _rng.nextDouble() * 1000,
        1 + _rng.nextDouble() * 3,
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    if (_stars.isEmpty) _init();
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: LayoutBuilder(
          builder: (context, constraints) {
            final size = Size(constraints.maxWidth, constraints.maxHeight);
            return AnimatedBuilder(
              animation: _ctrl,
              builder: (_, _) {
                for (final s in _stars) {
                  s.z -= 8.0; // Fly forward speed
                  if (s.z <= 0) {
                    s.z = 1000;
                    s.x = (_rng.nextDouble() - 0.5) * 1000;
                    s.y = (_rng.nextDouble() - 0.5) * 1000;
                  }
                }
                return CustomPaint(
                  size: size,
                  painter: _StarfieldPainter(_stars),
                );
              },
            );
          },
        ),
      ),
    );
  }
}

class _StarfieldPainter extends CustomPainter {
  final List<_Star> stars;
  _StarfieldPainter(this.stars);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF020208),
    );

    final cx = size.width / 2;
    final cy = size.height / 2;

    for (final s in stars) {
      // Perspective projection
      final k = 200.0 / s.z;
      final px = s.x * k + cx;
      final py = s.y * k + cy;

      if (px < 0 || px > size.width || py < 0 || py > size.height) continue;

      final r = s.size * (1 - s.z / 1000.0) * 2;
      final alpha = (1 - s.z / 1000.0).clamp(0.0, 1.0);

      canvas.drawCircle(
        Offset(px, py),
        r,
        Paint()..color = Colors.white.withValues(alpha: alpha),
      );
    }
  }

  @override
  bool shouldRepaint(_StarfieldPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 8. CYBER MESH BACKGROUND — scanning grid line bursts
// ─────────────────────────────────────────────────────────────────────────────
class CyberMeshBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const CyberMeshBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<CyberMeshBackground> createState() => _CyberMeshBackgroundState();
}

class _MeshPulse {
  double position, speed, alpha;
  bool isVertical;
  _MeshPulse(this.position, this.speed, this.alpha, this.isVertical);
}

class _CyberMeshBackgroundState extends State<CyberMeshBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;
  List<_MeshPulse> _pulses = [];
  final Random _rng = Random();

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 2),
    )..repeat();
    _pulses = List.generate(
      6,
      (i) => _MeshPulse(
        _rng.nextDouble(),
        0.003 + _rng.nextDouble() * 0.007,
        0.2 + _rng.nextDouble() * 0.5,
        i % 2 == 0,
      ),
    );
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (context, _) {
            for (final p in _pulses) {
              p.position += p.speed;
              if (p.position > 1.0) {
                p.position = 0.0;
                p.speed = 0.003 + _rng.nextDouble() * 0.007;
                p.alpha = 0.2 + _rng.nextDouble() * 0.5;
              }
            }
            return CustomPaint(
              painter: _CyberMeshPainter(_pulses, widget.borderRadius),
              child: Container(),
            );
          },
        ),
      ),
    );
  }
}

class _CyberMeshPainter extends CustomPainter {
  final List<_MeshPulse> pulses;
  final BorderRadius borderRadius;
  _CyberMeshPainter(this.pulses, this.borderRadius);

  @override
  void paint(Canvas canvas, Size size) {
    final rRect = RRect.fromRectAndCorners(
      Rect.fromLTWH(0, 0, size.width, size.height),
      topLeft: borderRadius.topLeft,
      topRight: borderRadius.topRight,
      bottomLeft: borderRadius.bottomLeft,
      bottomRight: borderRadius.bottomRight,
    );
    canvas.drawRRect(rRect, Paint()..color = const Color(0xFF030A14));

    // Draw static grid lines
    final gridPaint = Paint()
      ..color = const Color(0xFF00E5FF).withValues(alpha: 0.05)
      ..strokeWidth = 0.5;

    for (double x = 0; x < size.width; x += 30) {
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), gridPaint);
    }
    for (double y = 0; y < size.height; y += 30) {
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }

    // Draw dynamic pulses
    for (final p in pulses) {
      final pulsePaint = Paint()
        ..color = const Color(0xFF00E5FF).withValues(alpha: p.alpha)
        ..strokeWidth = 2.0;

      if (p.isVertical) {
        final x = p.position * size.width;
        canvas.drawLine(Offset(x, 0), Offset(x, size.height), pulsePaint);
      } else {
        final y = p.position * size.height;
        canvas.drawLine(Offset(0, y), Offset(size.width, y), pulsePaint);
      }
    }
  }

  @override
  bool shouldRepaint(_CyberMeshPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 9. FLUID DYNAMIC BACKGROUND — smooth colorful blending liquid blobs
// ─────────────────────────────────────────────────────────────────────────────
class FluidDynamicBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const FluidDynamicBackground({
    super.key,
    this.borderRadius = BorderRadius.zero,
  });

  @override
  State<FluidDynamicBackground> createState() => _FluidDynamicBackgroundState();
}

class _FluidDynamicBackgroundState extends State<FluidDynamicBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 12),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) {
            final t = _ctrl.value * 2 * pi;
            return CustomPaint(
              painter: _FluidDynamicPainter(t),
              child: Container(),
            );
          },
        ),
      ),
    );
  }
}

class _FluidDynamicPainter extends CustomPainter {
  final double t;
  _FluidDynamicPainter(this.t);

  @override
  void paint(Canvas canvas, Size size) {
    canvas.drawRect(
      Rect.fromLTWH(0, 0, size.width, size.height),
      Paint()..color = const Color(0xFF090212),
    );

    final blobs = [
      _Blob(
        cx: size.width * (0.5 + 0.3 * sin(t)),
        cy: size.height * (0.5 + 0.25 * cos(t * 0.7)),
        rx: size.width * 0.6,
        ry: size.width * 0.6,
        color: const Color(0xFFFF007F).withValues(alpha: 0.25),
      ),
      _Blob(
        cx: size.width * (0.2 + 0.25 * cos(t * 0.5)),
        cy: size.height * (0.8 + 0.2 * sin(t * 0.8)),
        rx: size.width * 0.5,
        ry: size.width * 0.5,
        color: const Color(0xFF00FFFF).withValues(alpha: 0.22),
      ),
      _Blob(
        cx: size.width * (0.8 + 0.2 * sin(t * 0.6)),
        cy: size.height * (0.2 + 0.25 * cos(t * 0.4)),
        rx: size.width * 0.55,
        ry: size.width * 0.55,
        color: const Color(0xFF7F00FF).withValues(alpha: 0.28),
      ),
    ];

    for (final blob in blobs) {
      final paint = Paint()
        ..shader =
            RadialGradient(
              colors: [blob.color, blob.color.withValues(alpha: 0.0)],
            ).createShader(
              Rect.fromCenter(
                center: Offset(blob.cx, blob.cy),
                width: blob.rx,
                height: blob.ry,
              ),
            )
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 35);
      canvas.drawOval(
        Rect.fromCenter(
          center: Offset(blob.cx, blob.cy),
          width: blob.rx,
          height: blob.ry,
        ),
        paint,
      );
    }
  }

  @override
  bool shouldRepaint(_FluidDynamicPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// 10. RETRO GRID BACKGROUND — 3D synthwave scrolling perspective grid
// ─────────────────────────────────────────────────────────────────────────────
class RetroGridBackground extends StatefulWidget {
  final BorderRadius borderRadius;
  const RetroGridBackground({super.key, this.borderRadius = BorderRadius.zero});

  @override
  State<RetroGridBackground> createState() => _RetroGridBackgroundState();
}

class _RetroGridBackgroundState extends State<RetroGridBackground>
    with SingleTickerProviderStateMixin {
  late AnimationController _ctrl;

  @override
  void initState() {
    super.initState();
    _ctrl = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 4),
    )..repeat();
  }

  @override
  void dispose() {
    _ctrl.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return RepaintBoundary(
      child: ClipRRect(
        borderRadius: widget.borderRadius,
        child: AnimatedBuilder(
          animation: _ctrl,
          builder: (_, _) => CustomPaint(
            painter: _RetroGridPainter(_ctrl.value, widget.borderRadius),
            child: Container(),
          ),
        ),
      ),
    );
  }
}

class _RetroGridPainter extends CustomPainter {
  final double t;
  final BorderRadius borderRadius;
  _RetroGridPainter(this.t, this.borderRadius);

  @override
  void paint(Canvas canvas, Size size) {
    // Cyberpunk twilight gradient background
    final bgPaint = Paint()
      ..shader = const LinearGradient(
        colors: [Color(0xFF0F001A), Color(0xFF330033)],
        begin: Alignment.topCenter,
        end: Alignment.bottomCenter,
      ).createShader(Rect.fromLTWH(0, 0, size.width, size.height));
    canvas.drawRect(Rect.fromLTWH(0, 0, size.width, size.height), bgPaint);

    final gridPaint = Paint()
      ..color = const Color(0xFFFF007F).withValues(alpha: 0.15)
      ..strokeWidth = 1.0;

    // Horizon line
    final horizonY = size.height * 0.4;
    canvas.drawLine(
      Offset(0, horizonY),
      Offset(size.width, horizonY),
      gridPaint,
    );

    // Perspective lines (radiating from horizon center)
    final vanishX = size.width / 2;
    const linesCount = 12;
    for (int i = 0; i <= linesCount; i++) {
      final ratio = i / linesCount;
      final startX = ratio * size.width;
      canvas.drawLine(
        Offset(vanishX, horizonY),
        Offset(startX, size.height),
        gridPaint,
      );
    }

    // Scrolling horizontal lines (exponentially spaced for 3D effect)
    final scrollOffset = t; // 0.0 to 1.0
    const horizLines = 7;
    for (int i = 0; i < horizLines; i++) {
      final linePos = (i + scrollOffset) / horizLines;
      // Exponential distribution to make lines closer near horizon
      final y = horizonY + (size.height - horizonY) * pow(linePos, 2.2);
      canvas.drawLine(Offset(0, y), Offset(size.width, y), gridPaint);
    }
  }

  @override
  bool shouldRepaint(_RetroGridPainter old) => true;
}

// ─────────────────────────────────────────────────────────────────────────────
// Helper: build the right animated background widget by key
// ─────────────────────────────────────────────────────────────────────────────
Widget buildAnimatedBackground(
  String key, {
  BorderRadius borderRadius = BorderRadius.zero,
}) {
  switch (key) {
    case 'matrix':
      return MatrixBackground(borderRadius: borderRadius);
    case 'particles':
      return ParticlesBackground(borderRadius: borderRadius);
    case 'aurora':
      return AuroraBackground(borderRadius: borderRadius);
    case 'waves':
      return WavesBackground(borderRadius: borderRadius);
    case 'neon_pulse':
      return NeonPulseBackground(borderRadius: borderRadius);
    case 'fireflies':
      return FirefliesBackground(borderRadius: borderRadius);
    case 'starfield':
      return StarfieldBackground(borderRadius: borderRadius);
    case 'cyber_mesh':
      return CyberMeshBackground(borderRadius: borderRadius);
    case 'fluid_dynamic':
      return FluidDynamicBackground(borderRadius: borderRadius);
    case 'retro_grid':
      return RetroGridBackground(borderRadius: borderRadius);
    default:
      return Container(
        decoration: BoxDecoration(
          color: Colors.black,
          borderRadius: borderRadius,
        ),
      );
  }
}

const Map<String, String> animatedBgLabels = {
  'matrix': 'Matrix Rain',
  'particles': 'Particles',
  'aurora': 'Aurora',
  'waves': 'Ocean Waves',
  'neon_pulse': 'Neon Pulse',
  'fireflies': 'Fireflies',
  'starfield': 'Starfield',
  'cyber_mesh': 'Cyber Mesh',
  'fluid_dynamic': 'Fluid Dynamic',
  'retro_grid': 'Retro Grid',
};
