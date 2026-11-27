import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../widgets/kline_viewport.dart';

/// 分笔（tick）圆点的几何口径：**绘制 / 命中 / 聚焦框三处必须同源**。
///
/// 口径（2026-11-13 用户明确 · 画板聚焦框偏离圆点、圆点被裁的根因）：
/// - 圆点半径：`barW = max(1, slotW*0.65)`，
///   `dotR = max(1.2, min(barW*0.45, slotW*0.35))`；
/// - 价格区间上下各留**一个**圆点半径的余量，保证最上/最下圆点完整不裁；
/// - 留量按「像素 ↔ 价格」换算：`pad = dotR * span / plotH`（像素→价格是
///   除以 plotH，不是乘 —— 乘会把区间撑成几百倍，圆点全挤在中间看不见）。

/// 当前视窗下单根 K 线槽宽（与 [KlineViewport.barSlotWidth] 同口径）。
double tickDotSlotWidth(double canvasWidth, double span) {
  final plotW =
      math.max(1, canvasWidth - KlineViewport.padL - KlineViewport.padR);
  return plotW / math.max(span, 1e-6);
}

/// 分笔圆点半径（与图表绘制、命中判定同口径）。
double tickDotRadius(double slotW) {
  final barW = math.max(1.0, slotW * 0.65);
  return math.max(1.2, math.min(barW * 0.45, slotW * 0.35));
}

/// 价格区间上下各留一个圆点半径的余量（像素 → 价格换算）。
///
/// [raw] 是按可见 K 极值给出的原始区间（含纵轴缩放/位移），
/// [dotR] 是圆点半径（像素），[plotH] 是绘图区高度（像素）。
PriceRange tickDotPaddedRange({
  required PriceRange raw,
  required double dotR,
  required double plotH,
}) {
  if (dotR <= 0 || plotH <= 0) return raw;
  final span = raw.span;
  // 1 像素 = span / plotH 价格；要把圆点整体挪进绘图区，需留 dotR 像素。
  final pad = dotR * span / plotH;
  if (pad <= 0) return raw;
  return PriceRange(raw.min - pad, raw.max + pad);
}

/// 画板 K0 窗口的圆点几何：一次算出半径、留白后的价格区间与绘图高度。
class TickDotGeometry {
  const TickDotGeometry({
    required this.viewport,
    required this.slotW,
    required this.dotR,
    required this.plotTop,
    required this.plotH,
    required this.width,
    required this.range,
  });

  /// 与 [KlineChart] 同一份视口（由联动控制器按层号提供）。
  final KlineViewport viewport;
  final double slotW;
  final double dotR;

  /// 主图绘图区顶边（桌面 = [KlineViewport.padT]）。
  final double plotTop;
  final double plotH;
  final double width;

  /// 已含圆点余量的价格区间（聚焦框 / 拖动改价都读它，与绘制同源）。
  final PriceRange range;

  /// 某根分笔圆点的屏幕中心。
  Offset centerOf(int barIdx, double close) => Offset(
        viewport.barCenterX(barIdx, width),
        range.yOf(close, plotTop, plotH),
      );
}
