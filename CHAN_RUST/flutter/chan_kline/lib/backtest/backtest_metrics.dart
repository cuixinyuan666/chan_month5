import 'dart:math' as math;

import 'equity_curve.dart';
import 'order_models.dart';

class BacktestMetrics {
  final double initialCapital;
  final double finalEquity;
  final double netProfit;
  final MetricNum returnPct;

  final int totalTrades;
  final int winningTrades;
  final int losingTrades;
  final MetricNum winRate;

  final double grossProfit;
  final double grossLoss;
  final MetricNum averageWin;
  final MetricNum averageLoss;
  final MetricNum profitFactor;
  final MetricNum payoffRatio;
  final MetricNum expectancy;

  /// 最大回撤那一段的峰/谷（不是全曲线最高点，除非回撤就发生在那里）
  final double peakEquity;
  final double troughEquity;
  /// 与 maxDrawdown 同值：最大回撤金额（峰−谷，≥0）
  final double drawdown;
  /// 与 maxDrawdownPct 同值：最大回撤比例（金额/峰，≥0；不是 NaN）
  final double drawdownPct;
  final double maxDrawdown;
  final double maxDrawdownPct;
  final int? maxDrawdownStartX;
  final int? maxDrawdownEndX;
  final int? recoveryX;

  final int maxConsecutiveWins;
  final int maxConsecutiveLosses;
  final MetricNum largestWin;
  final MetricNum largestLoss;

  const BacktestMetrics({
    required this.initialCapital,
    required this.finalEquity,
    required this.netProfit,
    required this.returnPct,
    required this.totalTrades,
    required this.winningTrades,
    required this.losingTrades,
    required this.winRate,
    required this.grossProfit,
    required this.grossLoss,
    required this.averageWin,
    required this.averageLoss,
    required this.profitFactor,
    required this.payoffRatio,
    required this.expectancy,
    required this.peakEquity,
    required this.troughEquity,
    required this.drawdown,
    required this.drawdownPct,
    required this.maxDrawdown,
    required this.maxDrawdownPct,
    required this.maxDrawdownStartX,
    required this.maxDrawdownEndX,
    required this.recoveryX,
    required this.maxConsecutiveWins,
    required this.maxConsecutiveLosses,
    required this.largestWin,
    required this.largestLoss,
  });
}

double _tradeNet(TradeRecord t) => t.netPnL;

BacktestMetrics computeBacktestMetrics({
  required double initialCapital,
  required List<EquityPoint> equityCurve,
  required List<TradeRecord> closedTrades,
}) {
  final lastEq =
      equityCurve.isEmpty ? initialCapital : equityCurve.last.equity;
  final netProfit = lastEq - initialCapital;
  final returnPct = initialCapital == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(netProfit / initialCapital);

  final pnls = closedTrades.map(_tradeNet).toList();
  final wins = pnls.where((p) => p > 0).toList();
  final losses = pnls.where((p) => p < 0).toList();
  final n = closedTrades.length;
  final nw = wins.length;
  final nl = losses.length;
  final grossProfit = wins.fold(0.0, (a, b) => a + b);
  final grossLoss = losses.fold(0.0, (a, b) => a + b);

  final winRate = n == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(nw / n);
  final averageWin = nw == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(grossProfit / nw);
  final averageLoss = nl == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(grossLoss / nl);

  MetricNum profitFactor;
  if (n == 0 || (grossProfit == 0 && grossLoss == 0)) {
    profitFactor = const MetricNum.unavailable();
  } else if (grossLoss == 0 && grossProfit > 0) {
    profitFactor = const MetricNum.infinity();
  } else {
    profitFactor = MetricNum.finite(grossProfit / grossLoss.abs());
  }

  MetricNum payoffRatio;
  if (nw == 0 || nl == 0) {
    payoffRatio = nw > 0 && nl == 0
        ? const MetricNum.infinity()
        : const MetricNum.unavailable();
  } else {
    payoffRatio = MetricNum.finite(
      (grossProfit / nw) / (grossLoss.abs() / nl),
    );
  }

  final expectancy = n == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(pnls.fold(0.0, (a, b) => a + b) / n);

  var maxConW = 0;
  var maxConL = 0;
  var curW = 0;
  var curL = 0;
  for (final p in pnls) {
    if (p > 0) {
      curW++;
      curL = 0;
      if (curW > maxConW) maxConW = curW;
    } else if (p < 0) {
      curL++;
      curW = 0;
      if (curL > maxConL) maxConL = curL;
    } else {
      curW = 0;
      curL = 0;
    }
  }

  final largestWin = wins.isEmpty
      ? const MetricNum.unavailable()
      : MetricNum.finite(wins.reduce((a, b) => a > b ? a : b));
  final largestLoss = losses.isEmpty
      ? const MetricNum.unavailable()
      : MetricNum.finite(losses.reduce((a, b) => a < b ? a : b));

  final dd = _maxDrawdown(equityCurve);

  return BacktestMetrics(
    initialCapital: initialCapital,
    finalEquity: lastEq,
    netProfit: netProfit,
    returnPct: returnPct,
    totalTrades: n,
    winningTrades: nw,
    losingTrades: nl,
    winRate: winRate,
    grossProfit: grossProfit,
    grossLoss: grossLoss,
    averageWin: averageWin,
    averageLoss: averageLoss,
    profitFactor: profitFactor,
    payoffRatio: payoffRatio,
    expectancy: expectancy,
    peakEquity: dd.peak,
    troughEquity: dd.trough,
    drawdown: dd.amount,
    drawdownPct: dd.pct,
    maxDrawdown: dd.amount,
    maxDrawdownPct: dd.pct,
    maxDrawdownStartX: dd.startX,
    maxDrawdownEndX: dd.endX,
    recoveryX: dd.recoveryX,
    maxConsecutiveWins: maxConW,
    maxConsecutiveLosses: maxConL,
    largestWin: largestWin,
    largestLoss: largestLoss,
  );
}

({
  double peak,
  double trough,
  double amount,
  double pct,
  int? startX,
  int? endX,
  int? recoveryX,
}) _maxDrawdown(List<EquityPoint> curve) {
  if (curve.isEmpty) {
    return (
      peak: 0,
      trough: 0,
      amount: 0,
      pct: 0,
      startX: null,
      endX: null,
      recoveryX: null,
    );
  }
  var peak = curve.first.equity;
  var peakX = curve.first.x;
  var globalMax = peak;
  var worst = 0.0;
  var worstPeak = peak;
  var worstTrough = peak;
  int? startX;
  int? endX;

  for (final p in curve) {
    if (p.equity > globalMax) globalMax = p.equity;
    // 等高也挪峰，回撤起点落在下跌前最后一根前高
    if (p.equity >= peak) {
      peak = p.equity;
      peakX = p.x;
    }
    final dd = peak - p.equity;
    if (dd > worst) {
      worst = dd;
      worstPeak = peak;
      worstTrough = p.equity;
      startX = peakX;
      endX = p.x;
    }
  }

  if (worst == 0) {
    return (
      peak: globalMax,
      trough: globalMax,
      amount: 0,
      pct: 0,
      startX: null,
      endX: null,
      recoveryX: null,
    );
  }

  int? recoveryX;
  for (final p in curve) {
    if (p.x <= endX!) continue;
    if (p.equity >= worstPeak) {
      recoveryX = p.x;
      break;
    }
  }

  final pct = worstPeak == 0 ? 0.0 : worst / worstPeak;
  return (
    peak: worstPeak,
    trough: worstTrough,
    amount: worst,
    pct: pct,
    startX: startX,
    endX: endX,
    recoveryX: recoveryX,
  );
}

/// 单段（样本内 / 样本外）完整绩效指标。
///
/// 分母为 0 / 无亏损 / 期末未平仓 / 样本不足 一律走 [MetricNum.unavailable()]
///（UI 显示「—」，不合成曲线、不出现 NaN）。年化按 252 交易日、无风险利率 0。
class SegmentMetrics {
  /// 已平仓笔数。
  final int trades;
  final int winning;
  final int losing;
  final int flat;

  final MetricNum winRate;
  final double grossProfit;
  final double grossLoss;
  final double netProfit;
  final MetricNum returnPct;

  final MetricNum payoffRatio;
  final MetricNum profitFactor;
  final MetricNum expectancy;
  final MetricNum averageWin;
  final MetricNum averageLoss;
  final MetricNum largestWin;
  final MetricNum largestLoss;

  final int maxConsecutiveWins;
  final int maxConsecutiveLosses;

  /// 最大回撤金额（峰−谷，≥0）。
  final double maxDrawdown;
  /// 最大回撤比例（金额/峰，≥0）。
  final double maxDrawdownPct;
  final int? maxDrawdownStartX;
  final int? maxDrawdownEndX;
  final int? recoveryX;

  /// 平均 / 中位 / 最长持仓 K 数（exitX − entryX）。
  final MetricNum avgHoldBars;
  final MetricNum medianHoldBars;
  final MetricNum maxHoldBars;
  /// 持仓时间占比 = Σ持仓K / 覆盖K数。
  final MetricNum holdTimeRatio;

  /// 年化收益率（CAGR）。
  final MetricNum annualReturn;
  /// 年化波动率。
  final MetricNum annualVol;
  final MetricNum sharpe;
  final MetricNum sortino;
  final MetricNum calmar;

  const SegmentMetrics({
    required this.trades,
    required this.winning,
    required this.losing,
    required this.flat,
    required this.winRate,
    required this.grossProfit,
    required this.grossLoss,
    required this.netProfit,
    required this.returnPct,
    required this.payoffRatio,
    required this.profitFactor,
    required this.expectancy,
    required this.averageWin,
    required this.averageLoss,
    required this.largestWin,
    required this.largestLoss,
    required this.maxConsecutiveWins,
    required this.maxConsecutiveLosses,
    required this.maxDrawdown,
    required this.maxDrawdownPct,
    required this.maxDrawdownStartX,
    required this.maxDrawdownEndX,
    required this.recoveryX,
    required this.avgHoldBars,
    required this.medianHoldBars,
    required this.maxHoldBars,
    required this.holdTimeRatio,
    required this.annualReturn,
    required this.annualVol,
    required this.sharpe,
    required this.sortino,
    required this.calmar,
  });

  static const empty = SegmentMetrics(
    trades: 0,
    winning: 0,
    losing: 0,
    flat: 0,
    winRate: MetricNum.unavailable(),
    grossProfit: 0,
    grossLoss: 0,
    netProfit: 0,
    returnPct: MetricNum.unavailable(),
    payoffRatio: MetricNum.unavailable(),
    profitFactor: MetricNum.unavailable(),
    expectancy: MetricNum.unavailable(),
    averageWin: MetricNum.unavailable(),
    averageLoss: MetricNum.unavailable(),
    largestWin: MetricNum.unavailable(),
    largestLoss: MetricNum.unavailable(),
    maxConsecutiveWins: 0,
    maxConsecutiveLosses: 0,
    maxDrawdown: 0,
    maxDrawdownPct: 0,
    maxDrawdownStartX: null,
    maxDrawdownEndX: null,
    recoveryX: null,
    avgHoldBars: MetricNum.unavailable(),
    medianHoldBars: MetricNum.unavailable(),
    maxHoldBars: MetricNum.unavailable(),
    holdTimeRatio: MetricNum.unavailable(),
    annualReturn: MetricNum.unavailable(),
    annualVol: MetricNum.unavailable(),
    sharpe: MetricNum.unavailable(),
    sortino: MetricNum.unavailable(),
    calmar: MetricNum.unavailable(),
  );
}

double _meanDouble(Iterable<double> xs) {
  final l = xs.toList();
  if (l.isEmpty) return 0;
  return l.fold(0.0, (a, b) => a + b) / l.length;
}

double _medianInt(List<int> xs) {
  if (xs.isEmpty) return 0;
  final s = [...xs]..sort();
  final n = s.length;
  return n.isOdd
      ? s[n ~/ 2].toDouble()
      : (s[n ~/ 2 - 1] + s[n ~/ 2]) / 2.0;
}

double _std(List<double> xs) {
  if (xs.length < 2) return 0;
  final m = _meanDouble(xs);
  return math.sqrt(
    xs.map((x) => (x - m) * (x - m)).fold(0.0, (a, b) => a + b) /
        (xs.length - 1),
  );
}

({
  MetricNum annualReturn,
  MetricNum annualVol,
  MetricNum sharpe,
  MetricNum sortino,
  MetricNum calmar,
}) _annualized(
  List<double> rets,
  List<EquityPoint> curve,
  double initialCapital,
  double maxDrawdownPct,
) {
  if (curve.length < 2 || rets.isEmpty || initialCapital == 0) {
    return (
      annualReturn: const MetricNum.unavailable(),
      annualVol: const MetricNum.unavailable(),
      sharpe: const MetricNum.unavailable(),
      sortino: const MetricNum.unavailable(),
      calmar: const MetricNum.unavailable(),
    );
  }
  final n = curve.length - 1;
  final ratio = curve.last.equity / initialCapital;
  if (ratio <= 0) {
    return (
      annualReturn: const MetricNum.unavailable(),
      annualVol: const MetricNum.unavailable(),
      sharpe: const MetricNum.unavailable(),
      sortino: const MetricNum.unavailable(),
      calmar: const MetricNum.unavailable(),
    );
  }
  final cagr = math.pow(ratio, 252 / n).toDouble() - 1;
  final annualReturn = MetricNum.finite(cagr);
  final sd = _std(rets);
  final annualVol = MetricNum.finite(sd * math.sqrt(252));
  final mean = _meanDouble(rets);
  final sharpe = sd == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(mean / sd * math.sqrt(252));
  final downs =
      rets.where((r) => r < 0).map((r) => r * r).toList();
  final dStd = downs.isEmpty
      ? 0.0
      : math.sqrt(downs.fold(0.0, (a, b) => a + b) / downs.length);
  final sortino = dStd == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(mean / dStd * math.sqrt(252));
  final calmar = maxDrawdownPct == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(cagr / maxDrawdownPct);
  return (
    annualReturn: annualReturn,
    annualVol: annualVol,
    sharpe: sharpe,
    sortino: sortino,
    calmar: calmar,
  );
}

/// 由真实闭合交易 + 净值曲线算单段完整指标。
///
/// [cutX] 非空时把净值曲线裁剪到 `x >= cutX` 再算（外段去掉切点前的平台期，
/// 避免污染年化波动率 / Sharpe）。持仓 K 数只来自闭合交易。
SegmentMetrics computeSegmentMetrics(
  List<TradeRecord> trades,
  List<EquityPoint> equityCurve,
  double initialCapital, {
  int? cutX,
}) {
  final curve = cutX == null
      ? equityCurve
      : equityCurve.where((p) => p.x >= cutX).toList();
  final m = computeBacktestMetrics(
    initialCapital: initialCapital,
    equityCurve: curve,
    closedTrades: trades,
  );

  final hold = trades.map((t) => t.exitX - t.entryX).toList();
  final avgHold = hold.isEmpty
      ? const MetricNum.unavailable()
      : MetricNum.finite(_meanDouble(hold.map((e) => e.toDouble())));
  final medianHold = hold.isEmpty
      ? const MetricNum.unavailable()
      : MetricNum.finite(_medianInt(hold));
  final maxHold = hold.isEmpty
      ? const MetricNum.unavailable()
      : MetricNum.finite(
          hold.fold(0, (a, b) => a > b ? a : b).toDouble(),
        );
  final holdTimeRatio = hold.isEmpty || curve.isEmpty
      ? const MetricNum.unavailable()
      : MetricNum.finite(
          hold.fold(0, (a, b) => a + b).toDouble() /
              (curve.last.x - curve.first.x + 1).toDouble(),
        );

  final rets = <double>[];
  for (var i = 1; i < curve.length; i++) {
    final prev = curve[i - 1].equity;
    if (prev != 0) rets.add(curve[i].equity / prev - 1);
  }
  final annual = _annualized(rets, curve, initialCapital, m.maxDrawdownPct);

  return SegmentMetrics(
    trades: m.totalTrades,
    winning: m.winningTrades,
    losing: m.losingTrades,
    flat: m.totalTrades - m.winningTrades - m.losingTrades,
    winRate: m.winRate,
    grossProfit: m.grossProfit,
    grossLoss: m.grossLoss,
    netProfit: m.netProfit,
    returnPct: m.returnPct,
    payoffRatio: m.payoffRatio,
    profitFactor: m.profitFactor,
    expectancy: m.expectancy,
    averageWin: m.averageWin,
    averageLoss: m.averageLoss,
    largestWin: m.largestWin,
    largestLoss: m.largestLoss,
    maxConsecutiveWins: m.maxConsecutiveWins,
    maxConsecutiveLosses: m.maxConsecutiveLosses,
    maxDrawdown: m.maxDrawdown,
    maxDrawdownPct: m.maxDrawdownPct,
    maxDrawdownStartX: m.maxDrawdownStartX,
    maxDrawdownEndX: m.maxDrawdownEndX,
    recoveryX: m.recoveryX,
    avgHoldBars: avgHold,
    medianHoldBars: medianHold,
    maxHoldBars: maxHold,
    holdTimeRatio: holdTimeRatio,
    annualReturn: annual.annualReturn,
    annualVol: annual.annualVol,
    sharpe: annual.sharpe,
    sortino: annual.sortino,
    calmar: annual.calmar,
  );
}
