import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 分型确认上升/下降色（红涨绿跌，与历史确认柱一致）
abstract final class FractalConfirmColors {
  static const up = Color(0xFFE53935);
  static const down = Color(0xFF26A69A);

  static Color of(int value) => value > 0 ? up : down;
}

/// 同类不同 Kn 用不同标记，叠画时易区分。
enum ConfirmMarkerShape { bar, diamond, triangle, circle, cross }

ConfirmMarkerShape confirmMarkerShapeForKn(int labelKn) {
  switch (labelKn % 5) {
    case 0:
      return ConfirmMarkerShape.bar;
    case 1:
      return ConfirmMarkerShape.diamond;
    case 2:
      return ConfirmMarkerShape.triangle;
    case 3:
      return ConfirmMarkerShape.circle;
    default:
      return ConfirmMarkerShape.cross;
  }
}

/// 极点距折线：按 Kn 换线型/粗细，叠画可辨。
({List<double> dash, double stroke}) peakDistLineStyleForKn(int labelKn) {
  switch (labelKn % 4) {
    case 0:
      return (dash: const <double>[], stroke: 1.4);
    case 1:
      return (dash: const <double>[6, 4], stroke: 1.5);
    case 2:
      return (dash: const <double>[2, 3], stroke: 1.6);
    default:
      return (dash: const <double>[10, 3, 2, 3], stroke: 1.7);
  }
}

/// 在副图画一个 ±1 确认标记（颜色按方向，形状按 Kn）。
void paintFractalConfirmMarker(
  Canvas canvas, {
  required double cx,
  required double y0,
  required double yp,
  required int value,
  required ConfirmMarkerShape shape,
  required double barW,
}) {
  if (value == 0) return;
  final color = FractalConfirmColors.of(value);
  final paint = Paint()
    ..color = color
    ..style = PaintingStyle.fill
    ..strokeWidth = 1.6
    ..strokeCap = StrokeCap.round;

  final tip = Offset(cx, yp);
  final mid = Offset(cx, (y0 + yp) / 2);
  final half = math.max(2.5, barW * 0.55);

  switch (shape) {
    case ConfirmMarkerShape.bar:
      final top = math.min(yp, y0);
      final height = math.max(1.0, (yp - y0).abs());
      final bw = math.max(2.0, math.min(barW, 8.0));
      canvas.drawRect(
        Rect.fromLTWH(cx - bw / 2, top, bw, height),
        paint,
      );
    case ConfirmMarkerShape.diamond:
      final path = Path()
        ..moveTo(mid.dx, mid.dy - half)
        ..lineTo(mid.dx + half, mid.dy)
        ..lineTo(mid.dx, mid.dy + half)
        ..lineTo(mid.dx - half, mid.dy)
        ..close();
      canvas.drawPath(path, paint);
    case ConfirmMarkerShape.triangle:
      final path = Path();
      if (value > 0) {
        // 向上三角（顶在 tip）
        path
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(tip.dx - half, y0)
          ..lineTo(tip.dx + half, y0)
          ..close();
      } else {
        path
          ..moveTo(tip.dx, tip.dy)
          ..lineTo(tip.dx - half, y0)
          ..lineTo(tip.dx + half, y0)
          ..close();
      }
      canvas.drawPath(path, paint);
    case ConfirmMarkerShape.circle:
      canvas.drawCircle(mid, half * 0.85, paint);
    case ConfirmMarkerShape.cross:
      paint.style = PaintingStyle.stroke;
      canvas.drawLine(
        Offset(mid.dx - half, mid.dy - half),
        Offset(mid.dx + half, mid.dy + half),
        paint,
      );
      canvas.drawLine(
        Offset(mid.dx + half, mid.dy - half),
        Offset(mid.dx - half, mid.dy + half),
        paint,
      );
  }
}
