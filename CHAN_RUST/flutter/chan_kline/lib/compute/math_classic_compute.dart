import 'dart:math' as math;

import '../models/bar_crosshair_feature.dart';
import '../models/fractal_judgment_event.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import 'chart_view_compute.dart';
import 'kn_ohlc_sample_compute.dart';

/// MACD / BOLL / RSI / KDJ：移植旧 Math，动态 Kn OHLC，K0 颗粒度展开。

// ─── MACD ─────────────────────────────────────────────

class MacdItem {
  final double dif;
  final double dea;
  final double macd; // 2*(DIF-DEA)
  const MacdItem({required this.dif, required this.dea, required this.macd});
}

class MacdEngine {
  MacdEngine({this.fast = 12, this.slow = 26, this.signal = 9});
  final int fast;
  final int slow;
  final int signal;
  final List<MacdItem> _items = [];
  double? _fastEma;
  double? _slowEma;

  MacdItem add(double value) {
    if (_items.isEmpty) {
      _fastEma = value;
      _slowEma = value;
      final item = const MacdItem(dif: 0, dea: 0, macd: 0);
      _items.add(item);
      return item;
    }
    _fastEma = (2 * value + (fast - 1) * _fastEma!) / (fast + 1);
    _slowEma = (2 * value + (slow - 1) * _slowEma!) / (slow + 1);
    final dif = _fastEma! - _slowEma!;
    final dea = (2 * dif + (signal - 1) * _items.last.dea) / (signal + 1);
    final item = MacdItem(dif: dif, dea: dea, macd: 2 * (dif - dea));
    _items.add(item);
    return item;
  }
}

class MacdK0Series {
  final List<double?> dif;
  final List<double?> dea;
  final List<double?> macd;
  const MacdK0Series({
    required this.dif,
    required this.dea,
    required this.macd,
  });
}

MacdK0Series computeMacdForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int fast = 12,
  int slow = 26,
  int signal = 9,
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  final eng = MacdEngine(fast: fast, slow: slow, signal: signal);
  final ptsDif = <({int x, double v})>[];
  final ptsDea = <({int x, double v})>[];
  final ptsMacd = <({int x, double v})>[];
  for (final s in use) {
    final it = eng.add(s.close);
    ptsDif.add((x: s.endX, v: it.dif));
    ptsDea.add((x: s.endX, v: it.dea));
    ptsMacd.add((x: s.endX, v: it.macd));
  }
  final n = bars.length;
  return MacdK0Series(
    dif: expandPointsToK0(ptsDif, n, asOf: asOf),
    dea: expandPointsToK0(ptsDea, n, asOf: asOf),
    macd: expandPointsToK0(ptsMacd, n, asOf: asOf),
  );
}

// ─── BOLL ─────────────────────────────────────────────

class BollItem {
  final double mid;
  final double up;
  final double down;
  const BollItem({required this.mid, required this.up, required this.down});
}

class BollEngine {
  BollEngine(this.n) : assert(n > 1);
  final int n;
  final List<double> _arr = [];

  BollItem add(double value) {
    _arr.add(value);
    if (_arr.length > n) _arr.removeRange(0, _arr.length - n);
    final ma = _arr.reduce((a, b) => a + b) / _arr.length;
    var varSum = 0.0;
    for (final x in _arr) {
      final d = x - ma;
      varSum += d * d;
    }
    final theta = math.sqrt(varSum / _arr.length);
    final t = theta == 0 ? 1e-7 : theta;
    final down = ma - 2 * t;
    return BollItem(
      mid: ma,
      up: ma + 2 * t,
      down: down == 0 ? 1e-7 : down,
    );
  }
}

class BollK0Series {
  final List<double?> mid;
  final List<double?> up;
  final List<double?> down;
  const BollK0Series({
    required this.mid,
    required this.up,
    required this.down,
  });
}

BollK0Series computeBollForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int n = 20,
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  final eng = BollEngine(n < 2 ? 2 : n);
  final ptsM = <({int x, double v})>[];
  final ptsU = <({int x, double v})>[];
  final ptsD = <({int x, double v})>[];
  for (final s in use) {
    final it = eng.add(s.close);
    ptsM.add((x: s.endX, v: it.mid));
    ptsU.add((x: s.endX, v: it.up));
    ptsD.add((x: s.endX, v: it.down));
  }
  final len = bars.length;
  return BollK0Series(
    mid: expandPointsToK0(ptsM, len, asOf: asOf),
    up: expandPointsToK0(ptsU, len, asOf: asOf),
    down: expandPointsToK0(ptsD, len, asOf: asOf),
  );
}

// ─── 唐奇安通道（Donchian） ───────────────────────────
// 经典口径：上轨 = 窗口 N 内最高价最大（HHV），下轨 = 窗口 N 内最低价最小（LLV），
// 中轨 = (上轨 + 下轨) / 2。样本钟与布林/KDJ 同构：K0=原生分钟K，K{n}=本层虚拟K。

class DonchianK0Series {
  final List<double?> up;
  final List<double?> mid;
  final List<double?> down;
  const DonchianK0Series({
    required this.up,
    required this.mid,
    required this.down,
  });
}

DonchianK0Series computeDonchianForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int n = 20,
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  final win = n < 1 ? 1 : n;
  final highs = <double>[];
  final lows = <double>[];
  final ptsU = <({int x, double v})>[];
  final ptsM = <({int x, double v})>[];
  final ptsD = <({int x, double v})>[];
  for (final s in use) {
    highs.add(s.high);
    lows.add(s.low);
    if (highs.length > win) {
      highs.removeRange(0, highs.length - win);
      lows.removeRange(0, lows.length - win);
    }
    var hh = highs.first;
    var ll = lows.first;
    for (var i = 1; i < highs.length; i++) {
      if (highs[i] > hh) hh = highs[i];
      if (lows[i] < ll) ll = lows[i];
    }
    ptsU.add((x: s.endX, v: hh));
    ptsD.add((x: s.endX, v: ll));
    ptsM.add((x: s.endX, v: (hh + ll) / 2));
  }
  final len = bars.length;
  return DonchianK0Series(
    up: expandPointsToK0(ptsU, len, asOf: asOf),
    mid: expandPointsToK0(ptsM, len, asOf: asOf),
    down: expandPointsToK0(ptsD, len, asOf: asOf),
  );
}

// ─── 回归通道（父层连线绑定） ─────────────────────────
// 基准区间：父层 K{n+1}连线（structure level = displayKn+1）在 asOf 视图下的**最后一段**
// ——倒数第二个极点 → 最后一个极点，端点含分型判断与构建中开口尾端；父层一出新段整条通道换新基准，旧的不留。
// 样本钟：K0 取区间内每根 K0 收盘；K{n}≥1 取右端 x 落在区间内的本层虚拟K收盘（与布林同一套钟）。
// 回归：以 K0 格点 x 为自变量做最小二乘 → 中轨；上下轨 = 中轨 ± k×残差总体标准差（除 m，与布林同口径）。
// 绘制：从基准起点 x1 一路平行外推到 asOf 截断（宽度恒定），asOf 右侧不画；不回写、不参与信号。

class RegressionChannelK0Series {
  final List<double?> mid;
  final List<double?> up;
  final List<double?> down;
  const RegressionChannelK0Series({
    required this.mid,
    required this.up,
    required this.down,
  });
}

/// 按「父层 K{n+1}连线最后一段」拟合回归通道（全层同构·不回写）。
///
/// [displayKn]：指标所在层；父层连线 = structure level `displayKn + 1`
/// （K0回归通道看 K1连线、K1看 K2…）。
/// [k]：上下轨带宽倍数（中轨 ± k×残差总体标准差）。
/// [asOf]：步进截断；基底连线按 asOf 当时可见的那条取，右端外推也截到 asOf。
/// [barFeatures] / [liveJudgments]：父层构建中虚线端点来源（与图上连线同源）；缺省时只认冻段。
/// 父层还没有连线、或区间内样本 < 2 → 该层整条不出线。
RegressionChannelK0Series computeRegressionChannelForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  List<FractalJudgmentEvent> liveJudgments = const [],
  double k = 2.0,
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final len = bars.length;
  final mid = List<double?>.filled(len, null);
  final up = List<double?>.filled(len, null);
  final down = List<double?>.filled(len, null);
  RegressionChannelK0Series empty() =>
      RegressionChannelK0Series(mid: mid, up: up, down: down);
  if (len == 0) return empty();

  final asOfEff = asOf ?? (len - 1);
  if (asOfEff < 0 || asOfEff >= len) return empty();

  // ① 基准区间 = 父层 K{n+1}连线最后一段
  final span = lastLevelLineSpanAtAsOf(
    bars: bars,
    levels: levels,
    barFeatures: barFeatures,
    level: displayKn + 1,
    asOf: asOfEff,
    liveJudgments: liveJudgments,
  );
  if (span == null) return empty();
  final x1 = span.x1;
  final x2 = span.x2;
  if (x1 < 0 || x2 <= x1) return empty();

  // ② 样本钟：K0=原生收盘；K{n}≥1=本层虚拟K（右端 x 落在区间内）
  final xs = <double>[];
  final ys = <double>[];
  if (displayKn <= 0) {
    for (final b in bars) {
      if (b.idx < x1) continue;
      if (b.idx > x2) break;
      xs.add(b.idx.toDouble());
      ys.add(b.close);
    }
  } else {
    final use = samples ??
        collectKnOhlcSamples(
          displayKn: displayKn,
          bars: bars,
          levels: levels,
          asOf: asOf,
        );
    for (final s in use) {
      if (s.endX < x1 || s.endX > x2) continue;
      xs.add(s.endX.toDouble());
      ys.add(s.close);
    }
  }
  final m = xs.length;
  if (m < 2) return empty();

  // ③ 最小二乘 + 残差总体标准差
  double sx = 0, sxx = 0, sy = 0, sxy = 0;
  for (var i = 0; i < m; i++) {
    sx += xs[i];
    sxx += xs[i] * xs[i];
    sy += ys[i];
    sxy += xs[i] * ys[i];
  }
  final denom = m * sxx - sx * sx;
  final bSlope = denom.abs() > 1e-12 ? (m * sxy - sx * sy) / denom : 0.0;
  final aInter = (sy - bSlope * sx) / m;
  var resVar = 0.0;
  for (var i = 0; i < m; i++) {
    final d = ys[i] - (aInter + bSlope * xs[i]);
    resVar += d * d;
  }
  final theta = math.sqrt(resVar / m); // 残差总体标准差（除 m，与布林同口径）
  final t = theta == 0 ? 1e-7 : theta;

  // ④ 从基准起点一路平行外推到 asOf 截断
  for (var i = x1; i <= asOfEff && i < len; i++) {
    final fitMid = aInter + bSlope * i;
    mid[i] = fitMid;
    up[i] = fitMid + k * t;
    down[i] = fitMid - k * t;
  }
  return RegressionChannelK0Series(mid: mid, up: up, down: down);
}

// ─── RSI ──────────────────────────────────────────────

class RsiEngine {
  RsiEngine(this.period);
  final int period;
  final List<double> _close = [];
  final List<double> _diff = [];
  final List<double> _up = [];
  final List<double> _down = [];

  double add(double close) {
    _close.add(close);
    if (_close.length == 1) return 50.0;
    _diff.add(_close.last - _close[_close.length - 2]);
    if (_diff.length < period) {
      var upSum = 0.0;
      var downSum = 0.0;
      for (final x in _diff) {
        if (x > 0) {
          upSum += x;
        } else if (x < 0) {
          downSum += -x;
        }
      }
      _up.add(upSum / _diff.length);
      _down.add(downSum / _diff.length);
    } else {
      final d = _diff.last;
      final upval = d > 0 ? d : 0.0;
      final downval = d < 0 ? -d : 0.0;
      _up.add((_up.last * (period - 1) + upval) / period);
      _down.add((_down.last * (period - 1) + downval) / period);
    }
    if (_down.last == 0) {
      return _up.last > 0 ? 100.0 : 0.0;
    }
    final rs = _up.last / _down.last;
    return 100.0 - 100.0 / (1.0 + rs);
  }
}

List<double?> computeRsiForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int period = 14,
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  final eng = RsiEngine(period < 1 ? 1 : period);
  final pts = <({int x, double v})>[
    for (final s in use) (x: s.endX, v: eng.add(s.close)),
  ];
  return expandPointsToK0(pts, bars.length, asOf: asOf);
}

// ─── KDJ ──────────────────────────────────────────────

class KdjItem {
  final double k;
  final double d;
  final double j;
  const KdjItem({required this.k, required this.d, required this.j});
}

class KdjEngine {
  KdjEngine(this.period);
  final int period;
  final List<({double high, double low})> _arr = [];
  KdjItem _pre = const KdjItem(k: 50, d: 50, j: 50);

  KdjItem add({required double high, required double low, required double close}) {
    _arr.add((high: high, low: low));
    if (_arr.length > period) _arr.removeAt(0);
    var hn = _arr.first.high;
    var ln = _arr.first.low;
    for (final e in _arr) {
      if (e.high > hn) hn = e.high;
      if (e.low < ln) ln = e.low;
    }
    final rsv = hn != ln ? 100 * (close - ln) / (hn - ln) : 0.0;
    final k = 2 / 3 * _pre.k + 1 / 3 * rsv;
    final d = 2 / 3 * _pre.d + 1 / 3 * k;
    final j = 3 * k - 2 * d;
    _pre = KdjItem(k: k, d: d, j: j);
    return _pre;
  }
}

class KdjK0Series {
  final List<double?> k;
  final List<double?> d;
  final List<double?> j;
  const KdjK0Series({required this.k, required this.d, required this.j});
}

KdjK0Series computeKdjForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  int period = 9,
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  final eng = KdjEngine(period < 1 ? 1 : period);
  final ptsK = <({int x, double v})>[];
  final ptsD = <({int x, double v})>[];
  final ptsJ = <({int x, double v})>[];
  for (final s in use) {
    final it = eng.add(high: s.high, low: s.low, close: s.close);
    ptsK.add((x: s.endX, v: it.k));
    ptsD.add((x: s.endX, v: it.d));
    ptsJ.add((x: s.endX, v: it.j));
  }
  final n = bars.length;
  return KdjK0Series(
    k: expandPointsToK0(ptsK, n, asOf: asOf),
    d: expandPointsToK0(ptsD, n, asOf: asOf),
    j: expandPointsToK0(ptsJ, n, asOf: asOf),
  );
}

/// 便捷：按配置算一层全部经典指标。
({
  MacdK0Series macd,
  BollK0Series boll,
  DonchianK0Series donchian,
  List<double?> rsi,
  KdjK0Series kdj,
}) computeClassicMathForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathIndicatorConfig config = const MathIndicatorConfig(),
  int? asOf,
  List<KnOhlcSample>? samples,
}) {
  final use = samples ??
      collectKnOhlcSamples(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        asOf: asOf,
      );
  return (
    macd: computeMacdForLevel(
      displayKn: displayKn,
      bars: bars,
      levels: levels,
      fast: config.macdFast,
      slow: config.macdSlow,
      signal: config.macdSignal,
      asOf: asOf,
      samples: use,
    ),
    boll: computeBollForLevel(
      displayKn: displayKn,
      bars: bars,
      levels: levels,
      n: config.bollN,
      asOf: asOf,
      samples: use,
    ),
    donchian: computeDonchianForLevel(
      displayKn: displayKn,
      bars: bars,
      levels: levels,
      n: config.donchianN,
      asOf: asOf,
      samples: use,
    ),
    rsi: computeRsiForLevel(
      displayKn: displayKn,
      bars: bars,
      levels: levels,
      period: config.rsiPeriod,
      asOf: asOf,
      samples: use,
    ),
    kdj: computeKdjForLevel(
      displayKn: displayKn,
      bars: bars,
      levels: levels,
      period: config.kdjPeriod,
      asOf: asOf,
      samples: use,
    ),
  );
}
