import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';

import 'search_core.dart';

/// 结果排序列。默认（无列）保持候选生成顺序，不隐含优劣排名。
enum VerdictSortColumn {
  type,
  inTrades,
  inWinRate,
  inPayoff,
  inPf,
  inNet,
  inSharpe,
  inCalmar,
  outTrades,
  outWinRate,
  outPayoff,
  outPf,
  outNet,
  outSharpe,
  outCalmar,
  avgHoldBars,
}

/// 单键排序状态：列 + 升/降序。
class SortKey {
  final VerdictSortColumn column;
  final bool ascending;
  const SortKey(this.column, this.ascending);
}

/// 多列累积排序状态：按点击顺序维护一串排序键（优先级从高到低）。
/// 空键列表 = 保持候选生成顺序（不隐含排名）。
class VerdictSortState {
  final List<SortKey> keys;

  const VerdictSortState({this.keys = const []});

  bool get isEmpty => keys.isEmpty;
  bool get isNotEmpty => keys.isNotEmpty;

  /// 该列所在的优先级（0 起；-1 表示未参与排序）。
  int priorityOf(VerdictSortColumn col) =>
      keys.indexWhere((k) => k.column == col);

  SortKey? keyFor(VerdictSortColumn col) {
    final i = priorityOf(col);
    return i < 0 ? null : keys[i];
  }

  bool has(VerdictSortColumn col) => priorityOf(col) >= 0;

  /// 点击某列：
  /// - 新列 → 追加为下一优先级（默认降序）；
  /// - 已存在 → 仅切换该键升/降序，不改变其优先级序号。
  VerdictSortState toggle(VerdictSortColumn col) {
    final i = priorityOf(col);
    if (i < 0) {
      return VerdictSortState(keys: [...keys, SortKey(col, false)]);
    }
    final next = [...keys];
    next[i] = SortKey(col, !keys[i].ascending);
    return VerdictSortState(keys: next);
  }

  /// 移除某列的排序键（长按/右键表头）。
  VerdictSortState remove(VerdictSortColumn col) =>
      VerdictSortState(keys: keys.where((k) => k.column != col).toList());

  VerdictSortState clear() => const VerdictSortState();
}

/// 排序时把不可用沉底、∞ 顶到头，有限数居中比较。
int _cmpMetric(MetricNum a, MetricNum b) {
  double v(MetricNum m) => m.isInfinity
      ? double.infinity
      : (m.isFinite ? m.value! : double.negativeInfinity);
  return v(a).compareTo(v(b));
}

/// 取某列在两行上的原始比较值（不乘方向；方向由调用方按键处理）。
int _compareCol(ComboVerdict a, ComboVerdict b, VerdictSortColumn col) {
  switch (col) {
    case VerdictSortColumn.type:
      return a.categoryLabel.compareTo(b.categoryLabel);
    case VerdictSortColumn.inTrades:
      return a.inSample.trades.compareTo(b.inSample.trades);
    case VerdictSortColumn.inWinRate:
      return _cmpMetric(a.inSample.winRate, b.inSample.winRate);
    case VerdictSortColumn.inPayoff:
      return _cmpMetric(a.inSample.payoffRatio, b.inSample.payoffRatio);
    case VerdictSortColumn.inPf:
      return _cmpMetric(a.inSample.profitFactor, b.inSample.profitFactor);
    case VerdictSortColumn.inNet:
      return a.inSample.netProfit.compareTo(b.inSample.netProfit);
    case VerdictSortColumn.inSharpe:
      return _cmpMetric(a.inSample.sharpe, b.inSample.sharpe);
    case VerdictSortColumn.inCalmar:
      return _cmpMetric(a.inSample.calmar, b.inSample.calmar);
    case VerdictSortColumn.outTrades:
      return a.outSample.trades.compareTo(b.outSample.trades);
    case VerdictSortColumn.outWinRate:
      return _cmpMetric(a.outSample.winRate, b.outSample.winRate);
    case VerdictSortColumn.outPayoff:
      return _cmpMetric(a.outSample.payoffRatio, b.outSample.payoffRatio);
    case VerdictSortColumn.outPf:
      return _cmpMetric(a.outSample.profitFactor, b.outSample.profitFactor);
    case VerdictSortColumn.outNet:
      return a.outSample.netProfit.compareTo(b.outSample.netProfit);
    case VerdictSortColumn.outSharpe:
      return _cmpMetric(a.outSample.sharpe, b.outSample.sharpe);
    case VerdictSortColumn.outCalmar:
      return _cmpMetric(a.outSample.calmar, b.outSample.calmar);
    case VerdictSortColumn.avgHoldBars:
      return _cmpMetric(a.inSample.avgHoldBars, b.inSample.avgHoldBars);
  }
}

List<ComboVerdict> sortVerdicts(
  List<ComboVerdict> rows,
  VerdictSortState state,
) {
  if (state.keys.isEmpty) return rows;
  final copy = [...rows];
  copy.sort((a, b) {
    for (final k in state.keys) {
      final c = _compareCol(a, b, k.column);
      if (c != 0) return k.ascending ? c : -c;
    }
    return 0;
  });
  return copy;
}

/// 寻优结果快照的可恢复会话（排序/展开/身份），供「返回寻优结果」与快照界面复用。
class IndicatorSearchSessionSnapshot {
  final List<ComboVerdict> verdicts;
  final int compiled;
  final int ran;
  final int splitX;
  final Duration elapsed;
  final VerdictSortState sort;
  final int? expanded;
  final String code;
  final String period;
  final String beginText;
  final String endText;
  final int barCount;
  final IndicatorSearchAlignSnapshot? align;
  final CandidateBuildSummary? buildSummary;
  final int maxKn;

  /// 完整 TSV 落盘路径（当次寻优产出）。恢复界面要用它渲染结果表；
  /// 空串表示旧快照未记录，界面退化为「未知路径」提示。
  final String resultsFilePath;

  const IndicatorSearchSessionSnapshot({
    required this.verdicts,
    required this.compiled,
    required this.ran,
    required this.splitX,
    required this.elapsed,
    this.sort = const VerdictSortState(),
    this.expanded,
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.barCount,
    this.align,
    this.buildSummary,
    this.maxKn = 16,
    this.resultsFilePath = '',
  });
}
