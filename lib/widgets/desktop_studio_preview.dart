import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' as ui;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../models/desktop_studio_template.dart';

/// Interactive virtual desktop canvas and live Dock Animation Engine.
/// Renders a simulated 16:9 Windows desktop with full dock styling,
/// fisheye magnification, hover lift, bounce on click, and edit mode guides.
class DesktopStudioPreview extends StatefulWidget {
  final DesktopStudioTemplate template;
  final bool isLivePreviewMode;
  final String? selectedElementId;
  final ValueChanged<String?>? onSelectElement;
  final ValueChanged<DesktopStudioTemplate>? onUpdateTemplate;

  const DesktopStudioPreview({
    super.key,
    required this.template,
    this.isLivePreviewMode = true,
    this.selectedElementId,
    this.onSelectElement,
    this.onUpdateTemplate,
  });

  @override
  State<DesktopStudioPreview> createState() => _DesktopStudioPreviewState();
}

class _DesktopStudioPreviewState extends State<DesktopStudioPreview>
    with TickerProviderStateMixin {
  // Fisheye tracking state
  Offset? _hoverGlobalPosition;
  final Map<String, GlobalKey> _itemKeys = {};
  final Map<String, AnimationController> _bounceControllers = {};

  // Running task pulse controller
  late AnimationController _pulseController;
  late Animation<double> _pulseAnimation;

  // Auto-hide controller
  late AnimationController _autoHideController;
  Timer? _autoHideTimer;
  bool _isMouseInsideDock = false;

  // Real-time clock ticks
  late Timer _clockTimer;
  DateTime _now = DateTime.now();

  @override
  void initState() {
    super.initState();

    _pulseController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 1400),
    )..repeat(reverse: true);
    _pulseAnimation = CurvedAnimation(
      parent: _pulseController,
      curve: Curves.easeInOut,
    );

    _autoHideController = AnimationController(
      vsync: this,
      duration: Duration(
        milliseconds: widget.template.animation.animationDurationMs > 0
            ? widget.template.animation.animationDurationMs
            : 220,
      ),
      value: 1.0, // fully visible initially
    );

    _clockTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) {
        setState(() => _now = DateTime.now());
      }
    });
  }

  @override
  void didUpdateWidget(covariant DesktopStudioPreview oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (widget.template.animation.enableAutoHide !=
        oldWidget.template.animation.enableAutoHide) {
      if (!widget.template.animation.enableAutoHide) {
        _autoHideTimer?.cancel();
        _autoHideController.value = 1.0;
      }
    }
  }

  @override
  void dispose() {
    _pulseController.dispose();
    _autoHideController.dispose();
    _autoHideTimer?.cancel();
    _clockTimer.cancel();
    for (final ctrl in _bounceControllers.values) {
      ctrl.dispose();
    }
    _bounceControllers.clear();
    super.dispose();
  }

  void _triggerBounce(String elementId) {
    if (!widget.template.animation.enableIconBounce ||
        widget.template.animation.reducedMotion) {
      return;
    }

    var ctrl = _bounceControllers[elementId];
    if (ctrl == null) {
      ctrl = AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 320),
      );
      _bounceControllers[elementId] = ctrl;
    }
    ctrl.forward(from: 0.0);
  }

  void _onDockPointerEnter(PointerEnterEvent event) {
    _isMouseInsideDock = true;
    _autoHideTimer?.cancel();
    if (_autoHideController.value < 1.0) {
      _autoHideController.forward();
    }
  }

  void _onDockPointerHover(PointerHoverEvent event) {
    setState(() {
      _hoverGlobalPosition = event.position;
    });
  }

  void _onDockPointerExit(PointerExitEvent event) {
    _isMouseInsideDock = false;
    setState(() {
      _hoverGlobalPosition = null;
    });

    if (widget.template.animation.enableAutoHide && widget.isLivePreviewMode) {
      _autoHideTimer?.cancel();
      _autoHideTimer = Timer(
        Duration(milliseconds: widget.template.animation.autoHideDelayMs),
        () {
          if (mounted && !_isMouseInsideDock) {
            _autoHideController.reverse();
          }
        },
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      decoration: BoxDecoration(
        color: const Color(0xFF0B0E17),
        borderRadius: BorderRadius.circular(16),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.08),
          width: 1.0,
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.6),
            blurRadius: 30,
            offset: const Offset(0, 10),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: LayoutBuilder(
          builder: (context, constraints) {
            const previewRatio = 16.0 / 9.0;
            const extraPadding = 18.0;
            final maxWidth = constraints.maxWidth;
            final maxHeight = constraints.maxHeight;

            final safeWidth = math.max(0.0, maxWidth - extraPadding * 2);
            final safeHeight = math.max(0.0, maxHeight - extraPadding * 2);

            final fitSize = safeWidth <= 0 || safeHeight <= 0
                ? Size(maxWidth, maxHeight)
                : (() {
                    if ((safeWidth / safeHeight) > previewRatio) {
                      final height = safeHeight;
                      final width = height * previewRatio;
                      return Size(width, height);
                    }
                    final width = safeWidth;
                    final height = width / previewRatio;
                    return Size(width, height);
                  })();

            return SizedBox(
              width: maxWidth,
              height: maxHeight,
              child: Center(
                child: SizedBox(
                  width: fitSize.width,
                  height: fitSize.height,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      // 1. Simulated Virtual Desktop Wallpaper
                      _buildSimulatedDesktopWallpaper(),

                      // 2. Simulated Desktop Window & Content
                      _buildSimulatedDesktopWindow(
                        BoxConstraints(
                          maxWidth: fitSize.width,
                          maxHeight: fitSize.height,
                        ),
                      ),

                      // 3. Edit Mode Visual Overlay Guides
                      if (!widget.isLivePreviewMode)
                        _buildEditModeGridOverlay(
                          BoxConstraints(
                            maxWidth: fitSize.width,
                            maxHeight: fitSize.height,
                          ),
                        ),

                      // 4. Live Dock Anchor & Dock Animation Engine
                      _buildDockAnchor(
                        BoxConstraints(
                          maxWidth: fitSize.width,
                          maxHeight: fitSize.height,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            );
          },
        ),
      ),
    );
  }

  Widget _buildSimulatedDesktopWallpaper() {
    return Container(
      decoration: const BoxDecoration(
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [Color(0xFF0F172A), Color(0xFF1E1B4B), Color(0xFF0A0F1D)],
        ),
      ),
      child: Stack(
        children: [
          // Ambient wallpaper glow
          Positioned(
            top: -60,
            right: -60,
            child: Container(
              width: 320,
              height: 320,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF38BDF8).withValues(alpha: 0.15),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          Positioned(
            bottom: -80,
            left: -40,
            child: Container(
              width: 360,
              height: 360,
              decoration: BoxDecoration(
                shape: BoxShape.circle,
                gradient: RadialGradient(
                  colors: [
                    const Color(0xFF818CF8).withValues(alpha: 0.12),
                    Colors.transparent,
                  ],
                ),
              ),
            ),
          ),
          // Subtle desktop grid lines
          CustomPaint(
            size: Size.infinite,
            painter: _DesktopBackgroundGridPainter(),
          ),
        ],
      ),
    );
  }

  Widget _buildSimulatedDesktopWindow(BoxConstraints constraints) {
    final winWidth = constraints.maxWidth * 0.54;
    final winHeight = constraints.maxHeight * 0.48;

    return Center(
      child: Container(
        width: winWidth,
        height: winHeight,
        decoration: BoxDecoration(
          color: const Color(0xFF131926).withValues(alpha: 0.85),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(
            color: Colors.white.withValues(alpha: 0.12),
            width: 1.0,
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.45),
              blurRadius: 28,
              offset: const Offset(0, 14),
            ),
          ],
        ),
        child: Column(
          children: [
            // Window titlebar
            Container(
              height: 28,
              padding: const EdgeInsets.symmetric(horizontal: 10),
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.04),
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(9),
                ),
                border: Border(
                  bottom: BorderSide(
                    color: Colors.white.withValues(alpha: 0.06),
                  ),
                ),
              ),
              child: Row(
                children: [
                  Row(
                    children: [
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Color(0xFFEF4444),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Color(0xFFF59E0B),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 5),
                      Container(
                        width: 9,
                        height: 9,
                        decoration: const BoxDecoration(
                          color: Color(0xFF10B981),
                          shape: BoxShape.circle,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(width: 12),
                  Text(
                    'WallSync Workspace Virtual Display',
                    style: TextStyle(
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                      color: Colors.white.withValues(alpha: 0.6),
                      letterSpacing: 0.4,
                    ),
                  ),
                  const Spacer(),
                  Icon(
                    Icons.crop_square_rounded,
                    size: 11,
                    color: Colors.white.withValues(alpha: 0.4),
                  ),
                ],
              ),
            ),
            // Mock window body
            Expanded(
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(
                      Icons.desktop_windows_rounded,
                      size: 32,
                      color: const Color(0xFF38BDF8).withValues(alpha: 0.35),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      widget.template.name,
                      style: const TextStyle(
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        color: Colors.white70,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      widget.isLivePreviewMode
                          ? 'Live Preview Mode (Hover & Click Active)'
                          : 'Edit Mode (Select items to inspect & customize)',
                      style: TextStyle(
                        fontSize: 10,
                        color: Colors.white.withValues(alpha: 0.4),
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

  Widget _buildEditModeGridOverlay(BoxConstraints constraints) {
    return IgnorePointer(
      child: Container(
        decoration: BoxDecoration(
          border: Border.all(
            color: const Color(0xFF38BDF8).withValues(alpha: 0.25),
            width: 1.5,
          ),
        ),
        child: Align(
          alignment: Alignment.topRight,
          child: Container(
            margin: const EdgeInsets.all(12),
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF38BDF8).withValues(alpha: 0.15),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(
                color: const Color(0xFF38BDF8).withValues(alpha: 0.4),
              ),
            ),
            child: const Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(
                  Icons.edit_note_rounded,
                  size: 13,
                  color: Color(0xFF38BDF8),
                ),
                SizedBox(width: 5),
                Text(
                  'EDIT MODE',
                  style: TextStyle(
                    fontSize: 10,
                    fontWeight: FontWeight.w800,
                    color: Color(0xFF38BDF8),
                    letterSpacing: 0.8,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildDockAnchor(BoxConstraints constraints) {
    final layout = widget.template.layout;

    Alignment alignment;
    switch (layout.position) {
      case DockPosition.top:
        switch (layout.alignment) {
          case DockAlignment.start:
            alignment = Alignment.topLeft;
            break;
          case DockAlignment.end:
            alignment = Alignment.topRight;
            break;
          case DockAlignment.center:
            alignment = Alignment.topCenter;
            break;
        }
        break;
      case DockPosition.left:
        switch (layout.alignment) {
          case DockAlignment.start:
            alignment = Alignment.topLeft;
            break;
          case DockAlignment.end:
            alignment = Alignment.bottomLeft;
            break;
          case DockAlignment.center:
            alignment = Alignment.centerLeft;
            break;
        }
        break;
      case DockPosition.right:
        switch (layout.alignment) {
          case DockAlignment.start:
            alignment = Alignment.topRight;
            break;
          case DockAlignment.end:
            alignment = Alignment.bottomRight;
            break;
          case DockAlignment.center:
            alignment = Alignment.centerRight;
            break;
        }
        break;
      case DockPosition.bottom:
        switch (layout.alignment) {
          case DockAlignment.start:
            alignment = Alignment.bottomLeft;
            break;
          case DockAlignment.end:
            alignment = Alignment.bottomRight;
            break;
          case DockAlignment.center:
            alignment = Alignment.bottomCenter;
            break;
        }
        break;
    }

    final edgeOffset = layout.edgeOffset;
    EdgeInsets edgeMargin;
    switch (layout.position) {
      case DockPosition.top:
        edgeMargin = EdgeInsets.only(top: edgeOffset);
        break;
      case DockPosition.bottom:
        edgeMargin = EdgeInsets.only(bottom: edgeOffset);
        break;
      case DockPosition.left:
        edgeMargin = EdgeInsets.only(left: edgeOffset);
        break;
      case DockPosition.right:
        edgeMargin = EdgeInsets.only(right: edgeOffset);
        break;
    }

    return Align(
      alignment: alignment,
      child: Padding(
        padding: edgeMargin,
        child: AnimatedBuilder(
          animation: _autoHideController,
          builder: (context, child) {
            double translateOffset =
                (1.0 - _autoHideController.value) *
                (layout.thickness + edgeOffset + 20);

            Offset slideOffset;
            switch (layout.position) {
              case DockPosition.bottom:
                slideOffset = Offset(0, translateOffset);
                break;
              case DockPosition.top:
                slideOffset = Offset(0, -translateOffset);
                break;
              case DockPosition.left:
                slideOffset = Offset(-translateOffset, 0);
                break;
              case DockPosition.right:
                slideOffset = Offset(translateOffset, 0);
                break;
            }

            return Transform.translate(
              offset: slideOffset,
              child: Opacity(
                opacity: _autoHideController.value.clamp(0.0, 1.0),
                child: child,
              ),
            );
          },
          child: MouseRegion(
            onEnter: _onDockPointerEnter,
            onHover: _onDockPointerHover,
            onExit: _onDockPointerExit,
            child: _buildDockContainer(constraints),
          ),
        ),
      ),
    );
  }

  Widget _buildDockContainer(BoxConstraints constraints) {
    final layout = widget.template.layout;
    final appearance = widget.template.appearance;

    final isHorizontal =
        layout.position == DockPosition.bottom ||
        layout.position == DockPosition.top;

    final safeWidth = constraints.maxWidth > 0 ? constraints.maxWidth : 1.0;
    final safeHeight = constraints.maxHeight > 0 ? constraints.maxHeight : 1.0;

    final containerHeight = isHorizontal
        ? layout.thickness
        : (layout.length ?? safeHeight * 0.7).clamp(40.0, safeHeight);
    final containerWidth = isHorizontal
        ? (layout.autoSize
              ? null
              : (layout.length ?? safeWidth * 0.95).clamp(40.0, safeWidth))
        : layout.thickness.clamp(40.0, safeWidth);

    Decoration decoration;
    switch (appearance.style) {
      case DockBackgroundStyle.solid:
        decoration = BoxDecoration(
          color: Color(appearance.backgroundColor),
          borderRadius: BorderRadius.circular(appearance.borderRadius),
          border: Border.all(
            color: Color(appearance.borderColor),
            width: appearance.borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: Color(appearance.shadowColor),
              blurRadius: appearance.shadowBlur,
              spreadRadius: appearance.shadowSpread,
            ),
          ],
        );
        break;
      case DockBackgroundStyle.gradient:
        decoration = BoxDecoration(
          gradient: LinearGradient(
            colors: appearance.gradientColors.map((c) => Color(c)).toList(),
            begin: Alignment.topLeft,
            end: Alignment.bottomRight,
          ),
          borderRadius: BorderRadius.circular(appearance.borderRadius),
          border: Border.all(
            color: Color(appearance.borderColor),
            width: appearance.borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: Color(appearance.shadowColor),
              blurRadius: appearance.shadowBlur,
              spreadRadius: appearance.shadowSpread,
            ),
          ],
        );
        break;
      case DockBackgroundStyle.glass:
        decoration = BoxDecoration(
          color: Color(appearance.backgroundColor).withValues(alpha: 0.70),
          borderRadius: BorderRadius.circular(appearance.borderRadius),
          border: Border.all(
            color: Color(appearance.borderColor),
            width: appearance.borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: Color(appearance.shadowColor),
              blurRadius: appearance.shadowBlur,
              spreadRadius: appearance.shadowSpread,
            ),
          ],
        );
        break;
      case DockBackgroundStyle.mica:
        decoration = BoxDecoration(
          color: Color(appearance.backgroundColor).withValues(alpha: 0.88),
          borderRadius: BorderRadius.circular(appearance.borderRadius),
          border: Border.all(
            color: Color(appearance.borderColor),
            width: appearance.borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: Color(appearance.shadowColor),
              blurRadius: appearance.shadowBlur,
              spreadRadius: appearance.shadowSpread,
            ),
          ],
        );
        break;
      case DockBackgroundStyle.acrylic:
        decoration = BoxDecoration(
          color: Color(appearance.backgroundColor),
          borderRadius: BorderRadius.circular(appearance.borderRadius),
          border: Border.all(
            color: Color(appearance.borderColor),
            width: appearance.borderWidth,
          ),
          boxShadow: [
            BoxShadow(
              color: Color(appearance.shadowColor),
              blurRadius: appearance.shadowBlur,
              spreadRadius: appearance.shadowSpread,
            ),
          ],
        );
    }

    Widget content = Container(
      width: containerWidth,
      height: containerHeight,
      padding: EdgeInsets.symmetric(
        horizontal: layout.paddingHorizontal,
        vertical: layout.paddingVertical,
      ),
      decoration: decoration,
      child: isHorizontal
          ? Row(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: _buildDockItems(isHorizontal: true),
            )
          : Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.center,
              children: _buildDockItems(isHorizontal: false),
            ),
    );

    // Apply acrylic backdrop blur
    if (appearance.style == DockBackgroundStyle.acrylic &&
        appearance.blurIntensity > 0) {
      content = ClipRRect(
        borderRadius: BorderRadius.circular(appearance.borderRadius),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(
            sigmaX: appearance.blurIntensity * 0.4,
            sigmaY: appearance.blurIntensity * 0.4,
          ),
          child: content,
        ),
      );
    }

    return content;
  }

  List<Widget> _buildDockItems({required bool isHorizontal}) {
    final elements = widget.template.elements;
    final items = <Widget>[];

    for (int i = 0; i < elements.length; i++) {
      final elem = elements[i];
      final key = _itemKeys.putIfAbsent(elem.id, () => GlobalKey());

      items.add(
        _buildAnimatedDockItem(
          elem: elem,
          key: key,
          index: i,
          isHorizontal: isHorizontal,
        ),
      );

      if (i < elements.length - 1 && elem.type != DockElementType.spacer) {
        items.add(
          SizedBox(
            width: isHorizontal ? widget.template.layout.itemSpacing : 0,
            height: isHorizontal ? 0 : widget.template.layout.itemSpacing,
          ),
        );
      }
    }

    return items;
  }

  Widget _buildAnimatedDockItem({
    required DockItemElement elem,
    required Key key,
    required int index,
    required bool isHorizontal,
  }) {
    final animConfig = widget.template.animation;
    final isSelected = widget.selectedElementId == elem.id;

    // Calculate fisheye magnification
    double scale = 1.0;
    double lift = 0.0;

    if (widget.isLivePreviewMode &&
        animConfig.enableHoverScale &&
        !animConfig.reducedMotion &&
        _hoverGlobalPosition != null) {
      final itemKey = _itemKeys[elem.id];
      final renderBox =
          itemKey?.currentContext?.findRenderObject() as RenderBox?;
      if (renderBox != null && renderBox.hasSize) {
        final itemCenterGlobal = renderBox.localToGlobal(
          Offset(renderBox.size.width / 2, renderBox.size.height / 2),
        );

        final distance = isHorizontal
            ? (itemCenterGlobal.dx - _hoverGlobalPosition!.dx).abs()
            : (itemCenterGlobal.dy - _hoverGlobalPosition!.dy).abs();

        if (distance < animConfig.hoverDistance) {
          // Smooth parabolic falloff factor [0.0 to 1.0]
          final factor = math.cos(
            (distance / animConfig.hoverDistance) * (math.pi / 2),
          );
          final targetScale =
              1.0 + (animConfig.hoverScaleFactor - 1.0) * factor;
          scale = targetScale;
          lift = animConfig.hoverLift * factor;
        }
      }
    }

    // Bounce animation factor
    final bounceCtrl = _bounceControllers[elem.id];
    final bounceValue = bounceCtrl?.value ?? 0.0;
    final bounceOffset = math.sin(bounceValue * math.pi) * 10.0;

    Offset translation;
    if (isHorizontal) {
      translation = Offset(0, -lift - bounceOffset);
    } else {
      translation = Offset(-lift - bounceOffset, 0);
    }

    Widget itemContent = _renderElementContent(elem);

    // Selected indicator border in edit mode
    if (!widget.isLivePreviewMode) {
      itemContent = Container(
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? const Color(0xFF38BDF8)
                : Colors.white.withValues(alpha: 0.15),
            width: isSelected ? 1.5 : 0.8,
          ),
          color: isSelected
              ? const Color(0xFF38BDF8).withValues(alpha: 0.12)
              : Colors.transparent,
        ),
        padding: const EdgeInsets.all(4),
        child: itemContent,
      );
    }

    return Transform.translate(
      offset: translation,
      child: Transform.scale(
        scale: scale,
        alignment: isHorizontal
            ? Alignment.bottomCenter
            : Alignment.centerRight,
        child: InkWell(
          key: key,
          onTap: () {
            if (widget.isLivePreviewMode) {
              _triggerBounce(elem.id);
            } else {
              widget.onSelectElement?.call(elem.id);
            }
          },
          borderRadius: BorderRadius.circular(8),
          child: itemContent,
        ),
      ),
    );
  }

  Widget _renderElementContent(DockItemElement elem) {
    final appearance = widget.template.appearance;
    final iconSize = appearance.iconSize;
    final activeColor = Color(appearance.activeIndicatorColor);

    switch (elem.type) {
      case DockElementType.appLauncher:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(5),
              decoration: BoxDecoration(
                gradient: LinearGradient(
                  colors: [
                    activeColor.withValues(alpha: 0.3),
                    const Color(0xFF818CF8).withValues(alpha: 0.2),
                  ],
                ),
                shape: BoxShape.circle,
                border: Border.all(
                  color: activeColor.withValues(alpha: 0.5),
                  width: 1.0,
                ),
              ),
              child: Icon(
                Icons.widgets_rounded,
                size: iconSize,
                color: activeColor,
              ),
            ),
          ],
        );

      case DockElementType.pinnedApp:
      case DockElementType.customAction:
        return Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              // ignore: non_const_argument_for_const_parameter
              IconData(elem.iconCodePoint, fontFamily: 'MaterialIcons'),
              size: iconSize,
              color: elem.customColor != null
                  ? Color(elem.customColor!)
                  : Colors.white.withValues(alpha: 0.88),
            ),
            const SizedBox(height: 2),
            // Subtly visible app dot
            Container(
              width: 3.5,
              height: 3.5,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.35),
                shape: BoxShape.circle,
              ),
            ),
          ],
        );

      case DockElementType.runningTasks:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildRunningTaskApp(Icons.code_rounded, activeColor, true),
            const SizedBox(width: 8),
            _buildRunningTaskApp(Icons.terminal_rounded, activeColor, false),
            const SizedBox(width: 8),
            _buildRunningTaskApp(Icons.folder_open_rounded, activeColor, false),
          ],
        );

      case DockElementType.separator:
        return Container(
          width: 1.2,
          height: 22,
          color: Colors.white.withValues(alpha: 0.18),
        );

      case DockElementType.spacer:
        return const SizedBox(width: 24);

      case DockElementType.clock:
        final hours = _now.hour.toString().padLeft(2, '0');
        final minutes = _now.minute.toString().padLeft(2, '0');
        return Text(
          '$hours:$minutes',
          style: TextStyle(
            fontSize: iconSize * 0.65,
            fontWeight: FontWeight.w700,
            color: Colors.white,
            letterSpacing: 0.6,
          ),
        );

      case DockElementType.date:
        final monthNames = [
          'Jan',
          'Feb',
          'Mar',
          'Apr',
          'May',
          'Jun',
          'Jul',
          'Aug',
          'Sep',
          'Oct',
          'Nov',
          'Dec',
        ];
        return Text(
          '${monthNames[_now.month - 1]} ${_now.day}',
          style: TextStyle(
            fontSize: iconSize * 0.55,
            fontWeight: FontWeight.w600,
            color: Colors.white70,
          ),
        );

      case DockElementType.weatherSlot:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.wb_sunny_rounded,
              size: iconSize * 0.85,
              color: const Color(0xFFFBBF24),
            ),
            const SizedBox(width: 4),
            Text(
              '24°C',
              style: TextStyle(
                fontSize: iconSize * 0.55,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        );

      case DockElementType.mediaControls:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.skip_previous_rounded,
              size: iconSize * 0.75,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.play_circle_fill_rounded,
              size: iconSize * 0.95,
              color: activeColor,
            ),
            const SizedBox(width: 4),
            Icon(
              Icons.skip_next_rounded,
              size: iconSize * 0.75,
              color: Colors.white70,
            ),
          ],
        );

      case DockElementType.volumeSlider:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.volume_up_rounded,
              size: iconSize * 0.8,
              color: Colors.white70,
            ),
            const SizedBox(width: 4),
            Container(
              width: 38,
              height: 4,
              decoration: BoxDecoration(
                color: Colors.white.withValues(alpha: 0.15),
                borderRadius: BorderRadius.circular(2),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: 0.7,
                child: Container(
                  decoration: BoxDecoration(
                    color: activeColor,
                    borderRadius: BorderRadius.circular(2),
                  ),
                ),
              ),
            ),
          ],
        );

      case DockElementType.networkStatus:
        return Icon(
          Icons.wifi_rounded,
          size: iconSize * 0.8,
          color: Colors.white70,
        );

      case DockElementType.batteryStatus:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.battery_charging_full_rounded,
              size: iconSize * 0.8,
              color: const Color(0xFF10B981),
            ),
            const SizedBox(width: 3),
            Text(
              '94%',
              style: TextStyle(
                fontSize: iconSize * 0.5,
                fontWeight: FontWeight.w600,
                color: Colors.white70,
              ),
            ),
          ],
        );

      case DockElementType.cpuSparkline:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.memory_rounded,
              size: iconSize * 0.75,
              color: const Color(0xFF38BDF8),
            ),
            const SizedBox(width: 4),
            Text(
              'CPU 18%',
              style: TextStyle(
                fontSize: iconSize * 0.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        );

      case DockElementType.ramSparkline:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.storage_rounded,
              size: iconSize * 0.75,
              color: const Color(0xFFA855F7),
            ),
            const SizedBox(width: 4),
            Text(
              'RAM 42%',
              style: TextStyle(
                fontSize: iconSize * 0.5,
                fontWeight: FontWeight.w700,
                color: Colors.white,
              ),
            ),
          ],
        );

      case DockElementType.systemTray:
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.keyboard_arrow_up_rounded,
              size: iconSize * 0.7,
              color: Colors.white60,
            ),
          ],
        );

      case DockElementType.quickSettings:
        return Icon(
          Icons.tune_rounded,
          size: iconSize * 0.8,
          color: Colors.white70,
        );

      default:
        return Icon(
          Icons.widgets_rounded,
          size: iconSize,
          color: Colors.white70,
        );
    }
  }

  Widget _buildRunningTaskApp(IconData icon, Color activeColor, bool isActive) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          icon,
          size: widget.template.appearance.iconSize,
          color: Colors.white.withValues(alpha: isActive ? 1.0 : 0.8),
        ),
        const SizedBox(height: 2),
        if (isActive && widget.template.animation.enableRunningPulse)
          AnimatedBuilder(
            animation: _pulseAnimation,
            builder: (context, _) {
              return Container(
                width: 4.5,
                height: 4.5,
                decoration: BoxDecoration(
                  color: activeColor.withValues(
                    alpha: 0.5 + (_pulseAnimation.value * 0.5),
                  ),
                  shape: BoxShape.circle,
                  boxShadow: [
                    BoxShadow(
                      color: activeColor.withValues(
                        alpha: 0.3 * _pulseAnimation.value,
                      ),
                      blurRadius: 4 * _pulseAnimation.value,
                      spreadRadius: 1 * _pulseAnimation.value,
                    ),
                  ],
                ),
              );
            },
          )
        else
          Container(
            width: 4,
            height: 4,
            decoration: BoxDecoration(
              color: isActive ? activeColor : Colors.white38,
              shape: BoxShape.circle,
            ),
          ),
      ],
    );
  }
}

/// Grid painter providing a desktop grid aesthetic
class _DesktopBackgroundGridPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = Colors.white.withValues(alpha: 0.02)
      ..strokeWidth = 1.0;

    const step = 40.0;
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
