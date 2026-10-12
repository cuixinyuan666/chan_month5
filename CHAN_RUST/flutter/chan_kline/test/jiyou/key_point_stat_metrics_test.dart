import 'package:chan_kline/key_point_stats/stat_metrics.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('分位数 / 标准差', () {
    test('分位数用线性插值，且单调夹住中位数', () {
      final s = [1.0, 2.0, 3.0, 4.0];
      expect(statPercentile(s, 0.0), 1.0);
      expect(statPercentile(s, 1.0), 4.0);
      expect(statPercentile(s, 0.5), 2.5);
      expect(statPercentile(s, 0.25), closeTo(1.75, 1e-12));
      expect(statPercentile(s, 0.75), closeTo(3.25, 1e-12));
    });

    test('单样本：分位数=自身，标准差=0', () {
      expect(statPercentile([7.0], 0.5), 7.0);
      expect(statStddev([7.0], 7.0), 0);
    });

    test('标准差为总体口径（除以 n）', () {
      final v = [2.0, 4.0, 4.0, 4.0, 5.0, 5.0, 7.0, 9.0];
      // 总体方差=4 → 标准差=2
      expect(statStddev(v, 5.0), closeTo(2.0, 1e-12));
    });

    test('空输入：分位数为 NaN、标准差为 0（不得抛）', () {
      expect(statPercentile([], 0.5).isNaN, isTrue);
      expect(statStddev([], 0), 0);
    });
  });

  group('众数', () {
    test('数值众数按小数位分桶，并列取最小桶（可复现）', () {
      final r = statNumericMode([1.00001, 1.00002, 2.5, 2.5], 4);
      expect(r.value, closeTo(1.0, 1e-12));
      expect(r.count, 2);

      final tie = statNumericMode([3.0, 1.0, 2.0], 2);
      expect(tie.value, 1.0); // 三者都出现 1 次 → 取最小
      expect(tie.count, 1);
    });

    test('桶宽=0 即整数桶', () {
      final r = statNumericMode([10.4, 10.2, 20.0], 0);
      expect(r.value, 10.0);
      expect(r.count, 2);
    });

    test('数值众数忽略 NaN / Inf', () {
      final r = statNumericMode([double.nan, double.infinity, 5.0, 5.0], 2);
      expect(r.value, 5.0);
      expect(r.count, 2);
    });

    test('类别众数是精确值，并列取字典序最小', () {
      final r = statCategoricalMode(['TOP', 'BOTTOM', 'TOP', 'UNKNOWN']);
      expect(r.value, 'TOP');
      expect(r.count, 2);

      final tie = statCategoricalMode(['BOTTOM', 'TOP']);
      expect(tie.value, 'BOTTOM');
    });

    test('空输入返回 null', () {
      expect(statNumericMode([], 4).value, isNull);
      expect(statCategoricalMode([]).value, isNull);
    });
  });
group('numericStat / categoricalStat', () {
    test('数值型汇总：均值落在最小/最大之间，四分位夹住中位数', () {
      final s = numericStat(
        metricKey: 'sub.rsi_0',
        labelCn: 'K0 RSI',
        rawValues: [10.0, 20.0, 30.0, 40.0, 50.0],
        totalCount: 5,
        modeDigits: 0,
      );
      expect(s.kind, StatValueKind.numeric);
      expect(s.sampleCount, 5);
      expect(s.totalCount, 5);
      expect(s.coverage, 1.0);
      expect(s.mean, closeTo(30.0, 1e-12));
      expect(s.median, closeTo(30.0, 1e-12));
      expect(s.min, 10.0);
      expect(s.max, 50.0);
      expect(s.p25, closeTo(20.0, 1e-12));
      expect(s.p75, closeTo(40.0, 1e-12));
      // 各值互不相同 → 并列取最小桶（10），众数命中 1 次。
      expect(s.mode, 10.0);
      expect(s.modeCount, 1);
    });

    test('空样本一律 null（不补 0、不前向填充）', () {
      final s = numericStat(
        metricKey: 'sub.macd_dif_0',
        labelCn: 'K0 DIF',
        rawValues: const [],
        totalCount: 8,
      );
      expect(s.sampleCount, 0);
      expect(s.isEmpty, isTrue);
      expect(s.mean, isNull);
      expect(s.median, isNull);
      expect(s.stddev, isNull);
      expect(s.min, isNull);
      expect(s.max, isNull);
      expect(s.mode, isNull);
      expect(s.coverage, 0);
      // 分母是分组转折点总数，不是有效样本数
      expect(s.totalCount, 8);
    });

    test('非有限值被剔除，样本数相应下降', () {
      final s = numericStat(
        metricKey: 'x',
        labelCn: 'x',
        rawValues: [1.0, double.nan, double.infinity, 3.0],
        totalCount: 4,
      );
      expect(s.sampleCount, 2);
      expect(s.mean, closeTo(2.0, 1e-12));
    });

    test('类别型汇总：精确众数 + 占比', () {
      final s = categoricalStat(
        metricKey: 'combine_fx',
        labelCn: '合并框分型',
        values: const ['TOP', 'TOP', 'BOTTOM', 'UNKNOWN'],
        totalCount: 4,
      );
      expect(s.kind, StatValueKind.categorical);
      expect(s.modeLabel, 'TOP');
      expect(s.modeCount, 2);
      expect(s.modeShare, closeTo(0.5, 1e-12));
      expect(s.mean, isNull);
    });

    test('JSON 落盘体：数值型带 8 个统计量、类别型带众数标签', () {
      final n = numericStat(
        metricKey: 'a',
        labelCn: 'A',
        rawValues: [1, 2, 3],
        totalCount: 3,
      ).toJson();
      expect(n['kind'], 'numeric');
      for (final k in const [
        'mean',
        'median',
        'stddev',
        'min',
        'max',
        'p25',
        'p75',
        'mode',
      ]) {
        expect(n.containsKey(k), isTrue, reason: '缺 $k');
      }
      final c = categoricalStat(
        metricKey: 'b',
        labelCn: 'B',
        values: const ['x'],
        totalCount: 1,
      ).toJson();
      expect(c['kind'], 'categorical');
      expect(c['mode_label'], 'x');
      expect(c.containsKey('mean'), isFalse);
    });
  });

  test('布尔类别标签用中文（面板不出现 true/false）', () {
    expect(statBoolLabel(true), '是');
    expect(statBoolLabel(false), '否');
  });
}