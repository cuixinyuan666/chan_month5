import 'package:chan_kline/ml/ml_rule_score.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('空表 → 观望', () {
    final r = MlRuleScore.score(BarFeatureLookup.empty());
    expect(r.stance, '观望');
    expect(r.categories, isEmpty);
  });

  test('一类买抬高买卖点分与总分偏多倾向', () {
    final bars = [
      const KlineBar(
        idx: 0,
        timeMs: 0,
        timeText: '2024/01/02 09:31',
        open: 10,
        high: 11,
        low: 9,
        close: 10.5,
        volume: 100,
        amount: 1000,
      ),
    ];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const <K0ConfirmSignal>[],
      barFeatures: const [],
    );
    final sub = lookup.byIdx[0]!['sub'] as Map<String, dynamic>;
    sub['buy1_0'] = '1Ba';
    sub['buy_volume_0'] = 80;
    sub['sell_volume_0'] = 10;
    sub['gray_volume_0'] = 10;
    sub['fractal_judgment_0'] = 'BOTTOM';

    final r = MlRuleScore.score(lookup);
    expect(r.categories.length, 8);
    final bs = r.categories.firstWhere((e) => e.id == 'bs');
    expect(bs.score, greaterThan(0));
    expect(r.disclaimer, contains('不构成任何投资建议'));
    expect(
      ['偏多', '观望', '偏空'].contains(r.stance),
      isTrue,
    );
  });
}
