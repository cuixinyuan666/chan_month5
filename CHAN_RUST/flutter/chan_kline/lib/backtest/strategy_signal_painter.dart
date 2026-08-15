import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../models/kline_bar.dart';
import '../widgets/kline_viewport.dart';
import 'signal_event.dart';

/// 策略买卖点颜色：刻意不用缠论 1Ba/1Sa 的红绿。
const Color kStrategyBuyColor = Color(0xFF00E676);
const Color kStrategySellColor = Color(0xFFD500F9);

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

/// 主图策略点位置：只消费 SignalEvent，不重算穿越。
Offset? strategyMarkerCenter({
  required SignalEvent signal,
  required List<KlineBar> bars,
  required KlineViewport viewport,
  required PriceRange priceRange,
  required double canvasW,
  required double plotTop,
  required double plotH,
}) {
  if (signal.side == null) return null;
  final bar = klineBarByIdx(bars, signal.discoveryX);
  if (bar == null) return null;
  if (signal.discoveryX < viewport.viewXMin - 1 ||
      signal.discoveryX > viewport.viewXMax + 1) {
    return null;
  }
  final cx = viewport.barCenterX(signal.discoveryX, canvasW);
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
}) {
  StrategyMarkerHit? best;
  var bestD = slop;
  for (final s in signals) {
    if (s.side == null) continue;
    if (asOf != null && s.discoveryX > asOf) continue;
    final c = strategyMarkerCenter(
      signal: s,
      bars: bars,
      viewport: viewport,
      priceRange: priceRange,
      canvasW: canvasW,
      plotTop: plotTop,
      plotH: plotH,
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
  final Set<String> highlightedIds;
  final KlineViewport viewport;
  final PriceRange priceRange;
  final double mainH;
  final int? asOf;

  StrategySignalPainter({
    required this.bars,
    required this.signals,
    required this.highlightedIds,
    required this.viewport,
    required this.priceRange,
    required this.mainH,
    this.asOf,
  });

  @override
  void paint(Canvas canvas, Size size) {
    if (signals.isEmpty || bars.isEmpty) return;
    final plotTop = KlineViewport.padT;
    final plotH = math.max(1.0, mainH - KlineViewport.padB - plotTop);
    final cut = asOf;
    final tp = TextPainter(textDirection: TextDirection.ltr);
    for (final s in signals) {
      if (s.side == null) continue;
      if (cut != null && s.discoveryX > cut) continue;
      final c = strategyMarkerCenter(
        signal: s,
        bars: bars,
        viewport: viewport,
        priceRange: priceRange,
        canvasW: size.width,
        plotTop: plotTop,
        plotH: plotH,
      );
      if (c == null) continue;
      final buy = s.side == TradeSide.buy;
      final color = buy ? kStrategyBuyColor : kStrategySellColor;
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
      if (buy) {
        // 尖朝上：策略买
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
        text: buy ? '策买' : '策卖',
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
        old.highlightedIds != highlightedIds ||
        old.bars != bars ||
        old.mainH != mainH ||
        old.asOf != asOf ||
        old.viewport.viewXMin != viewport.viewXMin ||
        old.viewport.viewXMax != viewport.viewXMax ||
        old.priceRange.min != priceRange.min ||
        old.priceRange.max != priceRange.max;
  }
}
