import '../backtest/backtest_metrics.dart';
import '../backtest/equity_curve.dart';

import 'search_verdict_views.dart';

/// 寻优结果宽表的**唯一列定义**。
///
/// 2026-10-09 重构：以前表头（`_bodyHeader`）、数据行（`_bodyRow`）、右键复制（`_rowTsv`）、
/// 落盘 TSV（`VerdictSink`）四处各写一份列清单，加一列要改四处、漏一处就对不上 ——
/// 已经出过「复制 16 列 / TSV 15 列、面板提示却说同列序」的事故。现改为单一注册表，
/// 四处全部遍历它，**结构上不可能再错位**。
///
/// 三态口径（面板 / 复制 / TSV 完全一致）：
/// - **不可用**（该指标在这段里无意义，如 0 成交时的回撤）→ `—`
/// - **∞**（如无亏损时的盈利因子）→ `∞`
/// - **有限的 0** → `0.00` —— 与上面两种严格区分
class SearchResultColumn {
  /// 排序键（也是快照里保存的列身份）。
  final VerdictSortColumn sort;

  /// 中文列名（不含「内/外」前缀，前缀由所在区段决定）。
  final String label;

  /// TSV 列键（英文，小写下划线）。
  final String tsvKey;

  final double width;

  /// 排序与三态用的**真实数值** —— 绝不用格式化后的字符串排序。
  final MetricNum Function(SegmentMetrics) metric;

  /// 单元格文本：面板、右键复制、TSV 落盘**共用这一个**。
  final String Function(SegmentMetrics) text;

  /// 白话口径（进 tooltip）。
  final String plain;

  /// 三态 / 边界补充说明（进 tooltip，可空）。
  final String? note;

  const SearchResultColumn({
    required this.sort,
    required this.label,
    required this.tsvKey,
    required this.width,
    required this.metric,
    required this.text,
    required this.plain,
    this.note,
  });

  /// 带区段前缀的 tooltip 正文：`中文名：白话（样本内）\n英文键`。
  String tip(String scope) => note == null
      ? '$label：$plain（$scope）\n$tsvKey'
      : '$label：$plain（$scope）\n$tsvKey（$note）';
}

/// 三态渲染：不可用 → `—`，∞ → `∞`，有限数按 [digits] 位（[pct] 时带 `%`）。
String renderMetric(MetricNum m, {bool pct = false, int digits = 2}) {
  if (m.isUnavailable) return '—';
  if (m.isInfinity) return '∞';
  final v = m.value!;
  return pct ? '${(v * 100).toStringAsFixed(1)}%' : v.toStringAsFixed(digits);
}

/// 列宽档位（避免每列各写一个魔数）。
const double kColTrades = 56;
const double kColRate = 64;
const double kColRatio = 64;
const double kColPf = 62;
const double kColNet = 78;
const double kColScore = 74;
const double kColPct = 72;

/// 单列构造器（内部用）。[inSample] 决定排序键与 tsvKey 走 in_ 还是 out_。
SearchResultColumn _col({
  required bool inSample,
  required VerdictSortColumn inSort,
  required VerdictSortColumn outSort,
  required String label,
  required String inKey,
  required double width,
  required MetricNum Function(SegmentMetrics) metric,
  required String Function(SegmentMetrics) text,
  required String plain,
  String? note,
}) =>
    SearchResultColumn(
      sort: inSample ? inSort : outSort,
      label: label,
      tsvKey: inSample ? inKey : inKey.replaceFirst('in_', 'out_'),
      width: width,
      metric: metric,
      text: text,
      plain: plain,
      note: note,
    );

MetricNum _trades(SegmentMetrics s) => MetricNum.finite(s.trades.toDouble());
MetricNum _net(SegmentMetrics s) => MetricNum.finite(s.netProfit);
/// 0 成交时最大回撤没有意义 → 不可用（三态里的 `—`），与「回撤真的是 0」区分开。
MetricNum _ddPct(SegmentMetrics s) =>
    s.trades == 0 ? const MetricNum.unavailable() : MetricNum.finite(s.maxDrawdownPct);
MetricNum _lossStreak(SegmentMetrics s) =>
    MetricNum.finite(s.maxConsecutiveLosses.toDouble());

/// 数值列定义（样本内 / 样本外共用同一份，只是排序键与 tsvKey 换 out_）。
List<SearchResultColumn> buildResultColumns({required bool inSample}) =>
    [
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inTrades,
        outSort: VerdictSortColumn.outTrades,
        label: '笔数',
        inKey: 'in_trades',
        width: kColTrades,
        metric: _trades,
        text: (s) => '${s.trades}',
        plain: '已平仓笔数（盈利＋亏损＋持平）',
        note: '0 成交显示 0（不是不可用）',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inWinRate,
        outSort: VerdictSortColumn.outWinRate,
        label: '胜率',
        inKey: 'in_win_rate',
        width: kColRate,
        metric: (s) => s.winRate,
        text: (s) => renderMetric(s.winRate, pct: true),
        plain: '盈利笔数 ÷ 已平仓总笔数',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inPayoff,
        outSort: VerdictSortColumn.outPayoff,
        label: '盈亏比',
        inKey: 'in_payoff_ratio',
        width: kColRatio,
        metric: (s) => s.payoffRatio,
        text: (s) => renderMetric(s.payoffRatio),
        plain: '单笔平均盈利 ÷ 单笔平均亏损',
        note: '全胜无亏显示 ∞',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inPf,
        outSort: VerdictSortColumn.outPf,
        label: '盈利因子',
        inKey: 'in_profit_factor',
        width: kColPf,
        metric: (s) => s.profitFactor,
        text: (s) => renderMetric(s.profitFactor),
        plain: '毛利 ÷ 毛亏',
        note: '无亏损显示 ∞，0 成交显示 —',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inNet,
        outSort: VerdictSortColumn.outNet,
        label: '净利',
        inKey: 'in_net_profit',
        width: kColNet,
        metric: _net,
        text: (s) => s.netProfit.toStringAsFixed(0),
        plain: '末净值 − 初始本金（已扣费用与滑点）',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inSharpe,
        outSort: VerdictSortColumn.outSharpe,
        label: '夏普',
        inKey: 'in_sharpe',
        width: kColScore,
        metric: (s) => s.sharpe,
        text: (s) => renderMetric(s.sharpe),
        plain: '每笔收益均值 ÷ 每笔收益标准差，按 252 根 K 年化',
        note: '标准差为 0 显示 —',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inCalmar,
        outSort: VerdictSortColumn.outCalmar,
        label: '卡玛',
        inKey: 'in_calmar',
        width: kColScore,
        metric: (s) => s.calmar,
        text: (s) => renderMetric(s.calmar),
        plain: '年化收益 ÷ 最大回撤幅度',
        note: '回撤为 0 显示 —',
      ),
      // ↓ 2026-10-09 新增主列：以下 5 列原本只躺在「点行展开」的明细里，
      //   计算早就有了（backtest_metrics.SegmentMetrics），此处只提升为可排序主列。
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inDdPct,
        outSort: VerdictSortColumn.outDdPct,
        label: '回撤%',
        inKey: 'in_dd_pct',
        width: kColPct,
        metric: _ddPct,
        text: (s) => renderMetric(_ddPct(s), pct: true),
        plain: '最大回撤 ÷ 初始本金（净值曲线口径，不是单笔亏损）',
        note: '0 成交显示 —；越小越稳，排序请用升序',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inSortino,
        outSort: VerdictSortColumn.outSortino,
        label: '索提诺',
        inKey: 'in_sortino',
        width: kColScore,
        metric: (s) => s.sortino,
        text: (s) => renderMetric(s.sortino),
        plain: '每笔收益均值 ÷ 每笔负收益标准差，按 252 根 K 年化（只罚下行）',
        note: '没有负收益波动时显示 —',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inExpectancy,
        outSort: VerdictSortColumn.outExpectancy,
        label: '期望',
        inKey: 'in_expectancy',
        width: kColNet,
        metric: (s) => s.expectancy,
        text: (s) => renderMetric(s.expectancy),
        plain: '每笔平均净盈亏（元，已扣费用与滑点）',
        note: '0 成交显示 —',
      ),
      _col(
        inSample: inSample,
        inSort: VerdictSortColumn.inLossStreak,
        outSort: VerdictSortColumn.outLossStreak,
        label: '连亏',
        inKey: 'in_loss_streak',
        width: kColTrades,
        metric: _lossStreak,
        text: (s) => '${s.maxConsecutiveLosses}',
        plain: '最长连续亏损笔数',
        note: '0 成交显示 0（不是不可用）',
      ),
      _col(
        inSample: inSample,
        // 历史枚举 avgHoldBars 本是「无列绑定的死枚举」，此处正式接上「样本内平均持仓」。
        inSort: VerdictSortColumn.avgHoldBars,
        outSort: VerdictSortColumn.outAvgHoldBars,
        label: '平均持仓',
        inKey: 'in_avg_hold_bars',
        width: kColTrades,
        metric: (s) => s.avgHoldBars,
        text: (s) => renderMetric(s.avgHoldBars, digits: 1),
        plain: '每笔平均持仓 K 数（出场根 − 进场根）',
        note: '0 成交显示 —',
      ),
    ];

/// 样本内数值列。
final List<SearchResultColumn> kInResultColumns =
    buildResultColumns(inSample: true);

/// 样本外数值列。
final List<SearchResultColumn> kOutResultColumns =
    buildResultColumns(inSample: false);

/// 全部数值列（样本内在前、样本外在后）—— 表头 / 数据行 / 复制 / TSV 落盘都按这个顺序。
final List<SearchResultColumn> kAllResultColumns = [
  ...kInResultColumns,
  ...kOutResultColumns,
];

/// TSV 表头行（制表符分隔），由列注册表生成，与数据行列序必然一致。
String buildResultTsvHeader() =>
    kAllResultColumns.map((c) => c.tsvKey).join('\t');

/// 一行的 TSV 文本（供右键复制与落盘共用）。
String buildResultTsvRow({
  required SegmentMetrics inSample,
  required SegmentMetrics outSample,
}) =>
    [
      for (final c in kInResultColumns) c.text(inSample),
      for (final c in kOutResultColumns) c.text(outSample),
    ].join('\t');

/// 按排序键找列定义（`_compareCol` 用它，保证排序值与显示列永远同源）。
SearchResultColumn? resultColumnOf(VerdictSortColumn sort) {
  for (final c in kAllResultColumns) {
    if (c.sort == sort) return c;
  }
  return null;
}
