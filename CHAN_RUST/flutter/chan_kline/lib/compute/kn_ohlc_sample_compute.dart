import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// 动态 Kn OHLC 采样（全层同构·K0 颗粒度展开用）。
///
/// K0=原生 bars；Kn≥1=冻 unitBars + activeUnit（当下 close/high/low/open）。

class KnOhlcSample {
  final int endX;
  final double open;
  final double high;
  final double low;
  final double close;

  const KnOhlcSample({
    required this.endX,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });
}

LevelBundle? bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

/// 收集 displayKn 的 OHLC 样本（asOf 截断；按 endX 升序）。
List<KnOhlcSample> collectKnOhlcSamples({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  if (bars.isEmpty) return const [];
  if (displayKn <= 0) {
    final out = <KnOhlcSample>[];
    for (final b in bars) {
      if (asOf != null && b.idx > asOf) break;
      out.add(KnOhlcSample(
        endX: b.idx,
        open: b.open,
        high: b.high,
        low: b.low,
        close: b.close,
      ));
    }
    return out;
  }
  final lv = bundleAtLevel(levels, displayKn);
  if (lv == null) return const [];
  final out = <KnOhlcSample>[];
  for (final u in lv.unitBars) {
    if (u.dir != 1 && u.dir != -1) continue;
    if (u.x2 < 0) continue;
    if (asOf != null && u.x2 > asOf) continue;
    out.add(KnOhlcSample(
      endX: u.x2,
      open: u.open,
      high: u.high,
      low: u.low,
      close: u.close,
    ));
  }
  final act = lv.activeUnit;
  if (act != null && (act.dir == 1 || act.dir == -1) && act.x2 >= 0) {
    final end = asOf != null && act.x2 > asOf ? asOf : act.x2;
    if (asOf == null || act.x1 <= asOf) {
      final sample = KnOhlcSample(
        endX: end,
        open: act.open,
        high: act.high,
        low: act.low,
        close: act.close,
      );
      final i = out.indexWhere((e) => e.endX == act.x2 || e.endX == end);
      if (i >= 0) {
        out[i] = sample;
      } else {
        out.add(sample);
      }
    }
  }
  out.sort((a, b) => a.endX.compareTo(b.endX));
  return out;
}

/// 样本点 (endX,v) 阶梯展开到 K0 长度。
List<double?> expandPointsToK0(
  List<({int x, double v})> points,
  int barCount, {
  int? asOf,
}) {
  if (barCount <= 0) return const [];
  final out = List<double?>.filled(barCount, null);
  if (points.isEmpty) return out;
  var pi = 0;
  double? cur;
  final last = asOf ?? (barCount - 1);
  for (var i = 0; i < barCount && i <= last; i++) {
    while (pi < points.length && points[pi].x <= i) {
      cur = points[pi].v;
      pi++;
    }
    out[i] = cur;
  }
  return out;
}

/// 事件点按 endX 阶梯铺到 K0（同 x 后写覆盖）。
List<T?> expandEventsToK0<T>(
  List<({int x, T v})> events,
  int barCount, {
  int? asOf,
}) {
  if (barCount <= 0) return const [];
  final out = List<T?>.filled(barCount, null);
  if (events.isEmpty) return out;
  final sorted = [...events]..sort((a, b) => a.x.compareTo(b.x));
  var pi = 0;
  T? cur;
  final last = asOf ?? (barCount - 1);
  for (var i = 0; i < barCount && i <= last; i++) {
    while (pi < sorted.length && sorted[pi].x <= i) {
      cur = sorted[pi].v;
      pi++;
    }
    out[i] = cur;
  }
  return out;
}
