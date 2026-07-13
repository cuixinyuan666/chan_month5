import 'bi_segment.dart';
import 'level_models.dart';

/// 主图指标种类：连线 / 合并框。
enum MainIndicatorKind { line, combine }

/// 主图一项指标（按加载后 maxKn 动态生成，如 3 层 → K0/K1/K2 连线）。
class MainChartIndicator {
  final MainIndicatorKind kind;
  /// 内部层号：连线 1..maxKn（展示名 K(n-1)连线）；合并 0..maxKn（展示名 Kn合并）
  final int kn;

  const MainChartIndicator.line(this.kn) : kind = MainIndicatorKind.line;
  const MainChartIndicator.combine(this.kn) : kind = MainIndicatorKind.combine;

  /// 连线展示名比内部层号小 1：笔=K0连线，线段=K1连线；合并仍按层号。
  String get label =>
      kind == MainIndicatorKind.line ? 'K${kn - 1}连线' : 'K$kn合并';

  @override
  bool operator ==(Object other) =>
      other is MainChartIndicator && other.kind == kind && other.kn == kn;

  @override
  int get hashCode => Object.hash(kind, kn);
}

/// 副图指标种类。
enum SubIndicatorKind { volume, fractalConfirm, fractalPeakDist }

/// 副图一项指标（分型确认/极点距按层动态生成）。
class SubChartIndicator {
  final SubIndicatorKind kind;
  /// 分型确认/极点距：0..maxKn-1（对应 level=kn+1 的 confirms）
  final int kn;

  const SubChartIndicator.volume()
      : kind = SubIndicatorKind.volume,
        kn = 0;
  const SubChartIndicator.fractalConfirm(this.kn)
      : kind = SubIndicatorKind.fractalConfirm;
  const SubChartIndicator.fractalPeakDist(this.kn)
      : kind = SubIndicatorKind.fractalPeakDist;

  String get label {
    switch (kind) {
      case SubIndicatorKind.volume:
        return '成交量';
      case SubIndicatorKind.fractalConfirm:
        return 'K$kn分型确认';
      case SubIndicatorKind.fractalPeakDist:
        return 'K$kn分型极点距';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is SubChartIndicator && other.kind == kind && other.kn == kn;

  @override
  int get hashCode => Object.hash(kind, kn);
}

/// 当前数据最高 Kn（levels 最大 level；无 levels 但有笔段时为 1）。
int chartMaxKn({
  required List<LevelBundle> levels,
  List<BiSegment> biSegments = const [],
}) {
  var m = 0;
  for (final lv in levels) {
    if (lv.level > m) m = lv.level;
  }
  if (m == 0 && biSegments.isNotEmpty) m = 1;
  return m;
}

/// 主图可选列表：Kn合并(0..maxKn) + 连线展示 K0..K(maxKn-1)（内部层号 1..maxKn）；maxKn=0 仅 K0合并。
List<MainChartIndicator> buildMainIndicatorCatalog(int maxKn) {
  final out = <MainChartIndicator>[];
  final maxCombine = maxKn < 0 ? 0 : maxKn;
  for (var n = 0; n <= maxCombine; n++) {
    out.add(MainChartIndicator.combine(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(MainChartIndicator.line(n));
  }
  return out;
}

/// 副图可选列表：成交量 + Kn分型确认/极点距(0..maxKn-1)；maxKn=0 仅成交量。
List<SubChartIndicator> buildSubIndicatorCatalog(int maxKn) {
  final out = <SubChartIndicator>[const SubChartIndicator.volume()];
  final maxFx = maxKn > 0 ? maxKn - 1 : -1;
  for (var n = 0; n <= maxFx; n++) {
    out.add(SubChartIndicator.fractalConfirm(n));
  }
  for (var n = 0; n <= maxFx; n++) {
    out.add(SubChartIndicator.fractalPeakDist(n));
  }
  return out;
}

/// 裁掉当前目录里已不存在的已选项。
Set<T> pruneIndicators<T>(Set<T> selected, List<T> catalog) {
  final allow = catalog.toSet();
  return selected.where(allow.contains).toSet();
}
