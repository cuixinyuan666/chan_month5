import 'dart:io';

import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_result_columns.dart';
import 'package:chan_kline/indicator_search/search_verdict_views.dart';
import 'package:flutter_test/flutter_test.dart';

/// 寻优结果宽表「列定义唯一落点」的回归（2026-10-09）。
///
/// 事故背景：以前表头 / 数据行 / 右键复制 / 落盘 TSV 四处各写一份列清单，
/// 于是出现过「复制 16 列、落盘 15 列、面板提示却说同列序」。现改为单一列注册表
/// `search_result_columns.dart`，本文件钉死「四处必须由同一份定义驱动」。
void main() {
  SegmentMetrics _seg({
    int trades = 10,
    double dd = 0.083,
    int streak = 3,
  }) {
    return SegmentMetrics(
      trades: trades,
      winning: trades - 1,
      losing: 1,
      flat: 0,
      winRate: MetricNum.finite(0.6),
      grossProfit: 600,
      grossLoss: 400,
      netProfit: 200,
      returnPct: MetricNum.finite(0.2),
      payoffRatio: MetricNum.finite(1.5),
      profitFactor: const MetricNum.infinity(),
      expectancy: MetricNum.finite(20),
      averageWin: MetricNum.finite(60),
      averageLoss: MetricNum.finite(-40),
      largestWin: MetricNum.finite(90),
      largestLoss: MetricNum.finite(-40),
      maxConsecutiveWins: 4,
      maxConsecutiveLosses: streak,
      maxDrawdown: 83,
      maxDrawdownPct: dd,
      maxDrawdownStartX: 3,
      maxDrawdownEndX: 8,
      recoveryX: 9,
      avgHoldBars: MetricNum.finite(2.5),
      medianHoldBars: MetricNum.finite(2),
      maxHoldBars: MetricNum.finite(6),
      holdTimeRatio: MetricNum.finite(0.4),
      annualReturn: MetricNum.finite(0.3),
      annualVol: MetricNum.finite(0.2),
      sharpe: MetricNum.finite(1.1),
      sortino: MetricNum.finite(1.6),
      calmar: MetricNum.finite(3.6),
    );
  }

  ComboVerdict _verdict() => ComboVerdict(
        name: '阈值｜候选A',
        buyText: 'MAIN.K1.MA.5 上穿 10',
        sellText: 'STRUCTURE.K0.SELL1 出现',
        inSample: _seg(),
        outSample: _seg(trades: 4, dd: 0.2, streak: 2),
        splitX: 500,
      );

  test('列注册表：内外两段列数相同、排序键与 tsvKey 一一对应', () {
    expect(kInResultColumns.length, kOutResultColumns.length);
    for (var i = 0; i < kInResultColumns.length; i++) {
      final a = kInResultColumns[i];
      final b = kOutResultColumns[i];
      expect(b.label, a.label);
      expect(b.tsvKey, a.tsvKey.replaceFirst('in_', 'out_'));
      expect(a.tsvKey, startsWith('in_'));
      expect(b.width, a.width);
    }
    expect(kAllResultColumns.length, kInResultColumns.length * 2);
  });

  test('落盘 TSV 的表头列数 == 数据行列数（复制与落盘同源）', () {
    final header = buildResultTsvHeader().split('\t');
    final row = buildResultTsvRow(
      inSample: _seg(),
      outSample: _seg(),
    ).split('\t');
    expect(row.length, header.length,
        reason: 'TSV 表头与数据行列数必须一致，否则粘进表格会错位');
    expect(header.length, kAllResultColumns.length);
    // 表头 key 顺序 == 注册表顺序
    for (var i = 0; i < header.length; i++) {
      expect(header[i], kAllResultColumns[i].tsvKey);
    }
  });

  test('VerdictSink 落盘的行 = 表头列数，且与 buildResultTsvRow 逐格一致', () {
    final dir = Directory.systemTemp.createTempSync('chan_tsv');
    addTearDown(() => dir.deleteSync(recursive: true));
    final f = File('${dir.path}/r.tsv');
    final sink = VerdictSink(f.path, maxKn: 16);
    final v = _verdict();
    sink.add(v);
    sink.close();
    final lines = f.readAsLinesSync();
    expect(lines.length, 2, reason: '1 行表头 + 1 行数据');
    final header = lines[0].split('\t');
    final cells = lines[1].split('\t');
    expect(cells.length, header.length);
    expect(header.take(3).toList(), ['name', 'buy', 'sell']);
    // 第 1 列候选名、第 2/3 列买卖条件
    expect(cells[0], '阈值｜候选A');
    expect(cells[1], contains('MA'));
    expect(cells[2], contains('SELL'));
    // 数值段与 buildResultTsvRow 逐格一致（面板复制走的是同一个函数）
    final expectRow = buildResultTsvRow(
      inSample: v.inSample,
      outSample: v.outSample,
    ).split('\t');
    expect(cells.skip(3).toList(), expectRow);
  });

  test('三态渲染：不可用 / ∞ / 有限 0 三者严格区分', () {
    expect(renderMetric(const MetricNum.unavailable()), '—');
    expect(renderMetric(const MetricNum.infinity()), '∞');
    expect(renderMetric(const MetricNum.finite(0)), '0.00');
    expect(renderMetric(const MetricNum.finite(0), pct: true), '0.0%');
    // 0 成交时的回撤是「不可用」，不是 0
    final zeroTrade = _seg(trades: 0);
    final ddCol = kInResultColumns.firstWhere((c) => c.sort == VerdictSortColumn.inDdPct);
    expect(ddCol.metric(zeroTrade).isUnavailable, isTrue);
    expect(ddCol.text(zeroTrade), '—');
    // 有成交时回撤 0 是真的 0（有限数），不能被当成不可用
    final flat = _seg(dd: 0);
    expect(ddCol.metric(flat).isFinite, isTrue);
    expect(ddCol.text(flat), '0.0%');
  });

  test('排序用真实数值而非格式化字符串：∞ 顶到头、不可用沉底', () {
    final hi = ComboVerdict(
      name: '阈值｜hi',
      buyText: '',
      sellText: '',
      inSample: _seg(),
      outSample: _seg(),
      splitX: 500,
    );
    final lo = ComboVerdict(
      name: '阈值｜lo',
      buyText: '',
      sellText: '',
      // 0 成交 → 回撤不可用（应沉底）
      inSample: _seg(trades: 0),
      outSample: _seg(trades: 0),
      splitX: 500,
    );
    final asc = sortVerdicts([hi, lo],
        const VerdictSortState(keys: [SortKey(VerdictSortColumn.inDdPct, true)]));
    expect(asc.first.name.endsWith('lo'), isTrue, reason: '不可用（—）必须排在所有有限数之后');
    final desc = sortVerdicts([hi, lo],
        const VerdictSortState(keys: [SortKey(VerdictSortColumn.inDdPct, false)]));
    expect(desc.first.name.endsWith('hi'), isTrue,
        reason: '降序时有限回撤（8.3%）应排在不可用（—）之前');
  });

  test('每个排序枚举（除 type）都绑到了列 —— 不许再有死枚举', () {
    for (final c in VerdictSortColumn.values) {
      if (c == VerdictSortColumn.type) continue;
      expect(resultColumnOf(c), isNotNull, reason: '$c 没有任何列绑定（死枚举）');
    }
  });

  test('面板不再自带列宽/文案魔数（源码守卫）', () {
    final src = File('lib/widgets/indicator_search_result_panel.dart')
        .readAsStringSync();
    for (final stale in const [
      '_colTrades',
      '_colRate',
      '_colRatio',
      '_colPf',
      '_colNet',
      '_colScore',
    ]) {
      expect(src.contains(stale), isFalse,
          reason: '$stale 应已迁到 search_result_columns.dart');
    }
    expect(src.contains('kInResultColumns'), isTrue,
        reason: '表头/数据行必须遍历列注册表');
  });
}

