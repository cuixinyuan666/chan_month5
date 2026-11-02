import '../backtest/backtest_metrics.dart';
import '../backtest/equity_curve.dart';

/// 寻优评分：把一段回测指标压成一个可比较的分数。
///
/// 这一层是纯函数，不跑回测、不改任何口径。它解决的是寻优从来没有的事：
/// 结果全列出来之后，怎么判定「哪个指标组合真正好用」。
///
/// 评分只看一段的指标，不知道这段是样本内还是样本外。排名时**以样本外为准**，
/// 样本内分数只用来算过拟合惩罚（内段好、外段崩的组合要被压低）。

/// 笔数少于此值的段，统计上没有意义（五笔全胜不能压过五十笔稳态）。
const int kMinTradesForScore = 6;

/// 样本内外一致性惩罚系数：内段比外段好出来的那一截，按此系数扣掉。
const double kConsistencyPenaltyLambda = 0.5;

/// 各项指标的权重。正项越大越好，负项（回撤、连亏）是扣分。
/// 权重之和为 1，便于直觉读「这一分里有多少来自胜率」。
const double kWeightWinRate = 0.20;
const double kWeightProfitFactor = 0.25;
const double kWeightSharpe = 0.15;
const double kWeightCalmar = 0.10;
const double kWeightExpectancy = 0.10;
const double kWeightDrawdown = 0.12;
const double kWeightLossStreak = 0.08;

/// 把一个指标压到 0 到 1。不可用或无穷按 [onMissing] 处理：
/// 正项缺失算 0 分（没有证据就不给分），负项缺失算满分（没有回撤就不扣分）。
double _squash(
  MetricNum m, {
  required double good,
  required double bad,
  required double onMissing,
}) {
  if (!m.isFinite) return onMissing;
  final span = good - bad;
  if (span == 0) return onMissing;
  final t = (m.value! - bad) / span;
  return t.clamp(0.0, 1.0);
}

/// 单段评分，范围约 0 到 1，越大越好。
///
/// 笔数不足 [kMinTradesForScore] 直接返回 0：样本太少的好看数字不值得信。
/// 各项按固定门槛压到 0 到 1，门槛取的是本工程回测里常见的好坏分界：
/// - 胜率 0.35 到 0.7
/// - 盈利因子 0.6 到 2.5
/// - 夏普 0 到 2
/// - 卡玛 0 到 3
/// - 期望（每笔均值）按毛利归一：毛亏超过毛利算 0，毛利超过毛亏两倍算满
/// - 回撤幅度 0 到 0.3（越小越好）
/// - 连亏 0 到 8 笔（越少越好）
double scoreSegment(SegmentMetrics s) {
  if (s.trades < kMinTradesForScore) return 0;

  final win = _squash(s.winRate, good: 0.7, bad: 0.35, onMissing: 0);
  final pf = _squash(s.profitFactor, good: 2.5, bad: 0.6, onMissing: 0);
  final sharpe = _squash(s.sharpe, good: 2.0, bad: 0.0, onMissing: 0);
  final calmar = _squash(s.calmar, good: 3.0, bad: 0.0, onMissing: 0);

  double expectancy = 0;
  if (s.expectancy.isFinite && s.grossProfit > 0) {
    expectancy =
        (s.expectancy.value! / s.grossProfit).clamp(0.0, 1.0);
  }

  final dd = s.trades == 0
      ? 1.0
      : (1.0 - (s.maxDrawdownPct / 0.3).clamp(0.0, 1.0));
  final streak = 1.0 -
      (s.maxConsecutiveLosses / 8.0).clamp(0.0, 1.0);

  return kWeightWinRate * win +
      kWeightProfitFactor * pf +
      kWeightSharpe * sharpe +
      kWeightCalmar * calmar +
      kWeightExpectancy * expectancy +
      kWeightDrawdown * dd +
      kWeightLossStreak * streak;
}

/// 过拟合惩罚：样本内比样本外好出来的那一截，按 [kConsistencyPenaltyLambda] 扣掉。
/// 内外一致或外段更好时惩罚为 0。
double consistencyPenalty(double scoreIn, double scoreOut) {
  final gap = scoreIn - scoreOut;
  if (gap <= 0) return 0;
  return gap * kConsistencyPenaltyLambda;
}

/// 稳健排名分：只以样本外为准，再扣掉过拟合惩罚。
///
/// 样本外亏钱、盈利因子低于 1、或样本外笔数不足，直接返回 0（沉底，不删数据）。
double robustRankScore(SegmentMetrics inSample, SegmentMetrics outSample) {
  if (outSample.trades < kMinTradesForScore) return 0;
  if (outSample.netProfit <= 0) return 0;
  if (outSample.profitFactor.isFinite &&
      outSample.profitFactor.value! < 1) {
    return 0;
  }
  final out = scoreSegment(outSample);
  final penalty = consistencyPenalty(scoreSegment(inSample), out);
  final score = out - penalty;
  return score < 0 ? 0 : score;
}
