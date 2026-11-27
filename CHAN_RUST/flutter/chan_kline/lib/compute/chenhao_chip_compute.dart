import 'dart:collection';
import 'dart:math' as math;

import '../models/kline_bar.dart';

/// 陈浩《筹码分布》的一套近似。
///
/// 只读当根及以前的 K。没有流通股本，也不改主图坐标、不改 K 线画法。
/// 获利盘、套牢盘、活动筹码、相对价位、成本重心、成本带宽、密集形态、
/// 下移法、横盘法、博弈 K 线长、90 比 3 都从同一套价格分档里读。
/// 成本均线 / 市场盈亏另走成交量加权，不跟分档直方图强行绑死。
class ChenhaoChip {
  ChenhaoChip._();

  /// 价格分档上限。区间变宽时把旧档重新并进这 96 档，避免每根 K 无界涨内存。
  static const maxBins = 96;

  /// 「近一年」按时间戳往回一个自然年，不写死 250 根。
  static const yearMs = 365.25 * 24 * 3600 * 1000;

  /// 活动筹码：收盘价上下各 10%。
  static const asrBand = 0.10;

  /// 90 比 3 的量能窗口。不足这么多根时，用已经走出的根数。
  static const quietLookback = 20;

  /// 近似换手：当根成交量 / 近 [quietLookback] 根成交量之和。低于这个数才算「很安静」。
  /// 这不是书里的真换手率（真换手率要流通股本）。
  static const quietShare = 0.03;

  static const profitHot = 0.90;

  /// 横盘：近这么多根的最高最低之差，小于收盘价的 [sidewaysRange]。
  /// 项目里没有现成的「波动收窄」口径，这里用这个阈值顶上。不满窗口不算横盘。
  static const sidewaysBars = 20;
  static const sidewaysRange = 0.06;

  /// 下移法里的「低价」：至今最高、最低价之间，靠下的这一段。
  static const lowBand = 0.30;

  static const noteK0 =
      '只挂在 K0 原始成交 K 上，不套到 K1 及以上的合并 K。';
  static const noteBins =
      '价格只分 96 档。区间变宽时旧档会重新并进去，不是指南针那种无限细的横向直方图。';
  static const noteNoCapital =
      'K 线没有流通股本。筹码衰减用「近一个自然年成交量之和」当流通量替身：'
      '当根量 / 这一年的量。历史不够一年，就用已经走出的全部量。一年按时间戳往回 365 天，不写死 250 根。';
  static const noteNoHistogram =
      '主图不画横向筹码直方图，免得改价格坐标。筹码分布改在副图看密集度和形态。';
  static const noteCyc =
      '成本均线不是收盘价均线，也不跟筹码分档绑死。有成交额并且有量时，这一根的价格用额/量；'
      '否则用 (高+低+收)/3，再按成交量加权。5、13、34 是这么卷的窗口。'
      '无穷成本是递推：上一根成本乘 (1-换手替身)，再加上这一根价格乘换手替身，只用当根及以前。';
  static const noteMyp =
      '近似，非书中原文。近一年最高价相对现价还能赚多少：(一年最高-收盘)/收盘。'
      '一年按时间戳往回 365 天，不写死 250 根。';
  static const noteNinety =
      '近似，不是真换手率。获利盘大于 90%，并且当根成交量占近 20 根成交量之和的比例小于 3%。'
      '不足 20 根时用已经走出的根数。没有流通股本，不能把这个数叫换手率。';
  static const noteSideways =
      '项目里没有现成的波动收窄口径。横盘 = 近 20 根最高价减最低价，小于收盘价的 6%。'
      '不满 20 根不算横盘。横盘法 = 这段价格区间里还留着的筹码比例；不是横盘时为 0。';
  static const noteShift =
      '下移法近似：至今最高、最低价之间靠下 30% 的区间里，并且低于现价的那部分筹码比例。'
      '用来估「涨上去以后仍停在低价」的获利筹码。价格还挤在底部时，这个数不能直接当成主力仓位。';
  static const noteCyqk =
      '不改 K 线本体画法。博弈 K 线长 = 这一根最高到最低穿过的筹码比例。'
      '穿过密区 = 这段价格里的筹码比它占的价格宽度更密；走在稀区 = 更稀。';
  static const noteShape =
      '形态数字：0 发散、1 单峰低位、2 单峰高位、3 低位锁定、4 双峰。'
      '高低是相对「至今最高价、最低价」，不是相对分档自己的跨度。'
      '现价已经明显离开低位峰值，记成低位锁定。密集度 = 至今价格跨度里最密的两成宽度所装的筹码比例。';
  static const noteSpread =
      '这一根的成交量均匀铺进它的最高价到最低价。高低一样时，整根量落在收盘价那一档。';
}

enum ChenhaoField {
  cyc5,
  cyc13,
  cyc34,
  cycInf,
  cys5,
  cys13,
  cys34,
  cysInf,
  winner,
  trapped,
  concentration,
  shape,
  cyqkLen,
  cyqkZone,
  asr,
  ckdp,
  ckdw,
  cbw,
  rpy,
  myp,
  shiftDown,
  sideways,
  ninety3,
}

/// 一根 K 上能读到的筹码读数。空着的字段表示这一根还算不出来。
class ChenhaoSnap {
  const ChenhaoSnap({
    this.cyc5,
    this.cyc13,
    this.cyc34,
    this.cycInf,
    this.cys5,
    this.cys13,
    this.cys34,
    this.cysInf,
    this.winner,
    this.trapped,
    this.concentration,
    this.shape,
    this.cyqkLen,
    this.cyqkZone,
    this.asr,
    this.ckdp,
    this.ckdw,
    this.cbw,
    this.rpy,
    this.myp,
    this.shiftDown,
    this.sideways = 0,
    this.ninety3 = 0,
  });

  final double? cyc5;
  final double? cyc13;
  final double? cyc34;
  final double? cycInf;
  final double? cys5;
  final double? cys13;
  final double? cys34;
  final double? cysInf;
  final double? winner;
  final double? trapped;
  final double? concentration;
  final int? shape;
  final double? cyqkLen;
  final int? cyqkZone;
  final double? asr;
  final double? ckdp;
  final double? ckdw;
  final double? cbw;
  final double? rpy;
  final double? myp;
  final double? shiftDown;
  final double sideways;
  final int ninety3;

  double? read(ChenhaoField field) {
    switch (field) {
      case ChenhaoField.cyc5:
        return cyc5;
      case ChenhaoField.cyc13:
        return cyc13;
      case ChenhaoField.cyc34:
        return cyc34;
      case ChenhaoField.cycInf:
        return cycInf;
      case ChenhaoField.cys5:
        return cys5;
      case ChenhaoField.cys13:
        return cys13;
      case ChenhaoField.cys34:
        return cys34;
      case ChenhaoField.cysInf:
        return cysInf;
      case ChenhaoField.winner:
        return winner;
      case ChenhaoField.trapped:
        return trapped;
      case ChenhaoField.concentration:
        return concentration;
      case ChenhaoField.shape:
        return shape?.toDouble();
      case ChenhaoField.cyqkLen:
        return cyqkLen;
      case ChenhaoField.cyqkZone:
        return cyqkZone?.toDouble();
      case ChenhaoField.asr:
        return asr;
      case ChenhaoField.ckdp:
        return ckdp;
      case ChenhaoField.ckdw:
        return ckdw;
      case ChenhaoField.cbw:
        return cbw;
      case ChenhaoField.rpy:
        return rpy;
      case ChenhaoField.myp:
        return myp;
      case ChenhaoField.shiftDown:
        return shiftDown;
      case ChenhaoField.sideways:
        return sideways;
      case ChenhaoField.ninety3:
        return ninety3.toDouble();
    }
  }
}

class ChenhaoSeries {
  ChenhaoSeries(this.byIdx);

  final Map<int, ChenhaoSnap> byIdx;

  static final empty = ChenhaoSeries(const {});

  ChenhaoSnap? atIdx(int idx) => byIdx[idx];

  double? read(int idx, ChenhaoField field) => byIdx[idx]?.read(field);

  /// 跟 [bars] 对齐的一列，给主图 / 副图按根去画。
  List<double?> column(List<KlineBar> bars, ChenhaoField field) {
    return [for (final b in bars) read(b.idx, field)];
  }
}

class ChenhaoShapeRead {
  const ChenhaoShapeRead({required this.code, required this.concentration});

  /// 0 发散，1 单峰低位，2 单峰高位，3 低位锁定，4 双峰。
  final int code;
  final double concentration;
}

String chenhaoShapeName(int code) {
  switch (code) {
    case 1:
      return '单峰低位';
    case 2:
      return '单峰高位';
    case 3:
      return '低位锁定';
    case 4:
      return '双峰';
    default:
      return '发散';
  }
}

String chenhaoZoneName(int? zone) {
  if (zone == null) return '无';
  if (zone > 0) return '穿过密区';
  if (zone < 0) return '走在稀区';
  return '中间';
}

String chenhaoPct(double? v) {
  if (v == null || !v.isFinite) return '无';
  return '${(v * 100).toStringAsFixed(1)}%';
}

String chenhaoPx(double? v) {
  if (v == null || !v.isFinite) return '无';
  return v.toStringAsFixed(2);
}

/// 有额有量用额/量，否则用 (高+低+收)/3。这是成本均线的一根价格，不是分档。
double chenhaoBarPrice(KlineBar bar) {
  if (bar.volume > 0 && bar.amount > 0 && bar.amount.isFinite) {
    final px = bar.amount / bar.volume;
    if (px.isFinite && px > 0) return px;
  }
  final h = bar.high.isFinite ? bar.high : bar.close;
  final l = bar.low.isFinite ? bar.low : bar.close;
  final c = bar.close.isFinite ? bar.close : h;
  return (h + l + c) / 3;
}

/// 目录变量 → 字段。不是这套指标时返回 null，调用方继续走别的指标。
ChenhaoField? chenhaoFieldOf({
  required String panel,
  required int kn,
  required List<String> rest,
}) {
  if (kn != 0 || rest.isEmpty) return null;
  if (panel == 'MAIN' && rest.length == 2 && rest[0] == 'CYC') {
    switch (rest[1]) {
      case '5':
        return ChenhaoField.cyc5;
      case '13':
        return ChenhaoField.cyc13;
      case '34':
        return ChenhaoField.cyc34;
      case 'INF':
        return ChenhaoField.cycInf;
    }
    return null;
  }
  if (panel != 'SUB') return null;
  if (rest.length == 2 && rest[0] == 'CYS') {
    switch (rest[1]) {
      case '5':
        return ChenhaoField.cys5;
      case '13':
        return ChenhaoField.cys13;
      case '34':
        return ChenhaoField.cys34;
      case 'INF':
        return ChenhaoField.cysInf;
    }
    return null;
  }
  if (rest.length == 2 && rest[0] == 'CYQ') {
    switch (rest[1]) {
      case 'CONC':
        return ChenhaoField.concentration;
      case 'SHAPE':
        return ChenhaoField.shape;
    }
    return null;
  }
  if (rest.length == 2 && rest[0] == 'CYQK') {
    switch (rest[1]) {
      case 'LEN':
        return ChenhaoField.cyqkLen;
      case 'ZONE':
        return ChenhaoField.cyqkZone;
    }
    return null;
  }
  if (rest.length != 1) return null;
  switch (rest[0]) {
    case 'WINNER':
      return ChenhaoField.winner;
    case 'TRAPPED':
      return ChenhaoField.trapped;
    case 'ASR':
      return ChenhaoField.asr;
    case 'CKDP':
      return ChenhaoField.ckdp;
    case 'CKDW':
      return ChenhaoField.ckdw;
    case 'CBW':
      return ChenhaoField.cbw;
    case 'RPY':
      return ChenhaoField.rpy;
    case 'MYP':
      return ChenhaoField.myp;
    case 'SHIFT':
      return ChenhaoField.shiftDown;
    case 'FLAT':
      return ChenhaoField.sideways;
    case 'NINETY3':
      return ChenhaoField.ninety3;
    default:
      return null;
  }
}

/// 按 K 线顺序正着推。下标 i 的读数只用 0..i。[asOf] 有值时，idx 比它大的根不参加计算。
ChenhaoSeries computeChenhaoSeries(List<KlineBar> bars, {int? asOf}) {
  final engine = _ChenhaoEngine();
  final map = <int, ChenhaoSnap>{};
  for (final bar in bars) {
    if (asOf != null && bar.idx > asOf) continue;
    engine.push(bar);
    map[bar.idx] = engine.snapshot();
  }
  return ChenhaoSeries(map);
}

/// 同一份 K 线列表在长度不变时复用。列表在末尾追加时接着往下推，不从头重算。
class ChenhaoSeriesCache {
  ChenhaoSeriesCache._();

  static int _ident = 0;
  static int _firstMs = 0;
  static int _built = 0;
  static int _lastMs = 0;
  static double _lastClose = 0;
  static _ChenhaoEngine? _engine;
  static Map<int, ChenhaoSnap> _snaps = {};

  static void clear() {
    _ident = 0;
    _firstMs = 0;
    _built = 0;
    _lastMs = 0;
    _lastClose = 0;
    _engine = null;
    _snaps = {};
  }

  static ChenhaoSeries of(List<KlineBar> bars) {
    if (bars.isEmpty) return ChenhaoSeries.empty;
    final ident = identityHashCode(bars);
    final first = bars.first;
    final canExtend = _engine != null &&
        ident == _ident &&
        first.timeMs == _firstMs &&
        _built > 0 &&
        _built <= bars.length &&
        bars[_built - 1].timeMs == _lastMs &&
        bars[_built - 1].close == _lastClose;
    if (!canExtend) {
      _engine = _ChenhaoEngine();
      _snaps = {};
      _ident = ident;
      _firstMs = first.timeMs;
      _built = 0;
    }
    final engine = _engine!;
    for (var i = _built; i < bars.length; i++) {
      final bar = bars[i];
      engine.push(bar);
      _snaps[bar.idx] = engine.snapshot();
      _built = i + 1;
      _lastMs = bar.timeMs;
      _lastClose = bar.close;
    }
    return ChenhaoSeries(Map<int, ChenhaoSnap>.from(_snaps));
  }
}

/// 回测 / 十字取值。不是这套变量时返回 null。
List<double?>? chenhaoPlotSeries({
  required String panel,
  required int kn,
  required List<String> rest,
  required List<KlineBar> bars,
  required int asOf,
}) {
  final field = chenhaoFieldOf(panel: panel, kn: kn, rest: rest);
  if (field == null || bars.isEmpty) return null;
  final series = ChenhaoSeriesCache.of(bars);
  var n = 0;
  for (final b in bars) {
    if (b.idx + 1 > n) n = b.idx + 1;
  }
  if (n <= 0) return null;
  final out = List<double?>.filled(n, null);
  for (final b in bars) {
    if (b.idx < 0 || b.idx >= n || b.idx > asOf) continue;
    out[b.idx] = series.read(b.idx, field);
  }
  return out;
}

void writeChenhaoFeatures({
  required List<KlineBar> bars,
  required Map<int, Map<String, dynamic>> byIdx,
  int? asOf,
}) {
  if (bars.isEmpty) return;
  final series = ChenhaoSeriesCache.of(bars);
  for (final bar in bars) {
    if (asOf != null && bar.idx > asOf) continue;
    final row = byIdx[bar.idx];
    if (row == null) continue;
    final sub = row['sub'];
    if (sub is! Map) continue;
    final snap = series.atIdx(bar.idx);
    if (snap == null) continue;
    writeChenhaoIntoRow(sub, snap);
  }
}

void writeChenhaoIntoRow(Map<dynamic, dynamic> sub, ChenhaoSnap snap) {
  void put(String key, double? value) {
    if (value != null && value.isFinite) sub[key] = value;
  }

  put('cyc_5', snap.cyc5);
  put('cyc_13', snap.cyc13);
  put('cyc_34', snap.cyc34);
  put('cyc_inf', snap.cycInf);
  put('cys_5', snap.cys5);
  put('cys_13', snap.cys13);
  put('cys_34', snap.cys34);
  put('cys_inf', snap.cysInf);
  put('chip_winner', snap.winner);
  put('chip_trapped', snap.trapped);
  put('chip_conc', snap.concentration);
  if (snap.shape != null) {
    sub['chip_shape'] = snap.shape;
    sub['chip_shape_name'] = chenhaoShapeName(snap.shape!);
  }
  put('cyqk_len', snap.cyqkLen);
  if (snap.cyqkZone != null) {
    sub['cyqk_zone'] = snap.cyqkZone;
    sub['cyqk_zone_name'] = chenhaoZoneName(snap.cyqkZone);
  }
  put('chip_asr', snap.asr);
  put('chip_ckdp', snap.ckdp);
  put('chip_ckdw', snap.ckdw);
  put('chip_cbw', snap.cbw);
  put('chip_rpy', snap.rpy);
  put('chip_myp', snap.myp);
  put('chip_shift', snap.shiftDown);
  sub['chip_flat'] = snap.sideways;
  sub['chip_ninety3'] = snap.ninety3;
  sub['cyc_text'] = _joinPx([
    if (snap.cyc5 != null) '5 ${chenhaoPx(snap.cyc5)}',
    if (snap.cyc13 != null) '13 ${chenhaoPx(snap.cyc13)}',
    if (snap.cyc34 != null) '34 ${chenhaoPx(snap.cyc34)}',
    if (snap.cycInf != null) '无穷 ${chenhaoPx(snap.cycInf)}',
  ]);
  sub['cys_text'] = _joinPx([
    if (snap.cys5 != null) '5 ${chenhaoPct(snap.cys5)}',
    if (snap.cys13 != null) '13 ${chenhaoPct(snap.cys13)}',
    if (snap.cys34 != null) '34 ${chenhaoPct(snap.cys34)}',
    if (snap.cysInf != null) '无穷 ${chenhaoPct(snap.cysInf)}',
  ]);
}

String _joinPx(List<String> parts) => parts.isEmpty ? '无' : parts.join(' / ');

/// 副图芯片上的一行读数。对不上的名字返回 null。
String? chenhaoReadout(String kind, Map<dynamic, dynamic> sub) {
  String pctKey(String key) => chenhaoPct(sub[key] is num ? (sub[key] as num).toDouble() : null);
  switch (kind) {
    case 'chipDist':
      final conc = pctKey('chip_conc');
      final name = sub['chip_shape_name'];
      return name is String ? '$conc · $name' : conc;
    case 'winner':
      return pctKey('chip_winner');
    case 'trapped':
      return pctKey('chip_trapped');
    case 'cys':
      final text = sub['cys_text'];
      return text is String ? text : '无';
    case 'cyqk':
      final len = pctKey('cyqk_len');
      final name = sub['cyqk_zone_name'];
      return name is String ? '$len · $name' : len;
    case 'asr':
      return pctKey('chip_asr');
    case 'ckdp':
      return pctKey('chip_ckdp');
    case 'ckdw':
      return pctKey('chip_ckdw');
    case 'cbw':
      return pctKey('chip_cbw');
    case 'rpy':
      return pctKey('chip_rpy');
    case 'myp':
      return pctKey('chip_myp');
    case 'shiftDown':
      return pctKey('chip_shift');
    case 'sideways':
      return pctKey('chip_flat');
    case 'ninetyThree':
      final v = sub['chip_ninety3'];
      if (v is num && v >= 1) return '成立';
      return '不成立';
    case 'costMa':
      final text = sub['cyc_text'];
      return text is String ? text : '无';
    default:
      return null;
  }
}

/// 十字线里 K0 的筹码行。没有这套读数时返回空，不占行。
List<({String label, String value})> chenhaoTooltipLines(Map<dynamic, dynamic>? sub) {
  if (sub == null || !sub.containsKey('chip_ninety3')) return const [];
  String pctKey(String key) =>
      chenhaoPct(sub[key] is num ? (sub[key] as num).toDouble() : null);
  final shape = sub['chip_shape_name'];
  final zone = sub['cyqk_zone_name'];
  final cyc = sub['cyc_text'];
  final cys = sub['cys_text'];
  return [
    (label: '成本均线', value: cyc is String ? cyc : '无'),
    (label: '市场盈亏', value: cys is String ? cys : '无'),
    (label: '获利盘', value: pctKey('chip_winner')),
    (label: '套牢盘', value: pctKey('chip_trapped')),
    (
      label: '筹码分布',
      value: shape is String ? '${pctKey('chip_conc')} · $shape' : pctKey('chip_conc'),
    ),
    (
      label: '博弈K线长',
      value: zone is String ? '${pctKey('cyqk_len')} · $zone' : pctKey('cyqk_len'),
    ),
    (label: '活动筹码', value: pctKey('chip_asr')),
    (label: '相对价位', value: pctKey('chip_ckdp')),
    (label: '成本重心', value: pctKey('chip_ckdw')),
    (label: '成本带宽', value: pctKey('chip_cbw')),
    (label: '年相对价位', value: pctKey('chip_rpy')),
    (label: '最大年收益', value: pctKey('chip_myp')),
    (label: '下移法', value: pctKey('chip_shift')),
    (label: '横盘法', value: pctKey('chip_flat')),
    (
      label: '90比3',
      value: (sub['chip_ninety3'] is num && (sub['chip_ninety3'] as num) >= 1)
          ? '成立'
          : '不成立',
    ),
  ];
}

/// 给单测直接喂分档，不经过换手衰减。
ChenhaoShapeRead classifyChenhaoShape({
  required List<double> bins,
  required double edge,
  required double width,
  required double close,
  required double histLow,
  required double histHigh,
}) {
  return _classify(
    bins: bins,
    edge: edge,
    width: width,
    close: close,
    histLow: histLow,
    histHigh: histHigh,
  );
}

class _Px {
  _Px(this.timeMs, this.high, this.low, this.close, this.volume);
  final int timeMs;
  final double high;
  final double low;
  final double close;
  final double volume;
}

class _VwapWin {
  _VwapWin(this.n);
  final int n;
  final List<({double px, double vol})> q = [];
  double pv = 0;
  double vol = 0;

  double? get value {
    if (vol > 1e-12) return pv / vol;
    return null;
  }

  void add(double px, double volume) {
    if (!px.isFinite || volume <= 0) return;
    q.add((px: px, vol: volume));
    pv += px * volume;
    vol += volume;
    if (q.length > n) {
      final old = q.removeAt(0);
      pv -= old.px * old.vol;
      vol -= old.vol;
      if (vol < 0) vol = 0;
    }
  }
}

class _ChenhaoEngine {
  final List<double> bins = List<double>.filled(ChenhaoChip.maxBins, 0);
  double edge = 0;
  double width = 0;
  bool ready = false;

  final List<_Px> hist = [];
  int volLeft = 0;
  double volSum = 0;
  final Queue<int> hiQ = Queue<int>();
  final Queue<int> loQ = Queue<int>();
  double histLow = double.infinity;
  double histHigh = double.negativeInfinity;

  final _VwapWin w5 = _VwapWin(5);
  final _VwapWin w13 = _VwapWin(13);
  final _VwapWin w34 = _VwapWin(34);
  double? cycInf;

  void push(KlineBar bar) {
    var high = bar.high.isFinite ? bar.high : bar.close;
    var low = bar.low.isFinite ? bar.low : bar.close;
    final close = bar.close.isFinite ? bar.close : high;
    if (high < low) {
      final swap = high;
      high = low;
      low = swap;
    }
    final volume = bar.volume.isFinite && bar.volume > 0 ? bar.volume : 0.0;
    final px = _Px(bar.timeMs, high, low, close, volume);
    hist.add(px);
    if (low < histLow) histLow = low;
    if (high > histHigh) histHigh = high;
    volSum += volume;
    final cut = px.timeMs - ChenhaoChip.yearMs;
    while (volLeft < hist.length - 1 && hist[volLeft].timeMs < cut) {
      volSum -= hist[volLeft].volume;
      volLeft++;
    }
    if (volSum < 0) volSum = 0;
    _pushExtreme(hiQ, px, highSide: true, cut: cut);
    _pushExtreme(loQ, px, highSide: false, cut: cut);

    final hsl = volSum > 0 ? (volume / volSum).clamp(0.0, 0.99) : 0.0;
    if (volume > 0) {
      _ensureCover(low, high);
      if (_total() > 0) _decay(1 - hsl);
      _deposit(low, high, volume);
      final price = chenhaoBarPrice(bar);
      w5.add(price, volume);
      w13.add(price, volume);
      w34.add(price, volume);
      cycInf = cycInf == null ? price : (1 - hsl) * cycInf! + hsl * price;
    }
  }

  void _pushExtreme(Queue<int> q, _Px px, {required bool highSide, required double cut}) {
    final i = hist.length - 1;
    while (q.isNotEmpty) {
      final prev = hist[q.last];
      final drop = highSide ? prev.high <= px.high : prev.low >= px.low;
      if (!drop) break;
      q.removeLast();
    }
    q.addLast(i);
    while (q.isNotEmpty && hist[q.first].timeMs < cut) {
      q.removeFirst();
    }
  }

  double _total() {
    var s = 0.0;
    for (final v in bins) {
      s += v;
    }
    return s;
  }

  void _decay(double keep) {
    for (var i = 0; i < bins.length; i++) {
      final v = bins[i] * keep;
      bins[i] = v < 1e-12 ? 0 : v;
    }
  }

  void _ensureCover(double low, double high) {
    if (!ready || width <= 0) {
      final span = math.max(high - low, math.max(low.abs(), 1) * 0.01);
      width = span / ChenhaoChip.maxBins;
      if (width <= 0) width = 0.01;
      edge = low;
      ready = true;
      return;
    }
    final curHi = edge + width * ChenhaoChip.maxBins;
    if (low >= edge && high <= curHi) return;
    final newLo = math.min(edge, low);
    final newHi = math.max(curHi, high);
    var newW = (newHi - newLo) / ChenhaoChip.maxBins;
    if (newW <= 0) newW = width;
    final next = List<double>.filled(ChenhaoChip.maxBins, 0);
    for (var i = 0; i < bins.length; i++) {
      final mass = bins[i];
      if (mass <= 0) continue;
      final a = edge + i * width;
      _addRange(next, newLo, newW, a, a + width, mass);
    }
    for (var i = 0; i < next.length; i++) {
      bins[i] = next[i];
    }
    edge = newLo;
    width = newW;
  }

  void _deposit(double low, double high, double volume) {
    if ((high - low).abs() <= width * 1e-6) {
      _addPoint(bins, edge, width, (low + high) / 2, volume);
      return;
    }
    _addRange(bins, edge, width, low, high, volume);
  }

  ChenhaoSnap snapshot() {
    final px = hist.last;
    final total = _total();
    final cyc5 = w5.value;
    final cyc13 = w13.value;
    final cyc34 = w34.value;
    double? cysOf(double? cyc) {
      if (cyc == null || cyc.abs() <= 1e-8) return null;
      return (px.close - cyc) / cyc;
    }

    double? winner;
    double? trapped;
    double? concentration;
    int? shape;
    double? cyqkLen;
    int? cyqkZone;
    double? asr;
    double? ckdp;
    double? ckdw;
    double? cbw;
    double? shiftDown;
    var sideways = 0.0;
    if (total > 1e-12 && ready) {
      final split = _splitAt(px.close);
      winner = split.profit / total;
      trapped = split.trapped / total;
      final bounds = _costBounds();
      final minC = bounds.minC;
      final maxC = bounds.maxC;
      final avg = bounds.avg;
      if (minC != null && maxC != null && maxC > minC) {
        ckdp = (px.close - minC) / (maxC - minC);
        if (avg != null) ckdw = (avg - minC) / (maxC - minC);
        if (minC > 1e-8) cbw = (maxC - minC) / minC;
      }
      final loBand = histLow + ChenhaoChip.lowBand * (histHigh - histLow);
      final lowTop = loBand < px.close ? loBand : px.close;
      shiftDown = _massByMid(lowTop) / total;
      asr = _massBetween(px.close * (1 - ChenhaoChip.asrBand), px.close * (1 + ChenhaoChip.asrBand)) /
          total;
      final passed = _massBetween(px.low, px.high);
      cyqkLen = passed / total;
      cyqkZone = _zone(passed / total, px.low, px.high, minC, maxC);
      if (hist.length >= ChenhaoChip.sidewaysBars) {
        final start = hist.length - ChenhaoChip.sidewaysBars;
        var hh = double.negativeInfinity;
        var ll = double.infinity;
        for (var i = start; i < hist.length; i++) {
          if (hist[i].high > hh) hh = hist[i].high;
          if (hist[i].low < ll) ll = hist[i].low;
        }
        final tight = px.close.abs() > 1e-12 &&
            (hh - ll) / px.close.abs() < ChenhaoChip.sidewaysRange;
        sideways = tight ? _massBetween(ll, hh) / total : 0;
      }
      final shaped = _classify(
        bins: bins,
        edge: edge,
        width: width,
        close: px.close,
        histLow: histLow,
        histHigh: histHigh,
      );
      shape = shaped.code;
      concentration = shaped.concentration;
    }

    double? rpy;
    double? myp;
    if (hiQ.isNotEmpty && loQ.isNotEmpty) {
      final hh = hist[hiQ.first].high;
      final ll = hist[loQ.first].low;
      final span = hh - ll;
      rpy = span <= 1e-12 ? 0.5 : (px.close - ll) / span;
      if (px.close.abs() > 1e-12) {
        final gain = (hh - px.close) / px.close;
        myp = gain < 0 ? 0 : gain;
      }
    }
    final quiet = _quiet(px.volume);
    final ninety3 = (winner != null && winner > ChenhaoChip.profitHot && quiet) ? 1 : 0;
    return ChenhaoSnap(
      cyc5: cyc5,
      cyc13: cyc13,
      cyc34: cyc34,
      cycInf: cycInf,
      cys5: cysOf(cyc5),
      cys13: cysOf(cyc13),
      cys34: cysOf(cyc34),
      cysInf: cysOf(cycInf),
      winner: winner,
      trapped: trapped,
      concentration: concentration,
      shape: shape,
      cyqkLen: cyqkLen,
      cyqkZone: cyqkZone,
      asr: asr,
      ckdp: ckdp,
      ckdw: ckdw,
      cbw: cbw,
      rpy: rpy,
      myp: myp,
      shiftDown: shiftDown,
      sideways: sideways,
      ninety3: ninety3,
    );
  }

  bool _quiet(double volume) {
    if (hist.isEmpty) return false;
    final n = math.min(ChenhaoChip.quietLookback, hist.length);
    var sum = 0.0;
    for (var i = hist.length - n; i < hist.length; i++) {
      sum += hist[i].volume;
    }
    if (sum <= 0) return false;
    return volume / sum < ChenhaoChip.quietShare;
  }

  int _zone(double share, double low, double high, double? minC, double? maxC) {
    if (minC == null || maxC == null) return 0;
    final span = maxC - minC;
    final frac = span <= 1e-12 ? 1.0 : (high - low) / span;
    if (frac <= 1e-12) return 0;
    final rel = share / frac;
    if (rel >= 1.2) return 1;
    if (rel <= 0.8) return -1;
    return 0;
  }

  ({double profit, double trapped}) _splitAt(double price) {
    var profit = 0.0;
    var trapped = 0.0;
    for (var i = 0; i < bins.length; i++) {
      final mass = bins[i];
      if (mass <= 0) continue;
      final left = edge + i * width;
      final right = left + width;
      if (right <= price) {
        profit += mass;
      } else if (left >= price) {
        trapped += mass;
      } else {
        final w = right - left;
        final part = w <= 0 ? 0.0 : ((price - left) / w).clamp(0.0, 1.0);
        profit += mass * part;
        trapped += mass * (1 - part);
      }
    }
    return (profit: profit, trapped: trapped);
  }

  ({double? minC, double? maxC, double? avg}) _costBounds() {
    double? minC;
    double? maxC;
    var weighted = 0.0;
    var mass = 0.0;
    for (var i = 0; i < bins.length; i++) {
      final v = bins[i];
      if (v <= 0) continue;
      final mid = edge + (i + 0.5) * width;
      minC ??= mid;
      maxC = mid;
      weighted += mid * v;
      mass += v;
    }
    return (minC: minC, maxC: maxC, avg: mass > 0 ? weighted / mass : null);
  }

  double _massBetween(double a, double b) {
    if (!a.isFinite || !b.isFinite) return 0;
    var lo = a;
    var hi = b;
    if (hi < lo) {
      final swap = lo;
      lo = hi;
      hi = swap;
    }
    var mass = 0.0;
    for (var i = 0; i < bins.length; i++) {
      final v = bins[i];
      if (v <= 0) continue;
      final left = edge + i * width;
      final right = left + width;
      final from = lo > left ? lo : left;
      final to = hi < right ? hi : right;
      if (to <= from) continue;
      final w = right - left;
      if (w <= 0) continue;
      mass += v * ((to - from) / w);
    }
    return mass;
  }

  double _massByMid(double top) {
    var mass = 0.0;
    for (var i = 0; i < bins.length; i++) {
      final v = bins[i];
      if (v <= 0) continue;
      final mid = edge + (i + 0.5) * width;
      if (mid <= top) mass += v;
    }
    return mass;
  }
}

void _addPoint(List<double> bins, double edge, double width, double price, double mass) {
  if (mass <= 0 || !price.isFinite || width <= 0) return;
  var i = ((price - edge) / width).floor();
  if (i < 0) i = 0;
  if (i >= bins.length) i = bins.length - 1;
  bins[i] += mass;
}

void _addRange(
  List<double> bins,
  double edge,
  double width,
  double a,
  double b,
  double mass,
) {
  if (mass <= 0 || width <= 0 || !a.isFinite || !b.isFinite) return;
  var lo = a;
  var hi = b;
  if (hi < lo) {
    final swap = lo;
    lo = hi;
    hi = swap;
  }
  if ((hi - lo) <= width * 1e-9) {
    _addPoint(bins, edge, width, (lo + hi) / 2, mass);
    return;
  }
  final i0 = ((lo - edge) / width).floor();
  final i1 = ((hi - edge) / width).floor();
  var covered = 0.0;
  final weights = <int, double>{};
  for (var i = i0; i <= i1; i++) {
    if (i < 0 || i >= bins.length) continue;
    final left = edge + i * width;
    final right = left + width;
    final from = lo > left ? lo : left;
    final to = hi < right ? hi : right;
    final w = to - from;
    if (w <= 0) continue;
    weights[i] = w;
    covered += w;
  }
  if (covered <= 0) {
    _addPoint(bins, edge, width, (lo + hi) / 2, mass);
    return;
  }
  for (final e in weights.entries) {
    bins[e.key] += mass * (e.value / covered);
  }
}

ChenhaoShapeRead _classify({
  required List<double> bins,
  required double edge,
  required double width,
  required double close,
  required double histLow,
  required double histHigh,
}) {
  final n = bins.length;
  if (n == 0 || width <= 0) {
    return const ChenhaoShapeRead(code: 0, concentration: 0);
  }
  final sm = List<double>.filled(n, 0);
  for (var i = 0; i < n; i++) {
    final left = i == 0 ? bins[i] : bins[i - 1];
    final right = i == n - 1 ? bins[i] : bins[i + 1];
    sm[i] = (left + 2 * bins[i] + right) / 4;
  }
  var maxSm = 0.0;
  for (final v in sm) {
    if (v > maxSm) maxSm = v;
  }
  final peaks = <int>[];
  if (maxSm > 0) {
    for (var i = 0; i < n; i++) {
      final left = i == 0 ? -1.0 : sm[i - 1];
      final right = i == n - 1 ? -1.0 : sm[i + 1];
      if (sm[i] > left && sm[i] >= right && sm[i] >= maxSm * 0.2 && sm[i] > 0) {
        if (peaks.isNotEmpty && i - peaks.last < 3) {
          if (sm[i] > sm[peaks.last]) peaks[peaks.length - 1] = i;
        } else {
          peaks.add(i);
        }
      }
    }
  }
  final spanLo = math.min(histLow, close);
  final spanHi = math.max(histHigh, close);
  final span = spanHi - spanLo;
  final conc = _concentration(bins, edge, width, spanLo, spanHi);
  var isDouble = false;
  if (peaks.length >= 2) {
    final ranked = [...peaks]..sort((a, b) => sm[b].compareTo(sm[a]));
    final a = ranked[0];
    final b = ranked[1];
    final left = math.min(a, b);
    final right = math.max(a, b);
    if (right - left >= 4) {
      var valley = sm[left];
      for (var i = left; i <= right; i++) {
        if (sm[i] < valley) valley = sm[i];
      }
      final lower = math.min(sm[a], sm[b]);
      if (lower > 0 && valley <= lower * 0.7) isDouble = true;
    }
  }
  if (isDouble) return ChenhaoShapeRead(code: 4, concentration: conc);
  if (conc < 0.40 || peaks.isEmpty) {
    return ChenhaoShapeRead(code: 0, concentration: conc);
  }
  final peak = peaks.reduce((a, b) => sm[a] >= sm[b] ? a : b);
  final peakPrice = edge + (peak + 0.5) * width;
  final pos = span <= 1e-12 ? 0.5 : (peakPrice - spanLo) / span;
  final closeAbove = close > peakPrice * 1.03 &&
      span > 1e-12 &&
      (close - peakPrice) / span >= 0.35 &&
      pos <= 0.40;
  if (closeAbove) return ChenhaoShapeRead(code: 3, concentration: conc);
  final mid = (histLow + histHigh) / 2;
  final code = peakPrice <= mid ? 1 : 2;
  return ChenhaoShapeRead(code: code, concentration: conc);
}

double _concentration(
  List<double> bins,
  double edge,
  double width,
  double spanLo,
  double spanHi,
) {
  var total = 0.0;
  for (final v in bins) {
    total += v;
  }
  if (total <= 0 || width <= 0) return 0;
  var lo = spanLo;
  var hi = spanHi;
  if (hi < lo) {
    final swap = lo;
    lo = hi;
    hi = swap;
  }
  var i0 = ((lo - edge) / width).floor();
  var i1 = ((hi - edge) / width).floor();
  if (i0 < 0) i0 = 0;
  if (i1 >= bins.length) i1 = bins.length - 1;
  if (i1 < i0) return 0;
  final spanN = i1 - i0 + 1;
  var win = math.max(3, (spanN * 0.2).ceil());
  if (win > spanN) win = spanN;
  var window = 0.0;
  for (var i = i0; i < i0 + win; i++) {
    window += bins[i];
  }
  var best = window;
  for (var i = i0 + win; i <= i1; i++) {
    window += bins[i] - bins[i - win];
    if (window > best) best = window;
  }
  return best / total;
}
