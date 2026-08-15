import '../compute/kn_ohlc_sample_compute.dart';
import '../compute/math_classic_compute.dart';
import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'signal_data_catalog.dart';
import 'trade_value.dart';

/// 按当步 K0 索引读「当时能看见」的值（plot/asOf）。
/// CROSS / 比较请走 [readEvalClockSeries]，不要拿铺平阶梯当穿越。
TradeScalar lookupTradeNumeric({
  required String variableId,
  required int asOf,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathSeriesFreezeStore? mathFreeze,
  int bollN = 20,
}) {
  if (bars.isEmpty || asOf < 0) return const TradeScalar.unavailable();

  final def = lookupTradeVariable(variableId, maxKn: 32);
  if (def == null || !def.expressionReady) {
    return const TradeScalar.unavailable();
  }

  final parsed = _parseId(variableId);
  if (parsed == null) return const TradeScalar.unavailable();

  if (parsed.panel == 'RAW') {
    return _lookupRaw(
      kn: parsed.kn,
      field: parsed.rest,
      asOf: asOf,
      bars: bars,
      levels: levels,
    );
  }
  if (parsed.panel == 'MAIN' &&
      parsed.rest.length >= 2 &&
      parsed.rest[0] == 'BOLL') {
    return _lookupBoll(
      kn: parsed.kn,
      band: parsed.rest[1],
      asOf: asOf,
      bars: bars,
      levels: levels,
      mathFreeze: mathFreeze,
      bollN: bollN,
    );
  }
  return const TradeScalar.unavailable();
}

({String panel, int kn, List<String> rest})? _parseId(String id) {
  final parts = id.split('.');
  if (parts.length < 3) return null;
  final knTok = parts[1];
  if (!knTok.startsWith('K')) return null;
  final kn = int.tryParse(knTok.substring(1));
  if (kn == null || kn < 0) return null;
  return (panel: parts[0], kn: kn, rest: parts.sublist(2));
}

TradeScalar _lookupRaw({
  required int kn,
  required List<String> field,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
}) {
  if (field.length != 1) return const TradeScalar.unavailable();
  final f = field[0];
  if (kn == 0) {
    KlineBar? bar;
    for (final b in bars) {
      if (b.idx == asOf) {
        bar = b;
        break;
      }
    }
    if (bar == null) return const TradeScalar.unavailable();
    switch (f) {
      case 'OPEN':
        return TradeScalar.num(bar.open);
      case 'HIGH':
        return TradeScalar.num(bar.high);
      case 'LOW':
        return TradeScalar.num(bar.low);
      case 'CLOSE':
        return TradeScalar.num(bar.close);
      case 'VOLUME':
        return TradeScalar.num(bar.volume);
      default:
        return const TradeScalar.unavailable();
    }
  }
  if (f == 'VOLUME') return const TradeScalar.unavailable();
  final samples = collectKnOhlcSamples(
    displayKn: kn,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final pts = <({int x, double v})>[];
  for (final s in samples) {
    final v = switch (f) {
      'OPEN' => s.open,
      'HIGH' => s.high,
      'LOW' => s.low,
      'CLOSE' => s.close,
      _ => null,
    };
    if (v == null) continue;
    pts.add((x: s.endX, v: v));
  }
  final series = expandPointsToK0(pts, bars.length, asOf: asOf);
  if (asOf >= series.length) return const TradeScalar.unavailable();
  final v = series[asOf];
  if (v == null) return const TradeScalar.unavailable();
  return TradeScalar.num(v);
}

TradeScalar _lookupBoll({
  required int kn,
  required String band,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required MathSeriesFreezeStore? mathFreeze,
  required int bollN,
}) {
  List<double?>? series;
  if (mathFreeze == null) {
    // 交易/回测禁止现算第二套布林；没有冻结仓就是不可用
    return const TradeScalar.unavailable();
  }
  series = _bollField(mathFreeze.boll(kn), band);
  if (series == null || asOf >= series.length) {
    return const TradeScalar.unavailable();
  }
  final v = series[asOf];
  if (v == null) return const TradeScalar.unavailable();
  return TradeScalar.num(v);
}

/// evalClock 上的一个样本：条件/穿越只走这里，不走铺平后的 K0 阶梯。
class EvalClockPoint {
  /// 该钟上的样本序号（0 起）
  final int evalIndex;
  /// 当时系统能知道这点的 K0 索引（成交也用这根轴）
  final int availableAt;
  final double value;

  const EvalClockPoint({
    required this.evalIndex,
    required this.availableAt,
    required this.value,
  });
}

/// 读变量在 evalClock 上的样本序列（asOf 截断）。
/// CROSS 必须用这份；[lookupTradeNumeric] 是当根 K0 能看见的 plot/asOf 读数。
List<EvalClockPoint> readEvalClockSeries({
  required String variableId,
  required int asOf,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathSeriesFreezeStore? mathFreeze,
  int bollN = 20,
}) {
  if (bars.isEmpty || asOf < 0) return const [];
  final def = lookupTradeVariable(variableId, maxKn: 32);
  if (def == null || !def.expressionReady) return const [];
  final parsed = _parseId(variableId);
  if (parsed == null) return const [];

  if (parsed.panel == 'RAW') {
    if (parsed.rest.length != 1) return const [];
    return _rawEvalSeries(
      kn: parsed.kn,
      field: parsed.rest[0],
      asOf: asOf,
      bars: bars,
      levels: levels,
    );
  }
  if (parsed.panel == 'MAIN' &&
      parsed.rest.length >= 2 &&
      parsed.rest[0] == 'BOLL') {
    return _bollEvalSeries(
      kn: parsed.kn,
      band: parsed.rest[1],
      asOf: asOf,
      bars: bars,
      levels: levels,
      mathFreeze: mathFreeze,
      bollN: bollN,
    );
  }
  return const [];
}

List<EvalClockPoint> _rawEvalSeries({
  required int kn,
  required String field,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
}) {
  if (kn == 0) {
    final out = <EvalClockPoint>[];
    var i = 0;
    for (final b in bars) {
      if (b.idx > asOf) continue;
      final v = switch (field) {
        'OPEN' => b.open,
        'HIGH' => b.high,
        'LOW' => b.low,
        'CLOSE' => b.close,
        'VOLUME' => b.volume,
        _ => null,
      };
      if (v == null) continue;
      out.add(EvalClockPoint(evalIndex: i, availableAt: b.idx, value: v));
      i++;
    }
    return out;
  }
  if (field == 'VOLUME') return const [];
  final samples = collectKnOhlcSamples(
    displayKn: kn,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final out = <EvalClockPoint>[];
  for (var i = 0; i < samples.length; i++) {
    final s = samples[i];
    final v = switch (field) {
      'OPEN' => s.open,
      'HIGH' => s.high,
      'LOW' => s.low,
      'CLOSE' => s.close,
      _ => null,
    };
    if (v == null) continue;
    out.add(EvalClockPoint(evalIndex: i, availableAt: s.endX, value: v));
  }
  return out;
}

List<EvalClockPoint> _bollEvalSeries({
  required int kn,
  required String band,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required MathSeriesFreezeStore? mathFreeze,
  required int bollN,
}) {
  List<double?>? plot;
  if (mathFreeze == null) {
    return const [];
  }
  plot = _bollField(mathFreeze.boll(kn), band);
  if (plot == null) return const [];

  if (kn <= 0) {
    final out = <EvalClockPoint>[];
    var i = 0;
    for (final b in bars) {
      if (b.idx > asOf) continue;
      if (b.idx >= plot.length) continue;
      final v = plot[b.idx];
      if (v == null) continue;
      out.add(EvalClockPoint(evalIndex: i, availableAt: b.idx, value: v));
      i++;
    }
    return out;
  }

  final samples = collectKnOhlcSamples(
    displayKn: kn,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final out = <EvalClockPoint>[];
  for (var i = 0; i < samples.length; i++) {
    final x = samples[i].endX;
    if (x < 0 || x >= plot.length) continue;
    final v = plot[x];
    if (v == null) continue;
    // 取样本右端那一格：那是该虚拟K上算出的布林，不是中间被铺平的持值
    out.add(EvalClockPoint(evalIndex: i, availableAt: x, value: v));
  }
  return out;
}

List<double?>? _bollField(BollK0Series? b, String band) {
  if (b == null) return null;
  switch (band) {
    case 'MID':
      return b.mid;
    case 'UP':
      return b.up;
    case 'DOWN':
      return b.down;
    default:
      return null;
  }
}
