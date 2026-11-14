/// K 线实体的几何口径：**绘制 / 命中 / 聚焦框三处必须同源**。
///
/// 口径（2026-11-15 用户明确 · K线画板抓不到实体、拖不准的根因）：
/// - 实体宽：`barW = max(1, slotW * 0.65)`（与 `_drawCandles` 一致）；
/// - 实体矩形：`x = cx - barW/2`，`top = min(yO,yC)`，
///   `bodyH = max(1, |yO-yC|)`；
/// - 影线：只画实体之外的两段（见 `candle_wick.dart` 的语义）；
/// - 像素↔价格：用 `PriceRange.yOf` / `priceFromY` 互为逆运算。
///
/// 画板（K线画板）以前没有这层几何，只能靠「分笔圆点命中」那条只认识
/// `close` 价格的旧通道，结果就是「按住实体没反应、反而多出一根 K」。
library;

import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/kline_bar.dart';
import '../widgets/candle_wick.dart';
import '../widgets/kline_viewport.dart';

/// K 线可被抓取的部位。
enum CandlePart {
  /// 实体中段偏上：抓它改开盘价（阳线上半是开盘侧的判据见
  /// [candleBodyPart]）。
  bodyOpen,
  /// 实体中段偏下：抓它改收盘价。
  bodyClose,
  /// 上影线端点：抓它改最高价。
  high,
  /// 下影线端点：抓它改最低价。
  low,
}

/// 单根 K 线的实体/影线屏幕几何。
class CandleGeometry {
  const CandleGeometry({
    required this.barIdx,
    required this.cx,
    required this.barW,
    required this.yHigh,
    required this.yLow,
    required this.yOpen,
    required this.yClose,
    required this.bodyTop,
    required this.bodyBottom,
  });

  final int barIdx;
  final double cx; // 实体中心 X
  final double barW; // 实体宽
  final double yHigh; // 最高价像素 y
  final double yLow; // 最低价像素 y
  final double yOpen; // 开盘价像素 y
  final double yClose; // 收盘价像素 y
  final double bodyTop; // 实体上沿（像素，小）
  final double bodyBottom; // 实体下沿（像素，大）

  /// 实体矩形（含边框）。
  Rect get bodyRect => Rect.fromLTWH(
        cx - barW / 2,
        bodyTop,
        barW,
        math.max(1.0, bodyBottom - bodyTop),
      );

  /// 上影线段（实体上沿之上）。
  Rect get upperWickRect => Rect.fromLTRB(
        cx - candleWickWidth(barW) / 2,
        yHigh,
        cx + candleWickWidth(barW) / 2,
        bodyTop,
      );

  /// 下影线段（实体下沿之下）。
  Rect get lowerWickRect => Rect.fromLTRB(
        cx - candleWickWidth(barW) / 2,
        bodyBottom,
        cx + candleWickWidth(barW) / 2,
        yLow,
      );
}

/// 实体宽（与 `_drawCandles` 的 `_candleBodyW` 同口径）。
double candleBodyWidth(double slotW) => math.max(1.0, slotW * 0.65);

/// 由 K 线 + 视口算出该根 K 的屏幕几何。
CandleGeometry candleGeometryOf({
  required KlineBar bar,
  required int barIdx,
  required KlineViewport viewport,
  required double canvasWidth,
  required PriceRange range,
  required double plotTop,
  required double plotH,
}) {
  final slotW = viewport.barSlotWidth(canvasWidth);
  final barW = candleBodyWidth(slotW);
  final cx = viewport.barCenterX(barIdx, canvasWidth);
  final yH = range.yOf(bar.high, plotTop, plotH);
  final yL = range.yOf(bar.low, plotTop, plotH);
  final yO = range.yOf(bar.open, plotTop, plotH);
  final yC = range.yOf(bar.close, plotTop, plotH);
  final top = math.min(yO, yC);
  final bottom = math.max(yO, yC);
  return CandleGeometry(
    barIdx: barIdx,
    cx: cx,
    barW: barW,
    yHigh: yH,
    yLow: yL,
    yOpen: yO,
    yClose: yC,
    bodyTop: top,
    bodyBottom: bottom,
  );
}

/// 命中实体时判定抓到的是开盘侧还是收盘侧。
///
/// 阳线（收 ≥ 开）：上半截靠收盘价，下半截靠开盘价；
/// 阴线（收 < 开）：上半截靠开盘价，下半截靠收盘价。
CandlePart candleBodyPart({
  required KlineBar bar,
  required CandleGeometry geo,
  required double localDy,
}) {
  final up = bar.close >= bar.open;
  final upperHalf = localDy <= geo.bodyRect.center.dy;
  if (up) {
    return upperHalf ? CandlePart.bodyClose : CandlePart.bodyOpen;
  }
  return upperHalf ? CandlePart.bodyOpen : CandlePart.bodyClose;
}

/// K线画板用的 K0 视口几何（与 KlineChart 绘制同源）。
class KlineDrawGeometry {
  const KlineDrawGeometry({
    required this.viewport,
    required this.range,
    required this.plotTop,
    required this.plotH,
    required this.canvasWidth,
  });

  final KlineViewport viewport;
  final PriceRange range; // 可见 K 的价格区间（图表实际绘制用的那个）
  final double plotTop;
  final double plotH;
  final double canvasWidth;

  /// 像素 y → 价格（与绘制互逆）。
  double priceAt(double py) => range.priceFromY(py, plotTop, plotH);

  /// 价格 → 像素 y。
  double yOf(double price) => range.yOf(price, plotTop, plotH);

  /// 某根 K 的实体几何。
  CandleGeometry geometryOf(KlineBar bar, int barIdx) => candleGeometryOf(
        bar: bar,
        barIdx: barIdx,
        viewport: viewport,
        canvasWidth: canvasWidth,
        range: range,
        plotTop: plotTop,
        plotH: plotH,
      );
}
