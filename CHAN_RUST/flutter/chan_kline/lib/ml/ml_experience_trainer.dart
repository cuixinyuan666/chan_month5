import 'dart:math' as math;

import 'ml_bsp_sample.dart';
import 'ml_dataset_split.dart';
import 'ml_drift_report.dart';
import 'ml_feature_flat.dart';

/// 训练集学出的经验（内存逻辑回归；阈值可经验证集选定）。
class MlExperienceModel {
  const MlExperienceModel({
    required this.featureNames,
    required this.weights,
    required this.bias,
    required this.means,
    required this.stds,
    this.threshold = 0.5,
    this.fitEpochs = 0,
    this.fitLr = 0,
    this.fitL2 = 0,
  });

  final List<String> featureNames;
  final List<double> weights;
  final double bias;
  final List<double> means;
  final List<double> stds;
  final double threshold;
  final int fitEpochs;
  final double fitLr;
  final double fitL2;

  MlExperienceModel withThreshold(double t) => MlExperienceModel(
        featureNames: featureNames,
        weights: weights,
        bias: bias,
        means: means,
        stds: stds,
        threshold: t,
        fitEpochs: fitEpochs,
        fitLr: fitLr,
        fitL2: fitL2,
      );

  double scoreOf(Map<String, double> features) {
    var z = bias;
    for (var i = 0; i < featureNames.length; i++) {
      final raw = features[featureNames[i]] ?? MlFeatureFlat.missing;
      if (raw == MlFeatureFlat.missing) continue;
      final s = stds[i];
      final x = s > 1e-9 ? (raw - means[i]) / s : 0.0;
      z += weights[i] * x;
    }
    if (z >= 0) {
      final e = math.exp(-z);
      return 1.0 / (1.0 + e);
    }
    final e = math.exp(z);
    return e / (1.0 + e);
  }

  bool adopt(double score) => score >= threshold;
}

/// 某一分割上的胜率等统计。
class MlSplitStats {
  const MlSplitStats({
    required this.total,
    required this.alphaWin,
    required this.alphaLose,
    required this.alphaWinRate,
    required this.adopted,
    required this.adoptedWin,
    required this.adoptedLose,
    required this.experienceWinRate,
    required this.experienceAccuracy,
    required this.coverage,
    required this.buyAdopted,
    required this.buyAdoptedWin,
    required this.sellAdopted,
    required this.sellAdoptedWin,
  });

  final int total;
  final int alphaWin;
  final int alphaLose;
  final double alphaWinRate;
  final int adopted;
  final int adoptedWin;
  final int adoptedLose;
  final double experienceWinRate;
  final double experienceAccuracy;
  final double coverage;
  final int buyAdopted;
  final int buyAdoptedWin;
  final int sellAdopted;
  final int sellAdoptedWin;

  /// 验证集选参用：先准再胜再覆盖
  double get tuneScore =>
      experienceAccuracy * 1000 + experienceWinRate * 10 + coverage;
}

/// XGB 附加信息（同一套采纳/胜率统计仍走 [MlRunReport]）。
class MlXgbExtras {
  const MlXgbExtras({
    required this.modelPath,
    required this.sidecarPath,
    required this.trainAuc,
    required this.validAuc,
    required this.numRounds,
    required this.elapsedSec,
    this.skipped = false,
  });

  final String modelPath;
  final String sidecarPath;
  final double? trainAuc;
  final double? validAuc;
  final int numRounds;
  final double elapsedSec;
  final bool skipped;
}

/// 跑完后的总报告：验证只用于调参说明；测试只报一次。
class MlRunReport {
  const MlRunReport({
    required this.trainTotal,
    required this.trainWinRate,
    required this.validStats,
    required this.testStats,
    required this.bestEpochs,
    required this.bestLr,
    required this.bestL2,
    required this.bestThreshold,
    required this.tuneTrials,
    required this.drift,
    this.testLocked = true,
    this.trainerKind = 'lr',
    this.xgb,
  });

  final int trainTotal;
  final double trainWinRate;
  final MlSplitStats validStats;
  final MlSplitStats testStats;
  final int bestEpochs;
  final double bestLr;
  final double bestL2;
  final double bestThreshold;
  final int tuneTrials;
  final MlDriftReport drift;
  final bool testLocked;

  /// `lr` | `xgb`
  final String trainerKind;
  final MlXgbExtras? xgb;

  /// 兼容旧字段名（UI 曾用 examStats）
  MlSplitStats get examStats => testStats;

  bool get isXgb => trainerKind == 'xgb';

  String get headline {
    final t = testStats;
    if (t.total == 0) return '测试集为空';
    if (t.adopted == 0) {
      return '测试集未采纳 · 基准胜率 ${(t.alphaWinRate * 100).toStringAsFixed(1)}%';
    }
    final prefix = isXgb ? 'XGB' : '测试';
    return '$prefix经验胜率 ${(t.experienceWinRate * 100).toStringAsFixed(1)}%'
        '（采纳${t.adopted} √${t.adoptedWin}/×${t.adoptedLose}）'
        ' · 基准 ${(t.alphaWinRate * 100).toStringAsFixed(1)}%';
  }

  String get tuneSummary {
    if (isXgb && xgb != null) {
      final x = xgb!;
      String auc(double? v) =>
          v == null ? '-' : v.toStringAsFixed(3);
      return 'XGB：rounds=${x.numRounds} thr=${bestThreshold.toStringAsFixed(2)}'
          ' · trainAUC=${auc(x.trainAuc)} validAUC=${auc(x.validAuc)}'
          ' · ${x.elapsedSec.toStringAsFixed(1)}s'
          '${x.skipped ? " · 复用已有模型" : ""}'
          ' · 验证准确率${(validStats.experienceAccuracy * 100).toStringAsFixed(1)}%';
    }
    return '验证调参×$tuneTrials：epochs=$bestEpochs lr=${bestLr.toStringAsFixed(2)} '
        'l2=${bestL2.toStringAsExponential(0)} thr=${bestThreshold.toStringAsFixed(2)}'
        ' · 验证准确率${(validStats.experienceAccuracy * 100).toStringAsFixed(1)}%';
  }
}
/// 兼容旧名
typedef MlExamStats = MlRunReport;

/// 训练 → 验证调参 → 测试只评估一次。
class MlExperienceTrainer {
  MlExperienceTrainer._();

  static const _epochGrid = [20, 40, 60];
  static const _lrGrid = [0.05, 0.15];
  static const _l2Grid = [1e-4, 1e-3];

  static MlExperienceModel fit(
    List<MlBspSample> train, {
    int epochs = 40,
    double lr = 0.15,
    double l2 = 1e-3,
    double threshold = 0.5,
  }) {
    final names = <String>{};
    for (final s in train) {
      names.addAll(s.features.keys);
    }
    final featureNames = names.toList()..sort();
    final dim = featureNames.length;
    if (dim == 0 || train.isEmpty) {
      return MlExperienceModel(
        featureNames: const [],
        weights: const [],
        bias: 0,
        means: const [],
        stds: const [],
        threshold: threshold,
        fitEpochs: epochs,
        fitLr: lr,
        fitL2: l2,
      );
    }

    final means = List<double>.filled(dim, 0);
    final stds = List<double>.filled(dim, 1);
    final counts = List<int>.filled(dim, 0);
    for (final s in train) {
      for (var i = 0; i < dim; i++) {
        final v = s.features[featureNames[i]];
        if (v == null || v == MlFeatureFlat.missing) continue;
        means[i] += v;
        counts[i]++;
      }
    }
    for (var i = 0; i < dim; i++) {
      if (counts[i] > 0) means[i] /= counts[i];
    }
    for (final s in train) {
      for (var i = 0; i < dim; i++) {
        final v = s.features[featureNames[i]];
        if (v == null || v == MlFeatureFlat.missing) continue;
        final d = v - means[i];
        stds[i] += d * d;
      }
    }
    for (var i = 0; i < dim; i++) {
      if (counts[i] > 1) {
        stds[i] = math.sqrt(stds[i] / (counts[i] - 1));
      } else {
        stds[i] = 1;
      }
      if (stds[i] < 1e-9) stds[i] = 1;
    }

    List<double> rowOf(MlBspSample s) {
      final x = List<double>.filled(dim, 0);
      for (var i = 0; i < dim; i++) {
        final v = s.features[featureNames[i]];
        if (v == null || v == MlFeatureFlat.missing) {
          x[i] = 0;
        } else {
          x[i] = (v - means[i]) / stds[i];
        }
      }
      return x;
    }

    final xs = train.map(rowOf).toList();
    final ys = train.map((s) => (s.isCorrect == true) ? 1.0 : 0.0).toList();
    final w = List<double>.filled(dim, 0);
    var bias = 0.0;
    final n = train.length.toDouble();

    for (var ep = 0; ep < epochs; ep++) {
      var gb = 0.0;
      final gw = List<double>.filled(dim, 0);
      for (var k = 0; k < train.length; k++) {
        var z = bias;
        for (var i = 0; i < dim; i++) {
          z += w[i] * xs[k][i];
        }
        final p = z >= 0
            ? 1.0 / (1.0 + math.exp(-z))
            : math.exp(z) / (1.0 + math.exp(z));
        final err = p - ys[k];
        gb += err;
        for (var i = 0; i < dim; i++) {
          gw[i] += err * xs[k][i];
        }
      }
      bias -= lr * (gb / n);
      for (var i = 0; i < dim; i++) {
        w[i] -= lr * (gw[i] / n + l2 * w[i]);
      }
    }

    return MlExperienceModel(
      featureNames: featureNames,
      weights: w,
      bias: bias,
      means: means,
      stds: stds,
      threshold: threshold,
      fitEpochs: epochs,
      fitLr: lr,
      fitL2: l2,
    );
  }

  static MlSplitStats statsOf(
    List<MlBspSample> subset,
    MlExperienceModel model, {
    bool writeScores = false,
  }) {
    return statsOfScored(
      subset,
      threshold: model.threshold,
      scoreOf: model.scoreOf,
      writeScores: writeScores,
    );
  }

  /// 已写 [MlBspSample.predictScore] 或按回调打分后的采纳统计（LR/XGB 共用）。
  static MlSplitStats statsOfScored(
    List<MlBspSample> subset, {
    required double threshold,
    double Function(Map<String, double> features)? scoreOf,
    bool writeScores = false,
  }) {
    var alphaWin = 0;
    var alphaLose = 0;
    var adopted = 0;
    var adoptedWin = 0;
    var adoptedLose = 0;
    var hit = 0;
    var evalN = 0;
    var buyAdopted = 0;
    var buyWin = 0;
    var sellAdopted = 0;
    var sellWin = 0;

    for (final s in subset) {
      final score = scoreOf != null
          ? scoreOf(s.features)
          : (s.predictScore ?? 0.0);
      if (writeScores) s.predictScore = score;
      final ok = s.isCorrect == true;
      if (ok) {
        alphaWin++;
      } else if (s.isCorrect == false) {
        alphaLose++;
      }
      if (s.isCorrect == null) continue;
      evalN++;
      final pred = score >= threshold;
      if (pred == ok) hit++;
      if (!pred) continue;
      adopted++;
      if (ok) {
        adoptedWin++;
      } else {
        adoptedLose++;
      }
      if (s.side == 'B') {
        buyAdopted++;
        if (ok) buyWin++;
      } else {
        sellAdopted++;
        if (ok) sellWin++;
      }
    }

    final n = subset.length;
    return MlSplitStats(
      total: n,
      alphaWin: alphaWin,
      alphaLose: alphaLose,
      alphaWinRate: n == 0 ? 0.0 : alphaWin / n,
      adopted: adopted,
      adoptedWin: adoptedWin,
      adoptedLose: adoptedLose,
      experienceWinRate: adopted == 0 ? 0.0 : adoptedWin / adopted,
      experienceAccuracy: evalN == 0 ? 0.0 : hit / evalN,
      coverage: n == 0 ? 0.0 : adopted / n,
      buyAdopted: buyAdopted,
      buyAdoptedWin: buyWin,
      sellAdopted: sellAdopted,
      sellAdoptedWin: sellWin,
    );
  }

  static const thrGrid = [0.4, 0.5, 0.6];

  /// 仅在验证集上选阈值（分数已写入 predictScore）。
  static double tuneThresholdOnValid(List<MlBspSample> valid) {
    if (valid.isEmpty) return 0.5;
    var bestThr = 0.5;
    var bestScore = -1.0;
    for (final thr in thrGrid) {
      final vs = statsOfScored(valid, threshold: thr);
      if (vs.tuneScore > bestScore) {
        bestScore = vs.tuneScore;
        bestThr = thr;
      }
    }
    return bestThr;
  }

  /// 仅在验证集上网格搜参；锁参后用 train(+valid) 重拟合；测试集只评估一次。
  static MlRunReport fitTuneAndTest({
    required List<MlBspSample> samples,
    bool refitOnTrainPlusValid = true,
  }) {
    final train = MlDatasetSplit.trainOf(samples);
    final valid = MlDatasetSplit.validOf(samples);
    final test = MlDatasetSplit.testOf(samples);

    final trainWin = train.where((e) => e.isCorrect == true).length;
    final trainRate = train.isEmpty ? 0.0 : trainWin / train.length;

    // 无验证集时：默认超参，直接测测试集
    if (valid.isEmpty) {
      final model = fit(train);
      for (final s in samples) {
        s.predictScore = model.scoreOf(s.features);
      }
      return MlRunReport(
        trainTotal: train.length,
        trainWinRate: trainRate,
        validStats: statsOf(valid, model),
        testStats: statsOf(test, model, writeScores: false),
        bestEpochs: model.fitEpochs,
        bestLr: model.fitLr,
        bestL2: model.fitL2,
        bestThreshold: model.threshold,
        tuneTrials: 0,
        drift: MlDriftReport.build(samples),
      );
    }

    var bestScore = -1.0;
    var bestEpochs = _epochGrid.first;
    var bestLr = _lrGrid.first;
    var bestL2 = _l2Grid.first;
    var bestThr = thrGrid.first;
    var trials = 0;

    for (final ep in _epochGrid) {
      for (final lr in _lrGrid) {
        for (final l2 in _l2Grid) {
          final base = fit(train, epochs: ep, lr: lr, l2: l2);
          for (final thr in thrGrid) {
            trials++;
            final m = base.withThreshold(thr);
            final vs = statsOf(valid, m);
            if (vs.tuneScore > bestScore) {
              bestScore = vs.tuneScore;
              bestEpochs = ep;
              bestLr = lr;
              bestL2 = l2;
              bestThr = thr;
            }
          }
        }
      }
    }

    // 锁参后重拟合：默认 train+valid（验证已只用于选参，不回头改参）
    final fitSet = refitOnTrainPlusValid ? [...train, ...valid] : train;
    final finalModel = fit(
      fitSet,
      epochs: bestEpochs,
      lr: bestLr,
      l2: bestL2,
      threshold: bestThr,
    );

    // 全样本写分（UI）；测试统计只算一次
    for (final s in samples) {
      s.predictScore = finalModel.scoreOf(s.features);
    }
    final validLocked = statsOf(valid, finalModel);
    final testOnce = statsOf(test, finalModel);

    return MlRunReport(
      trainTotal: train.length,
      trainWinRate: trainRate,
      validStats: validLocked,
      testStats: testOnce,
      bestEpochs: bestEpochs,
      bestLr: bestLr,
      bestL2: bestL2,
      bestThreshold: bestThr,
      tuneTrials: trials,
      drift: MlDriftReport.build(samples),
    );
  }

  /// 旧入口：不再用于生产；保留给旧测试迁移。
  static MlRunReport applyAndStats({
    required MlExperienceModel model,
    required List<MlBspSample> samples,
  }) {
    for (final s in samples) {
      s.predictScore = model.scoreOf(s.features);
    }
    final train = MlDatasetSplit.trainOf(samples);
    final trainWin = train.where((e) => e.isCorrect == true).length;
    return MlRunReport(
      trainTotal: train.length,
      trainWinRate: train.isEmpty ? 0.0 : trainWin / train.length,
      validStats: statsOf(MlDatasetSplit.validOf(samples), model),
      testStats: statsOf(MlDatasetSplit.testOf(samples), model),
      bestEpochs: model.fitEpochs,
      bestLr: model.fitLr,
      bestL2: model.fitL2,
      bestThreshold: model.threshold,
      tuneTrials: 0,
      drift: MlDriftReport.build(samples),
    );
  }
}
