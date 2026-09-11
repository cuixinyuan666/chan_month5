import 'dart:math' as math;

import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
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
