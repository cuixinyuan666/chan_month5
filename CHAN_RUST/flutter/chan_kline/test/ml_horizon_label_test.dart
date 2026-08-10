import 'package:chan_kline/ml/ml_bsp_labeler.dart';
import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_dataset_split.dart';
import 'package:chan_kline/ml/ml_drift_report.dart';
import 'package:chan_kline/ml/ml_split_config.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/k0_line.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

List<KlineBar> _bars(int n) => List.generate(
      n,
      (i) => KlineBar(
        idx: i,
        timeMs: i,
        timeText: 't$i',
        open: 10,
        high: 11 + (i == 5 ? 5 : 0),
        low: 9 - (i == 1 ? 1 : 0),
        close: 10,
        volume: 1,
        amount: 1,
      ),
    );

void main() {
  test('展望窗：asOf右侧高低不参与极值', () {
    // x=1 为 asOf=3 时最低；之后 bar5 更低也不该影响 asOf=3 判定
    final bars = [
      const KlineBar(
        idx: 0, timeMs: 0, timeText: 't0',
        open: 10, high: 11, low: 10, close: 10, volume: 1, amount: 1,
      ),
      const KlineBar(
        idx: 1, timeMs: 1, timeText: 't1',
        open: 10, high: 10.2, low: 8.0, close: 9, volume: 1, amount: 1,
      ),
      const KlineBar(
        idx: 2, timeMs: 2, timeText: 't2',
        open: 9, high: 10, low: 8.5, close: 9.5, volume: 1, amount: 1,
      ),
      const KlineBar(
        idx: 3, timeMs: 3, timeText: 't3',
        open: 9.5, high: 10, low: 9, close: 9.8, volume: 1, amount: 1,
      ),
      const KlineBar(
        idx: 4, timeMs: 4, timeText: 't4',
        open: 9, high: 10, low: 7.0, close: 8, volume: 1, amount: 1,
      ),
    ];
    const line = K0Line(
      idx: 0,
      dir: 1,
      beginConfirmX: 0,
      endConfirmX: 4,
      beginFractalX1: 0,
      beginFractalX2: 0,
      endFractalX1: 4,
      endFractalX2: 4,
    );
    final okAt3 = MlBspLabeler.matchesK0LineExtremeAsOf(
      side: 'B',
      x: 1,
      price: 8.0,
      asOfIdx: 3,
      k0Lines: const [line],
      bars: bars.sublist(0, 4),
    );
    expect(okAt3, isTrue);

    // 若错误用到 asOf=4 的更低点，x=1 不再是最低 → 应×；我们截断后仍√
    final stillOk = MlBspLabeler.matchesK0LineExtremeAsOf(
      side: 'B',
      x: 1,
      price: 8.0,
      asOfIdx: 3,
      k0Lines: const [line],
      bars: bars,
    );
    expect(stillOk, isTrue);
  });

  test('labelDue：未到期不打标；到期用live', () {
    final sample = MlBspSample(
      x: 1,
      side: 'B',
      label: '1Ba',
      price: 8.0,
      segIdx: 0,
      openTime: 't1',
      featureFrozenAt: 1,
      features: const {},
    );
    final bars = _bars(10);
    const line = K0Line(
      idx: 0,
      dir: 1,
      beginConfirmX: 0,
      endConfirmX: 9,
      beginFractalX1: 0,
      beginFractalX2: 0,
      endFractalX1: 9,
      endFractalX2: 9,
    );
    MlBspLabeler.labelDueSamples(
      samples: [sample],
      asOfIdx: 5,
      horizonBars: 64,
      isLastBar: false,
      liveBuy1: const [
        Buy1Frame(x: 1, price: 8.0, label: '1Ba', segIdx: 0, level: 0),
      ],
      liveSell1: const [],
      k0LinesAsOf: const [line],
      barsAsOf: bars.sublist(0, 6),
    );
    expect(sample.isCorrect, isNull); // 未到期

    MlBspLabeler.labelDueSamples(
      samples: [sample],
      asOfIdx: 9,
      horizonBars: 64,
      isLastBar: true,
      liveBuy1: const [],
      liveSell1: const [],
      k0LinesAsOf: const [line],
      barsAsOf: bars,
    );
    expect(sample.isCorrect, isFalse); // live 已不在
    expect(sample.labelReason.contains('展望窗'), isTrue);
  });

  test('漂移报告含三截标签率', () {
    final samples = List.generate(
      10,
      (i) => MlBspSample(
        x: i,
        side: 'B',
        label: '1Ba',
        price: 1,
        segIdx: 0,
        openTime: 't$i',
        featureFrozenAt: i,
        features: {'f': i.toDouble()},
      )..isCorrect = i < 7,
    );
    MlDatasetSplit.apply(
      samples,
      const MlSplitConfig(trainRatio: 0.6, validRatio: 0.2),
    );
    final d = MlDriftReport.build(samples);
    expect(d.trainN + d.validN + d.testN, 10);
    expect(d.labelRateSummary.contains('训练'), isTrue);
    expect(d.driftSummary.contains('漂移'), isTrue);
  });
}
