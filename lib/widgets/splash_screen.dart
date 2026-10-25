import 'dart:async';
import 'dart:math' as math;
import 'dart:ui';
import 'package:flutter/material.dart';

class AnimatedSplashScreen extends StatefulWidget {
  final VoidCallback onComplete;

  const AnimatedSplashScreen({super.key, required this.onComplete});

  @override
  State<AnimatedSplashScreen> createState() => _AnimatedSplashScreenState();
}

class SparkParticle {
  Offset position;
  Offset velocity;
  double size;
  double opacity;
  Color color;

  SparkParticle({
    required this.position,
    required this.velocity,
    required this.size,
    required this.opacity,
    required this.color,
  });

  void update() {
    position += velocity;
    opacity -= 0.035; // fade out quickly for sparkling effect
    if (size > 0.1) size -= 0.08;
  }
}

class _AnimatedSplashScreenState extends State<AnimatedSplashScreen>
    with TickerProviderStateMixin {
  // Animation controllers
  late AnimationController _wDrawController;
  late AnimationController _emergeController;
  late AnimationController _brandingController;
  late AnimationController _floatingController;
  late AnimationController _skipFadeController;
  late AnimationController _fadeOutController;

  // Animation values
  late Animation<double> _wDrawProgress;
  late Animation<double> _emergeProgress;
  late Animation<double> _brandingFade;
  late Animation<double> _brandingScale;
  late Animation<double> _skipFade;
  late Animation<double> _fadeOutProgress;

  bool _isSkipped = false;
  final List<SparkParticle> _particles = [];
  final List<Timer> _timers = [];

  @override
  void initState() {
    super.initState();

    // 1. W drawing animation (0 to 2.5s)
    _wDrawController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2500),
    );
    _wDrawProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _wDrawController, curve: Curves.easeInOutSine),
    );

    // Spawn sparks at the drawing tip of the logo
    _wDrawController.addListener(() {
      if (_wDrawProgress.value > 0.01 && _wDrawProgress.value < 0.99) {
        // Calculate tip in 200x140 logo painter coordinate space
        final tip = _getTipOffset(200, 140, _wDrawProgress.value);
        final r = math.Random();
        for (int i = 0; i < 2; i++) {
          final angle = r.nextDouble() * 2 * math.pi;
          final speed = r.nextDouble() * 1.2 + 0.4;
          final size = r.nextDouble() * 2.5 + 1.5;
          final colors = [
            const Color(0xFF00E5FF),
            const Color(0xFFEC4899),
            const Color(0xFFA855F7),
          ];
          final color = colors[r.nextInt(colors.length)];
          _particles.add(
            SparkParticle(
              position: tip,
              velocity: Offset(
                math.cos(angle) * speed,
                math.sin(angle) * speed,
              ),
              size: size,
              opacity: 1.0,
              color: color,
            ),
          );
        }
      }
    });

    // 2. Emerging items animation (starts after W is drawn, 2.5 to 4.5s)
    _emergeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 2000),
    );
    _emergeProgress = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _emergeController, curve: Curves.easeOutBack),
    );

    // 3. Branding text and logo glow animation (3.0s to 5.0s)
    _brandingController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1500),
    );
    _brandingFade = Tween<double>(begin: 0.0, end: 1.0).animate(
      CurvedAnimation(parent: _brandingController, curve: Curves.easeIn),
    );
    _brandingScale = Tween<double>(begin: 0.9, end: 1.0).animate(
      CurvedAnimation(parent: _brandingController, curve: Curves.easeOutCubic),
    );

    // 4. Continuous lightweight floating and background animation loop (vsync-bound)
    _floatingController = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();

    // Ticker logic to update particle positions smoothly every frame
    _floatingController.addListener(() {
      if (_particles.isNotEmpty) {
        for (int i = _particles.length - 1; i >= 0; i--) {
          _particles[i].update();
          if (_particles[i].opacity <= 0.0) {
            _particles.removeAt(i);
          }
        }
      }
    });

    // 5. Skip button fade in (fades in after 2.0s)
    _skipFadeController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _skipFade = Tween<double>(
      begin: 0.0,
      end: 1.0,
    ).animate(_skipFadeController);

    // 6. Overall fade out (7.2s to 8.0s)
    _fadeOutController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 800),
    );
    _fadeOutProgress = Tween<double>(begin: 1.0, end: 0.0).animate(
      CurvedAnimation(parent: _fadeOutController, curve: Curves.easeOut),
    );

    // Start sequence timeline
    _startAnimationTimeline();
  }

  void _startAnimationTimeline() {
    // 1. Draw W with neon sparks
    _wDrawController.forward();

    // 2. Fade in skip button after 1.8 seconds
    _timers.add(
      Timer(const Duration(milliseconds: 1800), () {
        if (!mounted || _isSkipped) return;
        _skipFadeController.forward();
      }),
    );

    // 3. Emerge photos & widgets
    _timers.add(
      Timer(const Duration(milliseconds: 2000), () {
        if (!mounted || _isSkipped) return;
        _emergeController.forward();
      }),
    );

    // 4. Fade/Scale in WallSync transparent logo & RedSkill Studios developer branding
    _timers.add(
      Timer(const Duration(milliseconds: 1600), () {
        if (!mounted || _isSkipped) return;
        _brandingController.forward();
      }),
    );

    // 5. Play to 7.0s, then trigger overall smooth fade out
    _timers.add(
      Timer(const Duration(milliseconds: 7000), () async {
        if (!mounted || _isSkipped) return;
        await _fadeOutController.forward();

        // 6. Complete
        if (mounted && !_isSkipped) {
          widget.onComplete();
        }
      }),
    );
  }

  void _skipSplash() async {
    if (_isSkipped) return;
    _isSkipped = true;

    for (final timer in _timers) {
      timer.cancel();
    }

    // Quick fade out on skip
    await _fadeOutController.forward();
    if (mounted) {
      widget.onComplete();
    }
  }

  Offset _getTipOffset(double w, double h, double progress) {
    final p0 = Offset(w * 0.18, h * 0.22);
    final p1 = Offset(w * 0.36, h * 0.78);
    final p2 = Offset(w * 0.50, h * 0.42);
    final p3 = Offset(w * 0.64, h * 0.78);
    final p4 = Offset(w * 0.82, h * 0.22);

    final d1 = (p1 - p0).distance;
    final d2 = (p2 - p1).distance;
    final d3 = (p3 - p2).distance;
    final d4 = (p4 - p3).distance;
    final totalLen = d1 + d2 + d3 + d4;

    final activeLen = totalLen * progress;
    double drawn = 0.0;

    if (activeLen <= d1) {
      return Offset.lerp(p0, p1, activeLen / d1)!;
    } else {
      drawn += d1;
      if (activeLen - drawn <= d2) {
        return Offset.lerp(p1, p2, (activeLen - drawn) / d2)!;
      } else {
        drawn += d2;
        if (activeLen - drawn <= d3) {
          return Offset.lerp(p2, p3, (activeLen - drawn) / d3)!;
        } else {
          drawn += d3;
          return Offset.lerp(
            p3,
            p4,
            ((activeLen - drawn) / d4).clamp(0.0, 1.0),
          )!;
        }
      }
    }
  }

  @override
  void dispose() {
    for (final timer in _timers) {
      timer.cancel();
    }
    _wDrawController.dispose();
    _emergeController.dispose();
    _brandingController.dispose();
    _floatingController.dispose();
    _skipFadeController.dispose();
    _fadeOutController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.of(context).size;
    final w = size.width;
    final h = size.height;

    final centerX = w / 2;
    final centerY = h / 2 - 30;

    return Scaffold(
      backgroundColor: const Color(0xFF060609),
      body: AnimatedBuilder(
        animation: _fadeOutProgress,
        builder: (context, child) {
          return Opacity(
            opacity: _fadeOutProgress.value,
            child: Stack(
              children: [
                // 1. Dynamic Mesh Gradient Background (vsync ticker-driven, no Timer)
                Positioned.fill(
                  child: AnimatedBuilder(
                    animation: _floatingController,
                    builder: (context, _) => _buildMeshGradient(w, h),
                  ),
                ),

                // Ambient dark tint overlay (Zero GPU blur overhead)
                Positioned.fill(
                  child: Container(color: Colors.black.withValues(alpha: 0.50)),
                ),

                // Background dot grid
                Positioned.fill(
                  child: RepaintBoundary(
                    child: CustomPaint(painter: GridPainter(opacity: 0.04)),
                  ),
                ),

                // 2. Emerging Photo Cards
                ..._buildPhotoCards(centerX, centerY),

                // 3. Emerging Widget Cards
                ..._buildWidgetCards(centerX, centerY),

                // 4. Center Logo and Sparkling Path
                Center(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      Container(
                        width: 280,
                        height: 280,
                        alignment: Alignment.center,
                        child: Stack(
                          alignment: Alignment.center,
                          children: [
                            // Ambient radial glow behind the logo
                            AnimatedBuilder(
                              animation: _brandingFade,
                              builder: (context, _) {
                                return Container(
                                  width: 240,
                                  height: 240,
                                  decoration: BoxDecoration(
                                    shape: BoxShape.circle,
                                    gradient: RadialGradient(
                                      colors: [
                                        const Color(0xFF00E5FF).withValues(
                                          alpha: 0.16 * _brandingFade.value,
                                        ),
                                        const Color(0xFFEC4899).withValues(
                                          alpha: 0.12 * _brandingFade.value,
                                        ),
                                        Colors.transparent,
                                      ],
                                      stops: const [0.0, 0.55, 1.0],
                                    ),
                                  ),
                                );
                              },
                            ),

                            // Drawing stroke and spark particles
                            AnimatedBuilder(
                              animation: Listenable.merge([
                                _wDrawProgress,
                                _brandingFade,
                                _floatingController,
                              ]),
                              builder: (context, _) {
                                return CustomPaint(
                                  painter: LogoWPainter(
                                    drawProgress: _wDrawProgress.value,
                                    glowIntensity: _brandingFade.value,
                                    strokeOpacity:
                                        (1.0 - _brandingFade.value).clamp(
                                          0.0,
                                          1.0,
                                        ),
                                    particles: _particles,
                                  ),
                                  size: const Size(200, 140),
                                );
                              },
                            ),

                            // Transparent 3D WallSync Official Logo
                            AnimatedBuilder(
                              animation: Listenable.merge([
                                _brandingFade,
                                _brandingScale,
                                _floatingController,
                              ]),
                              builder: (context, _) {
                                final floatTime =
                                    _floatingController.value * 2 * math.pi;
                                final floatY = 4.0 * math.sin(floatTime);
                                return Transform.translate(
                                  offset: Offset(0, floatY),
                                  child: Transform.scale(
                                    scale: _brandingScale.value,
                                    child: Opacity(
                                      opacity: _brandingFade.value.clamp(
                                        0.0,
                                        1.0,
                                      ),
                                      child: Container(
                                        width: 270,
                                        height: 270,
                                        decoration: BoxDecoration(
                                          boxShadow: [
                                            BoxShadow(
                                              color: const Color(
                                                0xFF00E5FF,
                                              ).withValues(
                                                alpha:
                                                    0.15 * _brandingFade.value,
                                              ),
                                              blurRadius: 36,
                                              spreadRadius: 2,
                                            ),
                                            BoxShadow(
                                              color: const Color(
                                                0xFFEC4899,
                                              ).withValues(
                                                alpha:
                                                    0.12 * _brandingFade.value,
                                              ),
                                              blurRadius: 48,
                                              spreadRadius: 4,
                                            ),
                                          ],
                                        ),
                                        child: Image.asset(
                                          'assets/wallsync_logo.png',
                                          fit: BoxFit.contain,
                                          filterQuality: FilterQuality.high,
                                        ),
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),

                // 5. Developer Studio Footer: RedSkill Studios
                Positioned(
                  bottom: 30,
                  left: 0,
                  right: 0,
                  child: AnimatedBuilder(
                    animation: _brandingController,
                    builder: (context, _) {
                      return Opacity(
                        opacity: _brandingFade.value.clamp(0.0, 1.0),
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              'DEVELOPED BY',
                              style: TextStyle(
                                fontSize: 9,
                                fontWeight: FontWeight.w800,
                                letterSpacing: 4.0,
                                color: Colors.white.withValues(alpha: 0.45),
                              ),
                            ),
                            const SizedBox(height: 8),
                            Container(
                              height: 38,
                              constraints: const BoxConstraints(maxWidth: 240),
                              decoration: BoxDecoration(
                                boxShadow: [
                                  BoxShadow(
                                    color: const Color(0xFFEF4444).withValues(
                                      alpha: 0.20 * _brandingFade.value,
                                    ),
                                    blurRadius: 22,
                                    spreadRadius: 2,
                                  ),
                                ],
                              ),
                              child: Image.asset(
                                'assets/redskills_studios.png',
                                fit: BoxFit.contain,
                                filterQuality: FilterQuality.high,
                              ),
                            ),
                          ],
                        ),
                      );
                    },
                  ),
                ),

                // 5. Skip Button
                Positioned(
                  top: 40,
                  right: 40,
                  child: AnimatedBuilder(
                    animation: _skipFade,
                    builder: (context, _) {
                      return Opacity(
                        opacity: _skipFade.value,
                        child: IgnorePointer(
                          ignoring: _skipFade.value < 0.1,
                          child: TextButton(
                            onPressed: _skipSplash,
                            style: TextButton.styleFrom(
                              foregroundColor: Colors.white70,
                              backgroundColor: Colors.white.withValues(
                                alpha: 0.05,
                              ),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 18,
                                vertical: 10,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(20),
                                side: BorderSide(
                                  color: Colors.white.withValues(alpha: 0.15),
                                ),
                              ),
                            ),
                            child: const Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  'Skip',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.bold,
                                    letterSpacing: 1.0,
                                  ),
                                ),
                                SizedBox(width: 4),
                                Icon(Icons.arrow_forward_ios_rounded, size: 10),
                              ],
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
        },
      ),
    );
  }

  Widget _buildMeshGradient(double w, double h) {
    const framesPerCycle = 240;
    final quantizedFrame = (_floatingController.value * framesPerCycle).floor();
    final double flowValue = quantizedFrame / framesPerCycle * 2 * math.pi;
    final double radius = math.min(w, h) * 0.3;
    final double cx = w / 2;
    final double cy = h / 2;

    // Smooth orbits
    final double b1x = cx + radius * math.cos(flowValue);
    final double b1y = cy + radius * math.sin(flowValue);

    final double b2x =
        cx + radius * math.cos(flowValue * 0.6 + math.pi * 2 / 3);
    final double b2y =
        cy + radius * math.sin(flowValue * 0.6 + math.pi * 2 / 3);

    final double b3x =
        cx + radius * math.cos(flowValue * 0.8 + math.pi * 4 / 3);
    final double b3y =
        cy + radius * math.sin(flowValue * 0.8 + math.pi * 4 / 3);

    return CustomPaint(
      painter: BackgroundBlobsPainter(
        b1: Offset(b1x, b1y),
        b2: Offset(b2x, b2y),
        b3: Offset(b3x, b3y),
        blobRadius: radius * 1.5,
      ),
    );
  }

  List<Widget> _buildPhotoCards(double centerX, double centerY) {
    final photos = [
      _EmergedItemData(
        assetPath: 'assets/cyberpunk.png',
        targetOffset: const Offset(-280, -140),
        angle: -0.15,
        title: 'Cyberpunk Skyline',
        floatPhase: 0.0,
      ),
      _EmergedItemData(
        assetPath: 'assets/aurora.png',
        targetOffset: const Offset(-310, 30),
        angle: 0.12,
        title: 'Aurora Borealis',
        floatPhase: math.pi / 3,
      ),
      _EmergedItemData(
        assetPath: 'assets/forest.png',
        targetOffset: const Offset(-240, 180),
        angle: -0.08,
        title: 'Mystic Forest',
        floatPhase: math.pi * 2 / 3,
      ),
    ];

    return photos.map((data) {
      return AnimatedBuilder(
        animation: Listenable.merge([_emergeProgress, _floatingController]),
        builder: (context, _) {
          final progress = _emergeProgress.value;
          if (progress <= 0.01) return const SizedBox.shrink();

          // Float animation offset
          final floatTime = _floatingController.value * 2 * math.pi;
          final floatX = 6 * math.sin(floatTime + data.floatPhase);
          final floatY = 8 * math.cos(floatTime + data.floatPhase);

          final currentX = centerX + data.targetOffset.dx * progress + floatX;
          final currentY = centerY + data.targetOffset.dy * progress + floatY;

          return Positioned(
            left: currentX - 70,
            top: currentY - 50,
            child: Transform.rotate(
              angle: data.angle * progress,
              child: Opacity(
                opacity: progress.clamp(0.0, 1.0),
                child: Container(
                  width: 140,
                  height: 100,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: const Color(
                        0xFF38BDF8,
                      ).withValues(alpha: 0.3 * progress),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 12,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(11),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Image.asset(
                            data.assetPath,
                            fit: BoxFit.cover,
                            cacheWidth: 171,
                            cacheHeight: 121,
                          ),
                        ),
                        // Reflective Gloss Sweep overlay
                        Positioned.fill(child: _buildGlossSweep(progress)),
                        // Label
                        Positioned(
                          bottom: 0,
                          left: 0,
                          right: 0,
                          child: Container(
                            padding: const EdgeInsets.symmetric(
                              vertical: 4,
                              horizontal: 8,
                            ),
                            color: Colors.black.withValues(alpha: 0.65),
                            child: Text(
                              data.title,
                              style: const TextStyle(
                                fontSize: 8,
                                fontWeight: FontWeight.bold,
                                color: Colors.white70,
                              ),
                              overflow: TextOverflow.ellipsis,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }).toList();
  }

  List<Widget> _buildWidgetCards(double centerX, double centerY) {
    final widgetsData = [
      _EmergedItemData(
        targetOffset: const Offset(260, -130),
        angle: 0.1,
        title: 'Clock Display',
        floatPhase: math.pi,
        customWidget: (progress) => _buildMockClockWidget(progress),
      ),
      _EmergedItemData(
        targetOffset: const Offset(310, 20),
        angle: -0.06,
        title: 'Color Palette',
        floatPhase: math.pi * 4 / 3,
        customWidget: (progress) => _buildMockPaletteWidget(progress),
      ),
      _EmergedItemData(
        targetOffset: const Offset(250, 170),
        angle: 0.08,
        title: 'System Sliders',
        floatPhase: math.pi * 5 / 3,
        customWidget: (progress) => _buildMockSlidersWidget(progress),
      ),
    ];

    return widgetsData.map((data) {
      return AnimatedBuilder(
        animation: Listenable.merge([_emergeProgress, _floatingController]),
        builder: (context, _) {
          final progress = _emergeProgress.value;
          if (progress <= 0.01) return const SizedBox.shrink();

          final floatTime = _floatingController.value * 2 * math.pi;
          final floatX = 8 * math.cos(floatTime + data.floatPhase);
          final floatY = 6 * math.sin(floatTime + data.floatPhase);

          final currentX = centerX + data.targetOffset.dx * progress + floatX;
          final currentY = centerY + data.targetOffset.dy * progress + floatY;

          return Positioned(
            left: currentX - 75,
            top: currentY - 50,
            child: Transform.rotate(
              angle: data.angle * progress,
              child: Opacity(
                opacity: progress.clamp(0.0, 1.0),
                child: Container(
                  width: 150,
                  height: 100,
                  decoration: BoxDecoration(
                    borderRadius: BorderRadius.circular(14),
                    color: Colors.black.withValues(alpha: 0.4),
                    border: Border.all(
                      color: const Color(
                        0xFFF472B6,
                      ).withValues(alpha: 0.25 * progress),
                      width: 1.5,
                    ),
                    boxShadow: [
                      BoxShadow(
                        color: Colors.black.withValues(alpha: 0.45),
                        blurRadius: 14,
                        spreadRadius: 1,
                      ),
                    ],
                  ),
                  child: ClipRRect(
                    borderRadius: BorderRadius.circular(13),
                    child: Stack(
                      children: [
                        Positioned.fill(
                          child: Padding(
                            padding: const EdgeInsets.all(8.0),
                            child: data.customWidget!(progress),
                          ),
                        ),
                        // Reflective gloss sweep
                        Positioned.fill(child: _buildGlossSweep(progress)),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          );
        },
      );
    }).toList();
  }

  // Helper to build diagonal gloss reflection sweep
  Widget _buildGlossSweep(double progress) {
    // Shimmer sweep maps linearly to progress value
    final double shimmerVal = progress;
    return Container(
      decoration: BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment(-2.5 + shimmerVal * 5.0, -1.2),
          end: Alignment(-0.5 + shimmerVal * 5.0, 1.2),
          colors: [
            Colors.white.withValues(alpha: 0.0),
            Colors.white.withValues(alpha: 0.1),
            Colors.white.withValues(alpha: 0.22),
            Colors.white.withValues(alpha: 0.1),
            Colors.white.withValues(alpha: 0.0),
          ],
          stops: const [0.0, 0.3, 0.5, 0.7, 1.0],
        ),
      ),
    );
  }

  // Mini clock widget mock with dynamic digital fade-in entry
  Widget _buildMockClockWidget(double progress) {
    // Map progress 0.3-0.9 to 0.0-1.0 clock content scale/opacity
    final double factor = ((progress - 0.3) / 0.6).clamp(0.0, 1.0);
    final double opacity = Curves.easeIn.transform(factor);
    final double scale = 0.8 + 0.2 * Curves.easeOutBack.transform(factor);

    return Opacity(
      opacity: opacity,
      child: Transform.scale(
        scale: scale,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisAlignment: MainAxisAlignment.center,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(
                  'CLOCK OVERLAY',
                  style: TextStyle(
                    fontSize: 7,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 1.0,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ),
                Container(
                  width: 5,
                  height: 5,
                  decoration: const BoxDecoration(
                    color: Colors.greenAccent,
                    shape: BoxShape.circle,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            const Text(
              '10:42 AM',
              style: TextStyle(
                fontSize: 22,
                fontWeight: FontWeight.bold,
                color: Colors.white,
                letterSpacing: 0.5,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              'SUNDAY, JUNE 21',
              style: TextStyle(
                fontSize: 7,
                fontWeight: FontWeight.w600,
                color: Colors.white.withValues(alpha: 0.6),
                letterSpacing: 0.8,
              ),
            ),
          ],
        ),
      ),
    );
  }

  // Mini color palette widget mock with staggered popup of circles
  Widget _buildMockPaletteWidget(double progress) {
    final colors = [
      const Color(0xFF38BDF8),
      const Color(0xFFF472B6),
      const Color(0xFFC084FC),
      const Color(0xFF34D399),
      const Color(0xFFFBBF24),
      const Color(0xFFF87171),
    ];

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'COLOR PALETTE',
          style: TextStyle(
            fontSize: 7,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 6,
          runSpacing: 6,
          children: List.generate(colors.length, (index) {
            // Stagger scale factor for each circle
            final double start = 0.4 + index * 0.08;
            final double end = (start + 0.35).clamp(0.0, 1.0);
            double circleScale = 0.0;
            if (progress >= start) {
              final double t = ((progress - start) / (end - start)).clamp(
                0.0,
                1.0,
              );
              circleScale = Curves.easeOutBack.transform(t);
            }

            return Transform.scale(
              scale: circleScale,
              child: Container(
                width: 22,
                height: 22,
                decoration: BoxDecoration(
                  color: colors[index],
                  shape: BoxShape.circle,
                  border: Border.all(color: Colors.white24, width: 1.0),
                ),
              ),
            );
          }),
        ),
      ],
    );
  }

  // Mini sliders widget mock with loading progress animation
  Widget _buildMockSlidersWidget(double progress) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        Text(
          'WINDOW CONTROLS',
          style: TextStyle(
            fontSize: 7,
            fontWeight: FontWeight.bold,
            letterSpacing: 1.0,
            color: Colors.white.withValues(alpha: 0.4),
          ),
        ),
        const SizedBox(height: 8),
        _buildMockSliderRow('Opacity', 0.8, const Color(0xFF38BDF8), progress),
        const SizedBox(height: 6),
        _buildMockSliderRow('Blur', 0.6, const Color(0xFFC084FC), progress),
      ],
    );
  }

  Widget _buildMockSliderRow(
    String label,
    double targetVal,
    Color color,
    double progress,
  ) {
    // Slide load track from 0.0 to target percentage after progress is halfway (0.5 to 1.0)
    double widthFactor = 0.0;
    if (progress > 0.5) {
      final double t = ((progress - 0.5) / 0.5).clamp(0.0, 1.0);
      widthFactor = targetVal * Curves.easeInOutCubic.transform(t);
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Text(
              label,
              style: const TextStyle(fontSize: 7, color: Colors.white70),
            ),
            Text(
              '${(widthFactor * 100).toInt()}%',
              style: TextStyle(
                fontSize: 7,
                color: color,
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 2),
        ClipRRect(
          borderRadius: BorderRadius.circular(2),
          child: Container(
            height: 4,
            width: double.infinity,
            color: Colors.white12,
            child: Align(
              alignment: Alignment.centerLeft,
              child: FractionallySizedBox(
                widthFactor: widthFactor.clamp(0.001, 1.0),
                child: Container(color: color),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _EmergedItemData {
  final String assetPath;
  final Offset targetOffset;
  final double angle;
  final String title;
  final double floatPhase;
  final Widget Function(double progress)? customWidget;

  _EmergedItemData({
    this.assetPath = '',
    required this.targetOffset,
    required this.angle,
    required this.title,
    required this.floatPhase,
    this.customWidget,
  });
}

class BackgroundBlobsPainter extends CustomPainter {
  final Offset b1;
  final Offset b2;
  final Offset b3;
  final double blobRadius;

  BackgroundBlobsPainter({
    required this.b1,
    required this.b2,
    required this.b3,
    required this.blobRadius,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final rect = Offset.zero & size;
    canvas.clipRect(rect);

    // Multi-stop radial gradients for ultra-smooth soft ambient diffusion
    // Eliminates the need for expensive fullscreen BackdropFilter blurs!
    final r = blobRadius * 1.35;

    final paint1 = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFF00E5FF).withValues(alpha: 0.22),
          const Color(0xFF00E5FF).withValues(alpha: 0.10),
          const Color(0xFF00E5FF).withValues(alpha: 0.03),
          const Color(0xFF00E5FF).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: b1, radius: r));
    canvas.drawCircle(b1, r, paint1);

    final paint2 = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFEC4899).withValues(alpha: 0.20),
          const Color(0xFFEC4899).withValues(alpha: 0.08),
          const Color(0xFFEC4899).withValues(alpha: 0.02),
          const Color(0xFFEC4899).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: b2, radius: r));
    canvas.drawCircle(b2, r, paint2);

    final paint3 = Paint()
      ..shader = RadialGradient(
        colors: [
          const Color(0xFFA855F7).withValues(alpha: 0.22),
          const Color(0xFFA855F7).withValues(alpha: 0.10),
          const Color(0xFFA855F7).withValues(alpha: 0.03),
          const Color(0xFFA855F7).withValues(alpha: 0.0),
        ],
        stops: const [0.0, 0.45, 0.75, 1.0],
      ).createShader(Rect.fromCircle(center: b3, radius: r));
    canvas.drawCircle(b3, r, paint3);
  }

  @override
  bool shouldRepaint(covariant BackgroundBlobsPainter oldDelegate) {
    return oldDelegate.b1 != b1 || oldDelegate.b2 != b2 || oldDelegate.b3 != b3;
  }
}

class GridPainter extends CustomPainter {
  final double opacity;

  const GridPainter({this.opacity = 1.0});

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: opacity)
      ..strokeWidth = 1.2
      ..strokeCap = StrokeCap.round;

    const double spacing = 24.0;
    final List<Offset> points = [];
    for (double x = 0; x < size.width; x += spacing) {
      for (double y = 0; y < size.height; y += spacing) {
        points.add(Offset(x, y));
      }
    }
    if (points.isNotEmpty) {
      canvas.drawPoints(PointMode.points, points, paint);
    }
  }

  @override
  bool shouldRepaint(covariant GridPainter oldDelegate) => false;
}

class LogoWPainter extends CustomPainter {
  final double drawProgress;
  final double glowIntensity;
  final double strokeOpacity;
  final List<SparkParticle> particles;

  LogoWPainter({
    required this.drawProgress,
    required this.glowIntensity,
    this.strokeOpacity = 1.0,
    required this.particles,
  });

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    final sAlpha = strokeOpacity.clamp(0.0, 1.0);

    // Stylized W path vertices: 4 strokes
    final p0 = Offset(w * 0.18, h * 0.22);
    final p1 = Offset(w * 0.36, h * 0.78);
    final p2 = Offset(w * 0.50, h * 0.42);
    final p3 = Offset(w * 0.64, h * 0.78);
    final p4 = Offset(w * 0.82, h * 0.22);

    final d1 = (p1 - p0).distance;
    final d2 = (p2 - p1).distance;
    final d3 = (p3 - p2).distance;
    final d4 = (p4 - p3).distance;
    final totalLen = d1 + d2 + d3 + d4;

    final activeLen = totalLen * drawProgress;

    final path = Path();
    path.moveTo(p0.dx, p0.dy);

    double drawn = 0.0;
    if (activeLen > 0) {
      if (activeLen <= d1) {
        final t = activeLen / d1;
        final cur = Offset.lerp(p0, p1, t)!;
        path.lineTo(cur.dx, cur.dy);
      } else {
        path.lineTo(p1.dx, p1.dy);
        drawn += d1;

        if (activeLen - drawn <= d2) {
          final t = (activeLen - drawn) / d2;
          final cur = Offset.lerp(p1, p2, t)!;
          path.lineTo(cur.dx, cur.dy);
        } else {
          path.lineTo(p2.dx, p2.dy);
          drawn += d2;

          if (activeLen - drawn <= d3) {
            final t = (activeLen - drawn) / d3;
            final cur = Offset.lerp(p2, p3, t)!;
            path.lineTo(cur.dx, cur.dy);
          } else {
            path.lineTo(p3.dx, p3.dy);
            drawn += d3;

            final t = (activeLen - drawn) / d4;
            final cur = Offset.lerp(p3, p4, t.clamp(0.0, 1.0))!;
            path.lineTo(cur.dx, cur.dy);
          }
        }
      }
    }

    final paintShader = const LinearGradient(
      colors: [Color(0xFF00E5FF), Color(0xFFEC4899), Color(0xFFA855F7)],
    ).createShader(Rect.fromLTWH(0, 0, w, h));

    // Glow effects
    if (glowIntensity > 0.01 && sAlpha > 0.02) {
      final glowPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 10.0 + 4.0 * glowIntensity
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(
          0xFFA855F7,
        ).withValues(alpha: 0.15 * glowIntensity * sAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 12.0 * glowIntensity);

      canvas.drawPath(path, glowPaint);

      final glowPaint2 = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 6.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..color = const Color(
          0xFFEC4899,
        ).withValues(alpha: 0.25 * glowIntensity * sAlpha)
        ..maskFilter = MaskFilter.blur(BlurStyle.normal, 6.0 * glowIntensity);

      canvas.drawPath(path, glowPaint2);
    }

    // Main line drawing
    if (sAlpha > 0.01) {
      final mainPaint = Paint()
        ..style = PaintingStyle.stroke
        ..strokeWidth = 5.0
        ..strokeCap = StrokeCap.round
        ..strokeJoin = StrokeJoin.round
        ..shader = paintShader;

      if (sAlpha < 0.99) {
        canvas.saveLayer(
          Rect.fromLTWH(0, 0, w, h),
          Paint()..color = Colors.white.withValues(alpha: sAlpha),
        );
        canvas.drawPath(path, mainPaint);
        canvas.restore();
      } else {
        canvas.drawPath(path, mainPaint);
      }
    }

    // Draw little glow point at drawing tip
    if (drawProgress > 0.01 && drawProgress < 0.99) {
      Offset tip = p0;
      if (activeLen <= d1) {
        tip = Offset.lerp(p0, p1, activeLen / d1)!;
      } else if (activeLen - d1 <= d2) {
        tip = Offset.lerp(p1, p2, (activeLen - d1) / d2)!;
      } else if (activeLen - d1 - d2 <= d3) {
        tip = Offset.lerp(p2, p3, (activeLen - d1 - d2) / d3)!;
      } else {
        tip = Offset.lerp(p3, p4, (activeLen - d1 - d2 - d3) / d4)!;
      }

      final tipGlow = Paint()
        ..color = Colors.white
        ..maskFilter = const MaskFilter.blur(BlurStyle.normal, 4.0);
      canvas.drawCircle(tip, 6.0, tipGlow);

      final tipSolid = Paint()..color = const Color(0xFF00E5FF);
      canvas.drawCircle(tip, 3.0, tipSolid);
    }

    // Render active sparkles/particles inside the local scope
    if (particles.isNotEmpty) {
      for (final p in particles) {
        final particlePaint = Paint()
          ..color = p.color.withValues(alpha: p.opacity)
          ..style = PaintingStyle.fill;

        // Draw double glow for particles
        if (p.opacity > 0.15) {
          final particleGlow = Paint()
            ..color = p.color.withValues(alpha: p.opacity * 0.3)
            ..maskFilter = MaskFilter.blur(BlurStyle.normal, p.size * 1.5);
          canvas.drawCircle(p.position, p.size * 2.5, particleGlow);
        }

        canvas.drawCircle(p.position, p.size, particlePaint);
      }
    }
  }

  @override
  bool shouldRepaint(covariant LogoWPainter oldDelegate) => true;
}
