import '../models/trend_model_config.dart';
import 'buy_n_var.dart';
import 'divergence_relation.dart';
import 'structure_object.dart';
import 'trade_clock.dart';

/// 可交易条件变量目录（阶段0）。
///
/// 现有计算结果 → 可交易变量契约 → 以后才是表达式 → 策略信号。
/// 图上能显示 ≠ 能拿来做买卖条件。比较/穿越必须先过同层同钟编译门禁。

/// 变量落在哪一类面板（给以后条件搭积木用）。
enum TradePanel {
  /// 原始/虚拟 K 的开高低收量
  raw,
  /// 主图指标（布林等同中枢号）
  main,
  /// 副图指标（本阶段只盘点）
  sub,
  /// 缠论结构（中枢/买卖点等，本阶段只盘点）
  structure,
}

enum TradeValueType {
  numeric,
  boolean,
  event,
  enumeration,
  /// 结构对象上的数值投影（如确认中枢 HIGH）
  objectProjection,
  /// 结构关系上的数值投影（如背驰 RATIO）
  relationProjection,
}

/// 能进比较 / CROSS 的「有大小的数」。事件、枚举、整个对象/关系不行。
bool isNumericComparableType(TradeValueType t) =>
    t == TradeValueType.numeric ||
    t == TradeValueType.objectProjection ||
    t == TradeValueType.relationProjection;

/// 已登记可进公式 / 只盘点不进公式。
enum TradeReadiness {
  registered,
  inventoryOnly,
}

/// 一条可交易（或仅盘点）变量的契约。
class TradeVariableDef {
  /// 稳定键，例如 RAW.K0.CLOSE、MAIN.K1.BOLL.DOWN
  final String variableId;
  /// 给人看的名字（白话）
  final String displayName;
  final TradePanel panel;
  /// 显示层 K0/K1/…；盘点模板可为 null
  final int? displayKn;
  final TradeClockFamily clockFamily;
  /// 条件只能在这根钟上算；K1+ 布林/收盘是虚拟K样本，不是铺平后的K0阶梯
  final TradeEvalClock? evalClock;
  /// 给人看时铺到哪（Kn 数学指标铺成 K0 格子）
  final TradePlotClock? plotClock;
  final TradeValueType valueType;
  final TradeReadiness readiness;
  /// 内部：从哪份现有数据读（不另起炉灶）
  final String source;
  final String unit;
  /// 取值是否禁止用未来 K
  final bool futureSafe;
  /// 何时才有数（白话）
  final String availabilityNote;
  /// 只盘点时：为什么还不能进公式
  final String? blockedReason;
  /// 盘点模板里的 `{n}` 层号占位
  final String? idPattern;
  /// 选择器分组键：ohlc / boll / macd / rsi / kdj / volume
  final String groupKey;
  final String groupLabel;
  /// 组内字段短名：DIF / 中轨 / 收
  final String fieldLabel;
  /// 给人看的来源说明（诊断面板）
  final String description;

  const TradeVariableDef({
    required this.variableId,
    required this.displayName,
    required this.panel,
    required this.displayKn,
    required this.clockFamily,
    this.evalClock,
    this.plotClock,
    required this.valueType,
    required this.readiness,
    required this.source,
    required this.unit,
    required this.futureSafe,
    required this.availabilityNote,
    this.blockedReason,
    this.idPattern,
    this.groupKey = '',
    this.groupLabel = '',
    this.fieldLabel = '',
    this.description = '',
  });

  bool get expressionReady => readiness == TradeReadiness.registered;

  /// 盘点模板是否盖住具体 id（如 SUB.K{n}.BUY1 盖 SUB.K2.BUY1）。
  bool matchesId(String id) {
    if (variableId == id) return true;
    final p = idPattern;
    if (p == null || p.isEmpty) return false;
    final escaped = p.split('{n}').map(RegExp.escape).join(r'\d+');
    return RegExp('^$escaped\$').hasMatch(id);
  }
}

String rawOhlcId(int kn, String field) => 'RAW.K$kn.${field.toUpperCase()}';

String bollBandId(int kn, String band) =>
    'MAIN.K$kn.BOLL.${band.toUpperCase()}';

String macdFieldId(int kn, String field) =>
    'SUB.K$kn.MACD.${field.toUpperCase()}';

String rsiValueId(int kn) => 'SUB.K$kn.RSI.VALUE';

String kdjFieldId(int kn, String field) =>
    'SUB.K$kn.KDJ.${field.toUpperCase()}';

String k0VolumeId() => 'RAW.K0.VOLUME';

String k0TickCountId() => 'RAW.K0.TICK_COUNT';

String maVarId(int kn, int period) => 'MAIN.K$kn.MA.$period';

String channelVarId(int kn, int period, String band) =>
    'MAIN.K$kn.CHANNEL.$period.${band.toUpperCase()}';

String demarkCompleteId(int kn, {required bool buy}) =>
    buy ? 'MAIN.K$kn.DEMARK.COMPLETE_BUY' : 'MAIN.K$kn.DEMARK.COMPLETE_SELL';

String fractalJudgmentId(int kn) => 'SUB.K$kn.FRACTAL_JUDGMENT';

String zsJudgmentId(int kn) => 'SUB.K$kn.ZS_JUDGMENT';

String zsActiveVarId(int kn, String field) =>
    'STRUCTURE.K$kn.ZS.ACTIVE.${field.toUpperCase()}';

String lineSlopeId(int kn) => 'SUB.K$kn.LINE_SLOPE';

String adjacentRatioId(int kn) => 'SUB.K$kn.ADJACENT_RATIO';

String stepRhythmId(int kn) => 'MAIN.K$kn.STEP_RHYTHM';

String knVolumeId(int kn) => kn <= 0 ? k0VolumeId() : 'SUB.K$kn.VOLUME';

String knTickCountId(int kn) =>
    kn <= 0 ? k0TickCountId() : 'SUB.K$kn.TICK_COUNT';

String trendLineVarId(int kn, String side) =>
    'MAIN.K$kn.TREND_LINE.${side.toUpperCase()}';

String fxTripleVarId(int kn) => 'MAIN.K$kn.FX_TRIPLE.PRICE';

String fxQuadVarId(int kn, String side) =>
    'MAIN.K$kn.FX_QUAD.${side.toUpperCase()}';

/// 默认登记框内 + 下侧-1..-3 + 上侧+1..+3
const int kTradeChipPeakMaxRank = 3;

/// SUB.K0.CHIP.PEAK / SUB.K0.CHIP.PEAK.M1 / SUB.K0.TICK.PEAK.P2
String chipPeakVarId({
  required String kind,
  required String token,
}) {
  final head = kind == 'tick' ? 'TICK' : 'CHIP';
  if (token.isEmpty) return 'SUB.K0.$head.PEAK';
  return 'SUB.K0.$head.PEAK.$token';
}

String chipPeakTokenOfSuffix(String suffix) {
  if (suffix.isEmpty) return '';
  if (suffix.startsWith('-')) return 'M${suffix.substring(1)}';
  if (suffix.startsWith('+')) return 'P${suffix.substring(1)}';
  return suffix;
}

String chipPeakSuffixOfToken(String token) {
  if (token.isEmpty) return '';
  if (token.startsWith('M')) return '-${token.substring(1)}';
  if (token.startsWith('P')) return '+${token.substring(1)}';
  return token;
}

String chipPeakFieldLabel(String suffix) {
  if (suffix.isEmpty) return '框内';
  return suffix;
}

/// SUB.K0.CHIP.PEAK.M1 → kn=0, kind=chip, suffix=-1
({int kn, String kind, String suffix})? parseChipPeakVarId(String id) {
  final parts = canonicalizeTradeVarId(id).split('.');
  if (parts.length < 4 || parts.length > 5) return null;
  if (parts[0] != 'SUB' || parts[3] != 'PEAK') return null;
  if (!parts[1].startsWith('K')) return null;
  final kn = int.tryParse(parts[1].substring(1));
  if (kn == null || kn < 0) return null;
  final head = parts[2];
  if (head != 'CHIP' && head != 'TICK') return null;
  final kind = head == 'TICK' ? 'tick' : 'chip';
  if (parts.length == 4) return (kn: kn, kind: kind, suffix: '');
  final token = parts[4];
  if (!RegExp(r'^[MP]\d+$').hasMatch(token)) return null;
  final n = int.tryParse(token.substring(1));
  if (n == null || n < 1) return null;
  return (kn: kn, kind: kind, suffix: chipPeakSuffixOfToken(token));
}

/// MAIN.K1.MA.5
({int kn, int period})? parseMaVarId(String id) {
  final parts = canonicalizeTradeVarId(id).split('.');
  if (parts.length != 4 || parts[0] != 'MAIN') return null;
  if (!parts[1].startsWith('K') || parts[2] != 'MA') return null;
  final kn = int.tryParse(parts[1].substring(1));
  final period = int.tryParse(parts[3]);
  if (kn == null || kn < 0 || period == null || period < 1) return null;
  return (kn: kn, period: period);
}

/// MAIN.K1.CHANNEL.20.MAX
({int kn, int period, String band})? parseChannelVarId(String id) {
  final parts = canonicalizeTradeVarId(id).split('.');
  if (parts.length != 5 || parts[0] != 'MAIN') return null;
  if (!parts[1].startsWith('K') || parts[2] != 'CHANNEL') return null;
  final kn = int.tryParse(parts[1].substring(1));
  final period = int.tryParse(parts[3]);
  final band = parts[4];
  if (kn == null || kn < 0 || period == null || period < 1) return null;
  if (band != 'MAX' && band != 'MIN') return null;
  return (kn: kn, period: period, band: band);
}

/// 把已登记 id 换到另一层。
/// 同名 id 没有（K1 成交量≠RAW.K1.VOLUME）时，按组名+字段名找对应项（K1成交量↔K0成交量）；再没有才退回收盘。
String remapRegisteredVarId(String variableId, int newKn, {int maxKn = 8}) {
  final canonical = canonicalizeTradeVarId(variableId);
  final parts = canonical.split('.');
  if (parts.length < 3 || !parts[1].startsWith('K')) {
    return rawOhlcId(newKn, 'CLOSE');
  }
  parts[1] = 'K$newKn';
  final next = parts.join('.');
  final def = lookupTradeVariable(next, maxKn: maxKn);
  if (def != null && def.expressionReady) return next;
  final src = lookupTradeVariable(canonical, maxKn: maxKn);
  if (src != null && src.groupKey.isNotEmpty) {
    for (final v in buildRegisteredTradeVariables(maxKn)) {
      if (v.displayKn == newKn &&
          v.expressionReady &&
          v.groupKey == src.groupKey &&
          v.fieldLabel == src.fieldLabel) {
        return v.variableId;
      }
    }
  }
  return rawOhlcId(newKn, 'CLOSE');
}

int? knFromVariableId(String variableId) {
  final parts = canonicalizeTradeVarId(variableId).split('.');
  if (parts.length < 2 || !parts[1].startsWith('K')) return null;
  return int.tryParse(parts[1].substring(1));
}

/// 某一层里、已进公式的变量，按登记顺序分组（选择器只用这份，不写死指标名）。
class TradeVarGroupSpec {
  final String key;
  final String label;
  final TradePanel panel;
  final List<TradeVariableDef> fields;

  const TradeVarGroupSpec({
    required this.key,
    required this.label,
    required this.panel,
    required this.fields,
  });
}

List<TradeVarGroupSpec> groupedRegisteredVars(int kn, int maxKn) {
  final vars = buildRegisteredTradeVariables(maxKn)
      .where((v) => v.displayKn == kn && v.expressionReady)
      .toList();
  final order = <String>[];
  final map = <String, List<TradeVariableDef>>{};
  for (final v in vars) {
    final g = v.groupKey.isEmpty ? v.panel.name : v.groupKey;
    map.putIfAbsent(g, () {
      order.add(g);
      return <TradeVariableDef>[];
    });
    map[g]!.add(v);
  }
  return [
    for (final g in order)
      TradeVarGroupSpec(
        key: g,
        label: map[g]!.first.groupLabel.isEmpty ? g : map[g]!.first.groupLabel,
        panel: map[g]!.first.panel,
        fields: map[g]!,
      ),
  ];
}

/// 阶段0已登记、可以进条件表达式的变量。
/// [maxKn] 与图上 chartMaxKn 同口径：布林 0..maxKn；虚拟K收盘 1..maxKn。
List<TradeVariableDef> buildRegisteredTradeVariables(int maxKn) {
  final hi = maxKn < 0 ? 0 : maxKn;
  final out = <TradeVariableDef>[];

  const ohlc = ['OPEN', 'HIGH', 'LOW', 'CLOSE'];
  const ohlcCn = {'OPEN': '开', 'HIGH': '高', 'LOW': '低', 'CLOSE': '收'};

  // K0 原生开高低收 + 成交量
  for (final f in ohlc) {
    out.add(TradeVariableDef(
      variableId: rawOhlcId(0, f),
      displayName: 'K0${ohlcCn[f]}',
      panel: TradePanel.raw,
      displayKn: 0,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.numeric,
      readiness: TradeReadiness.registered,
      source: '原生K线 bars[asOf]',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '走到这根 K0 时即可读；没有这根则为不可用',
      groupKey: 'ohlc',
      groupLabel: '开高低收',
      fieldLabel: ohlcCn[f]!,
      description: '原生 K0 开高低收',
    ));
  }
  out.add(const TradeVariableDef(
    variableId: 'RAW.K0.VOLUME',
    displayName: 'K0成交量',
    panel: TradePanel.raw,
    displayKn: 0,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: TradeEvalClock.k0Bar,
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.numeric,
    readiness: TradeReadiness.registered,
    source: '原生K线 bars[asOf].volume',
    unit: 'volume',
    futureSafe: true,
    availabilityNote: '走到这根 K0 时即可读',
    groupKey: 'volume',
    groupLabel: '成交量',
    fieldLabel: '成交量',
      description: '只登记 K0 原生成交量；K1+ 成交量走 SUB.K{n}.VOLUME（铺平序列，按该层计算钟取样）',
    ));
  out.add(const TradeVariableDef(
    variableId: 'RAW.K0.TICK_COUNT',
    displayName: 'K0笔数',
    panel: TradePanel.raw,
    displayKn: 0,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: TradeEvalClock.k0Bar,
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.numeric,
    readiness: TradeReadiness.registered,
    source: '原生K线 bars[asOf] tick_count / chip_tick_bins',
    unit: 'count',
    futureSafe: true,
    availabilityNote: '走到这根 K0 时即可读；没有逐笔数据则为 0',
    groupKey: 'tickCount',
    groupLabel: '笔数',
    fieldLabel: '笔数',
    description: '只登记 K0 原生笔数；K1+ 走 SUB.K{n}.TICK_COUNT',
  ));

  // K0 筹码峰 / 笔数峰：价，和开高低收同一套钟
  for (final kind in ['chip', 'tick']) {
    out.add(_chipPeakDef(kind: kind, suffix: ''));
    for (var n = 1; n <= kTradeChipPeakMaxRank; n++) {
      out.add(_chipPeakDef(kind: kind, suffix: '-$n'));
      out.add(_chipPeakDef(kind: kind, suffix: '+$n'));
    }
  }

  // Kn≥1：虚拟K开高低收（与布林同一套钟；含动态段）
  for (var kn = 1; kn <= hi; kn++) {
    for (final f in ohlc) {
      out.add(TradeVariableDef(
        variableId: rawOhlcId(kn, f),
        displayName: 'K$kn${ohlcCn[f]}',
        panel: TradePanel.raw,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: TradeEvalClock.knSample,
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.numeric,
        readiness: TradeReadiness.registered,
        source: 'evalClock=虚拟K样本（冻段+动态段）；plotClock=铺到K0格子给人看',
        unit: 'price',
        futureSafe: true,
        availabilityNote: '该层还没有第一根虚拟K时为不可用；不读未来K',
        groupKey: 'ohlc',
        groupLabel: '开高低收',
        fieldLabel: ohlcCn[f]!,
        description: '虚拟K开高低收，条件只在样本右端跳',
      ));
    }
  }

  // 各层布林：与中枢同号，读冻结仓
  const bands = ['MID', 'UP', 'DOWN'];
  const bandCn = {'MID': '中轨', 'UP': '上轨', 'DOWN': '下轨'};
  for (var kn = 0; kn <= hi; kn++) {
    for (final b in bands) {
      out.add(TradeVariableDef(
        variableId: bollBandId(kn, b),
        displayName: 'K$kn布林${bandCn[b]}',
        panel: TradePanel.main,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.numeric,
        readiness: TradeReadiness.registered,
        source: 'MathSeriesFreezeStore.boll(kn)，与图上布林同一仓；CROSS 取 evalClock 样本点',
        unit: 'price',
        futureSafe: true,
        availabilityNote: '有第一个布林样本才有数；热身不足仍按图上布林出数，不另造前N根不可用',
        groupKey: 'boll',
        groupLabel: '布林',
        fieldLabel: bandCn[b]!,
        description: '读图上已冻住的布林格子，禁止现场另算',
      ));
    }
  }

  // 各层均线/通道：与布林同一冻结仓、同一套钟
  const meanPeriods = TrendModelConfig.defaultMeanPeriods;
  const channelPeriods = TrendModelConfig.defaultChannelPeriods;
  for (var kn = 0; kn <= hi; kn++) {
    for (final p in meanPeriods) {
      out.add(_maDef(kn, p));
    }
    for (final p in channelPeriods) {
      out.add(_channelDef(kn, p, 'MAX'));
      out.add(_channelDef(kn, p, 'MIN'));
    }
    out.add(_demarkCompleteDef(kn, buy: true));
    out.add(_demarkCompleteDef(kn, buy: false));
  }

  // 副图 MACD / RSI / KDJ：与中枢同号、同一套 zsMath 钟；只读冻结仓
  const macdFields = ['DIF', 'DEA', 'HIST'];
  for (var kn = 0; kn <= hi; kn++) {
    for (final f in macdFields) {
      out.add(TradeVariableDef(
        variableId: macdFieldId(kn, f),
        displayName: 'K$kn MACD.$f',
        panel: TradePanel.sub,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.numeric,
        readiness: TradeReadiness.registered,
        source: 'MathSeriesFreezeStore.macd(kn)，与副图 MACD 同一仓',
        unit: 'macd',
        futureSafe: true,
        availabilityNote: '冻结仓该格有数才可读；没有仓或空格=不可用，不现场重算',
        groupKey: 'macd',
        groupLabel: 'MACD',
        fieldLabel: f,
        description: f == 'HIST'
            ? 'MACD 柱=2*(DIF-DEA)，读冻结仓 macd 序列'
            : '读冻结仓 ${f.toLowerCase()} 序列',
      ));
    }
    out.add(TradeVariableDef(
      variableId: rsiValueId(kn),
      displayName: 'K$kn RSI',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.numeric,
      readiness: TradeReadiness.registered,
      source: 'MathSeriesFreezeStore.rsi(kn)，与副图 RSI 同一仓',
      unit: 'rsi',
      futureSafe: true,
      availabilityNote: '冻结仓该格有数才可读；没有仓或空格=不可用，不现场重算',
      groupKey: 'rsi',
      groupLabel: 'RSI',
      fieldLabel: 'VALUE',
      description: 'RSI 单值序列，比较/穿越走现有变量 vs 常数',
    ));
    const kdjFields = {'K': 'K', 'D': 'D', 'J': 'J'};
    for (final e in kdjFields.entries) {
      out.add(TradeVariableDef(
        variableId: kdjFieldId(kn, e.key),
        displayName: 'K$kn KDJ.${e.key}',
        panel: TradePanel.sub,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.numeric,
        readiness: TradeReadiness.registered,
        source: 'MathSeriesFreezeStore.kdj(kn)，与副图 KDJ 同一仓',
        unit: 'kdj',
        futureSafe: true,
        availabilityNote: '冻结仓该格有数才可读；没有仓或空格=不可用，不现场重算',
        groupKey: 'kdj',
        groupLabel: 'KDJ',
        fieldLabel: e.value,
        description: '读冻结仓 KDJ.${e.key}，金叉死叉用 CROSS 表达',
      ));
    }
  }

  // 结构事件：发现边沿，不是持续状态。计算钟一律 K0（发现当根）。
  for (var kn = 0; kn <= hi; kn++) {
    const bs = [
      ('BUY1', '一类买点', 'buy1History 会话冻结，稳定身份首次发现'),
      ('SELL1', '一类卖点', 'sell1History 会话冻结，稳定身份首次发现'),
      ('BUY2', '二类买点', 'buy2History 会话冻结，发现边沿'),
      ('SELL2', '二类卖点', 'sell2History 会话冻结，发现边沿'),
    ];
    for (final e in bs) {
      final isClass1 = e.$1 == 'BUY1' || e.$1 == 'SELL1';
      out.add(TradeVariableDef(
        variableId: 'STRUCTURE.K$kn.${e.$1}',
        displayName: 'K$kn ${e.$2}',
        panel: TradePanel.structure,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: TradeEvalClock.k0Bar,
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.event,
        readiness: TradeReadiness.registered,
        source: e.$3,
        unit: 'event',
        futureSafe: true,
        availabilityNote: '首次发现当根才出现一次；动态段后续 x 不重复出交易事件',
        groupKey: isClass1 ? 'bs1' : 'bs2',
        groupLabel: isClass1 ? '一类BS' : '二类BS',
        fieldLabel: e.$1,
        description: 'EVENT_EXISTS；禁止比较/穿越',
      ));
    }
    for (var cls = kTradeMinBsClass; cls <= kTradeUiMaxBsClass; cls++) {
      out.add(TradeVariableDef(
        variableId: buyNVarId(kn, cls),
        displayName: 'K$kn ${tradeBsClassCn(cls)}类买点',
        panel: TradePanel.structure,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: TradeEvalClock.k0Bar,
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.event,
        readiness: TradeReadiness.registered,
        source: 'buyNHistory 会话冻结，按 class=$cls 过滤；发现边沿',
        unit: 'event',
        futureSafe: true,
        availabilityNote: '首次发现当根才出现一次；动态段后续 x 不重复出交易事件',
        groupKey: 'bsN',
        groupLabel: 'N类BS',
        fieldLabel: '${tradeBsClassCn(cls)}买',
        description: 'BUY_N(class=$cls) EVENT_EXISTS；禁止比较/穿越',
      ));
      out.add(TradeVariableDef(
        variableId: sellNVarId(kn, cls),
        displayName: 'K$kn ${tradeBsClassCn(cls)}类卖点',
        panel: TradePanel.structure,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: TradeEvalClock.k0Bar,
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.event,
        readiness: TradeReadiness.registered,
        source: 'sellNHistory 会话冻结，按 class=$cls 过滤；发现边沿',
        unit: 'event',
        futureSafe: true,
        availabilityNote: '首次发现当根才出现一次；动态段后续 x 不重复出交易事件',
        groupKey: 'bsN',
        groupLabel: 'N类BS',
        fieldLabel: '${tradeBsClassCn(cls)}卖',
        description: 'SELL_N(class=$cls) EVENT_EXISTS；禁止比较/穿越',
      ));
    }
    out.add(TradeVariableDef(
      variableId: 'SUB.K$kn.FRACTAL_CONFIRM',
      displayName: 'K$kn 分型确认',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.line,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.event,
      readiness: TradeReadiness.registered,
      source: kn == 0
          ? 'k0ConfirmSignals 首次确认'
          : 'LevelBundle.level==kn confirms 首次确认',
      unit: 'event',
      futureSafe: true,
      availabilityNote: '每颗确认当根出一次；连着的第二颗也出，不按假变真吞掉',
      groupKey: 'fxConfirm',
      groupLabel: '分型确认',
      fieldLabel: '确认',
        description: 'EVENT_EXISTS；当根脉冲；连线钟，不能和布林/RSI 直接 AND',
      ));
    out.add(TradeVariableDef(
      variableId: fractalJudgmentId(kn),
      displayName: 'K$kn 分型判断',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.line,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.event,
      readiness: TradeReadiness.registered,
      source: 'judgmentHistory 会话冻结；尚未确认分型的首次可判边沿',
      unit: 'event',
      futureSafe: true,
      availabilityNote: '同一分型首次判断当根出一次；离开窗后续 x 不重复出交易事件',
      groupKey: 'fxJudge',
      groupLabel: '分型判断',
      fieldLabel: '判断',
      description: 'EVENT_EXISTS；连线钟，不能和布林/RSI 直接 AND',
    ));
    out.add(TradeVariableDef(
      variableId: 'SUB.K$kn.ZS_CONFIRM',
      displayName: 'K$kn 中枢确认',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.event,
      readiness: TradeReadiness.registered,
      source: 'zsConfirmHistory 会话冻结，is_sure 首次',
      unit: 'event',
      futureSafe: true,
      availabilityNote: '首次确认事件；高低走 ZS.CURRENT 投影，不和事件混用',
      groupKey: 'zsConfirm',
      groupLabel: '中枢确认',
      fieldLabel: '确认',
        description: 'EVENT_EXISTS；与 RSI/MACD 同 zsMath 可 AND/OR',
    ));
    out.add(TradeVariableDef(
      variableId: zsJudgmentId(kn),
      displayName: 'K$kn 中枢判断',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.event,
      readiness: TradeReadiness.registered,
      source: 'zsJudgmentHistory 会话冻结；尚未确认中枢的首次可判边沿',
      unit: 'event',
      futureSafe: true,
      availabilityNote: '同一未确认框首次判断当根出一次；离开窗后续 x 不重复出交易事件',
      groupKey: 'zsJudge',
      groupLabel: '中枢判断',
      fieldLabel: '判断',
      description: 'EVENT_EXISTS；与 RSI/MACD 同 zsMath 可 AND/OR',
    ));
    // 确认中枢数值：先解析 CURRENT_CONFIRMED_ZS 的稳定 objectId，再投影
    const zsFields = [
      ('HIGH', '高'),
      ('LOW', '低'),
      ('CENTER', '中轴'),
    ];
    for (final f in zsFields) {
      out.add(TradeVariableDef(
        variableId: zsCurrentVarId(kn, f.$1),
        displayName: 'K$kn确认中枢${f.$2}',
        panel: TradePanel.structure,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.objectProjection,
        readiness: TradeReadiness.registered,
        source:
            'ZhongshuObjectStore.resolveCurrentConfirmedZs → ${f.$1}；只读现有中枢帧快照',
        unit: 'price',
        futureSafe: true,
        availabilityNote: '该层当时还没有已确认中枢则为不可用，不会填 0',
        groupKey: 'zsCurrent',
        groupLabel: '确认中枢',
        fieldLabel: f.$2,
        description:
            'CURRENT_CONFIRMED_ZS 的 ${f.$2}；动态延伸同一 objectId，历史 asOf 不跟末态改',
      ));
    }
    for (final f in zsFields) {
      out.add(TradeVariableDef(
        variableId: zsActiveVarId(kn, f.$1),
        displayName: 'K$kn未确认中枢${f.$2}',
        panel: TradePanel.structure,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.objectProjection,
        readiness: TradeReadiness.registered,
        source:
            'ZhongshuObjectStore.resolveCurrentActiveZs → ${f.$1}；只读当时未确认框快照',
        unit: 'price',
        futureSafe: true,
        availabilityNote: '这根 K 没有盖住的未确认中枢则为不可用，不会填 0、不沿用上一根',
        groupKey: 'zsActive',
        groupLabel: '未确认中枢',
        fieldLabel: f.$2,
        description:
            'ACTIVE 未确认框的 ${f.$2}；当步冻结；框外为空；确认后改走 CURRENT',
      ));
    }
    out.add(TradeVariableDef(
      variableId: lineSlopeId(kn),
      displayName: 'K$kn 连线斜率',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.line,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.numeric,
      readiness: TradeReadiness.registered,
      source: 'lineSlopeHistory 会话历史，与副图 Kn连线斜率同一份',
      unit: 'slope',
      futureSafe: true,
      availabilityNote: '该步还没有末根连线则为不可用；连线钟，不能和布林比',
      groupKey: 'lineSlope',
      groupLabel: '连线斜率',
      fieldLabel: '斜率',
      description: '连线钟数值；可与同层比例/分型确认拼，不能和布林/RSI 直接比',
    ));
    out.add(TradeVariableDef(
      variableId: adjacentRatioId(kn),
      displayName: 'K$kn 比例',
      panel: TradePanel.sub,
      displayKn: kn,
      clockFamily: TradeClockFamily.line,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.numeric,
      readiness: TradeReadiness.registered,
      source: 'adjacentRatioHistory 会话历史，虚实都算',
      unit: 'ratio',
      futureSafe: true,
      availabilityNote: '还不够两根子线则为不可用；连线钟，不能和布林比',
      groupKey: 'adjRatio',
      groupLabel: '相邻比例',
      fieldLabel: '比例',
      description: '连线钟数值；可与同层斜率比，不能和布林直接比',
    ));
    out.add(TradeVariableDef(
      variableId: stepRhythmId(kn),
      displayName: 'K$kn 节奏',
      panel: TradePanel.main,
      displayKn: kn,
      clockFamily: TradeClockFamily.line,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.numeric,
      readiness: TradeReadiness.registered,
      source: 'stepRhythmHistory 会话历史；关窗后持上个名字续写已算进这份历史',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '这根没有节奏线则为不可用；不另造持值',
      groupKey: 'rhythm',
      groupLabel: '节奏',
      fieldLabel: '投影价',
      description: '读会话已写下的投影价（含关窗持值）；连线钟，不能和布林直接比',
    ));
    if (kn >= 1) {
      out.add(TradeVariableDef(
        variableId: knVolumeId(kn),
        displayName: 'K$kn成交量',
        panel: TradePanel.sub,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.numeric,
        readiness: TradeReadiness.registered,
        source: 'computeAllKnVolumeSeries 铺平层序列，按该层计算钟取样（与 MACD 同构）',
        unit: 'volume',
        futureSafe: true,
        availabilityNote: '该层还没有确认门控量则为不可用',
        groupKey: 'volume',
        groupLabel: '成交量',
        fieldLabel: '成交量',
        description: 'K1+ 是铺平后的层序列，不是虚拟K样本总量；条件只在计算钟样本右端跳',
      ));
      out.add(TradeVariableDef(
        variableId: knTickCountId(kn),
        displayName: 'K$kn笔数',
        panel: TradePanel.sub,
        displayKn: kn,
        clockFamily: TradeClockFamily.zsMath,
        evalClock: evalClockForDisplayKn(kn),
        plotClock: TradePlotClock.k0Bar,
        valueType: TradeValueType.numeric,
        readiness: TradeReadiness.registered,
        source: 'computeAllKnTickCountSeries 铺平层序列，按该层计算钟取样',
        unit: 'count',
        futureSafe: true,
        availabilityNote: '该层还没有确认门控笔数则为不可用',
        groupKey: 'tickCount',
        groupLabel: '笔数',
        fieldLabel: '笔数',
        description: '与 Kn 成交量同一套铺平取样',
      ));
    }
    out.add(TradeVariableDef(
      variableId: fxTripleVarId(kn),
      displayName: 'K$kn三型价',
      panel: TradePanel.main,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.objectProjection,
      readiness: TradeReadiness.registered,
      source: 'Lookup/十字已冻的 fx_triple_price；无仓则按 asOf 前缀现算投影',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '这根没有三型延长线落到价位则为不可用',
      groupKey: 'fxTriple',
      groupLabel: '三型',
      fieldLabel: '价',
      description: '线→价投影，可与同层收盘/布林比',
    ));
    out.add(TradeVariableDef(
      variableId: fxQuadVarId(kn, 'TOP'),
      displayName: 'K$kn四型上',
      panel: TradePanel.main,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.objectProjection,
      readiness: TradeReadiness.registered,
      source: 'Lookup 已冻的 fx_quad_top_price',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '这根没有四型上沿价则为不可用',
      groupKey: 'fxQuad',
      groupLabel: '四型',
      fieldLabel: '上',
      description: '线→价投影，可与同层收盘/布林比',
    ));
    out.add(TradeVariableDef(
      variableId: fxQuadVarId(kn, 'BOTTOM'),
      displayName: 'K$kn四型下',
      panel: TradePanel.main,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.objectProjection,
      readiness: TradeReadiness.registered,
      source: 'Lookup 已冻的 fx_quad_bottom_price',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '这根没有四型下沿价则为不可用',
      groupKey: 'fxQuad',
      groupLabel: '四型',
      fieldLabel: '下',
      description: '线→价投影，可与同层收盘/布林比',
    ));
    out.add(TradeVariableDef(
      variableId: trendLineVarId(kn, 'SUPPORT'),
      displayName: 'K$kn趋势支撑',
      panel: TradePanel.main,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.objectProjection,
      readiness: TradeReadiness.registered,
      source: 'Lookup 已冻的 trend_support_price',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '这根没有趋势支撑价则为不可用',
      groupKey: 'trendLine',
      groupLabel: '趋势线',
      fieldLabel: '支撑',
      description: '线→价投影，可与同层收盘/布林比',
    ));
    out.add(TradeVariableDef(
      variableId: trendLineVarId(kn, 'RESIST'),
      displayName: 'K$kn趋势压力',
      panel: TradePanel.main,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.objectProjection,
      readiness: TradeReadiness.registered,
      source: 'Lookup 已冻的 trend_resist_price',
      unit: 'price',
      futureSafe: true,
      availabilityNote: '这根没有趋势压力价则为不可用',
      groupKey: 'trendLine',
      groupLabel: '趋势线',
      fieldLabel: '压力',
      description: '线→价投影，可与同层收盘/布林比',
    ));
    out.add(TradeVariableDef(
      variableId: diverExistsId(kn),
      displayName: 'K$kn 背驰出现',
      panel: TradePanel.structure,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: TradeEvalClock.k0Bar,
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.event,
      readiness: TradeReadiness.registered,
      source: 'DivergenceRelationStore EXISTS；引用比较对象，不按当前K猜',
      unit: 'event',
      futureSafe: true,
      availabilityNote: '确认背驰首次发现当根出现一次；确认翻转后再确认才是新事件',
      groupKey: 'diver',
      groupLabel: '背驰',
      fieldLabel: '出现',
      description: 'EVENT_EXISTS；禁止比较/穿越；默认 MACD 面积',
    ));
    out.add(TradeVariableDef(
      variableId: diverRatioId(kn),
      displayName: 'K$kn 背驰力度比',
      panel: TradePanel.structure,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.relationProjection,
      readiness: TradeReadiness.registered,
      source: 'DivergenceRelation.ratio（面积 out/in）；历史 asOf 不回写',
      unit: 'ratio',
      futureSafe: true,
      availabilityNote: '没有当时可见的确认背驰关系则为不可用，不是 0',
      groupKey: 'diver',
      groupLabel: '背驰',
      fieldLabel: '力度比',
      description: '关系投影；可与同层 RSI/收盘比较，不能 CROSS 整个背驰对象',
    ));
    out.add(TradeVariableDef(
      variableId: diverDirectionId(kn),
      displayName: 'K$kn 背驰方向',
      panel: TradePanel.structure,
      displayKn: kn,
      clockFamily: TradeClockFamily.zsMath,
      evalClock: evalClockForDisplayKn(kn),
      plotClock: TradePlotClock.k0Bar,
      valueType: TradeValueType.enumeration,
      readiness: TradeReadiness.registered,
      source: 'DivergenceRelation.direction（离开段方向）',
      unit: 'enum',
      futureSafe: true,
      availabilityNote: '没有当时可见的确认背驰关系则为不可用',
      groupKey: 'diver',
      groupLabel: '背驰',
      fieldLabel: '方向',
      description: '枚举 向上/向下；只能等于，不能比大小或穿越',
    ));
  }
  return out;
}

/// 能画、但身份未收口，暂不进公式。
List<TradeVariableDef> inventoryOnlyTradeVariables() {
  TradeVariableDef stub({
    required String pattern,
    required String name,
    required TradePanel panel,
    required TradeClockFamily clock,
    required TradeValueType type,
    required String why,
  }) {
    return TradeVariableDef(
      variableId: pattern,
      displayName: name,
      panel: panel,
      displayKn: null,
      clockFamily: clock,
      valueType: type,
      readiness: TradeReadiness.inventoryOnly,
      source: '仅盘点',
      unit: '',
      futureSafe: true,
      availabilityNote: '未进公式',
      blockedReason: why,
      idPattern: pattern,
    );
  }

  return [
    stub(
      pattern: 'STRUCTURE.K{n}.ZS.CURRENT',
      name: 'Kn确认中枢（整对象）',
      panel: TradePanel.structure,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.objectProjection,
      why: '整对象不能比大小；请用 ZS.CURRENT.HIGH/LOW/CENTER 投影',
    ),
    stub(
      pattern: 'STRUCTURE.K{n}.ZS.HIGH',
      name: 'Kn中枢高（未指定哪一框）',
      panel: TradePanel.structure,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '请用 ZS.CURRENT.HIGH 或 ZS.ACTIVE.HIGH。未指定哪一框不能进公式',
    ),
    stub(
      pattern: 'STRUCTURE.K{n}.ZS.LOW',
      name: 'Kn中枢低（未指定哪一框）',
      panel: TradePanel.structure,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '请用 ZS.CURRENT.LOW 或 ZS.ACTIVE.LOW',
    ),
    stub(
      pattern: 'STRUCTURE.K{n}.DIVERGENCE',
      name: 'Kn背驰关系（整对象）',
      panel: TradePanel.structure,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.relationProjection,
      why: '整段背驰关系不能比大小或穿越；请用 EXISTS / RATIO / DIRECTION 投影',
    ),
    stub(
      pattern: 'SUB.K{n}.DIVERGENCE',
      name: 'Kn背驰（未指定关系）',
      panel: TradePanel.sub,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '请用 STRUCTURE.K{n}.DIVERGENCE.EXISTS/RATIO/DIRECTION；背驰是关系不是一根 double',
    ),
    stub(
      pattern: 'SUB.K{n}.CHIP.PEAK',
      name: 'Kn筹码峰（非K0）',
      panel: TradePanel.sub,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '筹码峰只做 K0：请用 SUB.K0.CHIP.PEAK / PEAK.M1 / PEAK.P1，和开高低收比',
    ),
    stub(
      pattern: 'SUB.K{n}.TICK.PEAK',
      name: 'Kn笔数峰（非K0）',
      panel: TradePanel.sub,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '笔数峰只做 K0：请用 SUB.K0.TICK.PEAK / PEAK.M1 / PEAK.P1',
    ),
  ];
}

/// 在已登记表里找；找不到再看盘点模板。CHAN. 前缀与 STRUCTURE. 同义。
TradeVariableDef? lookupTradeVariable(String variableId, {int maxKn = 8}) {
  final id = canonicalizeTradeVarId(variableId);
  for (final d in buildRegisteredTradeVariables(maxKn)) {
    if (d.variableId == id) return d;
  }
  final n = parseClassNVarId(id);
  if (n != null && n.cls <= kTradeMaxBsClass && n.kn <= (maxKn < 0 ? 0 : maxKn)) {
    return _classNDef(n.kn, n.cls, buy: n.buy);
  }
  final ma = parseMaVarId(id);
  if (ma != null && ma.kn <= (maxKn < 0 ? 0 : maxKn)) {
    return _maDef(ma.kn, ma.period);
  }
  final ch = parseChannelVarId(id);
  if (ch != null && ch.kn <= (maxKn < 0 ? 0 : maxKn)) {
    return _channelDef(ch.kn, ch.period, ch.band);
  }
  final peak = parseChipPeakVarId(id);
  if (peak != null && peak.kn == 0) {
    return _chipPeakDef(kind: peak.kind, suffix: peak.suffix);
  }
  for (final d in inventoryOnlyTradeVariables()) {
    if (d.matchesId(id)) return d;
  }
  return null;
}

TradeVariableDef _classNDef(int kn, int cls, {required bool buy}) {
  return TradeVariableDef(
    variableId: buy ? buyNVarId(kn, cls) : sellNVarId(kn, cls),
    displayName: 'K$kn ${tradeBsClassCn(cls)}类${buy ? "买" : "卖"}点',
    panel: TradePanel.structure,
    displayKn: kn,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: TradeEvalClock.k0Bar,
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.event,
    readiness: TradeReadiness.registered,
    source: buy
        ? 'buyNHistory 会话冻结，按 class=$cls 过滤；发现边沿'
        : 'sellNHistory 会话冻结，按 class=$cls 过滤；发现边沿',
    unit: 'event',
    futureSafe: true,
    availabilityNote: '首次发现当根才出现一次；动态段后续 x 不重复出交易事件',
    groupKey: 'bsN',
    groupLabel: 'N类BS',
    fieldLabel: '${tradeBsClassCn(cls)}${buy ? "买" : "卖"}',
    description:
        '${buy ? "BUY_N" : "SELL_N"}(class=$cls) EVENT_EXISTS；禁止比较/穿越',
  );
}

TradeVariableDef _maDef(int kn, int period) {
  return TradeVariableDef(
    variableId: maVarId(kn, period),
    displayName: 'K$kn均线$period',
    panel: TradePanel.main,
    displayKn: kn,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: evalClockForDisplayKn(kn),
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.numeric,
    readiness: TradeReadiness.registered,
    source: 'MathSeriesFreezeStore.mean(kn)[$period]，与图上均线同一仓',
    unit: 'price',
    futureSafe: true,
    availabilityNote: '冻结仓该格有数才可读；没有仓或空格=不可用，不现场重算',
    groupKey: 'ma',
    groupLabel: '均线',
    fieldLabel: '$period',
    description: '读冻结仓均线$period，禁止现场另算',
  );
}

TradeVariableDef _channelDef(int kn, int period, String band) {
  final isMax = band == 'MAX';
  return TradeVariableDef(
    variableId: channelVarId(kn, period, band),
    displayName: 'K$kn通道$period${isMax ? "上" : "下"}',
    panel: TradePanel.main,
    displayKn: kn,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: evalClockForDisplayKn(kn),
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.numeric,
    readiness: TradeReadiness.registered,
    source: 'MathSeriesFreezeStore.channel(kn)[$period].${isMax ? "max" : "min"}',
    unit: 'price',
    futureSafe: true,
    availabilityNote: '冻结仓该格有数才可读；没有仓或空格=不可用，不现场重算',
    groupKey: 'channel',
    groupLabel: '通道',
    fieldLabel: '$period${isMax ? "上" : "下"}',
    description: '读冻结仓通道，禁止现场另算',
  );
}

TradeVariableDef _demarkCompleteDef(int kn, {required bool buy}) {
  return TradeVariableDef(
    variableId: demarkCompleteId(kn, buy: buy),
    displayName: 'K$kn Demark完成${buy ? "买" : "卖"}',
    panel: TradePanel.main,
    displayKn: kn,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: TradeEvalClock.k0Bar,
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.event,
    readiness: TradeReadiness.registered,
    source: 'MathSeriesFreezeStore.demark(kn) 完成买/卖标记边沿',
    unit: 'event',
    futureSafe: true,
    availabilityNote: '完成买/卖当根出一次；持值阶梯不重复出事件',
    groupKey: 'demark',
    groupLabel: 'Demark',
    fieldLabel: buy ? '完成买' : '完成卖',
    description: 'EVENT_EXISTS；与 RSI/收盘同 zsMath 可 AND/OR',
  );
}

TradeVariableDef _chipPeakDef({
  required String kind,
  required String suffix,
}) {
  final isTick = kind == 'tick';
  final prefix = isTick ? 'K0笔数峰' : 'K0筹码峰';
  final token = chipPeakTokenOfSuffix(suffix);
  return TradeVariableDef(
    variableId: chipPeakVarId(kind: kind, token: token),
    displayName: '$prefix${suffix.isEmpty ? "" : suffix}',
    panel: TradePanel.sub,
    displayKn: 0,
    clockFamily: TradeClockFamily.zsMath,
    evalClock: TradeEvalClock.k0Bar,
    plotClock: TradePlotClock.k0Bar,
    valueType: TradeValueType.numeric,
    readiness: TradeReadiness.registered,
    source: isTick
        ? 'TickDistProfileCompute + classifyProfilePeaks；与十字笔数峰同一套编号'
        : 'ChipProfileCompute + classifyProfilePeaks；与十字筹码峰同一套编号',
    unit: 'price',
    futureSafe: true,
    availabilityNote: '这根没有对应编号的峰则为不可用，不会填 0、不沿用上一根',
    groupKey: isTick ? 'tickPeak' : 'chipPeak',
    groupLabel: isTick ? '笔数峰' : '筹码峰',
    fieldLabel: chipPeakFieldLabel(suffix),
    description: '峰价；框内多峰取离收盘更近的一颗；可与 K0 开高低收比',
  );
}
