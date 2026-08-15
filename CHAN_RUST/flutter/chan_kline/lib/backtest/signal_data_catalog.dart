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
}

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

/// 把已登记 id 换到另一层；该层没有对应变量（如 K1 成交量）则退回该层收盘。
String remapRegisteredVarId(String variableId, int newKn, {int maxKn = 8}) {
  final parts = variableId.split('.');
  if (parts.length < 3 || !parts[1].startsWith('K')) {
    return rawOhlcId(newKn, 'CLOSE');
  }
  parts[1] = 'K$newKn';
  final next = parts.join('.');
  final def = lookupTradeVariable(next, maxKn: maxKn);
  if (def != null && def.expressionReady) return next;
  return rawOhlcId(newKn, 'CLOSE');
}

int? knFromVariableId(String variableId) {
  final parts = variableId.split('.');
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
    description: '只登记 K0 原生成交量；Kn 成交量是铺平阶梯，本阶段不进公式',
  ));

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
      availabilityNote: '确认事件不等于当前已确认分型列表',
      groupKey: 'fxConfirm',
      groupLabel: '分型确认',
      fieldLabel: '确认',
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
      availabilityNote: '首次确认事件；不暴露中枢高低',
      groupKey: 'zsConfirm',
      groupLabel: '中枢确认',
      fieldLabel: '确认',
      description: 'EVENT_EXISTS；与 RSI/MACD 同 zsMath 可 AND/OR',
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
      pattern: 'MAIN.K{n}.MA',
      name: 'Kn均线',
      panel: TradePanel.main,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '有序列，但阶段0先跑通布林；均线周期组合下一阶段再登记',
    ),
    stub(
      pattern: 'MAIN.K{n}.CHANNEL',
      name: 'Kn通道',
      panel: TradePanel.main,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '同上，先不进公式',
    ),
    stub(
      pattern: 'MAIN.K{n}.DEMARK',
      name: 'KnDemark',
      panel: TradePanel.main,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.event,
      why: '主图标记事件，不是一根数值序列',
    ),
    stub(
      pattern: 'MAIN.K{n}.STEP_RHYTHM',
      name: 'Kn节奏',
      panel: TradePanel.main,
      clock: TradeClockFamily.line,
      type: TradeValueType.numeric,
      why: '关窗后持上个名字续写；不是普通收盘序列',
    ),
    stub(
      pattern: 'MAIN.K{n}.FX_TRIPLE',
      name: 'Kn三型平移线',
      panel: TradePanel.main,
      clock: TradeClockFamily.line,
      type: TradeValueType.numeric,
      why: '几何线，不是开高低收',
    ),
    stub(
      pattern: 'MAIN.K{n}.FX_QUAD',
      name: 'Kn四型对线',
      panel: TradePanel.main,
      clock: TradeClockFamily.line,
      type: TradeValueType.numeric,
      why: '几何线，不是开高低收',
    ),
    stub(
      pattern: 'MAIN.K{n}.TREND_LINE',
      name: 'Kn趋势线',
      panel: TradePanel.main,
      clock: TradeClockFamily.line,
      type: TradeValueType.numeric,
      why: '段内拟合线，不是序列格子',
    ),
    stub(
      pattern: 'SUB.K{n}.VOLUME',
      name: 'Kn成交量',
      panel: TradePanel.sub,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: 'K1+ 成交量是铺平后的层序列，不是虚拟K样本总量；本阶段只登记 RAW.K0.VOLUME',
    ),
    stub(
      pattern: 'SUB.K{n}.FRACTAL_JUDGMENT',
      name: 'Kn分型判断',
      panel: TradePanel.sub,
      clock: TradeClockFamily.line,
      type: TradeValueType.event,
      why: '对象是尚未确认的分型，不是新芽；未写边沿',
    ),
    stub(
      pattern: 'STRUCTURE.K{n}.ZS.HIGH',
      name: 'Kn中枢高',
      panel: TradePanel.structure,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '一根K上可能盖着多个框，没写清用哪一框',
    ),
    stub(
      pattern: 'STRUCTURE.K{n}.ZS.LOW',
      name: 'Kn中枢低',
      panel: TradePanel.structure,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '同上',
    ),
    stub(
      pattern: 'SUB.K{n}.DIVERGENCE',
      name: 'Kn背驰',
      panel: TradePanel.sub,
      clock: TradeClockFamily.zsMath,
      type: TradeValueType.numeric,
      why: '12 路算法，需先定用哪一路力度',
    ),
    stub(
      pattern: 'SUB.K{n}.LINE_SLOPE',
      name: 'Kn连线斜率',
      panel: TradePanel.sub,
      clock: TradeClockFamily.line,
      type: TradeValueType.numeric,
      why: '连线钟，不能直接和布林比',
    ),
    stub(
      pattern: 'SUB.K{n}.ADJACENT_RATIO',
      name: 'Kn比例',
      panel: TradePanel.sub,
      clock: TradeClockFamily.line,
      type: TradeValueType.numeric,
      why: '连线钟；虚实都算，未写进公式',
    ),
  ];
}

/// 在已登记表里找；找不到再看盘点模板。
TradeVariableDef? lookupTradeVariable(String variableId, {int maxKn = 8}) {
  for (final d in buildRegisteredTradeVariables(maxKn)) {
    if (d.variableId == variableId) return d;
  }
  for (final d in inventoryOnlyTradeVariables()) {
    if (d.matchesId(variableId)) return d;
  }
  return null;
}
