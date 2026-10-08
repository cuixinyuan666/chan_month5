import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'kn_clock_timeline.dart';

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
///
/// [levels] 是**最终态**结构，只适用于「整段跑完再看」的场合（绘图、诊断）。
/// 条件求值（回测/寻优）必须改用 [collectKnOhlcSamplesAt]，用 asOf **当时**的段划分，
/// 否则动态段中途成立的 K1+ 穿越信号会丢或被推到段尾。详见 [KnClockTimeline]。
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
  // 方案B：Math/OHLC Kn≥1 → structure level==displayKn-1
  final lv = bundleAtLevel(levels, displayKn - 1);
  if (lv == null) return const [];
  return samplesFromUnits(
    unitBars: lv.unitBars,
    activeUnit: lv.activeUnit,
    asOf: asOf,
  );
}

/// 用 asOf **当时**的动态段收样本（K1+ 穿越判定的正确口径 / 当下性）。
///
/// 采样点 = 所有「x ≤ asOf 且 x 那一刻存在正在生长的段」的 bar——**每根 K 都在场判一次**，
/// 与实盘一致。段定型那一根同样是采样点（那一刻它就是 active 段末端）。
/// 这与 [collectKnOhlcSamples] 的「一段一个点」不同：后者只在 asOf 恰好是段尾时等价。
List<KnOhlcSample> collectKnOhlcSamplesAt({
  required int displayKn,
  required KnClockTimeline timeline,
  int? asOf,
}) {
  if (displayKn <= 0) return const [];
  final ends = timeline.sampleEnds(asOf);
  if (ends.isEmpty) return const [];
  final out = <KnOhlcSample>[];
  for (final x in ends) {
    final o = timeline.activeOhlcAt(x);
    if (o == null) continue;
    out.add(KnOhlcSample(
      endX: x,
      open: o.open,
      high: o.high,
      low: o.low,
      close: o.close,
    ));
  }
  return out;
}

/// 已确认段 + 当时动态段 → 样本点（asOf 截断；动态段右端夹到 asOf）。
List<KnOhlcSample> samplesFromUnits({
  required List<LevelUnitBar> unitBars,
  required LevelUnitBar? activeUnit,
  int? asOf,
}) {
  final out = <KnOhlcSample>[];
  for (final u in unitBars) {
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
  final act = activeUnit;
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

/// 可空阶梯：事件可把 cur 置 null（背驰无值时清掉旧 in/out/ratio）。
List<double?> expandNullablePointsToK0(
  List<({int x, double? v})> points,
  int barCount, {
  int? asOf,
}) {
  if (barCount <= 0) return const [];
  final out = List<double?>.filled(barCount, null);
  if (points.isEmpty) return out;
  final sorted = [...points]..sort((a, b) => a.x.compareTo(b.x));
  var pi = 0;
  double? cur;
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
