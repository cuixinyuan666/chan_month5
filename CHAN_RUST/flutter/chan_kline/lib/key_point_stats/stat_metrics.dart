import 'dart:math' as math;

/// 计优 · 统计算子。
///
/// 数值型：样本数 / 非空率 / 平均数 / 中位数 / 标准差 / 最小 / 最大 / P25 / P75 / 众数（分桶近似）。
/// 类别型：样本数 / 非空率 / 精确众数 / 众数占比。
/// 空样本一律输出 null（界面显示「—」），不补 0、不前向填充。

/// 指标取值类别。
enum StatValueKind {
  numeric,
  categorical,
}

/// 一组样本（某个分组 × 某个指标）的统计结果。
class StatSummary {
  final String metricKey;

  /// 中文可读名（`MlFeatureLabel.toChinese` 口径）。
  final String labelCn;

  final StatValueKind kind;

  /// 有效样本数（该指标在关键点位上真正有值的条数）。
  final int sampleCount;

  /// 该分组的转折点总数（用于算非空率）。
  final int totalCount;

  // ---- 数值型 ----
  final double? mean;
  final double? median;
  final double? stddev;
  final double? min;
  final double? max;
  final double? p25;
  final double? p75;

  /// 数值众数（按 `modeDigits` 小数位分桶后的桶值，**近似**）。
  final double? mode;

  /// 数值众数桶命中的样本数。
  final int modeCount;

  // ---- 类别型 ----

  /// 类别众数（精确值）。
  final String? modeLabel;

  /// 众数占比（0..1）。
  final double? modeShare;

  const StatSummary({
    required this.metricKey,
    required this.labelCn,
    required this.kind,
    required this.sampleCount,
    required this.totalCount,
    this.mean,
    this.median,
    this.stddev,
    this.min,
    this.max,
    this.p25,
    this.p75,
    this.mode,
    this.modeCount = 0,
    this.modeLabel,
    this.modeShare,
  });

  double get coverage => totalCount <= 0 ? 0 : sampleCount / totalCount;

  bool get isEmpty => sampleCount == 0;

  Map<String, dynamic> toJson() => {
        'key': metricKey,
        'label': labelCn,
        'kind': kind.name,
        'samples': sampleCount,
        'total': totalCount,
        'coverage': coverage,
        if (kind == StatValueKind.numeric) ...{
          'mean': mean,
          'median': median,
          'stddev': stddev,
          'min': min,
          'max': max,
          'p25': p25,
          'p75': p75,
          'mode': mode,
          'mode_count': modeCount,
        } else ...{
          'mode_label': modeLabel,
          'mode_share': modeShare,
        },
      };
}

/// 布尔 → 中文类别标签（统计面板用，避免面板里出现 true/false）。
String statBoolLabel(bool v) => v ? '是' : '否';
/// 线性插值分位数（p ∈ [0,1]；输入须已排序且非空）。
double statPercentile(List<double> sorted, double p) {
  if (sorted.isEmpty) return double.nan;
  if (sorted.length == 1) return sorted.first;
  final pos = p.clamp(0.0, 1.0) * (sorted.length - 1);
  final lo = pos.floor();
  final hi = pos.ceil();
  if (lo == hi) return sorted[lo];
  final frac = pos - lo;
  return sorted[lo] + (sorted[hi] - sorted[lo]) * frac;
}

/// 总体标准差（除以 n：这批关键点位就是本次统计的总体）。
double statStddev(List<double> values, double mean) {
  if (values.isEmpty) return 0;
  var acc = 0.0;
  for (final v in values) {
    final d = v - mean;
    acc += d * d;
  }
  final variance = acc / values.length;
  return variance <= 0 ? 0 : math.sqrt(variance);
}

/// 数值型分桶众数：按 [modeDigits] 位小数四舍五入后取出现最多的桶值。
///
/// 这是**近似**众数（浮点指标不可能有精确众数），面板会标注桶宽。
({double? value, int count}) statNumericMode(
  List<double> values,
  int modeDigits,
) {
  if (values.isEmpty) return (value: null, count: 0);
  final factor = math.pow(10, modeDigits.clamp(0, 8)).toDouble();
  final buckets = <int, int>{};
  for (final v in values) {
    if (!v.isFinite) continue;
    final key = (v * factor).round();
    buckets[key] = (buckets[key] ?? 0) + 1;
  }
  if (buckets.isEmpty) return (value: null, count: 0);
  // 排序后遍历，保证「并列取最小值」——结果可复现，不受哈希顺序影响。
  var bestKey = 0;
  var bestCount = -1;
  final keys = buckets.keys.toList()..sort();
  for (final k in keys) {
    final c = buckets[k]!;
    if (c > bestCount) {
      bestCount = c;
      bestKey = k;
    }
  }
  return (value: bestKey / factor, count: bestCount);
}

/// 类别型精确众数；并列取字典序最小，同样保证可复现。
({String? value, int count}) statCategoricalMode(List<String> values) {
  if (values.isEmpty) return (value: null, count: 0);
  final counts = <String, int>{};
  for (final v in values) {
    counts[v] = (counts[v] ?? 0) + 1;
  }
  final keys = counts.keys.toList()..sort();
  var bestKey = keys.first;
  var bestCount = 0;
  for (final k in keys) {
    final c = counts[k]!;
    if (c > bestCount) {
      bestCount = c;
      bestKey = k;
    }
  }
  return (value: bestKey, count: bestCount);
}
/// 汇总数值型指标。
StatSummary numericStat({
  required String metricKey,
  required String labelCn,
  required List<double> rawValues,
  required int totalCount,
  int modeDigits = 4,
}) {
  final values = rawValues.where((e) => e.isFinite).toList()..sort();
  if (values.isEmpty) {
    return StatSummary(
      metricKey: metricKey,
      labelCn: labelCn,
      kind: StatValueKind.numeric,
      sampleCount: 0,
      totalCount: totalCount,
    );
  }
  final sum = values.fold(0.0, (a, b) => a + b);
  final mean = sum / values.length;
  final mode = statNumericMode(values, modeDigits);
  return StatSummary(
    metricKey: metricKey,
    labelCn: labelCn,
    kind: StatValueKind.numeric,
    sampleCount: values.length,
    totalCount: totalCount,
    mean: mean,
    median: statPercentile(values, 0.5),
    stddev: statStddev(values, mean),
    min: values.first,
    max: values.last,
    p25: statPercentile(values, 0.25),
    p75: statPercentile(values, 0.75),
    mode: mode.value,
    modeCount: mode.count,
  );
}

/// 汇总类别型指标。
StatSummary categoricalStat({
  required String metricKey,
  required String labelCn,
  required List<String> values,
  required int totalCount,
}) {
  if (values.isEmpty) {
    return StatSummary(
      metricKey: metricKey,
      labelCn: labelCn,
      kind: StatValueKind.categorical,
      sampleCount: 0,
      totalCount: totalCount,
    );
  }
  final mode = statCategoricalMode(values);
  return StatSummary(
    metricKey: metricKey,
    labelCn: labelCn,
    kind: StatValueKind.categorical,
    sampleCount: values.length,
    totalCount: totalCount,
    modeLabel: mode.value,
    modeCount: mode.count,
    modeShare: mode.count / values.length,
  );
}