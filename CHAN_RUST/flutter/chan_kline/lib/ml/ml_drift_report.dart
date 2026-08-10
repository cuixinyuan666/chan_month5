import 'dart:math' as math;

import 'ml_bsp_sample.dart';
import 'ml_dataset_split.dart';
import 'ml_feature_flat.dart';

/// 标签率 + 简单特征漂移（训练 vs 测试）。
class MlDriftReport {
  const MlDriftReport({
    required this.trainLabelRate,
    required this.validLabelRate,
    required this.testLabelRate,
    required this.trainN,
    required this.validN,
    required this.testN,
    required this.featureCompared,
    required this.driftedFeatureCount,
    required this.maxAbsZ,
    required this.topDriftFeatures,
    required this.alert,
  });

  final double trainLabelRate;
  final double validLabelRate;
  final double testLabelRate;
  final int trainN;
  final int validN;
  final int testN;
  final int featureCompared;
  final int driftedFeatureCount;
  /// 测试均值相对训练标准差的最大 |z|
  final double maxAbsZ;
  final List<String> topDriftFeatures;
  final bool alert;

  String get labelRateSummary {
    String p(double r, int n) =>
        n == 0 ? '-' : '${(r * 100).toStringAsFixed(1)}%(n=$n)';
    return '标签√率 训练${p(trainLabelRate, trainN)} · '
        '验证${p(validLabelRate, validN)} · '
        '测试${p(testLabelRate, testN)}';
  }

  String get driftSummary {
    if (featureCompared == 0) return '特征漂移：无可比特征';
    final flag = alert ? '⚠疑似漂移' : '未见显著漂移';
    return '特征漂移：$flag · 漂移特征$driftedFeatureCount/$featureCompared'
        ' · max|z|=${maxAbsZ.toStringAsFixed(2)}'
        '${topDriftFeatures.isEmpty ? "" : " · 例:${topDriftFeatures.take(3).join(",")}"}';
  }

  static double _rate(List<MlBspSample> xs) {
    if (xs.isEmpty) return 0;
    return xs.where((e) => e.isCorrect == true).length / xs.length;
  }

  static MlDriftReport build(List<MlBspSample> samples) {
    final train = MlDatasetSplit.trainOf(samples);
    final valid = MlDatasetSplit.validOf(samples);
    final test = MlDatasetSplit.testOf(samples);

    final names = <String>{};
    for (final s in train) {
      names.addAll(s.features.keys);
    }
    final sorted = names.toList()..sort();

    final trainMean = <String, double>{};
    final trainStd = <String, double>{};
    final trainCnt = <String, int>{};
    for (final name in sorted) {
      var sum = 0.0;
      var n = 0;
      for (final s in train) {
        final v = s.features[name];
        if (v == null || v == MlFeatureFlat.missing) continue;
        sum += v;
        n++;
      }
      trainCnt[name] = n;
      trainMean[name] = n == 0 ? 0 : sum / n;
    }
    for (final name in sorted) {
      final m = trainMean[name]!;
      var ss = 0.0;
      var n = 0;
      for (final s in train) {
        final v = s.features[name];
        if (v == null || v == MlFeatureFlat.missing) continue;
        final d = v - m;
        ss += d * d;
        n++;
      }
      trainStd[name] = n > 1 ? math.sqrt(ss / (n - 1)) : 1.0;
      if (trainStd[name]! < 1e-9) trainStd[name] = 1.0;
    }

    final zList = <({String name, double z})>[];
    var compared = 0;
    var drifted = 0;
    for (final name in sorted) {
      if ((trainCnt[name] ?? 0) < 3) continue;
      var sum = 0.0;
      var n = 0;
      for (final s in test) {
        final v = s.features[name];
        if (v == null || v == MlFeatureFlat.missing) continue;
        sum += v;
        n++;
      }
      if (n < 2) continue;
      compared++;
      final z = ((sum / n) - trainMean[name]!) / trainStd[name]!;
      zList.add((name: name, z: z));
      if (z.abs() >= 1.5) drifted++;
    }
    zList.sort((a, b) => b.z.abs().compareTo(a.z.abs()));
    final maxZ = zList.isEmpty ? 0.0 : zList.first.z.abs();
    final top = zList
        .take(5)
        .map((e) => '${e.name}(z=${e.z.toStringAsFixed(1)})')
        .toList();

    // 标签率差或特征漂移超阈则报警
    final tr = _rate(train);
    final te = _rate(test);
    final labelGap = (tr - te).abs();
    final alert = (compared > 0 && drifted / compared >= 0.25) ||
        maxZ >= 2.5 ||
        (train.isNotEmpty && test.isNotEmpty && labelGap >= 0.2);

    return MlDriftReport(
      trainLabelRate: tr,
      validLabelRate: _rate(valid),
      testLabelRate: te,
      trainN: train.length,
      validN: valid.length,
      testN: test.length,
      featureCompared: compared,
      driftedFeatureCount: drifted,
      maxAbsZ: maxZ,
      topDriftFeatures: top,
      alert: alert,
    );
  }
}
