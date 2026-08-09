import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_dataset_split.dart';
import 'package:chan_kline/ml/ml_split_config.dart';
import 'package:flutter_test/flutter_test.dart';

MlBspSample _s(int x, {bool ok = true, double? pred}) => MlBspSample(
      x: x,
      side: 'B',
      label: '1Ba',
      price: 1,
      segIdx: 0,
      openTime: 't$x',
      featureFrozenAt: x,
      features: const {},
    )
      ..isCorrect = ok
      ..predictScore = pred;

void main() {
  test('按时间序切分：默认70%训练，至少留1条考试', () {
    final samples = List.generate(10, (i) => _s(i));
    MlDatasetSplit.apply(samples, const MlSplitConfig(trainRatio: 0.7));
    expect(MlDatasetSplit.trainOf(samples).length, 7);
    expect(MlDatasetSplit.examOf(samples).length, 3);
    // 前7训练、后3考试（按 x）
    expect(samples.where((e) => e.x < 7).every((e) => e.split == MlSampleSplit.train), isTrue);
    expect(samples.where((e) => e.x >= 7).every((e) => e.split == MlSampleSplit.exam), isTrue);
  });

  test('样本仅2条时考试至少1条', () {
    final samples = [_s(1), _s(2)];
    MlDatasetSplit.apply(samples, const MlSplitConfig(trainRatio: 0.9));
    expect(MlDatasetSplit.trainOf(samples).length, 1);
    expect(MlDatasetSplit.examOf(samples).length, 1);
  });

  test('考试集指标：α与模型准确率', () {
    final samples = [
      _s(1, ok: true, pred: 0.8),
      _s(2, ok: false, pred: 0.2),
      _s(3, ok: true, pred: 0.1), // 预测错
      _s(4, ok: false, pred: 0.9), // 预测错
    ];
    MlDatasetSplit.apply(samples, const MlSplitConfig(trainRatio: 0.5));
    final exam = MlDatasetSplit.examOf(samples);
    expect(exam.length, 2);
    final m = MlDatasetSplit.metrics(exam);
    expect(m.total, 2);
    expect(m.correct + m.wrong, 2);
    expect(m.predEvaluated, 2);
    expect(m.predAccuracy, isNotNull);
  });
}
