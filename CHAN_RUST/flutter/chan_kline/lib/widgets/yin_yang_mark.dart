import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 在画布上画完整太极（阴阳鱼+对眼+外圈），不裁切图案本身。
void drawYinYangSymbol(
  Canvas canvas,
  Offset center,
  double radius, {
  Color yang = const Color(0xFFF4F1EA),
  Color yin = const Color(0xFF141414),
  Color ring = const Color(0xFFC9A227),
}) {
  if (radius <= 0) return;
  final bodyR = radius;
  canvas.save();
  canvas.translate(center.dx, center.dy);
  canvas.clipPath(
    Path()..addOval(Rect.fromCircle(center: Offset.zero, radius: bodyR)),
  );
  final yangPaint = Paint()
    ..color = yang
    ..isAntiAlias = true;
  final yinPaint = Paint()
    ..color = yin
    ..isAntiAlias = true;
  canvas.drawRect(Rect.fromLTWH(-bodyR, -bodyR, bodyR, bodyR * 2), yangPaint);
  canvas.drawRect(Rect.fromLTWH(0, -bodyR, bodyR, bodyR * 2), yinPaint);
  final half = bodyR / 2;
  canvas.drawCircle(Offset(0, -half), half, yinPaint);
  canvas.drawCircle(Offset(0, half), half, yangPaint);
  final eye = math.max(bodyR / 6, bodyR * 0.04);
  canvas.drawCircle(Offset(0, -half), eye, yangPaint);
  canvas.drawCircle(Offset(0, half), eye, yinPaint);
  canvas.restore();
  canvas.drawCircle(
    center,
    bodyR,
    Paint()
      ..color = ring
      ..style = PaintingStyle.stroke
      ..strokeWidth = math.max(bodyR * 0.045, bodyR * 0.02)
      ..isAntiAlias = true,
  );
}

/// 铺满父级：正圆阴阳鱼，直径=父级高度×[heightFactor]（初始=屏高）。
class YinYangFullscreenCover extends StatelessWidget {
  const YinYangFullscreenCover({
    super.key,
    this.heightFactor = 1.0,
    this.opacity = 1.0,
    this.dimBackground = true,
  });

  /// 1=直径等于当前窗口高度；走完加载用 0.25（缩小 4 倍）。
  final double heightFactor;
  final double opacity;
  final bool dimBackground;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: dimBackground ? const Color(0xF0121212) : const Color(0x00000000),
      child: SizedBox.expand(
        child: YinYangFillSpin(heightFactor: heightFactor, opacity: opacity),
      ),
    );
  }
}

/// 正圆旋转；直径跟窗口高度走，不再按宽高分别拉伸成椭圆。
class YinYangFillSpin extends StatefulWidget {
  const YinYangFillSpin({
    super.key,
    this.heightFactor = 1.0,
    this.opacity = 1.0,
  });

  final double heightFactor;
  final double opacity;

  @override
  State<YinYangFillSpin> createState() => _YinYangFillSpinState();
}

class _YinYangFillSpinState extends State<YinYangFillSpin>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _spin,
      builder: (context, _) => Opacity(
        opacity: widget.opacity.clamp(0.0, 1.0),
        child: CustomPaint(
          painter: _YinYangFillPainter(
            turns: _spin.value,
            heightFactor: widget.heightFactor,
          ),
          child: const SizedBox.expand(),
        ),
      ),
    );
  }
}

class _YinYangFillPainter extends CustomPainter {
  _YinYangFillPainter({required this.turns, required this.heightFactor});

  final double turns;
  final double heightFactor;

  @override
  void paint(Canvas canvas, Size size) {
    final w = size.width;
    final h = size.height;
    if (w < 2 || h < 2) return;
    final diameter = h * heightFactor;
    final r = diameter / 2;
    if (r < 1) return;
    canvas.save();
    canvas.translate(w / 2, h / 2);
    canvas.rotate(turns * math.pi * 2);
    drawYinYangSymbol(canvas, Offset.zero, r);
    canvas.restore();
  }

  @override
  bool shouldRepaint(covariant _YinYangFillPainter old) =>
      old.turns != turns || old.heightFactor != heightFactor;
}

/// 易经太极（阴阳鱼）：完整圆形，不裁切。分笔加载时替代原来的小圆点转圈。
class YinYangLoadingMark extends StatefulWidget {
  const YinYangLoadingMark({super.key, this.size = 72});

  final double size;

  @override
  State<YinYangLoadingMark> createState() => _YinYangLoadingMarkState();
}

class _YinYangLoadingMarkState extends State<YinYangLoadingMark>
    with SingleTickerProviderStateMixin {
  late final AnimationController _spin;

  @override
  void initState() {
    super.initState();
    _spin = AnimationController(
      vsync: this,
      duration: const Duration(seconds: 8),
    )..repeat();
  }

  @override
  void dispose() {
    _spin.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final s = widget.size;
    return SizedBox(
      width: s,
      height: s,
      child: RotationTransition(
        turns: _spin,
        child: CustomPaint(
          size: Size.square(s),
          painter: const YinYangPainter(),
        ),
      ),
    );
  }
}

/// 标准太极图：白阳 / 黑阴 + 对眼，外圈描边保证深色底上也能看全。
class YinYangPainter extends CustomPainter {
  const YinYangPainter({
    this.yang = const Color(0xFFF4F1EA),
    this.yin = const Color(0xFF141414),
    this.ring = const Color(0xFFC9A227),
  });

  final Color yang;
  final Color yin;
  final Color ring;

  @override
  void paint(Canvas canvas, Size size) {
    final r = math.min(size.width, size.height) / 2;
    final c = Offset(size.width / 2, size.height / 2);
    // 留 1px 给描边，图案完整落在画布内、不被裁切
    final bodyR = r - 1.0;
    if (bodyR <= 1) return;
    drawYinYangSymbol(canvas, c, bodyR, yang: yang, yin: yin, ring: ring);
  }

  @override
  bool shouldRepaint(covariant YinYangPainter old) =>
      old.yang != yang || old.yin != yin || old.ring != ring;
}
