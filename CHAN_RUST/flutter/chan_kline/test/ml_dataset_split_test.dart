import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_dataset_split.dart';
import 'package:chan_kline/ml/ml_split_config.dart';
import 'package:flutter_test/flutter_test.dart';

MlBspSample _s(int x) => MlBspSample(
      x: x,
      side: 'B',
      label: '1Ba',
      price: 1,
      segIdx: 0,
      openTime: 't$x',
      featureFrozenAt: x,
      features: const {},
    );

void main() {
  test('时序三截：训练|验证|测试，禁止打乱', () {
    final samples = List.generate(10, _s);
    MlDatasetSplit.apply(
      samples,
      const MlSplitConfig(trainRatio: 0.6, validRatio: 0.2),
    );
    expect(MlDatasetSplit.trainOf(samples).length, 6);
    expect(MlDatasetSplit.validOf(samples).length, 2);
    expect(MlDatasetSplit.testOf(samples).length, 2);
    // 前段训练、中段验证、末段测试
    expect(samples.take(6).every((e) => e.split == MlSampleSplit.train), isTrue);
    expect(
      samples.skip(6).take(2).every((e) => e.split == MlSampleSplit.valid),
      isTrue,
    );
    expect(samples.skip(8).every((e) => e.split == MlSampleSplit.test), isTrue);
    // x 非递减
    final xs = samples.map((e) => e.x).toList()..sort();
    expect(samples.map((e) => e.x).toList(), xs);
  });

  test('样本≥3 时每段至少1条', () {
    final samples = [_s(1), _s(2), _s(3)];
    MlDatasetSplit.apply(
      samples,
      const MlSplitConfig(trainRatio: 0.8, validRatio: 0.1),
    );
    expect(MlDatasetSplit.trainOf(samples).length, greaterThanOrEqualTo(1));
    expect(MlDatasetSplit.validOf(samples).length, greaterThanOrEqualTo(1));
    expect(MlDatasetSplit.testOf(samples).length, greaterThanOrEqualTo(1));
  });
}
