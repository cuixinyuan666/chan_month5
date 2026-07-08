import '../models/bi_confirm_signal.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import 'default_bi_compute.dart';
import 'bi_virtual_bar_provisional_compute.dart';

/// Dart 回退：与 Rust `build_bi_virtual_bars` 同口径。
List<BiVirtualBar> computeBiVirtualBars(
  List<KlineBar> bars,
  List<BiSegment> segments,
) {
  if (bars.isEmpty || segments.isEmpty) return const [];

  (double open, double high, double low, double close) hlRange(int x1, int x2) {
    final a = x1 < x2 ? x1 : x2;
    final b = x1 > x2 ? x1 : x2;
    final aClamped = a.clamp(0, bars.length - 1);
    final bClamped = b.clamp(0, bars.length - 1);
    var hi = double.negativeInfinity;
    var lo = double.infinity;
    for (var i = aClamped; i <= bClamped; i++) {
      final bar = bars[i];
      if (bar.high > hi) hi = bar.high;
      if (bar.low < lo) lo = bar.low;
    }
    return (bars[aClamped].open, hi, lo, bars[bClamped].close);
  }

  final out = <BiVirtualBar>[];
  for (final seg in segments) {
    final bxFallback = seg.beginFractalX1 < seg.beginFractalX2
        ? seg.beginFractalX1
        : seg.beginFractalX2;
    final exFallback = seg.endFractalX1 > seg.endFractalX2
        ? seg.endFractalX1
        : seg.endFractalX2;
    // 起终点均取分型极点 K（与笔连线端点同口径）
    final x1 = seg.beginConfirmX == seg.endConfirmX
        ? bxFallback
        : (fractalPoleBarIdx(
              bars,
              seg.beginFractalX1,
              seg.beginFractalX2,
              -seg.dir,
            ) ??
            bxFallback);
    final x2 = fractalPoleBarIdx(
          bars,
          seg.endFractalX1,
          seg.endFractalX2,
          seg.dir,
        ) ??
        exFallback;
    final (open, high, low, close) = hlRange(x1, x2);
    out.add(
      BiVirtualBar(
        idx: seg.idx,
        dir: seg.dir,
        x1: x1,
        x2: x2,
        open: open,
        high: high,
        low: low,
        close: close,
        confirmX: seg.endConfirmX,
      ),
    );
  }
  return out;
}

BiVirtualBar? _provisionalFromLastConfirm(
  List<KlineBar> bars,
  List<BiConfirmSignal> biConfirms,
  int barX,
  int segIdx,
) {
  BiConfirmSignal? last;
  for (final c in biConfirms) {
    if (c.fx == 'TOP' || c.fx == 'BOTTOM') last = c;
  }
  if (last == null || last.x > barX) return null;
  final dir = last.fx == 'BOTTOM' ? 1 : -1;
  return computeBiVirtualBarProvisional(
    bars,
    last.fractalX1,
    last.fractalX2,
    barX,
    dir,
    segIdx,
  );
}

BiVirtualBar? _provisionalBiAt(
  List<KlineBar> bars,
  List<BiSegment> biSegments,
  List<BiConfirmSignal> biConfirms,
  int barX,
  int nextBi,
) {
  if (nextBi < biSegments.length) {
    final seg = biSegments[nextBi];
    if (!seg.isBootstrap &&
        seg.beginConfirmX <= barX &&
        barX < seg.endConfirmX) {
      return computeBiVirtualBarProvisional(
        bars,
        seg.beginFractalX1,
        seg.beginFractalX2,
        barX,
        seg.dir,
        seg.idx,
      );
    }
    return null;
  }
  return _provisionalFromLastConfirm(
    bars,
    biConfirms,
    barX,
    biSegments.length,
  );
}

/// Dart 回退：与 Rust `build_bi_virtual_bars_for_display` 同口径。
List<BiVirtualBar> computeBiVirtualBarsForDisplay(
  List<KlineBar> bars,
  List<BiSegment> segments,
  List<BiConfirmSignal> biConfirms,
  String defaultBiPolicy,
) {
  if (bars.isEmpty) return const [];
  final barX = bars.last.idx;
  return computeBiVirtualBarsAsOf(
    bars,
    segments,
    biConfirms,
    defaultBiPolicy,
    barX,
  );
}

/// 十字线当步展示：已确认笔段 + 进行中笔（笔确认当步亦起笔 provisional，含起始半侧修复）。
List<BiVirtualBar> computeBiVirtualBarsAsOf(
  List<KlineBar> bars,
  List<BiSegment> segments,
  List<BiConfirmSignal> biConfirms,
  String defaultBiPolicy,
  int asOfBarX,
) {
  if (bars.isEmpty) return const [];

  final barsSlice = bars.where((b) => b.idx <= asOfBarX).toList();
  if (barsSlice.isEmpty) return const [];

  final confirmedSegs =
      segments.where((s) => s.endConfirmX <= asOfBarX).toList();
  final virtualBars = computeBiVirtualBars(barsSlice, confirmedSegs);

  if (defaultBiPolicy == 'pending' && segments.isEmpty) {
    final d = buildPreConfirmDefaultBi(barsSlice, asOfBarX);
    if (d != null) virtualBars.add(d);
    return virtualBars;
  }

  final nextBi = confirmedSegs.length;
  final prov = _provisionalBiAt(
    barsSlice,
    segments,
    biConfirms,
    asOfBarX,
    nextBi,
  );
  if (prov != null) {
    virtualBars.add(prov);
  }
  return virtualBars;
}
