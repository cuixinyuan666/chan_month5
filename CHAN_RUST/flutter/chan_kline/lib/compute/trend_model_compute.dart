import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/trend_model_config.dart';

/// Kn均线 / Kn通道：移植旧 `Math/TrendModel.py`（收盘价滑窗 MEAN/MAX/MIN）。
///
/// **全层同构**：K0=原生 bars.close；Kn≥1=`levels[level==n].unitBars`(+active) 的 close。
/// 窗长 T：不足 T 时用已有长度（与旧 `arr` 截断语义一致）。
/// 展开到 K0：Kn 单元指标按 endX 阶梯铺到覆盖的 K0 柱（asOf 截断）。

enum TrendModelType { mean, max, min }

/// 旧 `CTrendModel`：滑窗状态机。
class TrendModelWindow {
  TrendModelWindow(this.type, this.t)
      : assert(t >= 1, 'T must be >= 1');

  final TrendModelType type;
  final int t;
  final List<double> _arr = [];

  double add(double value) {
    _arr.add(value);
    if (_arr.length > t) {
      _arr.removeRange(0, _arr.length - t);
    }
    switch (type) {
      case TrendModelType.mean:
        var s = 0.0;
        for (final v in _arr) {
          s += v;
        }
        return s / _arr.length;
      case TrendModelType.max:
        var m = _arr.first;
        for (final v in _arr) {
          if (v > m) m = v;
        }
        return m;
      case TrendModelType.min:
        var m = _arr.first;
        for (final v in _arr) {
          if (v < m) m = v;
        }
        return m;
    }
  }
}

/// 一层收盘价序列（按出现序）+ 对应 K0 终点索引（画线/展开用）。
class TrendCloseSample {
  final int endX;
  final double close;
  const TrendCloseSample({required this.endX, required this.close});
}

LevelBundle? _bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

/// 收集 displayKn 的 close 样本（asOf 截断）。
List<TrendCloseSample> collectTrendCloseSamples({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  if (bars.isEmpty) return const [];
  if (displayKn <= 0) {
    final out = <TrendCloseSample>[];
    for (final b in bars) {
      if (asOf != null && b.idx > asOf) break;
      out.add(TrendCloseSample(endX: b.idx, close: b.close));
    }
    return out;
  }
  final lv = _bundleAtLevel(levels, displayKn);
  if (lv == null) return const [];
  final out = <TrendCloseSample>[];
  for (final u in lv.unitBars) {
    if (u.dir != 1 && u.dir != -1) continue;
    if (u.x2 < 0) continue;
    if (asOf != null && u.x2 > asOf) continue;
    out.add(TrendCloseSample(endX: u.x2, close: u.close));
  }
  final act = lv.activeUnit;
  if (act != null && (act.dir == 1 || act.dir == -1) && act.x2 >= 0) {
    final end = asOf != null && act.x2 > asOf ? asOf : act.x2;
    if (asOf == null || act.x1 <= asOf) {
      final i = out.indexWhere((e) => e.endX == act.x2 || e.endX == end);
      final sample = TrendCloseSample(endX: end, close: act.close);
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

/// 对样本跑滑窗 → 每样本一点 (endX, value)。
List<({int x, double v})> runTrendModelOnSamples(
  List<TrendCloseSample> samples,
  TrendModelType type,
  int t,
) {
  if (samples.isEmpty || t < 1) return const [];
  final win = TrendModelWindow(type, t);
  return [
    for (final s in samples) (x: s.endX, v: win.add(s.close)),
  ];
}

/// 样本点阶梯展开到长度 [barCount] 的 K0 序列（未覆盖=null）。
List<double?> expandTrendPointsToK0(
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

/// 一层多周期均线：T → K0 序列。
Map<int, List<double?>> computeMeanSeriesForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  List<int> periods = TrendModelConfig.defaultMeanPeriods,
  int? asOf,
}) {
  final samples = collectTrendCloseSamples(
    displayKn: displayKn,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final barCount = bars.length;
  final out = <int, List<double?>>{};
  for (final t in periods) {
    if (t < 1) continue;
    final pts = runTrendModelOnSamples(samples, TrendModelType.mean, t);
    out[t] = expandTrendPointsToK0(pts, barCount, asOf: asOf);
  }
  return out;
}

/// 一层多周期通道：T → (max系列, min系列)。
Map<int, ({List<double?> max, List<double?> min})> computeChannelSeriesForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  List<int> periods = TrendModelConfig.defaultChannelPeriods,
  int? asOf,
}) {
  final samples = collectTrendCloseSamples(
    displayKn: displayKn,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final barCount = bars.length;
  final out = <int, ({List<double?> max, List<double?> min})>{};
  for (final t in periods) {
    if (t < 1) continue;
    final hi = runTrendModelOnSamples(samples, TrendModelType.max, t);
    final lo = runTrendModelOnSamples(samples, TrendModelType.min, t);
    out[t] = (
      max: expandTrendPointsToK0(hi, barCount, asOf: asOf),
      min: expandTrendPointsToK0(lo, barCount, asOf: asOf),
    );
  }
  return out;
}
