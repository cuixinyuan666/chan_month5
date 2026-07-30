import 'k0_line.dart';
import 'level_models.dart';

/// 主图指标：连线 / 合并框 / KN线 / 连续中枢。
enum MainIndicatorKind {
  line,
  combine,
  kn,
  zs,
}

/// 主图一项指标（按加载后 maxKn 动态生成）。
class MainChartIndicator {
  final MainIndicatorKind kind;
  /// kn=0：K0连续中枢（原生分钟K）；kn≥1：Kn连续中枢（连线段）。
  /// combine/line/kn：内部 kn≥1，显示层 = kn-1。
  final int kn;

  const MainChartIndicator.line(this.kn) : kind = MainIndicatorKind.line;
  const MainChartIndicator.combine(this.kn) : kind = MainIndicatorKind.combine;
  const MainChartIndicator.kn(this.kn) : kind = MainIndicatorKind.kn;
  const MainChartIndicator.zs(this.kn) : kind = MainIndicatorKind.zs;

  String get label {
    switch (kind) {
      case MainIndicatorKind.line:
        return 'K${kn - 1}连线';
      case MainIndicatorKind.combine:
        return 'K${kn - 1}合并';
      case MainIndicatorKind.kn:
        return 'K${kn - 1}';
      case MainIndicatorKind.zs:
        return 'K$kn连续中枢';
    }
  }

  /// 显示层号（K0/K1/…），用于「Kn指标」全选与 chip 分隔。
  int get displayLevel {
    switch (kind) {
      case MainIndicatorKind.zs:
        return kn;
      case MainIndicatorKind.line:
      case MainIndicatorKind.combine:
      case MainIndicatorKind.kn:
        return kn - 1;
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
}

/// 副图一项指标。
class SubChartIndicator {
  final SubIndicatorKind kind;
  final int kn;

  /// kn=0：K0成交量；kn≥1：Kn成交量（LevelBundle.level==kn）。
  const SubChartIndicator.volume(this.kn) : kind = SubIndicatorKind.volume;
  const SubChartIndicator.fractalConfirm(this.kn)
      : kind = SubIndicatorKind.fractalConfirm;
  const SubChartIndicator.fractalJudgment(this.kn)
      : kind = SubIndicatorKind.fractalJudgment;
  const SubChartIndicator.fractalPeakDist(this.kn)
      : kind = SubIndicatorKind.fractalPeakDist;
  const SubChartIndicator.truncation(this.kn)
      : kind = SubIndicatorKind.truncation;
  /// kn 与中枢同号：K0一类BS…Kn一类BS（买+卖同槽）
  const SubChartIndicator.buy1(this.kn) : kind = SubIndicatorKind.buy1;
  /// kn 与中枢同号：K0二类BS…Kn二类BS（买+卖同槽）
  const SubChartIndicator.buy2(this.kn) : kind = SubIndicatorKind.buy2;

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
    }
  }

  /// 显示层号（成交量/一类/二类 kn 直接；分型类 kn-1）。
  int get displayLevel {
    switch (kind) {
      case SubIndicatorKind.volume:
      case SubIndicatorKind.buy1:
      case SubIndicatorKind.buy2:
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
      other is SubChartIndicator && other.kind == kind && other.kn == kn;

  @override
  int get hashCode => Object.hash(kind, kn);
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
  for (var n = 1; n <= combineMax; n++) {
    out.add(MainChartIndicator.combine(n));
  }
  final knMax = maxKn < 1 ? 1 : maxKn;
  for (var n = 1; n <= knMax; n++) {
    out.add(MainChartIndicator.kn(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(MainChartIndicator.line(n));
  }
  for (var n = 0; n <= maxKn; n++) {
    out.add(MainChartIndicator.zs(n));
  }
  return out;
}

List<SubChartIndicator> buildSubIndicatorCatalog(
  int maxKn, {
  bool truncationCheck = true,
}) {
  final out = <SubChartIndicator>[];
  // Kn成交量：K0=原生量；K1..=对应 LevelBundle.level
  for (var n = 0; n <= maxKn; n++) {
    out.add(SubChartIndicator.volume(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(SubChartIndicator.fractalConfirm(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(SubChartIndicator.fractalJudgment(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(SubChartIndicator.fractalPeakDist(n));
  }
  if (truncationCheck) {
    for (var n = 1; n <= maxKn; n++) {
      out.add(SubChartIndicator.truncation(n));
    }
  }
  // Kn一类BS：与连续中枢同层同号（K0..Kn）
  for (var n = 0; n <= maxKn; n++) {
    out.add(SubChartIndicator.buy1(n));
  }
  // Kn二类BS：与一类同层同号（K0..Kn）
  for (var n = 0; n <= maxKn; n++) {
    out.add(SubChartIndicator.buy2(n));
  }
  return out;
}

/// 主图「K{displayLevel}指标」层全选成员（仅返回 catalog 内存在的项）。
List<MainChartIndicator> mainIndicatorsForLevel(
  int displayLevel,
  List<MainChartIndicator> catalog,
) {
  final allow = catalog.toSet();
  final candidates = <MainChartIndicator>[
    MainChartIndicator.kn(displayLevel + 1),
    MainChartIndicator.combine(displayLevel + 1),
    MainChartIndicator.line(displayLevel + 1),
    MainChartIndicator.zs(displayLevel),
  ];
  return candidates.where(allow.contains).toList();
}

/// 副图「K{displayLevel}指标」层全选成员。
List<SubChartIndicator> subIndicatorsForLevel(
  int displayLevel,
  List<SubChartIndicator> catalog,
) {
  final allow = catalog.toSet();
  final candidates = <SubChartIndicator>[
    SubChartIndicator.volume(displayLevel),
    SubChartIndicator.fractalConfirm(displayLevel + 1),
    SubChartIndicator.fractalJudgment(displayLevel + 1),
    SubChartIndicator.fractalPeakDist(displayLevel + 1),
    SubChartIndicator.truncation(displayLevel + 1),
    SubChartIndicator.buy1(displayLevel),
    SubChartIndicator.buy2(displayLevel),
  ];
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
/// 用 catalog(maxKn=1) 生成，保证含 K0连线 / 副图分型类。
Set<MainChartIndicator> defaultMainIndicatorsK0() {
  return mainIndicatorsForLevel(0, buildMainIndicatorCatalog(1)).toSet();
}

/// 启动默认：副图「K0指标」层全选（成交量+分型确认/判断/极点距/截断）。
Set<SubChartIndicator> defaultSubIndicatorsK0({bool truncationCheck = true}) {
  return subIndicatorsForLevel(
    0,
    buildSubIndicatorCatalog(1, truncationCheck: truncationCheck),
  ).toSet();
}
