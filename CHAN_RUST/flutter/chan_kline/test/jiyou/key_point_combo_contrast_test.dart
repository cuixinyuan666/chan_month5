import 'package:chan_kline/key_point_stats/key_point_combo_contrast.dart';
import 'package:chan_kline/key_point_stats/key_point_contrast.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优组合区分度的回归。
///
/// 构造两组指标：一个单看就能分开顶底，另一个单看分不开、但和第一个合在一起
/// 分得更开。验证组合搜索能找到它，并给出可读规则和正的提升。
void main() {
  KeyPointContrast contrast(String key, String label, double value) =>
      KeyPointContrast(
        level: 1,
        metricKey: key,
        labelCn: label,
        topMean: value,
        bottomMean: 0,
        deltaMean: value,
        pooledSigma: 1,
        contrast: value,
        topPoints: 4,
        bottomPoints: 4,
      );

  test('两个指标一起比单看分得更开', () {
    // 指标 A：顶组整体高于底组。
    final a = MetricColumn(
      metricKey: 'a',
      labelCn: '甲',
      topValues: [2, 3, 2.5, 3.5],
      bottomValues: [0, 1, 0.5, 1.5],
    );
    // 指标 B：单看重叠大，但和 A 同向，合在一起质心拉得更开。
    final b = MetricColumn(
      metricKey: 'b',
      labelCn: '乙',
      topValues: [1, 2, 1.5, 2.5],
      bottomValues: [0, 1.2, 0.4, 1.6],
    );

    final found = computeComboContrasts(
      ranked: [contrast('a', '甲', 1.5), contrast('b', '乙', 0.8)],
      columns: {'a': a, 'b': b},
      level: 1,
    );

    expect(found, isNotEmpty);
    final best = found.first;
    expect(best.metricKeys, containsAll(['a', 'b']));
    expect(best.lift, greaterThan(0));
    expect(best.ruleText, contains('甲'));
    expect(best.ruleText, contains('乙'));
    expect(best.ruleText, contains('且'));
  });

  test('再加一个纯噪声指标不会被选进来', () {
    final a = MetricColumn(
      metricKey: 'a',
      labelCn: '甲',
      topValues: [3, 3, 3, 3],
      bottomValues: [0, 0, 0, 0],
    );
    // 噪声：顶底完全一样，加进来不增加任何区分。
    final noise = MetricColumn(
      metricKey: 'n',
      labelCn: '噪声',
      topValues: [1, 1, 1, 1],
      bottomValues: [1, 1, 1, 1],
    );

    final found = computeComboContrasts(
      ranked: [contrast('a', '甲', 3), contrast('n', '噪声', 0.1)],
      columns: {'a': a, 'n': noise},
      level: 1,
    );
    expect(found.where((c) => c.metricKeys.contains('n')), isEmpty);
  });

  test('候选不足两个时不产出组合', () {
    final found = computeComboContrasts(
      ranked: [contrast('a', '甲', 1)],
      columns: {},
      level: 1,
    );
    expect(found, isEmpty);
  });

  test('结果可复现：同样输入两次结果一致', () {
    final a = MetricColumn(
      metricKey: 'a',
      labelCn: '甲',
      topValues: [2, 3, 2, 3],
      bottomValues: [0, 1, 0, 1],
    );
    final b = MetricColumn(
      metricKey: 'b',
      labelCn: '乙',
      topValues: [2, 2, 3, 3],
      bottomValues: [0, 1, 0, 1],
    );
    final ranked = [contrast('a', '甲', 1.2), contrast('b', '乙', 1.0)];
    final columns = {'a': a, 'b': b};
    final first = computeComboContrasts(
      ranked: ranked,
      columns: columns,
      level: 1,
    );
    final second = computeComboContrasts(
      ranked: ranked,
      columns: columns,
      level: 1,
    );
    expect(
      first.map((c) => c.ruleText).toList(),
      second.map((c) => c.ruleText).toList(),
    );
  });
}
