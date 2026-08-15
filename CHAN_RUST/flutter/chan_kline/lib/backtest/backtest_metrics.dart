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
