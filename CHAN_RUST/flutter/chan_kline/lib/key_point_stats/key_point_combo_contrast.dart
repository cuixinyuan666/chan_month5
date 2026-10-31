import 'key_point_contrast.dart';

/// 计优的组合区分度：找出哪几个指标一起看时，顶和底分得最开。
///
/// 单指标差异度只告诉你「这一个指标顶底差多少」。实战里转折往往是几个指标
/// 同时到位才算数。这里在单指标差异度最高的若干个里，用前向贪心找出组合：
/// 每加一个指标，看顶底两组在这些指标上的可分程度提升多少，留下提升最大的。
///
/// 结果是可读的规则，不是黑盒权重：列出每个指标在顶上更高还是更低，
/// 以及组合比单看最好的那个指标提升了多少。

/// 一个指标组合的区分结果。
class KeyPointComboContrast {
  /// 组合里的指标键（按加入顺序）。
  final List<String> metricKeys;

  /// 对应的中文名。
  final List<String> labelCns;

  /// 每个指标是否「顶上更高」。
  final List<bool> topHigher;

  /// 组合的区分度（越大顶底分得越开）。
  final double contrast;

  /// 相对组合里最好的单指标，区分度提升了多少（0 到 1 以上）。
  final double lift;

  final int level;

  const KeyPointComboContrast({
    required this.metricKeys,
    required this.labelCns,
    required this.topHigher,
    required this.contrast,
    required this.lift,
    required this.level,
  });

  /// 可读规则：`K1：RSI（顶更高）且 中枢上沿（顶更高），区分度 1.80，比单指标提升 20%`。
  String get ruleText {
    final parts = <String>[];
    for (var i = 0; i < labelCns.length; i++) {
      final dir = topHigher[i] ? '顶更高' : '底更高';
      parts.add('${labelCns[i]}（$dir）');
    }
    final liftPct = (lift * 100).toStringAsFixed(0);
    return 'K$level：${parts.join(' 且 ')}，区分度 ${contrast.toStringAsFixed(2)}'
        '，比单指标提升 $liftPct%';
  }

  Map<String, dynamic> toJson() => {
        'level': level,
        'keys': metricKeys,
        'labels': labelCns,
        'top_higher': topHigher,
        'contrast': contrast,
        'lift': lift,
        'rule': ruleText,
      };
}

/// 一个指标在各转折点上的取值列。
class MetricColumn {
  final String metricKey;
  final String labelCn;

  /// 顶组各点的取值（与 [bottomValues] 一一对应到各自的点）。
  final List<double> topValues;
  final List<double> bottomValues;

  const MetricColumn({
    required this.metricKey,
    required this.labelCn,
    required this.topValues,
    required this.bottomValues,
  });
}

/// 计算一个级别上的组合区分度。
///
/// [ranked] 是该级别已按差异度降序排好的单指标结果，取前 [topK] 个做候选。
/// [columns] 提供这些指标在每个转折点上的原始取值。
/// [maxSize] 组合长度上限。
///
/// 区分度的定义与单指标一致：两组均值之差的绝对值，除以组合并标准差。
/// 多指标时先把每个指标按自身标准差标准化，再求两组质心的距离。
List<KeyPointComboContrast> computeComboContrasts({
  required List<KeyPointContrast> ranked,
  required Map<String, MetricColumn> columns,
  required int level,
  int topK = 6,
  int maxSize = 3,
}) {
  final seeds = <_Seed>[];
  for (final c in ranked.take(topK)) {
    final col = columns[c.metricKey];
    if (col == null) continue;
    if (col.topValues.length < 2 || col.bottomValues.length < 2) continue;
    seeds.add(_Seed(contrast: c, column: col));
  }
  if (seeds.length < 2) return const [];

  final bestSingle = seeds.first.contrast.contrast;
  if (bestSingle <= 0) return const [];

  final out = <KeyPointComboContrast>[];
  var frontier = <List<_Seed>>[
    for (final s in seeds) [s],
  ];

  for (var size = 2; size <= maxSize; size++) {
    final next = <List<_Seed>>[];
    var bestGain = 0.0;
    List<_Seed>? bestSet;
    for (final base in frontier) {
      final have = base.map((s) => s.contrast.metricKey).toSet();
      for (final s in seeds) {
        if (have.contains(s.contrast.metricKey)) continue;
        final candidate = [...base, s];
        final contrast = _setContrast(candidate);
        if (contrast == null) continue;
        final gain = contrast - _setContrast(base)!;
        if (gain > bestGain) {
          bestGain = gain;
          bestSet = candidate;
        }
        next.add(candidate);
      }
    }
    if (bestSet == null || bestGain <= 0) break;
    final contrast = _setContrast(bestSet)!;
    out.add(KeyPointComboContrast(
      metricKeys: [for (final s in bestSet) s.contrast.metricKey],
      labelCns: [for (final s in bestSet) s.contrast.labelCn],
      topHigher: [for (final s in bestSet) s.contrast.topHigher],
      contrast: contrast,
      lift: (contrast - bestSingle) / bestSingle,
      level: level,
    ));
    frontier = next;
  }

  out.sort((a, b) => b.contrast.compareTo(a.contrast));
  return out;
}

class _Seed {
  final KeyPointContrast contrast;
  final MetricColumn column;
  const _Seed({required this.contrast, required this.column});
}

/// 一组指标的组合区分度：标准化后两组质心的欧氏距离。
/// 数据不足或没有离散度时返回 null。
double? _setContrast(List<_Seed> seeds) {
  if (seeds.isEmpty) return null;
  var sumSq = 0.0;
  for (final s in seeds) {
    final top = _mean(s.column.topValues);
    final bottom = _mean(s.column.bottomValues);
    final sigma = _pooledSigma(s.column.topValues, s.column.bottomValues);
    if (sigma <= 0) return null;
    final d = (top - bottom) / sigma;
    sumSq += d * d;
  }
  return _sqrt(sumSq);
}

double _mean(List<double> xs) {
  var s = 0.0;
  for (final x in xs) {
    s += x;
  }
  return s / xs.length;
}

double _pooledSigma(List<double> a, List<double> b) {
  double v(List<double> xs) {
    final m = _mean(xs);
    var s = 0.0;
    for (final x in xs) {
      s += (x - m) * (x - m);
    }
    return s / xs.length;
  }

  final m = (v(a) + v(b)) / 2;
  return m <= 0 ? 0 : _sqrt(m);
}

double _sqrt(double x) {
  if (x <= 0) return 0;
  var g = x;
  for (var i = 0; i < 40 && g > 0; i++) {
    g = 0.5 * (g + x / g);
  }
  return g;
}
