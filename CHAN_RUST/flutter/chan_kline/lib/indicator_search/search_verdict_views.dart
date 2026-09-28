import 'search_core.dart';

/// 寻优结果分桶（多维度筛选，不等同于最终投资建议）。
class SearchVerdictBuckets {
  const SearchVerdictBuckets._();

  static const gate = PassGate();

  static List<ComboVerdict> dualPassed(List<ComboVerdict> all) =>
      all.where((e) => e.passed).toList();

  static List<ComboVerdict> inSampleOnly(List<ComboVerdict> all) =>
      all
          .where((e) => gate.okSegment(e.inSample) && !gate.okSegment(e.outSample))
          .toList();

  static List<ComboVerdict> outSampleOnly(List<ComboVerdict> all) =>
      all
          .where((e) => gate.okSegment(e.outSample) && !gate.okSegment(e.inSample))
          .toList();

  /// 样本内过线、样本外未过（含早停 0 笔）。
  static List<ComboVerdict> inPassOutWeak(List<ComboVerdict> all) =>
      inSampleOnly(all);

  /// 保守分>0 但未双达标（供人工筛）。
  static List<ComboVerdict> rankPositiveNotDual(List<ComboVerdict> all) =>
      all.where((e) => e.inRankScore > 0 && !e.passed).toList();

  /// 样本外有成交且外段过线（不要求样本内）。
  static List<ComboVerdict> outSegmentStrong(List<ComboVerdict> all) =>
      all.where((e) => gate.okSegment(e.outSample)).toList();

  static List<ComboVerdict> byRankDesc(List<ComboVerdict> all) {
    final copy = [...all];
    copy.sort((a, b) => b.inRankScore.compareTo(a.inRankScore));
    return copy;
  }

  static List<ComboVerdict> allRan(List<ComboVerdict> all) => [...all];
}

enum VerdictSortColumn {
  type,
  inTrades,
  inWinRate,
  inPayoff,
  outTrades,
  outWinRate,
  outPayoff,
  rank,
}

class VerdictSortState {
  final VerdictSortColumn? column;
  final bool ascending;

  const VerdictSortState({this.column, this.ascending = false});

  VerdictSortState toggle(VerdictSortColumn col) {
    if (column != col) return VerdictSortState(column: col, ascending: false);
    return VerdictSortState(column: col, ascending: !ascending);
  }
}

List<ComboVerdict> sortVerdicts(
  List<ComboVerdict> rows,
  VerdictSortState state,
) {
  if (state.column == null) return rows;
  final copy = [...rows];
  int cmpNum(double? a, double? b) {
    final x = a ?? -1;
    final y = b ?? -1;
    return x.compareTo(y);
  }
  copy.sort((a, b) {
    int c;
    switch (state.column!) {
      case VerdictSortColumn.type:
        c = a.categoryLabel.compareTo(b.categoryLabel);
      case VerdictSortColumn.inTrades:
        c = a.inSample.trades.compareTo(b.inSample.trades);
      case VerdictSortColumn.inWinRate:
        c = cmpNum(a.inSample.winRate, b.inSample.winRate);
      case VerdictSortColumn.inPayoff:
        c = cmpNum(a.inSample.payoff, b.inSample.payoff);
      case VerdictSortColumn.outTrades:
        c = a.outSample.trades.compareTo(b.outSample.trades);
      case VerdictSortColumn.outWinRate:
        c = cmpNum(a.outSample.winRate, b.outSample.winRate);
      case VerdictSortColumn.outPayoff:
        c = cmpNum(a.outSample.payoff, b.outSample.payoff);
      case VerdictSortColumn.rank:
        c = a.inRankScore.compareTo(b.inRankScore);
    }
    return state.ascending ? c : -c;
  });
  return copy;
}
