import '../compute/kn_ohlc_sample_compute.dart';
import '../compute/math_classic_compute.dart';
import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'buy_n_var.dart';
import 'divergence_relation.dart';
import 'divergence_relation_store.dart';
import 'signal_data_catalog.dart';
import 'structure_object.dart';
import 'trade_value.dart';
import 'zhongshu_object_store.dart';

/// 按当步 K0 索引读「当时能看见」的值（plot/asOf）。
/// CROSS / 比较请走 [readEvalClockSeries]，不要拿铺平阶梯当穿越。
TradeScalar lookupTradeNumeric({
  required String variableId,
  required int asOf,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  MathSeriesFreezeStore? mathFreeze,
  ZhongshuObjectStore? zsObjects,
  DivergenceRelationStore? diverRelations,
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
  final zs = _lookupZsCurrent(
    parsed: parsed,
    asOf: asOf,
    zsObjects: zsObjects,
  );
  if (zs != null) return zs;
  final diver = _lookupDiverProjection(
    parsed: parsed,
    asOf: asOf,
    diverRelations: diverRelations,
  );
  if (diver != null) return diver;
  return _lookupFrozenPlot(
    parsed: parsed,
    asOf: asOf,
    mathFreeze: mathFreeze,
  );
}

({String panel, int kn, List<String> rest})? _parseId(String id) {
  final parts = canonicalizeTradeVarId(id).split('.');
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

/// 图上/十字用的铺平格子：只读冻结仓，禁止现算第二套 MACD/RSI/KDJ/布林。
TradeScalar _lookupFrozenPlot({
  required ({String panel, int kn, List<String> rest}) parsed,
  required int asOf,
  required MathSeriesFreezeStore? mathFreeze,
}) {
  if (mathFreeze == null) return const TradeScalar.unavailable();
  final series = frozenPlotSeries(parsed: parsed, store: mathFreeze);
  if (series == null || asOf < 0 || asOf >= series.length) {
    return const TradeScalar.unavailable();
  }
  final v = series[asOf];
  if (v == null) return const TradeScalar.unavailable();
  return TradeScalar.num(v);
}

/// 从冻结仓取出与图上同一份 K0 格子序列。没有仓/对不上字段 → null。
List<double?>? frozenPlotSeries({
  required ({String panel, int kn, List<String> rest}) parsed,
  required MathSeriesFreezeStore store,
}) {
  if (parsed.panel == 'MAIN' &&
      parsed.rest.length >= 2 &&
      parsed.rest[0] == 'BOLL') {
    return _bollField(store.boll(parsed.kn), parsed.rest[1]);
  }
  if (parsed.panel != 'SUB' || parsed.rest.isEmpty) return null;
  switch (parsed.rest[0]) {
    case 'MACD':
      if (parsed.rest.length < 2) return null;
      final m = store.macd(parsed.kn);
      if (m == null) return null;
      return switch (parsed.rest[1]) {
        'DIF' => m.dif,
        'DEA' => m.dea,
        'HIST' => m.macd,
        _ => null,
      };
    case 'RSI':
      if (parsed.rest.length < 2 || parsed.rest[1] != 'VALUE') return null;
      return store.rsi(parsed.kn);
    case 'KDJ':
      if (parsed.rest.length < 2) return null;
      final k = store.kdj(parsed.kn);
      if (k == null) return null;
      return switch (parsed.rest[1]) {
        'K' => k.k,
        'D' => k.d,
        'J' => k.j,
        _ => null,
      };
    default:
      return null;
  }
}

({String panel, int kn, List<String> rest})? parseTradeVariableId(String id) =>
    _parseId(id);

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
  ZhongshuObjectStore? zsObjects,
  DivergenceRelationStore? diverRelations,
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
  final zsProj = _zsProjectionOf(parsed);
  if (zsProj != null) {
    return _zsCurrentEvalSeries(
      kn: parsed.kn,
      projection: zsProj,
      asOf: asOf,
      bars: bars,
      levels: levels,
      zsObjects: zsObjects,
    );
  }
  final diverField = _diverProjectionField(parsed);
  if (diverField != null) {
    return _diverEvalSeries(
      kn: parsed.kn,
      field: diverField,
      asOf: asOf,
      bars: bars,
      levels: levels,
      diverRelations: diverRelations,
    );
  }
  if (mathFreeze == null) return const [];
  final plot = frozenPlotSeries(parsed: parsed, store: mathFreeze);
  if (plot == null) return const [];
  return _plotEvalSeries(
    kn: parsed.kn,
    plot: plot,
    asOf: asOf,
    bars: bars,
    levels: levels,
  );
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

/// 冻结仓是 K0 格子；条件只在 evalClock 样本上取（K0 每根，Kn 取虚拟K右端）。
List<EvalClockPoint> _plotEvalSeries({
  required int kn,
  required List<double?> plot,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
}) {
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

ZsProjection? _zsProjectionOf(
  ({String panel, int kn, List<String> rest}) parsed,
) {
  if (parsed.panel != 'STRUCTURE') return null;
  if (parsed.rest.length != 3) return null;
  if (parsed.rest[0] != 'ZS' || parsed.rest[1] != 'CURRENT') return null;
  return switch (parsed.rest[2]) {
    'HIGH' => ZsProjection.high,
    'LOW' => ZsProjection.low,
    'CENTER' => ZsProjection.center,
    _ => null,
  };
}

/// 没有确认中枢 → 不可用（不是 0）。
TradeScalar? _lookupZsCurrent({
  required ({String panel, int kn, List<String> rest}) parsed,
  required int asOf,
  required ZhongshuObjectStore? zsObjects,
}) {
  final proj = _zsProjectionOf(parsed);
  if (proj == null) return null;
  if (zsObjects == null || zsObjects.isEmpty) {
    return const TradeScalar.unavailable();
  }
  final v = zsObjects.projectCurrent(
    displayKn: parsed.kn,
    asOf: asOf,
    projection: proj,
  );
  if (v == null) return const TradeScalar.unavailable();
  return TradeScalar.num(v);
}

/// 中枢投影跟该层收盘同一套计算钟：K0 一根一根，K1+ 虚拟K右端。
List<EvalClockPoint> _zsCurrentEvalSeries({
  required int kn,
  required ZsProjection projection,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required ZhongshuObjectStore? zsObjects,
}) {
  if (zsObjects == null || zsObjects.isEmpty) return const [];
  final grid = _rawEvalSeries(
    kn: kn,
    field: 'CLOSE',
    asOf: asOf,
    bars: bars,
    levels: levels,
  );
  final out = <EvalClockPoint>[];
  var i = 0;
  for (final g in grid) {
    final v = zsObjects.projectCurrent(
      displayKn: kn,
      asOf: g.availableAt,
      projection: projection,
    );
    if (v == null) continue;
    out.add(EvalClockPoint(
      evalIndex: i,
      availableAt: g.availableAt,
      value: v,
    ));
    i++;
  }
  return out;
}

/// RATIO / DIRECTION。EXISTS 是事件，不走这里。
String? _diverProjectionField(
  ({String panel, int kn, List<String> rest}) parsed,
) {
  if (parsed.panel != 'STRUCTURE') return null;
  if (parsed.rest.length != 2) return null;
  if (parsed.rest[0] != 'DIVERGENCE') return null;
  final f = parsed.rest[1];
  if (f == 'RATIO' || f == 'DIRECTION') return f;
  return null;
}

/// 没有当时可见的确认背驰关系 → 不可用（不是 0）。
TradeScalar? _lookupDiverProjection({
  required ({String panel, int kn, List<String> rest}) parsed,
  required int asOf,
  required DivergenceRelationStore? diverRelations,
}) {
  final field = _diverProjectionField(parsed);
  if (field == null) return null;
  if (diverRelations == null || diverRelations.isEmpty) {
    return const TradeScalar.unavailable();
  }
  final rel = diverRelations.resolveCurrent(
    displayKn: parsed.kn,
    asOf: asOf,
  );
  if (rel == null) return const TradeScalar.unavailable();
  if (field == 'RATIO') {
    final r = rel.ratio;
    if (r == null) return const TradeScalar.unavailable();
    return TradeScalar.num(r);
  }
  return TradeScalar.num(divergenceDirectionCode(rel.direction));
}

/// 背驰投影跟该层收盘同一套计算钟：K0 一根一根，K1+ 虚拟K右端。
List<EvalClockPoint> _diverEvalSeries({
  required int kn,
  required String field,
  required int asOf,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required DivergenceRelationStore? diverRelations,
}) {
  if (diverRelations == null || diverRelations.isEmpty) return const [];
  final grid = _rawEvalSeries(
    kn: kn,
    field: 'CLOSE',
    asOf: asOf,
    bars: bars,
    levels: levels,
  );
  final out = <EvalClockPoint>[];
  var i = 0;
  for (final g in grid) {
    final rel = diverRelations.resolveCurrent(
      displayKn: kn,
      asOf: g.availableAt,
    );
    if (rel == null) continue;
    double? v;
    if (field == 'RATIO') {
      v = rel.ratio;
    } else if (field == 'DIRECTION') {
      v = divergenceDirectionCode(rel.direction);
    }
    if (v == null) continue;
    out.add(EvalClockPoint(
      evalIndex: i,
      availableAt: g.availableAt,
      value: v,
    ));
    i++;
  }
  return out;
}
