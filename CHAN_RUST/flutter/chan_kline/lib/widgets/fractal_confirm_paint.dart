import 'dart:math' as math;

import 'package:flutter/material.dart';

/// 副图分型确认/判断配色（自定义·全层同构）。
/// - 底分型（BOTTOM，value>0）= 红
/// - 顶分型（TOP，value<0）= 蓝
/// 踩坑：旧口径「红涨绿跌」已废；截断同色相 + 橙描边区分。
abstract final class FractalConfirmColors {
  static const bottom = Color(0xFFE53935); // 底分型：红
  static const top = Color(0xFF1E88E5); // 顶分型：蓝
  /// 浅描边，叠画时从下层标记里“抠”出来
  static const outline = Color(0xCC121212);

  static Color of(int value) => value > 0 ? bottom : top;
}

/// 中枢判断/确认配色（与分型顶蓝底红区分）。
/// 统一口径：对「上个中枢」——相对前一中枢中轴抬高=升红，下移=降绿。
/// （勿用框 first.dir：常与位置升降相反，例 85 确认抬高却 dir=-1）
abstract final class ZsSignalColors {
  static const rise = Color(0xFFE53935); // 上升中枢（抬高）
  static const fall = Color(0xFF16A34A); // 下降中枢（下移）
  static Color of(int value) => value > 0 ? rise : fall;
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

/// 叠画横向扇形错位：rank=在已选层中的序号(0起)，count=叠层数。
double confirmStackOffsetX({
  required int rank,
  required int count,
  required double barW,
}) {
  if (count <= 1) return 0;
  final step = math.max(3.0, math.min(barW * 0.45, 7.0));
  return (rank - (count - 1) / 2.0) * step;
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

/// 截断标记色（自定义·全层同构）。
/// - 向下截断 = 底分型截断（value>0）= 红
/// - 顶分型截断（value<0）= 蓝
/// 另加橙描边，与「分型确认」实心点区分。
abstract final class TruncationMarkerColors {
  static const accent = Color(0xFFFFB74D); // 橙描边：截断专属
  static Color of(int value) => FractalConfirmColors.of(value);
}

/// 在副图画一个截断触发点：方向色填充 + 橙色描边，形状按 Kn。
void paintTruncationMarker(
  Canvas canvas, {
  required double cx,
  required double y0,
  required double yp,
  required int value,
  required ConfirmMarkerShape shape,
  required double barW,
}) {
  if (value == 0) return;
  // 先画确认形态（顶蓝底红），再加一圈橙描边标「截断」
  paintFractalConfirmMarker(
    canvas,
    cx: cx,
    y0: y0,
    yp: yp,
    value: value,
    shape: shape,
    barW: barW,
    withOutline: false,
  );
  final mid = Offset(cx, (y0 + yp) / 2);
  final r = math.max(4.0, barW * 0.7);
  canvas.drawCircle(
    mid,
    r,
    Paint()
      ..color = TruncationMarkerColors.accent
      ..style = PaintingStyle.stroke
      ..strokeWidth = 2.0,
  );
}

/// 在副图画一个 ±1 确认标记（颜色按顶/底，形状按 Kn；可描边防叠盖）。
/// [fillAlpha]：填充透明度（分型判断用半透明）；[hollow]：空心描边（与确认实心区分）。
void paintFractalConfirmMarker(
  Canvas canvas, {
  required double cx,
  required double y0,
  required double yp,
  required int value,
  required ConfirmMarkerShape shape,
  required double barW,
  bool withOutline = true,
  double fillAlpha = 1.0,
  bool hollow = false,
  Color? colorOverride,
}) {
  if (value == 0) return;
  final base = colorOverride ?? FractalConfirmColors.of(value);
  final color = base.withValues(alpha: (fillAlpha.clamp(0.0, 1.0)) * base.a);
  final tip = Offset(cx, yp);
  final mid = Offset(cx, (y0 + yp) / 2);
  final half = math.max(2.5, barW * 0.55);

  void strokeThenFill(Path path) {
    if (withOutline) {
      canvas.drawPath(
        path,
        Paint()
          ..color = FractalConfirmColors.outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.4
          ..strokeJoin = StrokeJoin.round,
      );
    }
    canvas.drawPath(
      path,
      Paint()
        ..color = color
        ..style = hollow ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = hollow ? 1.8 : 0,
    );
  }

  void strokeThenFillRect(Rect rect) {
    if (withOutline) {
      canvas.drawRect(
        rect.inflate(1.0),
        Paint()
          ..color = FractalConfirmColors.outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 2.2,
      );
    }
    canvas.drawRect(
      rect,
      Paint()
        ..color = color
        ..style = hollow ? PaintingStyle.stroke : PaintingStyle.fill
        ..strokeWidth = hollow ? 1.8 : 0,
    );
  }

  switch (shape) {
    case ConfirmMarkerShape.bar:
      final top = math.min(yp, y0);
      final height = math.max(1.0, (yp - y0).abs());
      final bw = math.max(2.0, math.min(barW, 8.0));
      strokeThenFillRect(Rect.fromLTWH(cx - bw / 2, top, bw, height));
    case ConfirmMarkerShape.diamond:
      final path = Path()
        ..moveTo(mid.dx, mid.dy - half)
        ..lineTo(mid.dx + half, mid.dy)
        ..lineTo(mid.dx, mid.dy + half)
        ..lineTo(mid.dx - half, mid.dy)
        ..close();
      strokeThenFill(path);
    case ConfirmMarkerShape.triangle:
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(tip.dx - half, y0)
        ..lineTo(tip.dx + half, y0)
        ..close();
      strokeThenFill(path);
    case ConfirmMarkerShape.circle:
      if (withOutline) {
        canvas.drawCircle(
          mid,
          half * 0.85 + 1.0,
          Paint()
            ..color = FractalConfirmColors.outline
            ..style = PaintingStyle.stroke
            ..strokeWidth = 2.2,
        );
      }
      canvas.drawCircle(
        mid,
        half * 0.85,
        Paint()
          ..color = color
          ..style = hollow ? PaintingStyle.stroke : PaintingStyle.fill
          ..strokeWidth = hollow ? 1.8 : 0,
      );
    case ConfirmMarkerShape.cross:
      final paint = Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = hollow ? 1.5 : 1.8
        ..strokeCap = StrokeCap.round;
      if (withOutline) {
        final outline = Paint()
          ..color = FractalConfirmColors.outline
          ..style = PaintingStyle.stroke
          ..strokeWidth = 3.2
          ..strokeCap = StrokeCap.round;
        canvas.drawLine(
          Offset(mid.dx - half, mid.dy - half),
          Offset(mid.dx + half, mid.dy + half),
          outline,
        );
        canvas.drawLine(
          Offset(mid.dx + half, mid.dy - half),
          Offset(mid.dx - half, mid.dy + half),
          outline,
        );
      }
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
