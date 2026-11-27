import 'key_point_stat_runner.dart';
import 'stat_metrics.dart';

/// 计优体检：只读旁路诊断，**不改动任何一个统计值、不改变分组**。
///
/// 存在的理由与寻优那边的 `SearchInfPayoffDiagnostics` 完全同源 ——
/// 审查发现「5 笔全胜的组合压过 50 笔稳态组合」，即**统计口径被小样本劫持**。
/// 计优这边同源的坑有两个：
///   1. 分组转折点太少（n=2~3 的均值/标准差没有统计意义）；
///   2. 数值众数桶命中占比过低（占位近似退化成「取最小值」）。
/// 本类把这两件事量化出来并在面板上提示，**但不改门槛、不改排序** ——
/// 先让数据说话，是否收紧口径由人来定。
class KeyPointStatDiagnostics {
  /// 全部转折点总数。
  final int totalPoints;

  /// 各分组（含汇总）的转折点数：groupKey → 点数。
  final Map<String, int> groupPoints;

  /// 样本量最小的分组点数（0 = 无分组）。
  final int minGroupPoints;

  /// 低于样本下限的分组个数。
  final int lowSampleGroupCount;

  /// 因样本不足而**未算出**顶底差异度的级别数。
  final int contrastSkippedLevels;

  /// 参与顶底差异度的级别数。
  final int contrastLevels;

  /// 全部统计项里被判为「无显著众数」的条数（数值型，按显著性阈值）。
  final int insignificantModeCount;

  /// 参与统计的指标总数（按去重后的键计）。
  final int metricTotal;

  /// 判定「样本偏少」用的下限（来自当次统计设置）。
  final int minPointsLimit;

  const KeyPointStatDiagnostics({
    required this.totalPoints,
    required this.groupPoints,
    required this.minGroupPoints,
    required this.lowSampleGroupCount,
    required this.contrastSkippedLevels,
    required this.contrastLevels,
    required this.insignificantModeCount,
    required this.metricTotal,
    this.minPointsLimit = 3,
  });

  static const empty = KeyPointStatDiagnostics(
    totalPoints: 0,
    groupPoints: {},
    minGroupPoints: 0,
    lowSampleGroupCount: 0,
    contrastSkippedLevels: 0,
    contrastLevels: 0,
    insignificantModeCount: 0,
    metricTotal: 0,
  );

  bool get hasRisk => lowSampleGroupCount > 0;

  factory KeyPointStatDiagnostics.of(KeyPointStatResult r) {
    final limit = r.settings.minPoints;

    final groupPoints = <String, int>{};
    for (final g in r.groups) {
      groupPoints[g.groupKey] = g.pointCount;
    }
    // 无分组时也要如实报出转折点数（体检恰恰是「为什么一张表都没出」的答案）
    if (r.groups.isEmpty) {
      return KeyPointStatDiagnostics(
        totalPoints: r.collect.keyPoints.length,
        groupPoints: const {},
        minGroupPoints: 0,
        lowSampleGroupCount: 0,
        contrastSkippedLevels: 0,
        contrastLevels: 0,
        insignificantModeCount: 0,
        metricTotal: 0,
        minPointsLimit: limit,
      );
    }
    final minGroup = groupPoints.values.reduce((a, b) => a < b ? a : b);
    final lowCount = groupPoints.values.where((n) => n < limit).length;

    // 顶底差异度：哪些级别算出来了
    final topKeys = r.groups
        .map((g) => g.groupKey)
        .where((k) => k.startsWith('L') && k.endsWith('_TOP'))
        .toList();
    var contrastOk = 0;
    var contrastSkip = 0;
    for (final topKey in topKeys) {
      final lv = int.tryParse(topKey.substring(1, topKey.indexOf('_')));
      if (lv == null) continue;
      if (r.contrastsForLevel(lv).isNotEmpty) {
        contrastOk++;
      } else {
        contrastSkip++;
      }
    }

    // 众数显著性：以「全部转折点」汇总组为准（它样本最大，最能代表整体）
    final all = r.groups.where((g) => g.groupKey == 'ALL').toList();
    final allStats = all.isEmpty ? <StatSummary>[] : all.first.stats;
    final thr = r.settings.modeMinShare;
    var insignificant = 0;
    var metricTotal = 0;
    for (final s in allStats) {
      metricTotal++;
      if (s.kind != StatValueKind.numeric) continue;
      final share = s.modeShare;
      if (share == null || share < thr) insignificant++;
    }

    return KeyPointStatDiagnostics(
      totalPoints: r.collect.keyPoints.length,
      groupPoints: groupPoints,
      minGroupPoints: minGroup,
      lowSampleGroupCount: lowCount,
      contrastSkippedLevels: contrastSkip,
      contrastLevels: contrastOk,
      insignificantModeCount: insignificant,
      metricTotal: metricTotal,
      minPointsLimit: limit,
    );
  }

  /// 面板上的一行体检结论（无数据时返回 null）。
  String? toDisplayLine() {
    if (totalPoints == 0) return null;
    final buf = StringBuffer()
      ..write('计优体检：转折点 $totalPoints 个 · 分组 ${groupPoints.length} 张')
      ..write(' · 最小样本组 $minGroupPoints 个（下限 $minPointsLimit）')
      ..write(' · 顶底差异度覆盖 $contrastLevels 级'
          '${contrastSkippedLevels > 0 ? '、跳过 $contrastSkippedLevels 级' : ''}');
    if (insignificantModeCount > 0) {
      buf.write(' · 数值指标 $insignificantModeCount/$metricTotal 项无显著众数');
    }
    if (lowSampleGroupCount > 0) {
      buf.write(' ⚠ 有 $lowSampleGroupCount 张分组样本偏少，其统计量仅供参考');
    }
    return buf.toString();
  }

  Map<String, dynamic> toJson() => {
        'total_points': totalPoints,
        'group_points': groupPoints,
        'min_group_points': minGroupPoints,
        'min_points_limit': minPointsLimit,
        'low_sample_groups': lowSampleGroupCount,
        'contrast_levels': contrastLevels,
        'contrast_skipped_levels': contrastSkippedLevels,
        'insignificant_modes': insignificantModeCount,
        'metric_total': metricTotal,
      };

  /// 供机器人报告直接取用：Top-N 顶底差异清单。
  ///
  /// 「有没有洞察」是主观判断、写不成断言，所以把差异最大的 N 项原样输出到
  /// JSON，由人看报告时判读；机器人只负责证明链路（逐根走完→出表→排序正确）。
  List<Map<String, dynamic>> topContrastJson(KeyPointStatResult r, int topN) =>
      [for (final c in r.contrasts.take(topN)) c.toJson()];
}