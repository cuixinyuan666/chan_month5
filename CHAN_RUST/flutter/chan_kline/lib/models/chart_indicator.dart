import 'k0_line.dart';
import 'level_models.dart';

/// 主图指标：连线 / 合并框 / KN线 / 中枢 / 筹码分布。
enum MainIndicatorKind {
  line,
  combine,
  kn,
  zs,
  /// Kn筹码分布（主图右侧水平柱；全层同构）
  chip,
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
      case MainIndicatorKind.chip:
        return '筹码分布';
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
      case MainIndicatorKind.chip:
        return 4;
    }
  }
}

/// 主图一项指标（按加载后 maxKn 动态生成）。
class MainChartIndicator {
  final MainIndicatorKind kind;
  /// kn=0：K0中枢 / K0筹码（原生分钟K）；kn≥1：Kn中枢 / Kn筹码（连线段）。
  /// combine/line/kn：内部 kn≥1，显示层 = kn-1。
  final int kn;

  const MainChartIndicator.line(this.kn) : kind = MainIndicatorKind.line;
  const MainChartIndicator.combine(this.kn) : kind = MainIndicatorKind.combine;
  const MainChartIndicator.kn(this.kn) : kind = MainIndicatorKind.kn;
  const MainChartIndicator.zs(this.kn) : kind = MainIndicatorKind.zs;
  const MainChartIndicator.chip(this.kn) : kind = MainIndicatorKind.chip;

  String get label {
    switch (kind) {
      case MainIndicatorKind.line:
        return 'K${kn - 1}连线';
      case MainIndicatorKind.combine:
        return 'K${kn - 1}合并';
      case MainIndicatorKind.kn:
        return 'K${kn - 1}';
      case MainIndicatorKind.zs:
        // 自定义命名：去掉「连续」，展示为「Kn中枢」
        return 'K$kn中枢';
      case MainIndicatorKind.chip:
        return 'K$kn筹码分布';
    }
  }

  /// 显示层号（K0/K1/…），用于「Kn指标」全选与 chip 分隔。
  int get displayLevel {
    switch (kind) {
      case MainIndicatorKind.zs:
      case MainIndicatorKind.chip:
        return kn;
      case MainIndicatorKind.line:
      case MainIndicatorKind.combine:
      case MainIndicatorKind.kn:
        return kn - 1;
    }
  }

  /// 同层内展示序：Kn → Kn合并 → Kn中枢 → Kn连线 → Kn筹码分布（自定义·全层同构）。
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
      case MainIndicatorKind.chip:
        return 4;
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
  fractalConfirm,
  fractalJudgment,
  fractalPeakDist,
  truncation,
  buy1,
  buy2,
  /// 三类及以上（bsClass=3..）
  buyN,
  /// Kn相邻连线比例（旧 adjacent_bi_ratio；与 Kn连线同号；动态计算）
  adjacentRatio,
  /// Kn步进节奏副图（旧 step_rhythm；与 Kn连线同号；动态计算）
  stepRhythm,
}

/// 副图指标类别元数据。
extension SubIndicatorKindMeta on SubIndicatorKind {
  String get categoryLabel {
    switch (this) {
      case SubIndicatorKind.volume:
        return '成交量';
      case SubIndicatorKind.fractalConfirm:
        return '分型确认';
      case SubIndicatorKind.fractalJudgment:
        return '分型判断';
      case SubIndicatorKind.fractalPeakDist:
        return '分型极点距';
      case SubIndicatorKind.truncation:
        return '截断';
      case SubIndicatorKind.buy1:
        return '一类BS';
      case SubIndicatorKind.buy2:
        return '二类BS';
      case SubIndicatorKind.buyN:
        return 'N类BS';
      case SubIndicatorKind.adjacentRatio:
        return '相邻比例';
      case SubIndicatorKind.stepRhythm:
        return '步进节奏';
    }
  }

  int get categoryOrder {
    switch (this) {
      case SubIndicatorKind.volume:
        return 0;
      case SubIndicatorKind.fractalConfirm:
        return 1;
      case SubIndicatorKind.fractalJudgment:
        return 2;
      case SubIndicatorKind.fractalPeakDist:
        return 3;
      case SubIndicatorKind.truncation:
        return 4;
      case SubIndicatorKind.buy1:
        return 5;
      case SubIndicatorKind.buy2:
        return 6;
      case SubIndicatorKind.buyN:
        return 7;
      case SubIndicatorKind.adjacentRatio:
        return 8;
      case SubIndicatorKind.stepRhythm:
        return 9;
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
  };
  return names[cls] ?? '$cls';
}

/// 副图一项指标。
class SubChartIndicator {
  final SubIndicatorKind kind;
  final int kn;
  /// 仅 buyN：类号 ≥3；其它 kind 为 null
  final int? bsClass;

  /// kn=0：K0成交量；kn≥1：Kn成交量（LevelBundle.level==kn）。
  const SubChartIndicator.volume(this.kn)
      : kind = SubIndicatorKind.volume,
        bsClass = null;
  const SubChartIndicator.fractalConfirm(this.kn)
      : kind = SubIndicatorKind.fractalConfirm,
        bsClass = null;
  const SubChartIndicator.fractalJudgment(this.kn)
      : kind = SubIndicatorKind.fractalJudgment,
        bsClass = null;
  const SubChartIndicator.fractalPeakDist(this.kn)
      : kind = SubIndicatorKind.fractalPeakDist,
        bsClass = null;
  const SubChartIndicator.truncation(this.kn)
      : kind = SubIndicatorKind.truncation,
        bsClass = null;
  /// kn 与中枢同号：K0一类BS…Kn一类BS（买+卖同槽）
  const SubChartIndicator.buy1(this.kn)
      : kind = SubIndicatorKind.buy1,
        bsClass = null;
  /// kn 与中枢同号：K0二类BS…Kn二类BS（买+卖同槽）
  const SubChartIndicator.buy2(this.kn)
      : kind = SubIndicatorKind.buy2,
        bsClass = null;
  /// kn 与中枢同号：K0三类BS…；bsClass≥3
  const SubChartIndicator.buyN(this.kn, this.bsClass)
      : kind = SubIndicatorKind.buyN;
  /// kn=连线显示层：K0相邻比例…（动态：冻段+展示轨虚线；数据 level==kn+1）
  const SubChartIndicator.adjacentRatio(this.kn)
      : kind = SubIndicatorKind.adjacentRatio,
        bsClass = null;
  /// kn=连线显示层：K0步进节奏…（动态子线，不要求已确认）
  const SubChartIndicator.stepRhythm(this.kn)
      : kind = SubIndicatorKind.stepRhythm,
        bsClass = null;

  String get label {
    switch (kind) {
      case SubIndicatorKind.volume:
        return 'K$kn成交量';
      case SubIndicatorKind.fractalConfirm:
        return 'K${kn - 1}分型确认';
      case SubIndicatorKind.fractalJudgment:
        return 'K${kn - 1}分型判断';
      case SubIndicatorKind.fractalPeakDist:
        return 'K${kn - 1}分型极点距';
      case SubIndicatorKind.truncation:
        return 'K${kn - 1}截断';
      case SubIndicatorKind.buy1:
        return 'K$kn一类BS';
      case SubIndicatorKind.buy2:
        return 'K$kn二类BS';
      case SubIndicatorKind.buyN:
        return 'K$kn${bsClassChinese(bsClass ?? 3)}类BS';
      case SubIndicatorKind.adjacentRatio:
        return 'K$kn相邻比例';
      case SubIndicatorKind.stepRhythm:
        return 'K$kn步进节奏';
    }
  }

  /// 显示层号（成交量/BS/相邻比例/节奏 kn 直接；分型类 kn-1）。
  int get displayLevel {
    switch (kind) {
      case SubIndicatorKind.volume:
      case SubIndicatorKind.buy1:
      case SubIndicatorKind.buy2:
      case SubIndicatorKind.buyN:
      case SubIndicatorKind.adjacentRatio:
      case SubIndicatorKind.stepRhythm:
        return kn;
      case SubIndicatorKind.fractalConfirm:
      case SubIndicatorKind.fractalJudgment:
      case SubIndicatorKind.fractalPeakDist:
      case SubIndicatorKind.truncation:
        return kn - 1;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SubChartIndicator &&
      other.kind == kind &&
      other.kn == kn &&
      other.bsClass == bsClass;

  @override
  int get hashCode => Object.hash(kind, kn, bsClass);
}

int chartMaxKn({
  required List<LevelBundle> levels,
  List<K0Line> k0Lines = const [],
}) {
  var m = 0;
  for (final lv in levels) {
    if (lv.level > m) m = lv.level;
  }
  if (m == 0 && k0Lines.isNotEmpty) m = 1;
  return m;
}

List<MainChartIndicator> buildMainIndicatorCatalog(int maxKn) {
  final out = <MainChartIndicator>[];
  final combineMax = maxKn < 1 ? 1 : maxKn;
  final knMax = maxKn < 1 ? 1 : maxKn;
  // 按类别分组：K线 → 合并 → 中枢 → 连线 → 筹码分布
  for (var d = 1; d <= knMax; d++) {
    out.add(MainChartIndicator.kn(d));
  }
  for (var d = 1; d <= combineMax; d++) {
    out.add(MainChartIndicator.combine(d));
  }
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.zs(d));
  }
  for (var d = 1; d <= maxKn; d++) {
    out.add(MainChartIndicator.line(d));
  }
  for (var d = 0; d <= maxKn; d++) {
    out.add(MainChartIndicator.chip(d));
  }
  return out;
}

/// 副图 catalog；[maxBsClass] 默认至少 9，数据更高时调用方传入扩大。
/// 按类别分组：成交量 → 分型确认 → 分型判断 → 分型极点距 → 截断 → 一类BS → 二类BS → N类BS → 相邻比例 → 步进节奏。
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
  // 分型确认 (1..maxKn, internal kn)
  for (var d = 1; d <= maxKn; d++) {
    out.add(SubChartIndicator.fractalConfirm(d));
  }
  // 分型判断 (1..maxKn)
  for (var d = 1; d <= maxKn; d++) {
    out.add(SubChartIndicator.fractalJudgment(d));
  }
  // 分型极点距 (1..maxKn)
  for (var d = 1; d <= maxKn; d++) {
    out.add(SubChartIndicator.fractalPeakDist(d));
  }
  // 截断 (1..maxKn)
  if (truncationCheck) {
    for (var d = 1; d <= maxKn; d++) {
      out.add(SubChartIndicator.truncation(d));
    }
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
  return out;
}

/// 主图「K{displayLevel}指标」层全选成员（仅返回 catalog 内存在的项）。
/// 层内序：Kn → Kn合并 → Kn中枢 → Kn连线 → Kn筹码分布。
List<MainChartIndicator> mainIndicatorsForLevel(
  int displayLevel,
  List<MainChartIndicator> catalog,
) {
  final allow = catalog.toSet();
  final candidates = <MainChartIndicator>[
    MainChartIndicator.kn(displayLevel + 1),
    MainChartIndicator.combine(displayLevel + 1),
    MainChartIndicator.zs(displayLevel),
    MainChartIndicator.line(displayLevel + 1),
    MainChartIndicator.chip(displayLevel),
  ];
  return candidates.where(allow.contains).toList();
}

/// 副图「K{displayLevel}指标」层全选成员。
/// 含 Kn相邻比例 / Kn步进节奏（与连线同号；catalog 有才入选）。
List<SubChartIndicator> subIndicatorsForLevel(
  int displayLevel,
  List<SubChartIndicator> catalog, {
  int maxBsClass = 9,
}) {
  final allow = catalog.toSet();
  final candidates = <SubChartIndicator>[
    SubChartIndicator.volume(displayLevel),
    SubChartIndicator.fractalConfirm(displayLevel + 1),
    SubChartIndicator.fractalJudgment(displayLevel + 1),
    SubChartIndicator.fractalPeakDist(displayLevel + 1),
    SubChartIndicator.truncation(displayLevel + 1),
    SubChartIndicator.buy1(displayLevel),
    SubChartIndicator.buy2(displayLevel),
    // 必须进「Kn指标」层全选（与连线同显示层）
    SubChartIndicator.adjacentRatio(displayLevel),
    SubChartIndicator.stepRhythm(displayLevel),
  ];
  final hi = maxBsClass < 3 ? 3 : maxBsClass;
  for (var cls = 3; cls <= hi; cls++) {
    candidates.add(SubChartIndicator.buyN(displayLevel, cls));
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
/// 用 catalog(maxKn=1) 生成，保证含 K0连线 / K0筹码 / 副图分型类与相邻比例/节奏。
Set<MainChartIndicator> defaultMainIndicatorsK0() {
  return mainIndicatorsForLevel(0, buildMainIndicatorCatalog(1)).toSet();
}

/// 启动默认：副图「K0指标」层全选（含相邻比例/步进节奏，与层全选同口径）。
Set<SubChartIndicator> defaultSubIndicatorsK0({bool truncationCheck = true}) {
  return subIndicatorsForLevel(
    0,
    buildSubIndicatorCatalog(1, truncationCheck: truncationCheck),
  ).toSet();
}
