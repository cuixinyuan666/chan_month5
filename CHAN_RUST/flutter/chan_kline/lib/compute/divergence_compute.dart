import 'dart:math' as math;

import '../models/divergence_algo.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import '../models/zs_frame.dart';
import 'math_classic_compute.dart';
import 'kn_ohlc_sample_compute.dart';
import 'zs_compute.dart';

export '../models/divergence_algo.dart';

/// 单条背驰样本（离开段右端 x）。
class DivergenceSample {
  final int x;
  final double? inMetric;
  final double? outMetric;
  final double? ratio;
  /// 背离=1，未背离=-1，无值=0
  final int diver;

  const DivergenceSample({
    required this.x,
    this.inMetric,
    this.outMetric,
    this.ratio,
    required this.diver,
  });
}

/// 单算法 K0 展开序列。
class DivergenceAlgoK0Series {
  final List<double?> inAt;
  final List<double?> outAt;
  final List<double?> ratioAt;
  final List<int> diverAt;

  const DivergenceAlgoK0Series({
    required this.inAt,
    required this.outAt,
    required this.ratioAt,
    required this.diverAt,
  });
}

/// 进出段视图（K0=单根分钟K；Kn=连线段/active）。
class _SegView {
  final int idx;
  final int dir;
  final int beginX;
  final int endX;
  final double high;
  final double low;

  const _SegView({
    required this.idx,
    required this.dir,
    required this.beginX,
    required this.endX,
    required this.high,
    required this.low,
  });

  bool get isUp => dir > 0;
  bool get isDown => dir < 0;

  int get loX => beginX < endX ? beginX : endX;
  int get hiX => beginX > endX ? beginX : endX;
}

/// 计算某 displayKn、全部 12 算法的背驰特征（K0 阶梯展开）。
Map<DivergenceAlgo, DivergenceAlgoK0Series> computeDivergenceForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  List<ZSFrame> zsK0Frames = const [],
  MathIndicatorConfig config = const MathIndicatorConfig(),
  int? asOf,
}) {
  final n = bars.length;
  final empty = {
    for (final a in DivergenceAlgoMeta.all)
      a: DivergenceAlgoK0Series(
        inAt: List<double?>.filled(n, null),
        outAt: List<double?>.filled(n, null),
        ratioAt: List<double?>.filled(n, null),
        diverAt: List<int>.filled(n, 0),
      ),
  };
  if (n <= 0) return empty;

  final zsList = rustZsFramesForKn(
    kn: displayKn,
    zsK0Frames: zsK0Frames,
    levels: levels,
  );
  if (zsList.isEmpty) return empty;

  // 力度用 K0 MACD/RSI（对齐旧笔内 klu 序列，非 Kn 采样）
  final macdK0 = computeMacdForLevel(
    displayKn: 0,
    bars: bars,
    levels: levels,
    fast: config.macdFast,
    slow: config.macdSlow,
    signal: config.macdSignal,
    asOf: asOf,
  );
  final rsiK0 = computeRsiForLevel(
    displayKn: 0,
    bars: bars,
    levels: levels,
    period: config.rsiPeriod,
    asOf: asOf,
  );
  final macdHist = macdK0.macd;
  final rsiArr = rsiK0;

  final eventsByAlgo = {
    for (final a in DivergenceAlgoMeta.all) a: <DivergenceSample>[],
  };

  for (final zs in zsList) {
    final inIdx = zs.inSegIdx;
    final outIdx = zs.outSegIdx;
    if (inIdx == null || outIdx == null) continue;

    final inSeg = _resolveSeg(
      displayKn: displayKn,
      idx: inIdx,
      bars: bars,
      levels: levels,
      asOf: asOf,
    );
    final outSeg = _resolveSeg(
      displayKn: displayKn,
      idx: outIdx,
      bars: bars,
      levels: levels,
      asOf: asOf,
    );
    if (inSeg == null || outSeg == null) continue;

    final eventX = outSeg.endX;
    if (eventX < 0 || (asOf != null && eventX > asOf)) continue;

    final broke = _endSegBreak(outSeg, zs);
    for (final algo in DivergenceAlgoMeta.all) {
      if (!broke) {
        eventsByAlgo[algo]!.add(DivergenceSample(x: eventX, diver: 0));
        continue;
      }
      final inM = _calMetric(
        algo: algo,
        seg: inSeg,
        isReverse: false,
        bars: bars,
        macdHist: macdHist,
        rsi: rsiArr,
      );
      final outM = _calMetric(
        algo: algo,
        seg: outSeg,
        isReverse: true,
        bars: bars,
        macdHist: macdHist,
        rsi: rsiArr,
      );
      if (inM == null ||
          outM == null ||
          !inM.isFinite ||
          !outM.isFinite ||
          inM == 0.0) {
        eventsByAlgo[algo]!.add(DivergenceSample(x: eventX, diver: 0));
        continue;
      }
      final ratio = outM / inM;
      if (!ratio.isFinite) {
        eventsByAlgo[algo]!.add(DivergenceSample(x: eventX, diver: 0));
        continue;
      }
      final rate = config.divergenceRate;
      final isDiver = rate > 100 || outM <= rate * inM;
      eventsByAlgo[algo]!.add(DivergenceSample(
        x: eventX,
        inMetric: inM,
        outMetric: outM,
        ratio: ratio,
        diver: isDiver ? 1 : -1,
      ));
    }
  }

  final out = <DivergenceAlgo, DivergenceAlgoK0Series>{};
  for (final algo in DivergenceAlgoMeta.all) {
    final ev = eventsByAlgo[algo]!;
    // 每事件四字段同口径：diver=0 时 in/out/ratio 同步清空，禁止 hold 旧值
    out[algo] = DivergenceAlgoK0Series(
      inAt: expandNullablePointsToK0(
        [for (final e in ev) (x: e.x, v: e.inMetric)],
        n,
        asOf: asOf,
      ),
      outAt: expandNullablePointsToK0(
        [for (final e in ev) (x: e.x, v: e.outMetric)],
        n,
        asOf: asOf,
      ),
      ratioAt: expandNullablePointsToK0(
        [for (final e in ev) (x: e.x, v: e.ratio)],
        n,
        asOf: asOf,
      ),
      diverAt: _expandDiverToK0(ev, n, asOf: asOf),
    );
  }
  return out;
}

/// diver 阶梯：默认 0，事件后 hold。
List<int> _expandDiverToK0(
  List<DivergenceSample> events,
  int barCount, {
  int? asOf,
}) {
  final out = List<int>.filled(barCount, 0);
  if (events.isEmpty || barCount <= 0) return out;
  final sorted = [...events]..sort((a, b) => a.x.compareTo(b.x));
  var pi = 0;
  var cur = 0;
  final last = asOf ?? (barCount - 1);
  for (var i = 0; i < barCount && i <= last; i++) {
    while (pi < sorted.length && sorted[pi].x <= i) {
      cur = sorted[pi].diver;
      pi++;
    }
    out[i] = cur;
  }
  return out;
}

bool _endSegBreak(_SegView out, ZSFrame zs) {
  // 离开段突破中枢：向下破 ZD 或向上破 ZG
  return (out.isDown && out.low < zs.low) || (out.isUp && out.high > zs.high);
}

_SegView? _resolveSeg({
  required int displayKn,
  required int idx,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  if (displayKn <= 0) {
    if (idx < 0 || idx >= bars.length) return null;
    if (asOf != null && idx > asOf) return null;
    final b = bars[idx];
    final dir = _k0BarDir(bars, idx);
    return _SegView(
      idx: idx,
      dir: dir,
      beginX: idx,
      endX: idx,
      high: b.high,
      low: b.low,
    );
  }
  LevelBundle? lv;
  for (final b in levels) {
    if (b.level == displayKn) {
      lv = b;
      break;
    }
  }
  if (lv == null) return null;
  for (final s in lv.segments) {
    if (s.idx == idx) {
      if (asOf != null && s.endConfirmX > asOf && s.endPoleX > asOf) {
        return null;
      }
      return _SegView(
        idx: s.idx,
        dir: s.dir,
        beginX: s.beginPoleX,
        endX: s.endPoleX,
        high: s.high,
        low: s.low,
      );
    }
  }
  final a = lv.activeUnit;
  if (a != null && a.idx == idx) {
    final x2 = asOf != null ? math.min(a.x2, asOf) : a.x2;
    return _SegView(
      idx: a.idx,
      dir: a.dir,
      beginX: a.x1,
      endX: x2,
      high: a.high,
      low: a.low,
    );
  }
  return null;
}

/// 对齐 Rust `kline_bars_to_segments` 方向。
int _k0BarDir(List<KlineBar> bars, int i) {
  if (i <= 0 || i >= bars.length) return 1;
  final b = bars[i];
  final p = bars[i - 1];
  final mid = (b.high + b.low) / 2.0;
  final pMid = (p.high + p.low) / 2.0;
  return mid >= pMid ? 1 : -1;
}

double? _calMetric({
  required DivergenceAlgo algo,
  required _SegView seg,
  required bool isReverse,
  required List<KlineBar> bars,
  required List<double?> macdHist,
  required List<double?> rsi,
}) {
  switch (algo) {
    case DivergenceAlgo.area:
      return _metricArea(seg, isReverse, macdHist);
    case DivergenceAlgo.peak:
      return _metricPeak(seg, macdHist);
    case DivergenceAlgo.fullArea:
      return _metricFullArea(seg, macdHist);
    case DivergenceAlgo.diff:
      return _metricDiff(seg, macdHist);
    case DivergenceAlgo.slope:
      return _metricSlope(seg, bars);
    case DivergenceAlgo.amp:
      return _metricAmp(seg, bars);
    case DivergenceAlgo.amount:
      return _metricTrade(seg, bars, _TradeField.amount, avg: false);
    case DivergenceAlgo.volumn:
      return _metricTrade(seg, bars, _TradeField.volume, avg: false);
    case DivergenceAlgo.amountAvg:
      return _metricTrade(seg, bars, _TradeField.amount, avg: true);
    case DivergenceAlgo.volumnAvg:
      return _metricTrade(seg, bars, _TradeField.volume, avg: true);
    case DivergenceAlgo.turnrateAvg:
      return _metricTrade(seg, bars, _TradeField.turnrate, avg: true);
    case DivergenceAlgo.rsi:
      return _metricRsi(seg, rsi);
  }
}

double _metricArea(_SegView seg, bool isReverse, List<double?> macd) {
  var s = 1e-7;
  if (!isReverse) {
    final begin = seg.beginX;
    if (begin < 0 || begin >= macd.length) return s;
    final peak = macd[begin];
    if (peak == null) return s;
    for (var i = begin; i < macd.length && i <= seg.hiX; i++) {
      final m = macd[i];
      if (m == null) break;
      if (m * peak > 0) {
        s += m.abs();
      } else {
        break;
      }
    }
    return s;
  }
  // 从终点往回：异号停止
  final begin = seg.endX;
  if (begin < 0 || begin >= macd.length) return s;
  final peak = macd[begin];
  if (peak == null) return s;
  for (var i = begin; i >= 0 && i >= seg.loX; i--) {
    final m = macd[i];
    if (m == null) break;
    if (m * peak > 0) {
      s += m.abs();
    } else {
      break;
    }
  }
  return s;
}

double _metricPeak(_SegView seg, List<double?> macd) {
  var peak = 1e-7;
  for (var i = seg.loX; i <= seg.hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    if (m.abs() > peak) {
      if (seg.isDown && m < 0) {
        peak = m.abs();
      } else if (seg.isUp && m > 0) {
        peak = m.abs();
      }
    }
  }
  return peak;
}

double _metricFullArea(_SegView seg, List<double?> macd) {
  var s = 1e-7;
  for (var i = seg.loX; i <= seg.hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    if ((seg.isDown && m < 0) || (seg.isUp && m > 0)) {
      s += m.abs();
    }
  }
  return s;
}

double? _metricDiff(_SegView seg, List<double?> macd) {
  var maxV = double.negativeInfinity;
  var minV = double.infinity;
  var any = false;
  for (var i = seg.loX; i <= seg.hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    any = true;
    if (m > maxV) maxV = m;
    if (m < minV) minV = m;
  }
  if (!any) return null;
  return maxV - minV;
}

double? _metricSlope(_SegView seg, List<KlineBar> bars) {
  final b0 = seg.beginX;
  final b1 = seg.endX;
  if (b0 < 0 || b1 < 0 || b0 >= bars.length || b1 >= bars.length) return null;
  final begin = bars[b0];
  final end = bars[b1];
  final cnt = (b1 - b0).abs() + 1;
  if (seg.isUp) {
    if (end.high == 0) return null;
    return (end.high - begin.low) / end.high / cnt;
  }
  if (begin.high == 0) return null;
  return (begin.high - end.low) / begin.high / cnt;
}

double? _metricAmp(_SegView seg, List<KlineBar> bars) {
  final b0 = seg.beginX;
  final b1 = seg.endX;
  if (b0 < 0 || b1 < 0 || b0 >= bars.length || b1 >= bars.length) return null;
  final begin = bars[b0];
  final end = bars[b1];
  if (seg.isDown) {
    if (begin.high == 0) return null;
    return (begin.high - end.low) / begin.high;
  }
  if (begin.low == 0) return null;
  return (end.high - begin.low) / begin.low;
}

enum _TradeField { amount, volume, turnrate }

double? _metricTrade(
  _SegView seg,
  List<KlineBar> bars,
  _TradeField field, {
  required bool avg,
}) {
  var sum = 0.0;
  var cnt = 0;
  for (var i = seg.loX; i <= seg.hiX && i < bars.length; i++) {
    if (i < 0) continue;
    final b = bars[i];
    double? v;
    switch (field) {
      case _TradeField.amount:
        v = b.amount;
        break;
      case _TradeField.volume:
        v = b.volume;
        break;
      case _TradeField.turnrate:
        final raw = b.metrics['turnrate'] ?? b.metrics['turn_rate'];
        if (raw is num) {
          v = raw.toDouble();
        } else {
          return null; // 缺换手 → 无值
        }
        break;
    }
    sum += v;
    cnt++;
  }
  if (cnt <= 0) return null;
  return avg ? sum / cnt : sum;
}

double? _metricRsi(_SegView seg, List<double?> rsi) {
  final vals = <double>[];
  for (var i = seg.loX; i <= seg.hiX && i < rsi.length; i++) {
    if (i < 0) continue;
    final v = rsi[i];
    if (v != null) vals.add(v);
  }
  if (vals.isEmpty) return null;
  if (seg.isDown) {
    final m = vals.reduce(math.min);
    return 10000.0 / (m + 1e-7);
  }
  return vals.reduce(math.max);
}
