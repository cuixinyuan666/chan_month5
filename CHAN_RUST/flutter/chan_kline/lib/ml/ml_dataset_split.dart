import 'ml_bsp_sample.dart';
import 'ml_split_config.dart';

enum MlSampleSplit { train, exam }

/// 按 x 升序切分训练集 / 考试集。
class MlDatasetSplit {
  MlDatasetSplit._();

  static void apply(List<MlBspSample> samples, MlSplitConfig cfg) {
    if (samples.isEmpty) return;
    final ordered = [...samples]..sort((a, b) {
        final c = a.x.compareTo(b.x);
        if (c != 0) return c;
        return a.sampleKey.compareTo(b.sampleKey);
      });
    final trainN = (ordered.length * cfg.trainRatio).floor().clamp(
          1,
          ordered.length,
        );
    // 至少留 1 条考试（样本≥2 时）
    final cut = ordered.length >= 2
        ? trainN.clamp(1, ordered.length - 1)
        : ordered.length;
    for (var i = 0; i < ordered.length; i++) {
      ordered[i].split = i < cut ? MlSampleSplit.train : MlSampleSplit.exam;
    }
  }

  static List<MlBspSample> trainOf(List<MlBspSample> samples) =>
      samples.where((e) => e.split == MlSampleSplit.train).toList();

  static List<MlBspSample> examOf(List<MlBspSample> samples) =>
      samples.where((e) => e.split == MlSampleSplit.exam).toList();

  static MlSplitMetrics metrics(List<MlBspSample> subset) {
    final n = subset.length;
    final ok = subset.where((e) => e.isCorrect == true).length;
    final bad = subset.where((e) => e.isCorrect == false).length;
    final labeled = ok + bad;
    final alphaAcc = labeled == 0 ? 0.0 : ok / labeled;

    var predOk = 0;
    var predN = 0;
    for (final s in subset) {
      if (s.predictScore == null || s.isCorrect == null) continue;
      predN++;
      final predPos = s.predictScore! >= 0.5;
      if (predPos == s.isCorrect) predOk++;
    }
    final predAcc = predN == 0 ? null : predOk / predN;

    return MlSplitMetrics(
      total: n,
      correct: ok,
      wrong: bad,
      alphaAccuracy: alphaAcc,
      predAccuracy: predAcc,
      predEvaluated: predN,
    );
  }
}

class MlSplitMetrics {
  const MlSplitMetrics({
    required this.total,
    required this.correct,
    required this.wrong,
    required this.alphaAccuracy,
    required this.predAccuracy,
    required this.predEvaluated,
  });

  final int total;
  final int correct;
  final int wrong;
  final double alphaAccuracy;
  final double? predAccuracy;
  final int predEvaluated;

  String get alphaSummary =>
      'α准确率 ${(alphaAccuracy * 100).toStringAsFixed(1)}%（√$correct/×$wrong）';

  String get predSummary {
    if (predAccuracy == null) return '模型预测：未评估';
    return '模型准确率 ${(predAccuracy! * 100).toStringAsFixed(1)}%'
        '（阈值0.5，n=$predEvaluated）';
  }
}
