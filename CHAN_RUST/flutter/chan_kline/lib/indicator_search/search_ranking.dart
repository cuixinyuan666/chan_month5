import 'search_core.dart';
import 'search_scoring.dart';

/// 寻优排名：给每个候选一个稳健分，并按它排序。
///
/// 只排序、不删除。分数为 0 的候选（笔数不足、样本外亏钱、盈利因子低于 1）
/// 沉到底部，但仍在结果里，用户能看到它们为什么没被选中。

/// 一个候选的排名结果。
class RankedVerdict {
  final ComboVerdict verdict;

  /// 样本内分数（只用于过拟合惩罚，不用于排序）。
  final double scoreIn;

  /// 样本外分数（排序的唯一依据）。
  final double scoreOut;

  /// 过拟合惩罚（内段好、外段崩时为正）。
  final double penalty;

  /// 最终排名分 = 样本外分数 − 惩罚，下限 0。
  final double rankScore;

  const RankedVerdict({
    required this.verdict,
    required this.scoreIn,
    required this.scoreOut,
    required this.penalty,
    required this.rankScore,
  });
}

/// 给候选打分。纯函数，不改候选本身。
RankedVerdict rankOne(ComboVerdict v) {
  final inScore = scoreSegment(v.inSample);
  final outScore = scoreSegment(v.outSample);
  final penalty = consistencyPenalty(inScore, outScore);
  return RankedVerdict(
    verdict: v,
    scoreIn: inScore,
    scoreOut: outScore,
    penalty: penalty,
    rankScore: robustRankScore(v.inSample, v.outSample),
  );
}

/// 全部打分并按排名分降序。同分时按名称升序，保证结果可复现。
List<RankedVerdict> rankVerdicts(List<ComboVerdict> verdicts) {
  final ranked = [for (final v in verdicts) rankOne(v)];
  ranked.sort((a, b) {
    final c = b.rankScore.compareTo(a.rankScore);
    if (c != 0) return c;
    return a.verdict.name.compareTo(b.verdict.name);
  });
  return ranked;
}
