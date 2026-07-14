import 'bi_segment.dart';
import 'level_models.dart';

/// 主图指标种类：连线 / 合并框 / 跨段中枢框。
enum MainIndicatorKind { line, combine, kuaduan }

/// 主图一项指标（按加载后 maxKn 动态生成，如 3 层 → K0/K1/K2 连线/合并/跨段中枢）。
class MainChartIndicator {
  final MainIndicatorKind kind;
  /// 内部层号（合并/连线/跨段中枢统一用层号）：1..maxKn。
  /// 展示名比层号小 1：连线=K(n-1)连线，合并=K(n-1)合并，跨段中枢=K(n-1)跨段中枢，三者同号对齐。
  final int kn;

  const MainChartIndicator.line(this.kn) : kind = MainIndicatorKind.line;
  const MainChartIndicator.combine(this.kn) : kind = MainIndicatorKind.combine;
  const MainChartIndicator.kuaduan(this.kn) : kind = MainIndicatorKind.kuaduan;

  /// 展示名比内部层号小 1：笔=K0连线、合并=K0合并、跨段中枢=K0跨段中枢，… 三者同号对齐。
  String get label {
    switch (kind) {
      case MainIndicatorKind.line:
        return 'K${kn - 1}连线';
      case MainIndicatorKind.combine:
        return 'K${kn - 1}合并';
      case MainIndicatorKind.kuaduan:
        return 'K${kn - 1}跨段中枢';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MainChartIndicator && other.kind == kind && other.kn == kn;

  @override
  int get hashCode => Object.hash(kind, kn);
}

/// 副图指标种类。
enum SubIndicatorKind { volume, fractalConfirm, fractalPeakDist, truncation }

/// 副图一项指标（分型确认/极点距/截断按层动态生成）。
class SubChartIndicator {
  final SubIndicatorKind kind;
  /// 分型确认/极点距/截断：1..maxKn（对应 level=kn 的 confirms；与主图 combine/line 同号=层号）
  final int kn;

  const SubChartIndicator.volume()
      : kind = SubIndicatorKind.volume,
        kn = 0;
  const SubChartIndicator.fractalConfirm(this.kn)
      : kind = SubIndicatorKind.fractalConfirm;
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

/// 主图可选列表：合并与连线统一按层号 1..maxKn 生成（展示名 K(n-1)）。
/// maxKn=0（无笔段）时仍保留 K0合并（combine(1)）可勾。
List<MainChartIndicator> buildMainIndicatorCatalog(int maxKn) {
  final out = <MainChartIndicator>[];
  // 合并与连线统一层号：combine(n)=Kn-1合并；maxKn=0 仍保留 K0合并
  final combineMax = maxKn < 1 ? 1 : maxKn;
  for (var n = 1; n <= combineMax; n++) {
    out.add(MainChartIndicator.combine(n));
  }
  for (var n = 1; n <= maxKn; n++) {
    out.add(MainChartIndicator.line(n));
  }
  // 跨段中枢框与合并/连线同号：kuaduan(n)=K(n-1)跨段中枢（笔跨段中枢=K0跨段中枢、线段跨段中枢=K1跨段中枢）
  for (var n = 1; n <= maxKn; n++) {
    out.add(MainChartIndicator.kuaduan(n));
  }
  return out;
}

/// 副图可选列表：成交量 + Kn分型确认/极点距/截断（1..maxKn，与主图 combine/line 同号=层号）；
/// 截断项仅在 [truncationCheck]=true 时出现。
List<SubChartIndicator> buildSubIndicatorCatalog(
  int maxKn, {
  bool truncationCheck = true,
}) {
  final out = <SubChartIndicator>[const SubChartIndicator.volume()];
  for (var n = 1; n <= maxKn; n++) {
    out.add(SubChartIndicator.fractalConfirm(n));
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

/// 裁掉当前目录里已不存在的已选项。
Set<T> pruneIndicators<T>(Set<T> selected, List<T> catalog) {
  final allow = catalog.toSet();
  return selected.where(allow.contains).toSet();
}
