import 'dart:convert';

import 'package:chan_kline/key_point_stats/key_point.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_contrast.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_align.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_diagnostics.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_export.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/stat_metrics.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 手造一条统计：直接给 mean/stddev/samples，便于把差异度算成手算可验的数。
StatSummary _num(
  String key, {
  required double mean,
  required double stddev,
  required int samples,
  double? mode,
  int modeCount = 0,
}) =>
    StatSummary(
      metricKey: key,
      labelCn: key,
      kind: StatValueKind.numeric,
      sampleCount: samples,
      totalCount: samples,
      mean: mean,
      median: mean,
      stddev: stddev,
      min: mean - stddev,
      max: mean + stddev,
      p25: mean - stddev,
      p75: mean + stddev,
      mode: mode,
      modeCount: modeCount,
      modeShare: samples > 0 ? modeCount / samples : null,
    );

Map<String, dynamic> _row(int idx, double rsi, String fx) => {
      'idx': idx,
      'close': 10 + idx.toDouble(),
      'high': 12.0,
      'low': 8.0,
      'open': 11.0,
      'volume': 1000.0,
      'combine_fx': fx,
      'sub': <String, dynamic>{'rsi_0': rsi, 'fractal_judgment_0': fx},
    };

KeyPoint _kp(int level, String fx, int poleX) =>
    KeyPoint(level: level, fx: fx, poleX: poleX, confirmX: poleX + 1, source: 't');
void main() {
  group('Q1 · 众数显著性门控', () {
    test('数值型 modeShare = 众数桶命中数 / 样本数', () {
      final s = numericStat(
        metricKey: 'a',
        labelCn: 'a',
        rawValues: const [1, 1, 1, 5, 9, 12, 20],
        totalCount: 7,
        modeDigits: 0,
      );
      expect(s.mode, 1.0);
      expect(s.modeCount, 3);
      expect(s.modeShare, closeTo(3 / 7, 1e-12));
    });

    test('只出现一次的值：modeShare 很低，正是要门控掉的那种', () {
      final s = numericStat(
        metricKey: 'p',
        labelCn: '价格',
        rawValues: const [11.7261, 11.8102, 12.0044, 12.3310],
        totalCount: 4,
      );
      expect(s.modeCount, 1);
      expect(s.modeShare, closeTo(0.25, 1e-12));
      expect(
        s.modeShare! < const KeyPointStatSettings().modeMinShare,
        isTrue,
        reason: '默认值 0.3 下应当判为无显著众数',
      );
    });

    test('TSV：未达显著性阈值时众数列留空（不是写 0）', () {
      final s = numericStat(
        metricKey: 'p',
        labelCn: '价格',
        rawValues: const [11.7261, 11.8102, 12.0044, 12.3310],
        totalCount: 4,
      );
      final tsv = KeyPointStatExport.buildTsv(
        _resultFor([s], settings: const KeyPointStatSettings(minPoints: 1)),
      );
      final row = tsv.trim().split('\n').last.split('\t');
      // 第 15 列是众数、第 16 列是众数命中数
      expect(row[14], '');
      expect(row[15], '1');
      expect(row[16], '0.2500', reason: '占比按 4 位小数落盘');
    });

    test('TSV：达到阈值时照常给众数；类别型众数永不受门控', () {
      final ok = numericStat(
        metricKey: 'a',
        labelCn: 'a',
        rawValues: const [1, 1, 1, 5, 9, 12, 20],
        totalCount: 7,
        modeDigits: 0,
      );
      final cat = categoricalStat(
        metricKey: 'fx',
        labelCn: '方向',
        values: const ['TOP', 'BOTTOM', 'TOP', 'UNKNOWN'],
        totalCount: 4,
      );
      final tsv = KeyPointStatExport.buildTsv(
        _resultFor([ok, cat], settings: const KeyPointStatSettings(minPoints: 1)),
      );
      final rows = tsv.trim().split('\n').skip(2).toList();
      final numRow = rows.firstWhere((r) => r.contains('\ta\t'));
      final catRow = rows.firstWhere((r) => r.contains('\tfx\t'));
      expect(numRow.split('\t')[14], '1.000000');
      expect(catRow.split('\t')[14], 'TOP');
    });
  });

  group('Q3 · 顶底差异度', () {
    test('contrast = |顶均值−底均值| / RMS(两组标准差)，降序返回', () {
      final out = computeContrasts(
        topStats: [
          _num('A', mean: 10, stddev: 2, samples: 5),
          _num('B', mean: 5, stddev: 1, samples: 5),
        ],
        bottomStats: [
          _num('A', mean: 6, stddev: 2, samples: 5),
          _num('B', mean: 4, stddev: 1, samples: 5),
        ],
        level: 1,
        minPoints: 3,
      );
      // A: delta=4, pooled=sqrt((4+4)/2)=2 → 2.0
      // B: delta=1, pooled=1 → 1.0
      expect(out.map((e) => e.metricKey).toList(), ['A', 'B']);
      expect(out[0].contrast, closeTo(2.0, 1e-12));
      expect(out[0].deltaMean, closeTo(4.0, 1e-12));
      expect(out[0].pooledSigma, closeTo(2.0, 1e-12));
      expect(out[0].topHigher, isTrue);
      expect(out[1].contrast, closeTo(1.0, 1e-12));
    });

    test('方向可反：底更高的指标 deltaMean 为负', () {
      final out = computeContrasts(
        topStats: [_num('A', mean: 3, stddev: 1, samples: 5)],
        bottomStats: [_num('A', mean: 8, stddev: 1, samples: 5)],
        level: 1,
        minPoints: 3,
      );
      expect(out.single.deltaMean, closeTo(-5.0, 1e-12));
      expect(out.single.topHigher, isFalse);
      expect(out.single.contrast, closeTo(5.0, 1e-12));
    });

    test('任一侧样本不足 → 不出差异度（宁可不给也不给假差异）', () {
      final out = computeContrasts(
        topStats: [_num('A', mean: 10, stddev: 2, samples: 2)],
        bottomStats: [_num('A', mean: 6, stddev: 2, samples: 5)],
        level: 1,
        minPoints: 3,
      );
      expect(out, isEmpty);
    });

    test('合并标准差为 0（组内无波动）→ 不出差异度', () {
      final out = computeContrasts(
        topStats: [_num('A', mean: 10, stddev: 0, samples: 5)],
        bottomStats: [_num('A', mean: 6, stddev: 0, samples: 5)],
        level: 1,
        minPoints: 3,
      );
      expect(out, isEmpty, reason: '分母趋零会把差异放大成假信号');
    });

    test('类别型指标不参与差异度', () {
      final cat = StatSummary(
        metricKey: 'fx',
        labelCn: 'fx',
        kind: StatValueKind.categorical,
        sampleCount: 5,
        totalCount: 5,
        modeLabel: 'TOP',
        modeCount: 3,
        modeShare: 0.6,
      );
      final out = computeContrasts(
        topStats: [cat],
        bottomStats: [cat],
        level: 1,
        minPoints: 3,
      );
      expect(out, isEmpty);
    });
  });
group('Q2 · 只读体检诊断类', () {
    test('统计总点数、各组样本量与低样本组数', () {
      final r = _multiLevelResult();
      final d = KeyPointStatDiagnostics.of(r);
      expect(d.totalPoints, 12); // 3 顶 + 3 底 × 2 级
      expect(d.groupPoints['L1_TOP'], 3);
      expect(d.groupPoints['L1_BOTTOM'], 3);
      expect(d.groupPoints['ALL'], 12);
      expect(d.minGroupPoints, 3);
      expect(d.lowSampleGroupCount, 0);
      expect(d.hasRisk, isFalse);
    });

    test('样本不足时分组被过滤，无分组则不给体检行', () {
      final r = KeyPointStatRunner.run(
        lookup: BarFeatureLookup.fromCached(
          byIdx: {0: _row(0, 10, 'TOP'), 1: _row(1, 20, 'BOTTOM')},
        ),
        collect: KeyPointCollectResult(
          keyPoints: [_kp(1, 'TOP', 0), _kp(1, 'BOTTOM', 1)],
        ),
        settings: const KeyPointStatSettings(minPoints: 5),
      );
      expect(r.groups, isEmpty);
      final d = KeyPointStatDiagnostics.of(r);
      expect(d.totalPoints, 2, reason: '无分组也要如实报出转折点数');
      expect(d.groupPoints, isEmpty);
      final line = d.toDisplayLine();
      expect(line, contains('转折点 2 个'), reason: '体检恰恰要回答「为什么没出表」');
      expect(line, contains('分组 0 张'));
    });

    test('体检行含转折点数 / 分组数 / 差异度覆盖 / 无显著众数', () {
      final line = KeyPointStatDiagnostics.of(_multiLevelResult())
          .toDisplayLine()!;
      expect(line, contains('计优体检'));
      expect(line, contains('转折点 12 个'));
      expect(line, contains('分组 5 张'));
      expect(line, contains('顶底差异度覆盖 2 级'));
    });

    test('体检是只读的：不改变任何统计值与分组', () {
      final r = _multiLevelResult();
      final before = KeyPointStatExport.buildTsv(r);
      KeyPointStatDiagnostics.of(r);
      expect(KeyPointStatExport.buildTsv(r), before);
      expect(r.groups.length, 5);
    });

    test('toJson 可序列化，Top-N 差异清单按降序导出', () {
      final r = _multiLevelResult();
      final d = KeyPointStatDiagnostics.of(r);
      expect(() => jsonEncode(d.toJson()), returnsNormally);
      final top = d.topContrastJson(r, 3);
      expect(top, isNotEmpty);
      expect(top.length, lessThanOrEqualTo(3));
      expect(top.first.containsKey('contrast'), isTrue);
      expect(top.first.containsKey('top_mean'), isTrue);
      for (var i = 1; i < top.length; i++) {
        expect(top[i - 1]['contrast'], greaterThanOrEqualTo(top[i]['contrast']));
      }
    });
  });
group('Q4 · 复现参数两行', () {
    test('点位层：写清统计的是哪些点（含截断开关）', () {
      final line = _align.pointScopeLine();
      expect(line, startsWith('点位口径：'));
      expect(line, contains('002003'));
      expect(line, contains('1m'));
      expect(line, contains('K0 289 根'));
      expect(line, contains('asOf 288'));
      expect(line, contains('maxKn 4'));
      expect(line, contains('截断监察 关'), reason: '截断开关会改转折点位置');
    });

    test('数值层：写清每格的值是怎么来的', () {
      final line = _align.indicatorParamsLine();
      expect(line, startsWith('指标参数：'));
      expect(line, contains('布林10'), reason: '改 N 就改值，必须记');
      expect(line, contains('RSI21'));
      expect(line, contains('MACD 12/26/9'));
      expect(line, contains('唐奇安20'));
      expect(line, contains('筹码桶宽0.02'));
      expect(line, contains('峰编号volume'));
    });

    test('align.headerLines = 两行复现参数；result.headerLine 前两行就是它们', () {
      final lines = _align.headerLines.split('\n');
      expect(lines.first, _align.pointScopeLine());
      expect(lines[1], _align.indicatorParamsLine());

      final h = _multiLevelResult().headerLine;
      final hl = h.split('\n');
      expect(hl.length, greaterThanOrEqualTo(4));
      expect(h, contains('点位口径：'));
      expect(h, contains('指标参数：'));
      expect(h, contains('事后统计'));
      expect(h, contains('数值众数为分桶近似'));
    });

    test('JSON 分 point_scope / indicator_params 两层', () {
      final j = _align.toJson();
      expect(j['point_scope']['truncation_check'], isFalse);
      expect(j['point_scope']['bar_count'], 289);
      expect(j['indicator_params']['bollN'], 10);
      expect(j['indicator_params']['chip_bucket_step'], 0.02);
      expect(j['indicator_params']['peak_rank_mode'], 'volume');
      expect(() => jsonEncode(j), returnsNormally);
    });

    test('计优报告 JSON 带 align 与 contrasts 段', () {
      final j = jsonDecode(KeyPointStatExport.buildJson(_multiLevelResult()));
      expect(j['align'], isA<Map<String, dynamic>>());
      expect(j['align']['point_scope'], isA<Map<String, dynamic>>());
      expect((j['contrasts'] as List).isNotEmpty, isTrue);
    });

    test('落盘表头自带代码/周期 —— 复现参数不能只在内存里', () {
      // 这条钉的是「同输入重跑但漏传 code/period」那类漂移：
      // 报告头既然纳入复现参数，任何一次 run 的 TSV 都必须能自证是哪只票、哪个周期。
      final r = KeyPointStatRunner.run(
        lookup: BarFeatureLookup.fromCached(byIdx: {0: _row(0, 80, 'TOP')}),
        collect: KeyPointCollectResult(keyPoints: [_kp(1, 'TOP', 0)]),
        settings: const KeyPointStatSettings(minPoints: 1),
        code: '002003',
        period: '1m',
        barCount: 1,
      );
      final tsv = KeyPointStatExport.buildTsv(r);
      expect(tsv, contains('002003'));
      expect(tsv, contains('1m'));
      expect(tsv.split('\n')[1], startsWith('# 点位口径：'));
    });
  });
}

const KeyPointStatAlign _align = KeyPointStatAlign(
  code: '002003',
  period: '1m',
  beginText: '2004/07/19 09:30:00',
  endText: '2004/07/20 15:00:00',
  barCount: 289,
  asOf: 288,
  maxKn: 4,
  truncationCheck: false,
  mathConfig: MathIndicatorConfig(bollN: 10, rsiPeriod: 21),
  bucketStep: 0.02,
  peakRankMode: 'volume',
);

/// 造一个「两级 × 顶底各 3 点」的确定性结果：RSI 顶高(80~84)、底低(20~24)。
KeyPointStatResult _multiLevelResult() {
  final byIdx = <int, Map<String, dynamic>>{};
  final pts = <KeyPoint>[];
  var i = 0;
  for (final lv in [1, 2]) {
    for (final rsi in [80.0, 82.0, 84.0]) {
      byIdx[i] = _row(i, rsi, 'TOP');
      pts.add(_kp(lv, 'TOP', i));
      i++;
    }
    for (final rsi in [20.0, 22.0, 24.0]) {
      byIdx[i] = _row(i, rsi, 'BOTTOM');
      pts.add(_kp(lv, 'BOTTOM', i));
      i++;
    }
  }
  return KeyPointStatRunner.run(
    lookup: BarFeatureLookup.fromCached(byIdx: byIdx),
    collect: KeyPointCollectResult(keyPoints: pts),
    settings: const KeyPointStatSettings(minPoints: 3),
  );
}

/// 把给定的一组 StatSummary 包成最小可落盘结果（只测落盘，不测编排）。
KeyPointStatResult _resultFor(
  List<StatSummary> stats, {
  KeyPointStatSettings settings = const KeyPointStatSettings(),
}) =>
    KeyPointStatResult(
      finishedAt: DateTime(2026, 10, 1),
      code: '',
      period: '',
      beginText: '',
      endText: '',
      barCount: 0,
      maxKn: 0,
      settings: settings,
      align: const KeyPointStatAlign(),
      collect: const KeyPointCollectResult(keyPoints: []),
      keyPoints: const [],
      groups: [
        KeyPointStatGroup(
          groupKey: 'ALL',
          groupLabel: '全部转折点',
          pointCount: stats.isEmpty ? 0 : stats.first.totalCount,
          stats: stats,
        ),
      ],
      contrasts: const [],
      elapsedMs: 0,
    );