import 'dart:convert';

import 'package:chan_kline/key_point_stats/key_point.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_export.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/stat_metrics.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一行冻结账：rsi / 收盘价各给一个值，分型方向给字符串。
Map<String, dynamic> _row({
  required int idx,
  required double rsi,
  required double close,
  required String fx,
  bool truncated = false,
}) =>
    {
      'idx': idx,
      'time_ms': 1700000000000 + idx * 60000,
      'time_text': '2004/07/19 09:30:00',
      'weekday': '-',
      'merge_inner_seq': 1,
      'merge_count': 2,
      'merge_box_seq': 3,
      'open': close - 1,
      'high': close + 2,
      'low': close - 2,
      'close': close,
      'volume': 1000 + idx.toDouble(),
      'amount': 2000 + idx.toDouble(),
      'combine_fx': fx,
      'combine_high': close + 2,
      'combine_low': close - 2,
      'sub': <String, dynamic>{
        'rsi_0': rsi,
        // ML 禁止键（字符串汇总）：不该进统计表
        'mean_text_0': 'MA5=1 MA10=2',
        'fractal_judgment_0': fx,
        'fractal_judgment_trunc_0': truncated,
        'macd_dif_0': rsi / 2,
      },
    };

KeyPoint _kp(int level, String fx, int poleX, int confirmX) => KeyPoint(
      level: level,
      fx: fx,
      poleX: poleX,
      confirmX: confirmX,
      source: 'test',
    );
/// 本文件夹具每侧只有 2 个转折点，而产品默认 `minPoints=3`（防止 n=2 的
/// 均值/标准差误导）。这里显式降到 1，好让这些用例专心验「取值口径 /
/// 分流 / 落盘」；默认门槛本身由另一条用例单独钉住。
const KeyPointStatSettings _base = KeyPointStatSettings(minPoints: 1);

void main() {
  // 4 个转折点；confirmX 故意与 poleX 不同且值不同 —— 用来证明「只读极点 K」。
  final lookup = BarFeatureLookup.fromCached(
    byIdx: {
      2: _row(idx: 2, rsi: 80, close: 12, fx: 'TOP'),
      4: _row(idx: 4, rsi: 20, close: 8, fx: 'BOTTOM', truncated: true),
      6: _row(idx: 6, rsi: 70, close: 11, fx: 'TOP'),
      8: _row(idx: 8, rsi: 30, close: 9, fx: 'BOTTOM'),
      // 确认当步那几根的值刻意不同：若实现误读 confirmX，统计会立刻对不上。
      3: _row(idx: 3, rsi: 1, close: 999, fx: 'UNKNOWN'),
      5: _row(idx: 5, rsi: 2, close: 888, fx: 'UNKNOWN'),
      7: _row(idx: 7, rsi: 3, close: 777, fx: 'UNKNOWN'),
      9: _row(idx: 9, rsi: 4, close: 666, fx: 'UNKNOWN'),
    },
  );

  final points = [
    _kp(1, 'TOP', 2, 3),
    _kp(1, 'BOTTOM', 4, 5),
    _kp(1, 'TOP', 6, 7),
    _kp(1, 'BOTTOM', 8, 9),
  ];
  final collect = KeyPointCollectResult(keyPoints: points);

  KeyPointStatResult runWith([KeyPointStatSettings? cfg]) => KeyPointStatRunner.run(
        lookup: lookup,
        collect: collect,
        settings: cfg ?? _base,
      );

  group('分组', () {
    test('按级别 × 顶/底 分组，外加全部汇总', () {
      final r = runWith();
      expect(
        r.groups.map((e) => e.groupKey).toList(),
        ['L1_TOP', 'L1_BOTTOM', 'ALL'],
      );
      expect(r.groups[0].groupLabel, 'K1 顶');
      expect(r.groups[0].pointCount, 2);
      expect(r.groups[2].groupLabel, '全部转折点');
      expect(r.groups[2].pointCount, 4);
    });

    test('默认样本下限是 3：2 个点的分组会被过滤掉（防止 n=2 误导）', () {
      final r = KeyPointStatRunner.run(
        lookup: lookup,
        collect: collect,
        settings: const KeyPointStatSettings(),
      );
      // 每侧只有 2 个点 < 3 → 顶/底两张表都不出，只剩 4 个点的汇总表
      expect(r.groups.map((e) => e.groupKey).toList(), ['ALL']);
      expect(
        const KeyPointStatSettings().minPoints,
        3,
        reason: '默认值不得被改回 1',
      );
    });

    test('关闭分组开关 → 每级顶底合并成一张表', () {
      final r = runWith(const KeyPointStatSettings(splitTopBottom: false));
      expect(r.groups.map((e) => e.groupKey).toList(), ['L1_ALL', 'ALL']);
      expect(r.groups.first.groupLabel, 'K1（顶底合并）');
      expect(r.groups.first.pointCount, 4);
    });

    test('分组样本下限：样本不够的分组不出表', () {
      final r = runWith(const KeyPointStatSettings(minPoints: 3));
      expect(r.groups.map((e) => e.groupKey).toList(), ['ALL']);
    });

    test('无关键点位时不产生任何分组', () {
      final r = KeyPointStatRunner.run(
        lookup: lookup,
        collect: const KeyPointCollectResult(keyPoints: []),
        settings: _base,
      );
      expect(r.groups, isEmpty);
      expect(r.metricCount, 0);
    });
  });

  group('取值口径：只读极点 K 那一行', () {
    test('顶分组 RSI 均值 = (80+70)/2，而不是确认当步的 (1+3)/2', () {
      final r = runWith();
      final top = r.groups.firstWhere((e) => e.groupKey == 'L1_TOP');
      final rsi = top.stats.firstWhere((e) => e.metricKey == 'sub.rsi_0');
      expect(rsi.sampleCount, 2);
      expect(rsi.mean, closeTo(75.0, 1e-12));
      expect(rsi.min, 70.0);
      expect(rsi.max, 80.0);
    });

    test('收盘价均值同样来自极点 K', () {
      final r = runWith();
      final all = r.groups.firstWhere((e) => e.groupKey == 'ALL');
      final close = all.stats.firstWhere((e) => e.metricKey == 'close');
      expect(close.mean, closeTo(10.0, 1e-12)); // (12+8+11+9)/4
    });

    test('MACD DIF 等副图指标同源一起统计', () {
      final r = runWith();
      final all = r.groups.firstWhere((e) => e.groupKey == 'ALL');
      final dif = all.stats.firstWhere((e) => e.metricKey == 'sub.macd_dif_0');
      expect(dif.mean, closeTo(25.0, 1e-12)); // (40+10+35+15)/4
    });
  });
group('数值型 / 类别型分流', () {
    test('字符串指标走类别众数（精确值）', () {
      final r = runWith();
      final top = r.groups.firstWhere((e) => e.groupKey == 'L1_TOP');
      final fx = top.stats.firstWhere((e) => e.metricKey == 'combine_fx');
      expect(fx.kind, StatValueKind.categorical);
      expect(fx.modeLabel, 'TOP');
      expect(fx.modeCount, 2);
      expect(fx.modeShare, 1.0);
    });

    test('布尔指标用中文标签做众数', () {
      final r = runWith();
      final all = r.groups.firstWhere((e) => e.groupKey == 'ALL');
      final trunc = all.stats
          .firstWhere((e) => e.metricKey == 'sub.fractal_judgment_trunc_0');
      expect(trunc.kind, StatValueKind.categorical);
      // 4 个点里只有 idx4 是截断
      expect(trunc.modeLabel, '否');
      expect(trunc.modeCount, 3);
      expect(trunc.modeShare, closeTo(0.75, 1e-12));
    });

    test('非空率：分母是该分组转折点数', () {
      final r = runWith();
      final all = r.groups.firstWhere((e) => e.groupKey == 'ALL');
      final merge = all.stats.firstWhere((e) => e.metricKey == 'merge_count');
      expect(merge.sampleCount, 4);
      expect(merge.totalCount, 4);
      expect(merge.coverage, 1.0);
    });
  });

  group('黑名单与去噪', () {
    test('定位/时间/结构对象键不进统计表', () {
      final r = runWith();
      final keys = r.groups
          .firstWhere((e) => e.groupKey == 'ALL')
          .stats
          .map((e) => e.metricKey)
          .toSet();
      for (final k in const [
        'idx',
        'time_ms',
        'time_text',
        'weekday',
        'levels',
        'level_confirms',
        'k0_confirm',
        'k0_line',
        'metrics',
      ]) {
        expect(keys.contains(k), isFalse, reason: '$k 不该进统计表');
      }
    });

    test('ML 禁止键（动态名/字符串汇总）不进统计表', () {
      final r = runWith();
      final keys = r.groups
          .firstWhere((e) => e.groupKey == 'ALL')
          .stats
          .map((e) => e.metricKey)
          .toList();
      expect(keys.any((e) => e.startsWith('mean_text_')), isFalse);
    });

    test('指标中文名优先用 ML 映射', () {
      final r = runWith();
      final all = r.groups.firstWhere((e) => e.groupKey == 'ALL');
      final rsi = all.stats.firstWhere((e) => e.metricKey == 'sub.rsi_0');
      expect(rsi.labelCn, contains('RSI'));
    });
  });

  group('可复现与落盘', () {
    test('同输入重跑结果逐字节一致', () {
      expect(
        KeyPointStatExport.buildTsv(runWith()),
        KeyPointStatExport.buildTsv(runWith()),
      );
    });

    test('众数桶宽由设置写进口径行', () {
      const tight = KeyPointStatSettings(modeDigits: 0);
      const loose = KeyPointStatSettings(modeDigits: 4);
      expect(runWith(tight).headerLine, isNot(equals(runWith(loose).headerLine)));
      expect(runWith(tight).settings.modeDigits, 0);
      expect(runWith(loose).settings.modeDigits, 4);
    });

    test('JSON 落盘体含关键点位清单与分组', () {
      final json = jsonDecode(KeyPointStatExport.buildJson(runWith()));
      expect(json['type'], 'key_point_stat_report');
      expect((json['key_points'] as List).length, 4);
      expect((json['groups'] as List).length, 3);
      expect(json['settings'], isA<Map<String, dynamic>>());
    });

    test('TSV 首行是表头，每张分组表的每个指标一行', () {
      final r = runWith();
      final tsv = KeyPointStatExport.buildTsv(r);
      final lines = tsv.trim().split('\n');
      expect(lines.first.split('\t').first, '分组');
      expect(lines.first.split('\t'), contains('众数占比'));
      final dataRows = r.groups.fold<int>(0, (n, g) => n + g.stats.length);
      expect(lines.length, 2 + dataRows); // 表头 + 口径注释 + 数据
      expect(lines.any((e) => e.contains('全部转折点')), isTrue);
      expect(lines.any((e) => e.contains('K1 顶')), isTrue);
    });

    test('账本里没有指标时，TSV 只有表头与口径行（不写假 0）', () {
      final empty = KeyPointStatRunner.run(
        lookup: BarFeatureLookup.fromCached(
          byIdx: {2: <String, dynamic>{'idx': 2, 'sub': <String, dynamic>{}}},
        ),
        collect: KeyPointCollectResult(keyPoints: [_kp(1, 'TOP', 2, 2)]),
        settings: const KeyPointStatSettings(),
      );
      expect(empty.metricCount, 0);
      expect(KeyPointStatExport.buildTsv(empty).trim().split('\n').length, 2);
    });
  });
}