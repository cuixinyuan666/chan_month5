import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_dataset_split.dart';
import 'package:chan_kline/ml/ml_experience_trainer.dart';
import 'package:chan_kline/ml/ml_split_config.dart';
import 'package:flutter_test/flutter_test.dart';

MlBspSample _s({
  required int x,
  required bool ok,
  required double feat,
}) =>
    MlBspSample(
      x: x,
      side: 'B',
      label: '1Ba',
      price: 1,
      segIdx: 0,
      openTime: 't$x',
      featureFrozenAt: x,
      features: {'sig': feat},
    )..isCorrect = ok;

void main() {
  test('验证集调参后测试集只评估；测试不参与选参', () {
    // 可分：高 sig→√；覆盖训练/验证/测试
    final samples = <MlBspSample>[
      for (var i = 0; i < 12; i++)
        _s(x: i, ok: i.isEven, feat: i.isEven ? 3.0 : -3.0),
    ];
    MlDatasetSplit.apply(
      samples,
      const MlSplitConfig(trainRatio: 0.6, validRatio: 0.2),
    );
    expect(MlDatasetSplit.validOf(samples), isNotEmpty);
    expect(MlDatasetSplit.testOf(samples), isNotEmpty);

    final report = MlExperienceTrainer.fitTuneAndTest(samples: samples);
    expect(report.tuneTrials, greaterThan(0));
    expect(report.testStats.total, greaterThan(0));
    expect(report.validStats.total, greaterThan(0));
    // 测试集应被打分
    for (final s in MlDatasetSplit.testOf(samples)) {
      expect(s.predictScore, isNotNull);
    }
    expect(report.headline.contains('测试'), isTrue);
  });
}
