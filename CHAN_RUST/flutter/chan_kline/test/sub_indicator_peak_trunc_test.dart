import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int i) => KlineBar(
      idx: i,
      timeMs: i * 60000,
      timeText: 't$i',
      open: 10,
      high: 11,
      low: 9,
      close: 10.5,
      volume: 100,
      amount: 1000,
    );

void main() {
  test('截断副图仅 truncationCheck=开 时进入目录', () {
    final on = buildSubIndicatorCatalog(3, truncationCheck: true);
    expect(on.any((e) => e.kind == SubIndicatorKind.truncation), isTrue);
    expect(on.any((e) => e.label == 'K0截断'), isTrue);

    final off = buildSubIndicatorCatalog(3, truncationCheck: false);
    expect(off.any((e) => e.kind == SubIndicatorKind.truncation), isFalse);
    expect(off.any((e) => e.label == 'K0分型极点距'), isTrue);

    // 关截断后 prune 掉已勾选的截断项
    final pruned = pruneIndicators(
      {
        const SubChartIndicator.volume(),
        const SubChartIndicator.truncation(1),
        const SubChartIndicator.fractalPeakDist(1),
      },
      off,
    );
    expect(pruned.contains(const SubChartIndicator.truncation(1)), isFalse);
    expect(pruned.contains(const SubChartIndicator.fractalPeakDist(1)), isTrue);
  });

  test('副图目录大类顺序：确认 < 判断 < 极点距 < 截断', () {
    final cat = buildSubIndicatorCatalog(3, truncationCheck: true);
    final labels = cat.map((e) => e.label).toList();
    expect(labels.indexOf('K0分型确认'), lessThan(labels.indexOf('K0分型判断')));
    expect(labels.indexOf('K0分型判断'), lessThan(labels.indexOf('K0分型极点距')));
    expect(labels.indexOf('K0分型极点距'), lessThan(labels.indexOf('K0截断')));
  });

  test('十字线副图：截断触发步显示 Kn截断值', () {
    final bars = List.generate(5, _bar);
    final k0Confirms = [
      const K0ConfirmSignal(
        x: 2,
        fx: 'BOTTOM',
        value: 1,
        fractalX1: 1,
        fractalX2: 1,
      ),
      const K0ConfirmSignal(
        x: 3,
        fx: 'TOP',
        value: -1,
        fractalX1: 2,
        fractalX2: 2,
        truncated: true,
      ),
    ];
    final levels = [
      LevelBundle(
        level: 1,
        confirms: [
          const LevelConfirm(
            x: 3,
            fx: 'TOP',
            value: -1,
            fractalX1: 2,
            fractalX2: 2,
            poleX: 2,
            truncated: true,
          ),
        ],
      ),
    ];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: k0Confirms,
      barFeatures: [
        for (var i = 0; i < 5; i++)
          BarCrosshairFeature(
            idx: i,
            weekday: '周一',
            mergeInnerSeq: 0,
            fractalPeakDist: i,
          ),
      ],
      levels: levels,
      subIndicators: {
        const SubChartIndicator.truncation(1),
        const SubChartIndicator.fractalPeakDist(1),
      },
    );

    final atTrunc = lookup.crosshairSubLines(3, {
      const SubChartIndicator.truncation(1),
      const SubChartIndicator.fractalPeakDist(1),
    });
    expect(atTrunc.any((l) => l == 'K0截断:-1'), isTrue);
    expect(atTrunc.any((l) => l.startsWith('K0分型极点距:')), isTrue);

    final atNormal = lookup.crosshairSubLines(2, {
      const SubChartIndicator.truncation(1),
    });
    expect(atNormal.any((l) => l.startsWith('K0截断:')), isFalse);
  });
}
