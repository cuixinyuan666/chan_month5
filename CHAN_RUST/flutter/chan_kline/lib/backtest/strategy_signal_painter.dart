import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/kline_bar.dart';
import '../widgets/kline_viewport.dart';
import 'order_models.dart';
import 'signal_event.dart';
import 'strategy_trade_round.dart';

export 'strategy_trade_round.dart' show strategySideLabel;

/// 策略买卖点颜色：买=红、卖=绿，与缠论 1Ba/1Sa 标签区分。
const Color kStrategyBuyColor = Color(0xFFEF5350);
const Color kStrategySellColor = Color(0xFF00E676);

Color strategySideColor(TradeSide side) =>
    side == TradeSide.buy ? kStrategyBuyColor : kStrategySellColor;

KlineBar? klineBarByIdx(List<KlineBar> bars, int idx) {
  if (idx >= 0 && idx < bars.length && bars[idx].idx == idx) {
    return bars[idx];
  }
  for (final b in bars) {
    if (b.idx == idx) return b;
  }
  return null;
}

class StrategyMarkerHit {
  final SignalEvent signal;
  final Offset center;
  const StrategyMarkerHit(this.signal, this.center);
}

/// 图上画在发现根：有成交才画；被拒/过期不画；无成交列表时仍画发现根（单测）。
int? strategyMarkerPlotX({
  required SignalEvent signal,
  List<Fill> fills = const [],
}) {
  if (fills.isEmpty) return signal.discoveryX;
  for (final f in fills) {
    if (f.signalId == signal.signalId) return signal.discoveryX;
  }
  return null;
}

/// 主图策略点位置：只消费 SignalEvent，不重算穿越。
Offset? strategyMarkerCenter({
  required SignalEvent signal,
  required List<KlineBar> bars,
  required KlineViewport viewport,
  required PriceRange priceRange,
  required double canvasW,
  required double plotTop,
  required double plotH,
  List<Fill> fills = const [],
}) {
  if (signal.side == null) return null;
  final x = strategyMarkerPlotX(signal: signal, fills: fills);
  if (x == null) return null;
  final bar = klineBarByIdx(bars, x);
  if (bar == null) return null;
  if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
    return null;
  }
  final cx = viewport.barCenterX(x, canvasW);
  final isBuy = signal.side == TradeSide.buy;
  final y = isBuy
      ? priceRange.yOf(bar.low, plotTop, plotH) + 10
      : priceRange.yOf(bar.high, plotTop, plotH) - 10;
  return Offset(cx, y);
}

StrategyMarkerHit? hitTestStrategySignal({
  required Offset local,
  required List<SignalEvent> signals,
  required List<KlineBar> bars,
  required KlineViewport viewport,
  required PriceRange priceRange,
  required double canvasW,
  required double plotTop,
  required double plotH,
  int? asOf,
  double slop = 16,
  List<Fill> fills = const [],
}) {
  StrategyMarkerHit? best;
  var bestD = slop;
  for (final s in signals) {
    if (s.side == null) continue;
    final x = strategyMarkerPlotX(signal: s, fills: fills);
    if (x == null) continue;
    if (asOf != null && x > asOf) continue;
    final c = strategyMarkerCenter(
      signal: s,
      bars: bars,
      viewport: viewport,
      priceRange: priceRange,
      canvasW: canvasW,
      plotTop: plotTop,
      plotH: plotH,
      fills: fills,
    );
    if (c == null) continue;
    final d = (c - local).distance;
    if (d <= bestD) {
      bestD = d;
      best = StrategyMarkerHit(s, c);
    }
  }
  return best;
}

/// 独立覆盖层：策略买/卖三角，与缠论一类/二类 BS 分离。
class StrategySignalPainter extends CustomPainter {
  final List<KlineBar> bars;
  final List<SignalEvent> signals;
  final List<Fill> fills;
  final Map<String, int> roundBySignalId;
  final Set<String> highlightedIds;
  final KlineViewport viewport;
  final PriceRange priceRange;
  final double mainH;
  final int? asOf;
  /// 视口是可变对象：平移时同一份被改掉，必须把当时的窗拷下来，否则点不跟 K 线走。
  final double _viewXMin;
  final double _viewXMax;
  final double _yZoom;
  final double _yShift;

  StrategySignalPainter({
    required this.bars,
    required this.signals,
    this.fills = const [],
    this.roundBySignalId = const {},
    required this.highlightedIds,
    required this.viewport,
    required this.priceRange,
    required this.mainH,
    this.asOf,
  })  : _viewXMin = viewport.viewXMin,
        _viewXMax = viewport.viewXMax,
        _yZoom = viewport.yZoomRatio,
        _yShift = viewport.yShiftRatio;

  @override
  void paint(Canvas canvas, Size size) {
    if (signals.isEmpty || bars.isEmpty) return;
    final plotTop = KlineViewport.padT;
    final plotH = math.max(1.0, mainH - KlineViewport.padB - plotTop);
    final cut = asOf;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final s in signals) {
      if (s.side == null) continue;
      final x = strategyMarkerPlotX(signal: s, fills: fills);
      if (x == null) continue;
      if (cut != null && x > cut) continue;
      final c = strategyMarkerCenter(
        signal: s,
        bars: bars,
        viewport: viewport,
        priceRange: priceRange,
        canvasW: size.width,
        plotTop: plotTop,
        plotH: plotH,
        fills: fills,
      );
      if (c == null) continue;
      final side = s.side!;
      final color = strategySideColor(side);
      final hot = highlightedIds.contains(s.signalId);
      if (hot) {
        canvas.drawCircle(
          c,
          14,
          Paint()..color = color.withValues(alpha: 0.28),
        );
      }
      final path = Path();
      const r = 7.0;
      final buy = side == TradeSide.buy;
      if (buy) {
        // 尖朝上：买
        path.moveTo(c.dx, c.dy - r);
        path.lineTo(c.dx - r, c.dy + r * 0.7);
        path.lineTo(c.dx + r, c.dy + r * 0.7);
      } else {
        path.moveTo(c.dx, c.dy + r);
        path.lineTo(c.dx - r, c.dy - r * 0.7);
        path.lineTo(c.dx + r, c.dy - r * 0.7);
      }
      path.close();
      canvas.drawPath(path, Paint()..color = color);
      canvas.drawPath(
        path,
        Paint()
          ..color = Colors.white
          ..style = PaintingStyle.stroke
          ..strokeWidth = hot ? 1.8 : 1.0,
      );
      tp.text = TextSpan(
        text: strategySideLabel(
          side,
          round: roundBySignalId[s.signalId],
        ),
        style: TextStyle(
          color: color,
          fontSize: 9,
          fontWeight: FontWeight.w700,
        ),
      );
      tp.layout();
      final ly = buy ? c.dy + 8 : c.dy - 8 - tp.height;
      tp.paint(canvas, Offset(c.dx - tp.width / 2, ly));
    }
  }

  @override
  bool shouldRepaint(covariant StrategySignalPainter old) {
    return old.signals != signals ||
        old.fills != fills ||
        old.roundBySignalId != roundBySignalId ||
        old.highlightedIds != highlightedIds ||
        old.bars != bars ||
        old.mainH != mainH ||
        old.asOf != asOf ||
        old._viewXMin != _viewXMin ||
        old._viewXMax != _viewXMax ||
        old._yZoom != _yZoom ||
        old._yShift != _yShift ||
        old.priceRange.min != priceRange.min ||
        old.priceRange.max != priceRange.max;
  }
}
