import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/trend_model_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/trend_model_config.dart';

KlineBar _bar(int idx, double close) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: close,
    high: close + 1,
    low: close - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

void main() {
  group('TrendModelWindow', () {
    test('MEAN：不足 T 用已有长度；满窗滚动', () {
      final w = TrendModelWindow(TrendModelType.mean, 3);
      expect(w.add(1), closeTo(1, 1e-12));
      expect(w.add(2), closeTo(1.5, 1e-12));
      expect(w.add(3), closeTo(2, 1e-12));
      expect(w.add(6), closeTo((2 + 3 + 6) / 3, 1e-12));
    });

    test('MAX/MIN', () {
      final mx = TrendModelWindow(TrendModelType.max, 2);
      final mn = TrendModelWindow(TrendModelType.min, 2);
      expect(mx.add(3), 3);
      expect(mx.add(5), 5);
      expect(mx.add(4), 5);
      expect(mn.add(3), 3);
      expect(mn.add(5), 3);
      expect(mn.add(4), 4);
    });
  });

  group('K0 均线/通道', () {
    test('均线系列长度=柱数且末值正确', () {
      final bars = [for (var i = 0; i < 5; i++) _bar(i, (i + 1).toDouble())];
      final means = computeMeanSeriesForLevel(
        displayKn: 0,
        bars: bars,
        periods: const [3],
      );
      expect(means[3]!.length, 5);
      expect(means[3]![0], closeTo(1, 1e-12));
      expect(means[3]![2], closeTo(2, 1e-12)); // (1+2+3)/3
      expect(means[3]![4], closeTo((3 + 4 + 5) / 3, 1e-12));
    });

    test('通道 MAX/MIN', () {
      final bars = [
        _bar(0, 10),
        _bar(1, 12),
        _bar(2, 8),
        _bar(3, 11),
      ];
      final ch = computeChannelSeriesForLevel(
        displayKn: 0,
        bars: bars,
        periods: const [2],
      );
      expect(ch[2]!.max[1], 12);
      expect(ch[2]!.min[1], 10);
      expect(ch[2]!.max[2], 12);
      expect(ch[2]!.min[2], 8);
    });

    test('asOf 截断', () {
      final bars = [for (var i = 0; i < 5; i++) _bar(i, 10.0 + i)];
      final means = computeMeanSeriesForLevel(
        displayKn: 0,
        bars: bars,
        periods: const [2],
        asOf: 2,
      );
      expect(means[2]![2], isNotNull);
      expect(means[2]![3], isNull);
    });
  });

  group('Kn 样本', () {
    test('displayKn=1 用 unitBars close', () {
      final bars = [for (var i = 0; i < 10; i++) _bar(i, 100)];
      final units = [
        const LevelUnitBar(
          idx: 0,
          dir: 1,
          x1: 0,
          x2: 2,
          close: 10,
        ),
        const LevelUnitBar(
          idx: 1,
          dir: -1,
          x1: 2,
          x2: 5,
          close: 20,
        ),
        const LevelUnitBar(
          idx: 2,
          dir: 1,
          x1: 5,
          x2: 8,
          close: 30,
        ),
      ];
      final levels = [LevelBundle(level: 0, unitBars: units)];
      final samples = collectTrendCloseSamples(
        displayKn: 1,
        bars: bars,
        levels: levels,
      );
      expect(samples.map((e) => e.close).toList(), [10, 20, 30]);
      final means = computeMeanSeriesForLevel(
        displayKn: 1,
        bars: bars,
        levels: levels,
        periods: const [2],
      );
      // 阶梯：x<=2→10；x<=5→15；x<=8→25
      expect(means[2]![2], closeTo(10, 1e-12));
      expect(means[2]![5], closeTo(15, 1e-12));
      expect(means[2]![8], closeTo(25, 1e-12));
    });
  });

  group('catalog', () {
    test('含均线/通道且默认 K0 纳入', () {
      final cat = buildMainIndicatorCatalog(1);
      final m = cat.where((e) => e.kind == MainIndicatorKind.meanLine);
      final c = cat.where((e) => e.kind == MainIndicatorKind.trendChannel);
      expect(m.map((e) => e.kn), [0, 1]);
      expect(c.map((e) => e.kn), [0, 1]);
      expect(m.first.label, 'K0均线');
      expect(c.first.label, 'K0通道');

      final d = defaultMainIndicatorsK0();
      expect(d.any((e) => e.kind == MainIndicatorKind.meanLine), isTrue);
      expect(d.any((e) => e.kind == MainIndicatorKind.trendChannel), isTrue);
    });

    test('周期文本解析', () {
      expect(
        TrendModelConfig.parsePeriodsText('5, 10，20', const [1]),
        [5, 10, 20],
      );
      expect(
        TrendModelConfig.parsePeriodsText('abc', const [5, 10]),
        [5, 10],
      );
    });
  });
}
