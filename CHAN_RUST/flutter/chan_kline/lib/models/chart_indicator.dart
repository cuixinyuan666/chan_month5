import 'divergence_algo.dart';
import 'k0_line.dart';
import 'level_models.dart';

/// 主图指标：连线 / 合并框 / KN线 / 中枢 / 延伸类 / 均线通道。
/// （筹码分布已迁出主图指标，改由设置面板总开关控制，仅保留 K0 分支）
enum MainIndicatorKind {
  line,
  combine,
  kn,
  zs,
  /// Kn三型平移线（前三确认分型：两同定斜率，过异型向右）
  fxTripleParallel,
  /// Kn四型对线（前四确认分型：两顶线+两底线向右）
  fxQuadPair,
  /// Kn趋势线（父段内子线端点拟合支撑/压力；子线层同号）
  trendLine,
  /// Kn均线（收盘价滑窗 MEAN；kn 同中枢显示层）
  meanLine,
  /// Kn通道（收盘价滑窗 MAX/MIN；kn 同中枢显示层）
  trendChannel,
  /// Kn布林带（MID/UP/DOWN；kn 同中枢）
  boll,
  /// Kn Demark（setup/countdown/完成信号；kn 同中枢；主图标注）
  demark,
}

/// 主图指标类别元数据。
extension MainIndicatorKindMeta on MainIndicatorKind {
  String get categoryLabel {
    switch (this) {
      case MainIndicatorKind.kn:
        return 'K线';
      case MainIndicatorKind.combine:
        return '合并';
      case MainIndicatorKind.zs:
        return '中枢';
      case MainIndicatorKind.line:
        return '连线';
      case MainIndicatorKind.fxTripleParallel:
      case MainIndicatorKind.fxQuadPair:
      case MainIndicatorKind.trendLine:
        return '延伸';
      case MainIndicatorKind.meanLine:
      case MainIndicatorKind.trendChannel:
      case MainIndicatorKind.boll:
        return '均线';
      case MainIndicatorKind.demark:
        return 'Demark';
    }
  }

  int get categoryOrder {
    switch (this) {
      case MainIndicatorKind.kn:
        return 0;
      case MainIndicatorKind.combine:
        return 1;
      case MainIndicatorKind.zs:
        return 2;
      case MainIndicatorKind.line:
        return 3;
      case MainIndicatorKind.fxTripleParallel:
      case MainIndicatorKind.fxQuadPair:
      case MainIndicatorKind.trendLine:
        return 4;
      case MainIndicatorKind.meanLine:
      case MainIndicatorKind.trendChannel:
      case MainIndicatorKind.boll:
        return 5;
      case MainIndicatorKind.demark:
        return 6;
    }
  }
}

/// 主图一项指标（按加载后 maxKn 动态生成）。
class MainChartIndicator {
  final MainIndicatorKind kind;
  /// kn=0：K0中枢/均线/通道（原生分钟K）；kn≥1：Kn中枢/均线/通道。
  /// 方案B：combine/line/kn/延伸 catalog kn==displayKn（K0连线 kn=0）。
  final int kn;

  const MainChartIndicator.line(this.kn) : kind = MainIndicatorKind.line;
  const MainChartIndicator.combine(this.kn) : kind = MainIndicatorKind.combine;
  const MainChartIndicator.kn(this.kn) : kind = MainIndicatorKind.kn;
  const MainChartIndicator.zs(this.kn) : kind = MainIndicatorKind.zs;
  const MainChartIndicator.fxTripleParallel(this.kn)
      : kind = MainIndicatorKind.fxTripleParallel;
  const MainChartIndicator.fxQuadPair(this.kn)
      : kind = MainIndicatorKind.fxQuadPair;
  const MainChartIndicator.trendLine(this.kn)
      : kind = MainIndicatorKind.trendLine;
  const MainChartIndicator.meanLine(this.kn)
      : kind = MainIndicatorKind.meanLine;
  const MainChartIndicator.trendChannel(this.kn)
      : kind = MainIndicatorKind.trendChannel;
  const MainChartIndicator.boll(this.kn) : kind = MainIndicatorKind.boll;
  const MainChartIndicator.demark(this.kn) : kind = MainIndicatorKind.demark;

  String get label {
    switch (kind) {
      case MainIndicatorKind.line:
        return 'K$kn连线';
      case MainIndicatorKind.combine:
        return 'K$kn合并';
      case MainIndicatorKind.kn:
        return 'K$kn';
      case MainIndicatorKind.zs:
        // 自定义命名：去掉「连续」，展示为「Kn中枢」
        return 'K$kn中枢';
      case MainIndicatorKind.fxTripleParallel:
        return 'K$kn三型平移线';
      case MainIndicatorKind.fxQuadPair:
        return 'K$kn四型对线';
      case MainIndicatorKind.trendLine:
        return 'K$kn趋势线';
      case MainIndicatorKind.meanLine:
        return 'K$kn均线';
      case MainIndicatorKind.trendChannel:
        return 'K$kn通道';
      case MainIndicatorKind.boll:
        return 'K$kn布林';
      case MainIndicatorKind.demark:
        return 'K${kn}Demark';
    }
  }

  /// 显示层号（K0/K1/…），用于「Kn指标」全选。方案B：连线族 kn 即 display。
  int get displayLevel {
    return kn;
  }

  /// 同层内展示序：… → 均线 → 通道 → 布林。
  int get kindOrderInLevel {
    switch (kind) {
      case MainIndicatorKind.kn:
        return 0;
      case MainIndicatorKind.combine:
        return 1;
      case MainIndicatorKind.zs:
        return 2;
      case MainIndicatorKind.line:
        return 3;
      case MainIndicatorKind.fxTripleParallel:
        return 4;
      case MainIndicatorKind.fxQuadPair:
        return 5;
      case MainIndicatorKind.trendLine:
        return 6;
      case MainIndicatorKind.meanLine:
        return 7;
      case MainIndicatorKind.trendChannel:
        return 8;
      case MainIndicatorKind.boll:
        return 9;
      case MainIndicatorKind.demark:
        return 10;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MainChartIndicator && other.kind == kind && other.kn == kn;

  @override
  int get hashCode => Object.hash(kind, kn);
}

/// 副图指标种类。
enum SubIndicatorKind {
  volume,
  /// Kn笔数：逐笔离线数据，与成交量同设计逻辑（B/S 红绿着色）
  tickCount,
  fractalConfirm,
  fractalJudgment,
  fractalPeakDist,
  truncation,
  /// Kn中枢确认（is_sure=true 首次当步；与中枢同号）
  zsConfirm,
  /// Kn中枢判断（is_sure=false；离开窗≥2不确定可逐K；单开放只首次）
  zsJudgment,
  buy1,
  buy2,
  /// 三类及以上（bsClass=3..）
  buyN,
  /// Kn相邻连线比例（旧 adjacent_bi_ratio；与 Kn连线同号；动态计算）
  adjacentRatio,
  /// Kn步进节奏副图（old step_rhythm；与 Kn连线同号；动态计算）
  stepRhythm,
  /// Kn连线斜率（与 Kn连线同号；动态：冻段+展示轨）
  lineSlope,
  /// Kn MACD（动态 Kn close；kn 同中枢）
  macd,
  /// Kn RSI
  rsi,
  /// Kn KDJ
  kdj,
  /// Kn背驰（分算法；kn 同中枢；输出 in/out/ratio/diver）
  divergence,
}

/// 副图指标类别元数据。
extension SubIndicatorKindMeta on SubIndicatorKind {
  String get categoryLabel {
    switch (this) {
      case SubIndicatorKind.volume:
        return '成交量';
      case SubIndicatorKind.tickCount:
        return '笔数';
      case SubIndicatorKind.fractalConfirm:
        return '分型确认';
      case SubIndicatorKind.fractalJudgment:
        return '分型判断';
      case SubIndicatorKind.fractalPeakDist:
        return '分型极点距';
      case SubIndicatorKind.truncation:
        return '截断';
      case SubIndicatorKind.zsConfirm:
        return '中枢确认';
      case SubIndicatorKind.zsJudgment:
        return '中枢判断';
      case SubIndicatorKind.buy1:
        return '一类BS';
      case SubIndicatorKind.buy2:
        return '二类BS';
      case SubIndicatorKind.buyN:
        return 'N类BS';
      case SubIndicatorKind.adjacentRatio:
        return '比例';
      case SubIndicatorKind.stepRhythm:
        return '节奏';
      case SubIndicatorKind.lineSlope:
        return '斜率';
      case SubIndicatorKind.macd:
        return 'MACD';
      case SubIndicatorKind.rsi:
        return 'RSI';
      case SubIndicatorKind.kdj:
        return 'KDJ';
      case SubIndicatorKind.divergence:
        return '背驰';
    }
  }

  int get categoryOrder {
    switch (this) {
      case SubIndicatorKind.volume:
        return 0;
      case SubIndicatorKind.tickCount:
        return 1;
      case SubIndicatorKind.fractalConfirm:
        return 2;
      case SubIndicatorKind.fractalJudgment:
        return 3;
      case SubIndicatorKind.fractalPeakDist:
        return 4;
      case SubIndicatorKind.truncation:
        return 5;
      case SubIndicatorKind.zsConfirm:
        return 6;
      case SubIndicatorKind.zsJudgment:
        return 7;
      case SubIndicatorKind.buy1:
        return 8;
      case SubIndicatorKind.buy2:
        return 9;
      case SubIndicatorKind.buyN:
        return 10;
      case SubIndicatorKind.adjacentRatio:
        return 11;
      case SubIndicatorKind.stepRhythm:
        return 12;
      case SubIndicatorKind.lineSlope:
        return 13;
      case SubIndicatorKind.macd:
        return 14;
      case SubIndicatorKind.rsi:
        return 15;
      case SubIndicatorKind.kdj:
        return 16;
      case SubIndicatorKind.divergence:
        return 17;
    }
  }
}

/// 类号中文（副图命名：三类/四类…）
String bsClassChinese(int cls) {
  const names = <int, String>{
    1: '一',
    2: '二',
    3: '三',
    4: '四',
    5: '五',
    6: '六',
    7: '七',
    8: '八',
    9: '九',
    10: '十',
    11: '十一',
    12: '十二',
    13: '十三',
    14: '十四',
    15: '十五',
    16: '十六',
    17: '十七',
    18: '十八',
    19: '十九',
    20: '二十',
  };
  // >9 须用中文名，避免 K1+11 →「K111类BS」粘连
  return names[cls] ?? '$cls';
}

/// 副图一项指标。
class SubChartIndicator {
  final SubIndicatorKind kind;
  final int kn;
  /// 仅 buyN：类号 ≥3；其它 kind 为 null
  final int? bsClass;
  /// 仅 divergence：12 力度算法分项
  final DivergenceAlgo? diverAlgo;

  /// kn=0：K0成交量；kn≥1：Kn成交量（LevelBundle.level==kn）。
  const SubChartIndicator.volume(this.kn)
      : kind = SubIndicatorKind.volume,
        bsClass = null,
        diverAlgo = null;
  /// kn=0：K0笔数；kn≥1：Kn笔数（逐笔离线数据，与成交量同设计逻辑）。
  const SubChartIndicator.tickCount(this.kn)
      : kind = SubIndicatorKind.tickCount,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.fractalConfirm(this.kn)
      : kind = SubIndicatorKind.fractalConfirm,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.fractalJudgment(this.kn)
      : kind = SubIndicatorKind.fractalJudgment,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.fractalPeakDist(this.kn)
      : kind = SubIndicatorKind.fractalPeakDist,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.truncation(this.kn)
      : kind = SubIndicatorKind.truncation,
        bsClass = null,
        diverAlgo = null;
  /// kn 与中枢同号：K0中枢确认…Kn中枢确认
  const SubChartIndicator.zsConfirm(this.kn)
      : kind = SubIndicatorKind.zsConfirm,
        bsClass = null,
        diverAlgo = null;
  /// kn 与中枢同号：K0中枢判断…Kn中枢判断
  const SubChartIndicator.zsJudgment(this.kn)
      : kind = SubIndicatorKind.zsJudgment,
        bsClass = null,
        diverAlgo = null;
  /// kn 与中枢同号：K0一类BS…Kn一类BS（买+卖同槽）
  const SubChartIndicator.buy1(this.kn)
      : kind = SubIndicatorKind.buy1,
        bsClass = null,
        diverAlgo = null;
  /// kn 与中枢同号：K0二类BS…Kn二类BS（买+卖同槽）
  const SubChartIndicator.buy2(this.kn)
      : kind = SubIndicatorKind.buy2,
        bsClass = null,
        diverAlgo = null;
  /// kn 与中枢同号：K0三类BS…；bsClass≥3
  const SubChartIndicator.buyN(this.kn, this.bsClass)
      : kind = SubIndicatorKind.buyN,
        diverAlgo = null;
  /// kn=连线显示层：K0相邻比例…（动态：冻段+展示轨虚线；方案B 数据 level==kn）
  const SubChartIndicator.adjacentRatio(this.kn)
      : kind = SubIndicatorKind.adjacentRatio,
        bsClass = null,
        diverAlgo = null;
  /// kn=连线显示层：K0步进节奏…（动态子线，不要求已确认）
  const SubChartIndicator.stepRhythm(this.kn)
      : kind = SubIndicatorKind.stepRhythm,
        bsClass = null,
        diverAlgo = null;
  /// kn=连线显示层：K0连线斜率…（动态：冻段+展示轨；方案B 数据 level==kn）
  const SubChartIndicator.lineSlope(this.kn)
      : kind = SubIndicatorKind.lineSlope,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.macd(this.kn)
      : kind = SubIndicatorKind.macd,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.rsi(this.kn)
      : kind = SubIndicatorKind.rsi,
        bsClass = null,
        diverAlgo = null;
  const SubChartIndicator.kdj(this.kn)
      : kind = SubIndicatorKind.kdj,
        bsClass = null,
        diverAlgo = null;
  /// kn 同中枢；algo=力度算法
  const SubChartIndicator.divergence(this.kn, DivergenceAlgo algo)
      : kind = SubIndicatorKind.divergence,
        bsClass = null,
        diverAlgo = algo;

  String get label {
    switch (kind) {
      case SubIndicatorKind.volume:
        return 'K$kn成交量';
      case SubIndicatorKind.tickCount:
        return 'K$kn笔数';
      case SubIndicatorKind.fractalConfirm:
        return 'K$kn分型确认';
      case SubIndicatorKind.fractalJudgment:
        return 'K$kn分型判断';
      // 方案B：kn==display；K0 数据源=k0_confirm/feat
      case SubIndicatorKind.fractalPeakDist:
        return 'K$kn分型极点距';
      case SubIndicatorKind.truncation:
        return 'K$kn截断';
      case SubIndicatorKind.zsConfirm:
        return 'K$kn中枢确认';
      case SubIndicatorKind.zsJudgment:
        return 'K$kn中枢判断';
      case SubIndicatorKind.buy1:
        return 'K$kn一类BS';
      case SubIndicatorKind.buy2:
        return 'K$kn二类BS';
      case SubIndicatorKind.buyN:
        return 'K$kn${bsClassChinese(bsClass ?? 3)}类BS';
      case SubIndicatorKind.adjacentRatio:
        return 'K$kn比例';
      case SubIndicatorKind.stepRhythm:
        return 'K$kn节奏';
      case SubIndicatorKind.lineSlope:
        return 'K$kn连线斜率';
      case SubIndicatorKind.macd:
        return 'K${kn}MACD';
      case SubIndicatorKind.rsi:
        return 'K${kn}RSI';
      case SubIndicatorKind.kdj:
        return 'K${kn}KDJ';
      case SubIndicatorKind.divergence:
        return 'K$kn背驰_${diverAlgo?.key ?? "?"}';
    }
  }

  /// 显示层号。方案B：全体 catalog kn 即 displayKn。
  int get displayLevel => kn;

  @override
  bool operator ==(Object other) =>
      other is SubChartIndicator &&
      other.kind == kind &&
      other.kn == kn &&
      other.bsClass == bsClass &&
      other.diverAlgo == diverAlgo;

  @override
  int get hashCode => Object.hash(kind, kn, bsClass, diverAlgo);
}

/// 方案B：chartMaxKn = structureMax+1；无 levels 有 k0Lines→1；全空→0。
/// 有 structure level==0 时勿再走「m==0 && k0Lines→1」旧逻辑。
int chartMaxKn({
  required List<LevelBundle> levels,
  List<K0Line> k0Lines = const [],
}) {
  if (levels.isEmpty) {
    return k0Lines.isNotEmpty ? 1 : 0;
  }
  var structureMax = 0;
  for (final lv in levels) {
    if (lv.level > structureMax) structureMax = lv.level;
  }
  return structureMax + 1;
}

List<MainChartIndicator> buildMainIndicatorCatalog(int maxKn) {
  final out = <MainChartIndicator>[];
  // 方案B：连线族 0..maxKn-1；中枢/Math 0..maxKn；趋势线上界 structureMax-1=maxKn-2（至少占位0）
  final lineHi = maxKn < 1 ? 0 : maxKn - 1;
  final lineCount = lineHi < 0 ? 0 : lineHi + 1;
  final knMax = lineCount < 1 ? 1 : lineCount;
  final combineMax = knMax;
  // 按类别分组：K线 → 合并 → 中枢 → 连线 → 延伸（筹码分布已迁设置·仅K0，不在目录）
  for (var d = 0; d < knMax; d++) {
    out.add(MainChartIndicator.kn(d));
  }
  for (var d = 0; d < combineMax; d++) {
    out.add(MainChartIndicator.combine(d));
  }
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.zs(d));
  }
  for (var d = 0; d < maxKn; d++) {
    out.add(MainChartIndicator.line(d));
  }
  // 三型平移 / 四型对线（与连线同号：d=0→K0）
  for (var d = 0; d < maxKn; d++) {
    out.add(MainChartIndicator.fxTripleParallel(d));
  }
  for (var d = 0; d < maxKn; d++) {
    out.add(MainChartIndicator.fxQuadPair(d));
  }
  // 趋势线：子=displayKn、父=displayKn+1；maxKn<2 仍挂 K0 占位
  final trendMax = maxKn < 2 ? 0 : maxKn - 2;
  for (var d = 0; d <= trendMax; d++) {
    out.add(MainChartIndicator.trendLine(d));
  }
  // 均线 / 通道（与中枢同号：d=0→K0）
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.meanLine(d));
  }
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.trendChannel(d));
  }
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.boll(d));
  }
  // Demark（与中枢同号；主图标注）
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.demark(d));
  }
  return out;
}

/// 副图 catalog；[maxBsClass] 默认至少 9，数据更高时调用方传入扩大。
/// 按类别分组：成交量 → … → 相邻比例 → 步进节奏 → 连线斜率。
List<SubChartIndicator> buildSubIndicatorCatalog(
  int maxKn, {
  bool truncationCheck = true,
  int maxBsClass = 9,
}) {
  final out = <SubChartIndicator>[];
  final hi = maxBsClass < 3 ? 3 : maxBsClass;
  final maxD = maxKn;
  // 成交量 (0..maxKn)
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.volume(d));
  }
  // 笔数 (0..maxKn)
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.tickCount(d));
  }
  // 方案B：分型/截断与连线同号 0..maxKn-1
  for (var d = 0; d < maxKn; d++) {
    out.add(SubChartIndicator.fractalConfirm(d));
  }
  for (var d = 0; d < maxKn; d++) {
    out.add(SubChartIndicator.fractalJudgment(d));
  }
  for (var d = 0; d < maxKn; d++) {
    out.add(SubChartIndicator.fractalPeakDist(d));
  }
  if (truncationCheck) {
    for (var d = 0; d < maxKn; d++) {
      out.add(SubChartIndicator.truncation(d));
    }
  }
  // 中枢确认 / 中枢判断 (0..maxKn，与中枢同号)
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.zsConfirm(d));
  }
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.zsJudgment(d));
  }
  // 一类BS (0..maxKn)
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.buy1(d));
  }
  // 二类BS (0..maxKn)
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.buy2(d));
  }
  // N类BS (0..maxKn, cls 3..hi)
  for (var d = 0; d <= maxD; d++) {
    for (var cls = 3; cls <= hi; cls++) {
      out.add(SubChartIndicator.buyN(d, cls));
    }
  }
  // 相邻比例 (0..maxKn-1)
  for (var d = 0; d < maxKn; d++) {
    out.add(SubChartIndicator.adjacentRatio(d));
  }
  // 步进节奏 (0..maxKn-1)
  for (var d = 0; d < maxKn; d++) {
    out.add(SubChartIndicator.stepRhythm(d));
  }
  // 连线斜率 (0..maxKn-1)
  for (var d = 0; d < maxKn; d++) {
    out.add(SubChartIndicator.lineSlope(d));
  }
  // MACD / RSI / KDJ (0..maxKn，与中枢同号)
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.macd(d));
  }
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.rsi(d));
  }
  for (var d = 0; d <= maxD; d++) {
    out.add(SubChartIndicator.kdj(d));
  }
  // Demark 已迁主图（MainIndicatorKind.demark）
  // 背驰：按算法分类，层内 0..maxKn（12 算法；默认不勾）
  for (final algo in DivergenceAlgoMeta.all) {
    for (var d = 0; d <= maxD; d++) {
      out.add(SubChartIndicator.divergence(d, algo));
    }
  }
  return out;
}

/// 主图「K{displayLevel}指标」层全选成员（仅返回 catalog 内存在的项）。
/// 层内序：… → 趋势线 → 均线 → 通道。
List<MainChartIndicator> mainIndicatorsForLevel(
  int displayLevel,
  List<MainChartIndicator> catalog,
) {
  final allow = catalog.toSet();
  // 方案B：连线/分型用 *(displayLevel)，不再 +1
  final candidates = <MainChartIndicator>[
    MainChartIndicator.kn(displayLevel),
    MainChartIndicator.combine(displayLevel),
    MainChartIndicator.zs(displayLevel),
    MainChartIndicator.line(displayLevel),
    MainChartIndicator.fxTripleParallel(displayLevel),
    MainChartIndicator.fxQuadPair(displayLevel),
    MainChartIndicator.trendLine(displayLevel),
    MainChartIndicator.meanLine(displayLevel),
    MainChartIndicator.trendChannel(displayLevel),
    MainChartIndicator.boll(displayLevel),
    MainChartIndicator.demark(displayLevel),
  ];
  return candidates.where(allow.contains).toList();
}

/// 副图「K{displayLevel}指标」层全选成员。
/// 含比例/节奏/斜率/MACD/RSI/KDJ/背驰算法（catalog 有才入选；Demark 已迁主图）。
List<SubChartIndicator> subIndicatorsForLevel(
  int displayLevel,
  List<SubChartIndicator> catalog, {
  int maxBsClass = 9,
}) {
  final allow = catalog.toSet();
  // 方案B：分型类 kn==displayLevel
  final candidates = <SubChartIndicator>[
    SubChartIndicator.volume(displayLevel),
    SubChartIndicator.tickCount(displayLevel),
    SubChartIndicator.fractalConfirm(displayLevel),
    SubChartIndicator.fractalJudgment(displayLevel),
    SubChartIndicator.fractalPeakDist(displayLevel),
    SubChartIndicator.truncation(displayLevel),
    SubChartIndicator.zsConfirm(displayLevel),
    SubChartIndicator.zsJudgment(displayLevel),
    SubChartIndicator.buy1(displayLevel),
    SubChartIndicator.buy2(displayLevel),
    // 必须进「Kn指标」层全选（与连线同显示层）
    SubChartIndicator.adjacentRatio(displayLevel),
    SubChartIndicator.stepRhythm(displayLevel),
    SubChartIndicator.lineSlope(displayLevel),
    SubChartIndicator.macd(displayLevel),
    SubChartIndicator.rsi(displayLevel),
    SubChartIndicator.kdj(displayLevel),
  ];
  final hi = maxBsClass < 3 ? 3 : maxBsClass;
  for (var cls = 3; cls <= hi; cls++) {
    candidates.add(SubChartIndicator.buyN(displayLevel, cls));
  }
  // 背驰 12 算法：进「Kn指标」层全选（默认启动仍不勾，见 defaultSubIndicatorsK0）
  for (final algo in DivergenceAlgoMeta.all) {
    candidates.add(SubChartIndicator.divergence(displayLevel, algo));
  }
  return candidates.where(allow.contains).toList();
}

/// 主图可选的显示层列表（有成员才出「Kn指标」）。
List<int> mainDisplayLevels(List<MainChartIndicator> catalog) {
  final levels = <int>{};
  for (final e in catalog) {
    levels.add(e.displayLevel);
  }
  final sorted = levels.toList()..sort();
  return sorted;
}

/// 副图可选的显示层列表。
List<int> subDisplayLevels(List<SubChartIndicator> catalog) {
  final levels = <int>{};
  for (final e in catalog) {
    levels.add(e.displayLevel);
  }
  final sorted = levels.toList()..sort();
  return sorted;
}

Set<T> pruneIndicators<T>(Set<T> selected, List<T> catalog) {
  final allow = catalog.toSet();
  return selected.where(allow.contains).toSet();
}

/// 启动默认：勾选「K0指标」层全选（与选择栏层全选同口径）。
/// 用 catalog(maxKn=1) 生成，保证含 K0连线 / 副图分型类与相邻比例/节奏。
/// （筹码分布由设置面板控制，不在默认指标内）
Set<MainChartIndicator> defaultMainIndicatorsK0() {
  return mainIndicatorsForLevel(0, buildMainIndicatorCatalog(1)).toSet();
}

/// 启动默认：副图「K0指标」层全选，但背驰 12 项默认不勾（可在选择栏「K0指标」里一键勾上）。
Set<SubChartIndicator> defaultSubIndicatorsK0({bool truncationCheck = true}) {
  return subIndicatorsForLevel(
    0,
    buildSubIndicatorCatalog(1, truncationCheck: truncationCheck),
  ).where((e) => e.kind != SubIndicatorKind.divergence).toSet();
}

/// 层全选关联后默认「实际绘制」的主图（其余关联项默认删除线静音）。
/// 重要：关联≠全画——「Kn指标」仍勾全集，但启动/新层只亮：
/// Kn / Kn合并 / Kn中枢 / Kn连线；其它进 `_mutedMains`，单击 chip 可打开。
bool isDefaultDrawnMain(MainChartIndicator e) {
  switch (e.kind) {
    case MainIndicatorKind.kn:
    case MainIndicatorKind.combine:
    case MainIndicatorKind.zs:
    case MainIndicatorKind.line:
      return true;
    case MainIndicatorKind.fxTripleParallel:
    case MainIndicatorKind.fxQuadPair:
    case MainIndicatorKind.trendLine:
    case MainIndicatorKind.meanLine:
    case MainIndicatorKind.trendChannel:
    case MainIndicatorKind.boll:
    case MainIndicatorKind.demark:
      return false;
  }
}

/// 层全选关联后默认「实际绘制」的副图（其余关联项默认删除线静音）。
/// 重要：只亮分型确认/判断、截断、中枢确认/判断；成交量/BS/Math/背驰等默认 muted。
bool isDefaultDrawnSub(SubChartIndicator e) {
  switch (e.kind) {
    case SubIndicatorKind.fractalConfirm:
    case SubIndicatorKind.fractalJudgment:
    case SubIndicatorKind.truncation:
    case SubIndicatorKind.zsConfirm:
    case SubIndicatorKind.zsJudgment:
      return true;
    case SubIndicatorKind.volume:
    case SubIndicatorKind.tickCount:
    case SubIndicatorKind.fractalPeakDist:
    case SubIndicatorKind.buy1:
    case SubIndicatorKind.buy2:
    case SubIndicatorKind.buyN:
    case SubIndicatorKind.adjacentRatio:
    case SubIndicatorKind.stepRhythm:
    case SubIndicatorKind.lineSlope:
    case SubIndicatorKind.macd:
    case SubIndicatorKind.rsi:
    case SubIndicatorKind.kdj:
    case SubIndicatorKind.divergence:
      return false;
  }
}

/// 学习观察：勾选 MACD 类背驰（area/peak/full_area/diff）时自动并入同号 Kn MACD。
Set<SubChartIndicator> ensureMacdForDivergenceArea(
  Set<SubChartIndicator> selected,
) {
  final next = Set<SubChartIndicator>.from(selected);
  for (final e in selected) {
    if (e.kind == SubIndicatorKind.divergence &&
        isMacdDivergenceAlgo(e.diverAlgo)) {
      next.add(SubChartIndicator.macd(e.kn));
    }
  }
  return next;
}

/// 某层是否勾选了 MACD 类背驰（用于强制绘制同号 MACD）。
bool hasMacdDivergenceForKn(Set<SubChartIndicator> selected, int kn) {
  return selected.any((e) =>
      e.kind == SubIndicatorKind.divergence &&
      isMacdDivergenceAlgo(e.diverAlgo) &&
      e.kn == kn);
}

/// 某层用于 MACD 高亮的背驰算法（多选时优先级 area→peak→full_area→diff）。
DivergenceAlgo? macdDivergenceAlgoForKn(
  Set<SubChartIndicator> selected,
  int kn,
) {
  const order = [
    DivergenceAlgo.area,
    DivergenceAlgo.peak,
    DivergenceAlgo.fullArea,
    DivergenceAlgo.diff,
  ];
  for (final a in order) {
    if (selected.any((e) =>
        e.kind == SubIndicatorKind.divergence &&
        e.diverAlgo == a &&
        e.kn == kn)) {
      return a;
    }
  }
  return null;
}

/// 兼容旧名。
bool hasDivergenceAreaForKn(Set<SubChartIndicator> selected, int kn) =>
    hasMacdDivergenceForKn(selected, kn);
