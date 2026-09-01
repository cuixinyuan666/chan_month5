import '../models/bar_crosshair_feature.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// K0 volume: native bars[].volume.
List<double> computeK0VolumeSeries(List<KlineBar> bars) {
  return [for (final b in bars) b.volume];
}

/// K0 buy volume: 从 chip_tick_bins 或 tick_side 估算买入量。
/// 副图叠柱仍用「买 vs 非买」（无 bins 时可 50%）；与 tip B/S/G 三分解不同源——
/// ML 以 [computeK0VolumeBsgSeries] / metrics 为准，勿把副图买柱当 tip B。
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

/// K0 成交量 B/S/G 三分解（G=gray/灰度）；有 bins 时按 b+s+w 占比分 volume，否则按 tick_side；无方向则全归 G。
List<({double b, double s, double g})> computeK0VolumeBsgSeries(
    List<KlineBar> bars) {
  return [for (final bar in bars) _k0VolumeBsg(bar)];
}

({double b, double s, double g}) _k0VolumeBsg(KlineBar bar) {
  final bins = bar.metrics['chip_tick_bins'];
  if (bins is Map) {
    final bQty = _sumBins(bins['b']);
    final sQty = _sumBins(bins['s']);
    final wQty = _sumBins(bins['w']);
    final total = bQty + sQty + wQty;
    if (total > 0) {
      return (
        b: bar.volume * bQty / total,
        s: bar.volume * sQty / total,
        g: bar.volume * wQty / total,
      );
    }
  }
  final side = bar.metrics['tick_side'];
  if (side == 'B') return (b: bar.volume, s: 0, g: 0);
  if (side == 'S') return (b: 0, s: bar.volume, g: 0);
  return (b: 0, s: 0, g: bar.volume);
}

List<double> computeK0SellVolumeSeries(List<KlineBar> bars) =>
    [for (final e in computeK0VolumeBsgSeries(bars)) e.s];

List<double> computeK0GrayVolumeSeries(List<KlineBar> bars) =>
    [for (final e in computeK0VolumeBsgSeries(bars)) e.g];

/// tooltip 用买入量（与 B/S/G 同源三分解的 B，可与副图 buy 略异）。
List<double> computeK0BuyVolumeBsgSeries(List<KlineBar> bars) =>
    [for (final e in computeK0VolumeBsgSeries(bars)) e.b];

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

/// K0 tick count: 优先 Rust 真实笔数 metrics.tick_count（分笔第4列；显式0即为0）；
/// 旧数据回退 chip_tick_bins 数组长度；再无 tick 数据时回退到 tick_side。
/// 含 w（灰度）笔，与 _tickSideColor 三态一致。
List<double> computeK0TickCountSeries(List<KlineBar> bars) {
  double tickCount(KlineBar b) {
    final m = b.metrics['tick_count'];
    // 键存在即用（含 0）；勿用 >0 判断，否则显式0会误回退成 bins 长度/1
    if (m is num) return m.toDouble();
    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      final bLen = _listLen(bins['b']);
      final sLen = _listLen(bins['s']);
      final wLen = _listLen(bins['w']);
      if (bLen + sLen + wLen > 0) return (bLen + sLen + wLen).toDouble();
    }
    // 无逐笔数据时回退到 tick_side 方向（B/S 各算 1 笔）
    final side = b.metrics['tick_side'];
    if (side == 'B' || side == 'S') return 1;
    return 0;
  }
  return [for (final b in bars) tickCount(b)];
}

/// K0 buy tick count: 优先 Rust 真实买入笔数 metrics.buy_tick_count（含显式 0）；
/// 旧数据回退 chip_tick_bins 数组长度；再无 tick 数据时回退到 tick_side。
/// 灰笔 (w) 不计入买入笔数。
List<double> computeK0BuyTickCountSeries(List<KlineBar> bars) {
  double buyTick(KlineBar b) {
    final m = b.metrics['buy_tick_count'];
    if (m is num) return m.toDouble(); // 含 0，勿 >0 再回退
    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      final bLen = _listLen(bins['b']);
      if (bLen > 0) return bLen.toDouble();
    }
    // 无逐笔数据时回退到 tick_side 方向
    final side = b.metrics['tick_side'];
    if (side == 'B') return 1;
    return 0;
  }
  return [for (final b in bars) buyTick(b)];
}

/// K0 卖出笔数：优先 metrics.sell_tick_count；回退 bins['s'] 长度 / tick_side。
List<double> computeK0SellTickCountSeries(List<KlineBar> bars) {
  double sellTick(KlineBar b) {
    final m = b.metrics['sell_tick_count'];
    if (m is num) return m.toDouble();
    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      final sLen = _listLen(bins['s']);
      if (sLen > 0) return sLen.toDouble();
    }
    final side = b.metrics['tick_side'];
    if (side == 'S') return 1;
    return 0;
  }
  return [for (final b in bars) sellTick(b)];
}

/// K0 灰笔数：优先 bins['w']；否则 total−buy−sell（夹到 ≥0）。
List<double> computeK0GrayTickCountSeries(List<KlineBar> bars) {
  final total = computeK0TickCountSeries(bars);
  final buy = computeK0BuyTickCountSeries(bars);
  final sell = computeK0SellTickCountSeries(bars);
  final out = <double>[];
  for (var i = 0; i < bars.length; i++) {
    final bins = bars[i].metrics['chip_tick_bins'];
    if (bins is Map) {
      final wLen = _listLen(bins['w']);
      if (wLen > 0 ||
          _listLen(bins['b']) + _listLen(bins['s']) + wLen > 0) {
        out.add(wLen.toDouble());
        continue;
      }
    }
    final g = total[i] - buy[i] - sell[i];
    out.add(g > 0 ? g : 0);
  }
  return out;
}

int _listLen(dynamic binData) {
  if (binData is List) return binData.length;
  return 0;
}

/// 内部复用：从 K0 系列出发，逐一累积各层确认门控系列。
Map<int, List<double>> computeAllKnFromK0Series({
  required List<double> k0Series,
  required List<LevelBundle> levels,
  required List<KlineBar> bars,
}) {
  return _computeAllKnFromK0(
    k0Series: k0Series,
    levels: levels,
    bars: bars,
  );
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

  // 方案B：structure level L → display kn=L+1（K0 已在 out[0]）
  final sorted = [...levels]..sort((a, b) => a.level.compareTo(b.level));
  for (final bundle in sorted) {
    final displayKn = bundle.level + 1;
    if (displayKn < 1) continue;
    final series = _accumulateConfirmGated(
      lowerIncrements: increments,
      bundle: bundle,
      bars: bars,
    );
    out[displayKn] = series;
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

/// All Kn tooltip 用买入量（B/S/G 三分解的 B）。
Map<int, List<double>> computeAllKnBuyVolumeBsgSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0BuyVolumeBsgSeries(bars),
    levels: levels,
    bars: bars,
  );
}

/// All Kn 卖出量系列（tooltip B/S/G）。
Map<int, List<double>> computeAllKnSellVolumeSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0SellVolumeSeries(bars),
    levels: levels,
    bars: bars,
  );
}

/// All Kn 灰量系列（tooltip G）。
Map<int, List<double>> computeAllKnGrayVolumeSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0GrayVolumeSeries(bars),
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

/// All Kn 卖出笔数系列（tooltip B/S/G）。
Map<int, List<double>> computeAllKnSellTickCountSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0SellTickCountSeries(bars),
    levels: levels,
    bars: bars,
  );
}

/// All Kn 灰笔数系列（tooltip G）。
Map<int, List<double>> computeAllKnGrayTickCountSeries({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  List<BarCrosshairFeature> barFeatures = const [],
}) {
  return _computeAllKnFromK0(
    k0Series: computeK0GrayTickCountSeries(bars),
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