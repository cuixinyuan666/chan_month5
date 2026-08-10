import 'ml_bsp_sample.dart';
import 'ml_split_config.dart';

enum MlSampleSplit { train, valid, test }

/// 按 x 升序严格时序切分：训练 | 验证 | 测试（禁止打乱）。
class MlDatasetSplit {
  MlDatasetSplit._();

  static void apply(List<MlBspSample> samples, MlSplitConfig cfg) {
    if (samples.isEmpty) return;
    final ordered = [...samples]..sort((a, b) {
        final c = a.x.compareTo(b.x);
        if (c != 0) return c;
        return a.sampleKey.compareTo(b.sampleKey);
      });
    final n = ordered.length;
    if (n == 1) {
      ordered[0].split = MlSampleSplit.train;
      return;
    }
    if (n == 2) {
      ordered[0].split = MlSampleSplit.train;
      ordered[1].split = MlSampleSplit.test;
      return;
    }

    // 三截各至少 1 条
    var trainN = (n * cfg.trainRatio).floor();
    var validN = (n * cfg.validRatio).floor();
    var testN = n - trainN - validN;
    if (trainN < 1) trainN = 1;
    if (validN < 1) validN = 1;
    if (testN < 1) testN = 1;
    while (trainN + validN + testN > n) {
      if (trainN >= validN && trainN >= testN && trainN > 1) {
        trainN--;
      } else if (validN >= testN && validN > 1) {
        validN--;
      } else if (testN > 1) {
        testN--;
      } else {
        break;
      }
    }
    // 补齐差额给测试（末段）
    final used = trainN + validN + testN;
    if (used < n) testN += n - used;

    for (var i = 0; i < n; i++) {
      if (i < trainN) {
        ordered[i].split = MlSampleSplit.train;
      } else if (i < trainN + validN) {
        ordered[i].split = MlSampleSplit.valid;
      } else {
        ordered[i].split = MlSampleSplit.test;
      }
    }
  }

  static List<MlBspSample> trainOf(List<MlBspSample> samples) =>
      samples.where((e) => e.split == MlSampleSplit.train).toList();

  static List<MlBspSample> validOf(List<MlBspSample> samples) =>
      samples.where((e) => e.split == MlSampleSplit.valid).toList();

  static List<MlBspSample> testOf(List<MlBspSample> samples) =>
      samples.where((e) => e.split == MlSampleSplit.test).toList();

  /// 兼容旧名：考试=测试
  static List<MlBspSample> examOf(List<MlBspSample> samples) => testOf(samples);
}
