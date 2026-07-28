import 'k0_line.dart';
import 'level_models.dart';

/// 主图指标：连线 / 合并框 / KN线 / Normal中枢 / OverSeg中枢。
enum MainIndicatorKind {
  line,
  combine,
  kn,
  zsNormal,
  zsOverSeg,
}

/// 主图一项指标（按加载后 maxKn 动态生成）。
class MainChartIndicator {
  final MainIndicatorKind kind;
  /// kn=0：K0中枢（原生分钟K）；kn≥1：Kn中枢（连线段）。
  final int kn;

  const MainChartIndicator.line(this.kn) : kind = MainIndicatorKind.line;
  const MainChartIndicator.combine(this.kn) : kind = MainIndicatorKind.combine;
  const MainChartIndicator.kn(this.kn) : kind = MainIndicatorKind.kn;
  const MainChartIndicator.zsNormal(this.kn)
      : kind = MainIndicatorKind.zsNormal;
  const MainChartIndicator.zsOverSeg(this.kn)
      : kind = MainIndicatorKind.zsOverSeg;

  String get label {
    switch (kind) {
      case MainIndicatorKind.line:
        return 'K${kn - 1}连线';
      case MainIndicatorKind.combine:
        return 'K${kn - 1}合并';
      case MainIndicatorKind.kn:
        return 'K${kn - 1}';
      case MainIndicatorKind.zsNormal:
        return 'K$kn中枢(Normal)';
      case MainIndicatorKind.zsOverSeg:
        return 'K$kn中枢(OverSeg)';
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
}

/// 副图一项指标。
class SubChartIndicator {
  final SubIndicatorKind kind;
  final int kn;

  const SubChartIndicator.volume()
      : kind = SubIndicatorKind.volume,
        kn = 0;
  const SubChartIndicator.fractalConfirm(this.kn)
      : kind = SubIndicatorKind.fractalConfirm;
  const SubChartIndicator.fractalJudgment(this.kn)
      : kind = SubIndicatorKind.fractalJudgment;
  const SubChartIndicator.fractalPeakDist(this.kn)
      : kind = SubIndicatorKind.fractalPeakDist;
  const SubChartIndicator.truncation(this.kn)
      : kind = SubIndicatorKind.truncation;

  String get label {
    switch (kind) {
      case SubIndicatorKind.volume:
        return '成交量';
      case SubIndicatorKind.fractalConfirm:
        return 'K${kn - 1}分型确认';
      case SubIndicatorKind.fractalJudgment:
        return 'K${kn - 1}分型判断';
      case SubIndicatorKind.fractalPeakDist:
        return 'K${kn - 1}分型极点距';
      case SubIndicatorKind.truncation:
        return 'K${kn - 1}截断';
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
  out.add(const MainChartIndicator.zsNormal(0));
  out.add(const MainChartIndicator.zsOverSeg(0));
  for (var n = 1; n <= maxKn; n++) {
    out.add(MainChartIndicator.zsNormal(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(MainChartIndicator.zsOverSeg(n));
  }
  return out;
}

List<SubChartIndicator> buildSubIndicatorCatalog(
  int maxKn, {
  bool truncationCheck = true,
}) {
  final out = <SubChartIndicator>[const SubChartIndicator.volume()];
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
  return out;
}

Set<T> pruneIndicators<T>(Set<T> selected, List<T> catalog) {
  final allow = catalog.toSet();
  return selected.where(allow.contains).toSet();
}
