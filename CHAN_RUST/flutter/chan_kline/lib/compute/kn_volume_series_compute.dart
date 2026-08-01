import '../models/bar_crosshair_feature.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// K0 volume: native bars[].volume.
List<double> computeK0VolumeSeries(List<KlineBar> bars) {
  return [for (final b in bars) b.volume];
}

/// K0 buy volume: 从 chip_tick_bins 或 tick_side 估算买入量。
List<double> computeK0BuyVolumeSeries(List<KlineBar> bars) {
  double buyVol(KlineBar b) {
    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      final bQty = _sumBins(bins['b']);
      final sQty = _sumBins(bins['s']);
      final total = bQty + sQty;
      if (total > 0) return b.volume * bQty / total;
    }
    final side = b.metrics['tick_side'];
    if (side == 'B') return b.volume;
    if (side == 'S') return 0;
    return b.volume * 0.5;
  }
  return [for (final b in bars) buyVol(b)];
}

double _sumBins(dynamic binData) {
  if (binData is List) {
    double sum = 0;
    for (final e in binData) {
      sum += (e as num).toDouble();
    }
    return sum;
  }
  return 0;
}

/// K0 tick count: 从 chip_tick_bins 数组长度统计笔数。
List<double> computeK0TickCountSeries(List<KlineBar> bars) {
  double tickCount(KlineBar b) {
    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      final bLen = _listLen(bins['b']);
      final sLen = _listLen(bins['s']);
      return (bLen + sLen).toDouble();
    }
    final side = b.metrics['tick_side'];
    if (side == 'B' || side == 'S') return 1;
    return 0;
  }
  return [for (final b in bars) tickCount(b)];
}

/// K0 buy tick count: 从 chip_tick_bins 数组长度统计买入笔数。
List<double> computeK0BuyTickCountSeries(List<KlineBar> bars) {
  double buyTick(KlineBar b) {
    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      return _listLen(bins['b']).toDouble();
    }
    final side = b.metrics['tick_side'];
    if (side == 'B') return 1;
    return 0;
  }
  return [for (final b in bars) buyTick(b)];
}

int _listLen(dynamic binData) {
  if (binData is List) return binData.length;
  return 0;
}

/// 内部复用：从 K0 系列出发，逐一累积各层确认门控系列。
Map<int, List<double>> _computeAllKnFromK0({
  required List<double> k0Series,
  required List<LevelBundle> levels,
  required List<KlineBar> bars,
}) {
  final n = bars.length;
  final out = <int, List<double>>{};
  if (n == 0) return out;

  var increments = List<double>.from(k0Series);
  out[0] = List<double>.from(increments);

  final sorted = [...levels]..sort((a, b) => a.level.compareTo(b.level));
  for (final bundle in sorted) {
    final kn = bundle.level;
    if (kn < 1) continue;
    final series = _accumulateConfirmGated(
      lowerIncrements: increments,
      bundle: bundle,
      bars: bars,
    );
    out[kn] = series;
    increments = _cumulativeToIncrements(series);
  }
  return out;
}

/// All Kn 总成交量系列（key = display kn: 0=K0, 1=K1, ...）。
Map<int, List<double>> computeAllKnVolumeSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0VolumeSeries(bars),
    levels: levels,
    bars: bars,
  );
}

/// All Kn 买入量系列（key = display kn: 0=K0, 1=K1, ...）。
/// 与总成交量同结构，用于红绿叠柱绘制。
Map<int, List<double>> computeAllKnBuyVolumeSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0BuyVolumeSeries(bars),
    levels: levels,
    bars: bars,
  );
}

/// All Kn 总笔数系列（key = display kn: 0=K0, 1=K1, ...）。
Map<int, List<double>> computeAllKnTickCountSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0TickCountSeries(bars),
    levels: levels,
    bars: bars,
  );
}

/// All Kn 买入笔数系列，用于红绿叠柱。
Map<int, List<double>> computeAllKnBuyTickCountSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0BuyTickCountSeries(bars),
    levels: levels,
    bars: bars,
  );
}

List<double> computeKnVolumeSeries({
  required List<KlineBar> bars,
  required LevelBundle bundle,
  List<double>? lowerIncrements,
}) {
  return _accumulateConfirmGated(
    lowerIncrements: lowerIncrements ?? computeK0VolumeSeries(bars),
    bundle: bundle,
    bars: bars,
  );
}

List<double> _accumulateConfirmGated({
  required List<double> lowerIncrements,
  required LevelBundle bundle,
  required List<KlineBar> bars,
}) {
  final n = bars.length;
  final out = List<double>.filled(n, 0.0);
  if (n == 0) return out;
  final idxToI = <int, int>{for (var i = 0; i < n; i++) bars[i].idx: i};
  final lastIdx = bars.last.idx;

  final units = <LevelUnitBar>[
    ...bundle.unitBars,
    if (bundle.activeUnit != null) bundle.activeUnit!,
  ];
  if (units.isEmpty) return out;

  LevelUnitBar? prev;
  for (final u in units) {
    final isActiveTail =
        bundle.activeUnit != null && identical(u, bundle.activeUnit);

    late final int sumStart;
    late final int displayStart;
    if (prev == null) {
      sumStart = u.x1 >= 0 ? u.x1 : 0;
      displayStart = sumStart;
    } else {
      sumStart = prev.x2 + 1;
      displayStart =
          prev.confirmX >= 0 ? prev.confirmX : (prev.x2 + 1);
    }

    final int endX;
    if (isActiveTail) {
      endX = lastIdx;
    } else if (u.confirmX >= 0) {
      endX = u.confirmX - 1;
    } else {
      endX = u.x2;
    }
    if (endX < sumStart) {
      prev = u;
      continue;
    }

    var run = 0.0;
    for (var x = sumStart; x <= endX; x++) {
      final i = idxToI[x];
      if (i == null) continue;
      run += lowerIncrements[i];
      if (x >= displayStart) {
        out[i] = run;
      }
    }
    prev = u;
  }
  return out;
}

/// 构建 K0 idx → Kn unit bar index 映射。
Map<int, int> buildKnUnitIdxMap(LevelBundle bundle) {
  final map = <int, int>{};
  final units = <LevelUnitBar>[
    ...bundle.unitBars,
    if (bundle.activeUnit != null) bundle.activeUnit!,
  ];
  for (var ui = 0; ui < units.length; ui++) {
    final u = units[ui];
    for (var x = u.x1; x <= u.x2; x++) {
      map[x] = ui;
    }
  }
  return map;
}

List<double> _cumulativeToIncrements(List<double> series) {
  final n = series.length;
  if (n == 0) return const [];
  final incr = List<double>.filled(n, 0.0);
  incr[0] = series[0];
  for (var i = 1; i < n; i++) {
    final v = series[i];
    if (v == 0) {
      incr[i] = 0;
      continue;
    }
    final prev = series[i - 1];
    if (prev == 0 || v < prev) {
      incr[i] = v;
    } else {
      incr[i] = v - prev;
    }
  }
  return incr;
}