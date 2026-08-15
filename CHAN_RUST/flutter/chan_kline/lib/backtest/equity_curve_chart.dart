import 'dart:math' as math;

import 'package:flutter/material.dart';

import 'backtest_metrics.dart';
import 'equity_curve.dart';

/// 净值曲线：只画 equityCurve，区间用 metrics 里已算好的回撤起止。
class EquityCurveChart extends StatelessWidget {
  final List<EquityPoint> curve;
  final BacktestMetrics metrics;
  final int? focusX;
  final ValueChanged<int>? onTapX;

  const EquityCurveChart({
    super.key,
    required this.curve,
    required this.metrics,
    this.focusX,
    this.onTapX,
  });

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onTapDown: onTapX == null || curve.isEmpty
          ? null
          : (d) {
              final box = context.findRenderObject() as RenderBox?;
              if (box == null) return;
              final x = _xAt(d.localPosition.dx, box.size.width);
              if (x != null) onTapX!(x);
            },
      child: CustomPaint(
        painter: _EquityPainter(
          curve: curve,
          metrics: metrics,
          focusX: focusX,
        ),
        child: const SizedBox.expand(),
      ),
    );
  }

  int? _xAt(double dx, double w) {
    if (curve.isEmpty || w <= 1) return null;
    final x0 = curve.first.x.toDouble();
    final x1 = curve.last.x.toDouble();
    final span = math.max(1.0, x1 - x0);
    final t = (dx / w).clamp(0.0, 1.0);
    return (x0 + t * span).round();
  }
}

class _EquityPainter extends CustomPainter {
  final List<EquityPoint> curve;
  final BacktestMetrics metrics;
  final int? focusX;

  _EquityPainter({
    required this.curve,
    required this.metrics,
    required this.focusX,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (curve.isEmpty || size.width < 4 || size.height < 4) return;
    var minE = curve.first.equity;
    var maxE = minE;
    for (final p in curve) {
      if (p.equity < minE) minE = p.equity;
      if (p.equity > maxE) maxE = p.equity;
    }
    if ((maxE - minE).abs() < 1e-9) {
      minE -= 1;
      maxE += 1;
    }
    final pad = 6.0;
    final x0 = curve.first.x.toDouble();
    final x1 = curve.last.x.toDouble();
    final span = math.max(1.0, x1 - x0);
    Offset pt(EquityPoint p) {
      final nx = pad + (p.x - x0) / span * (size.width - pad * 2);
      final ny = pad +
          (maxE - p.equity) / (maxE - minE) * (size.height - pad * 2);
      return Offset(nx, ny);
    }

    double xToPx(int x) => pad + (x - x0) / span * (size.width - pad * 2);

    final start = metrics.maxDrawdownStartX;
    final end = metrics.maxDrawdownEndX;
    if (start != null && end != null && metrics.maxDrawdown > 0) {
      final left = xToPx(start);
      final right = xToPx(end);
      canvas.drawRect(
        Rect.fromLTRB(left, pad, math.max(left + 1, right), size.height - pad),
        Paint()..color = const Color(0x55E53935),
      );
    }
    if (metrics.recoveryX != null) {
      final rx = xToPx(metrics.recoveryX!);
      canvas.drawLine(
        Offset(rx, pad),
        Offset(rx, size.height - pad),
        Paint()
          ..color = const Color(0xAA66BB6A)
          ..strokeWidth = 1,
      );
    }

    final path = Path()..moveTo(pt(curve.first).dx, pt(curve.first).dy);
    for (var i = 1; i < curve.length; i++) {
      final o = pt(curve[i]);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFF4FC3F7)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.4,
    );

    if (focusX != null) {
      final fx = xToPx(focusX!);
      canvas.drawLine(
        Offset(fx, pad),
        Offset(fx, size.height - pad),
        Paint()
          ..color = const Color(0xFFFFD54F)
          ..strokeWidth = 1.2,
      );
    }
  }

  @override
  bool shouldRepaint(covariant _EquityPainter old) =>
      old.curve != curve || old.metrics != metrics || old.focusX != focusX;
}

/// 回撤曲线：由同一份净值逐点算峰-当前，不另算交易盈亏。
class DrawdownCurveChart extends StatelessWidget {
  final List<EquityPoint> curve;
  final BacktestMetrics metrics;

  const DrawdownCurveChart({
    super.key,
    required this.curve,
    required this.metrics,
  });

  @override
  Widget build(BuildContext context) {
    return CustomPaint(
      painter: _DdPainter(curve: curve, metrics: metrics),
      child: const SizedBox.expand(),
    );
  }
}

class _DdPainter extends CustomPainter {
  final List<EquityPoint> curve;
  final BacktestMetrics metrics;

  _DdPainter({required this.curve, required this.metrics});

  @override
  void paint(Canvas canvas, Size size) {
    if (curve.isEmpty || size.width < 4) return;
    var peak = curve.first.equity;
    final dds = <double>[];
    var maxDd = 0.0;
    for (final p in curve) {
      if (p.equity > peak) peak = p.equity;
      final dd = peak - p.equity;
      dds.add(dd);
      if (dd > maxDd) maxDd = dd;
    }
    if (maxDd < 1e-12) maxDd = 1;
    final pad = 6.0;
    final x0 = curve.first.x.toDouble();
    final x1 = curve.last.x.toDouble();
    final span = math.max(1.0, x1 - x0);
    Offset pt(int i) {
      final nx = pad + (curve[i].x - x0) / span * (size.width - pad * 2);
      final ny = pad + (1 - dds[i] / maxDd) * (size.height - pad * 2);
      return Offset(nx, ny);
    }

    final path = Path()..moveTo(pt(0).dx, pt(0).dy);
    for (var i = 1; i < curve.length; i++) {
      final o = pt(i);
      path.lineTo(o.dx, o.dy);
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = const Color(0xFFFF8A65)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.3,
    );
  }

  @override
  bool shouldRepaint(covariant _DdPainter old) => old.curve != curve;
}
