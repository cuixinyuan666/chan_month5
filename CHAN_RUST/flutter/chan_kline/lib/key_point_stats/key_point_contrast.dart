import 'stat_metrics.dart';

/// 顶底差异度：同一指标在「本级别顶组」与「底组」之间的标准化差异。
///
/// 这是计优相对寻优**唯一不可替代**的价值 —— 寻优只告诉你「哪个组合能赚钱」，
/// 计优告诉你「转折点上这些指标长什么样、顶和底差在哪」。
///
/// 差异度 = |顶均值 − 底均值| / 合并标准差（RMS），合并标准差取两组标准差的
/// 均方根：`sqrt((s_top² + s_bottom²) / 2)`。用 RMS 而不是 (n-1) 加权公式，
/// 是因为 StatSummary 里的标准差是**总体口径**（除以 n），混用会自相矛盾。
class KeyPointContrast {
  /// 0 = K0 连线；1..n = K{n} 连线。
  final int level;

  final String metricKey;
  final String labelCn;

  final double topMean;
  final double bottomMean;

  /// 顶均值 − 底均值（带符号；正 = 顶更高）。
  final double deltaMean;

  /// 两组标准差的均方根。
  final double pooledSigma;

  /// 标准化差异度（|deltaMean| / pooledSigma）；越大顶底分得越开。
  final double contrast;

  final int topPoints;
  final int bottomPoints;

  const KeyPointContrast({
    required this.level,
    required this.metricKey,
    required this.labelCn,
    required this.topMean,
    required this.bottomMean,
    required this.deltaMean,
    required this.pooledSigma,
    required this.contrast,
    required this.topPoints,
    required this.bottomPoints,
  });

  /// 顶更高的指标为正方向，便于看「哪些指标在顶上更高」。
  bool get topHigher => deltaMean > 0;

  String get levelLabel => 'K$level';

  Map<String, dynamic> toJson() => {
        'level': level,
        'key': metricKey,
        'label': labelCn,
        'top_mean': topMean,
        'bottom_mean': bottomMean,
        'delta_mean': deltaMean,
        'pooled_sigma': pooledSigma,
        'contrast': contrast,
        'top_points': topPoints,
        'bottom_points': bottomPoints,
      };
}

/// 由两组的统计结果算出顶底差异表。
///
/// 只算**两侧都达到样本下限**、且合并标准差非零的指标；其余一律不出差异度
/// （宁可不给，也不给一个分母趋零时被放大的假差异）。
///
/// 结果按 [KeyPointContrast.contrast] 降序返回；同一 [contrast] 时按指标名、
/// 键升序，保证结果可复现、不受哈希顺序影响。
///
/// 只吃 [StatSummary] 列表而不吃分组类型，避免与 runner 形成循环依赖。
List<KeyPointContrast> computeContrasts({
  required List<StatSummary> topStats,
  required List<StatSummary> bottomStats,
  required int level,
  required int minPoints,
}) {
  final bottomByKey = {for (final s in bottomStats) s.metricKey: s};
  final out = <KeyPointContrast>[];

  for (final ts in topStats) {
    if (ts.kind != StatValueKind.numeric) continue;
    if (ts.sampleCount < minPoints) continue;
    final bs = bottomByKey[ts.metricKey];
    if (bs == null || bs.kind != StatValueKind.numeric) continue;
    if (bs.sampleCount < minPoints) continue;

    final tm = ts.mean;
    final bm = bs.mean;
    final tsd = ts.stddev;
    final bsd = bs.stddev;
    if (tm == null || bm == null || tsd == null || bsd == null) continue;

    final pooled = _rms(tsd, bsd);
    if (pooled <= 0) continue;

    final delta = tm - bm;
    out.add(KeyPointContrast(
      level: level,
      metricKey: ts.metricKey,
      labelCn: ts.labelCn,
      topMean: tm,
      bottomMean: bm,
      deltaMean: delta,
      pooledSigma: pooled,
      contrast: delta.abs() / pooled,
      topPoints: ts.sampleCount,
      bottomPoints: bs.sampleCount,
    ));
  }

  out.sort((a, b) {
    final c = b.contrast.compareTo(a.contrast);
    if (c != 0) return c;
    final l = a.labelCn.compareTo(b.labelCn);
    if (l != 0) return l;
    return a.metricKey.compareTo(b.metricKey);
  });
  return out;
}

double _rms(double a, double b) {
  final m = (a * a + b * b) / 2;
  return m <= 0 ? 0 : _sqrtApprox(m);
}

double _sqrtApprox(double x) {
  if (x <= 0) return 0;
  var g = x;
  for (var i = 0; i < 40 && g > 0; i++) {
    g = 0.5 * (g + x / g);
  }
  return g;
}