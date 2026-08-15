import 'backtest_metrics.dart';
import 'equity_curve.dart';
import 'order_models.dart';
import 'signal_event.dart';

/// 单条买卖规则的结果归因（Phase 13）。只解释已有回测，不做参数优化。
class RulePerformance {
  final String ruleId;
  final String label;
  final TradeSide side;
  final int signalCount;
  final int acceptedOrderCount;
  final int filledCount;
  final int tradeCount;
  final MetricNum winRate;
  final double netProfit;
  final MetricNum avgTrade;
  final MetricNum profitFactor;
  /// 该规则入场交易区间内，净值曲线最深回撤（金额）
  final double maxDrawdownContribution;

  const RulePerformance({
    required this.ruleId,
    required this.label,
    required this.side,
    required this.signalCount,
    required this.acceptedOrderCount,
    required this.filledCount,
    required this.tradeCount,
    required this.winRate,
    required this.netProfit,
    required this.avgTrade,
    required this.profitFactor,
    required this.maxDrawdownContribution,
  });
}

List<RulePerformance> computeRulePerformance({
  required List<SignalEvent> signals,
  required List<Order> orders,
  required List<TradeRecord> trades,
  required List<EquityPoint> equityCurve,
}) {
  final byRule = <String, _Acc>{};
  for (final s in signals) {
    final acc = byRule.putIfAbsent(
      s.ruleId,
      () => _Acc(
        ruleId: s.ruleId,
        side: s.side ?? TradeSide.buy,
        label: s.conditionText,
      ),
    );
    acc.signalCount++;
    if (acc.label.isEmpty) acc.label = s.conditionText;
  }
  final sigRule = <String, String>{
    for (final s in signals) s.signalId: s.ruleId,
  };
  for (final o in orders) {
    final rid = sigRule[o.signalId];
    if (rid == null) continue;
    final acc = byRule[rid];
    if (acc == null) continue;
    if (o.status == OrderStatus.filled || o.status == OrderStatus.pending) {
      acc.accepted++;
    }
    if (o.status == OrderStatus.filled) acc.filled++;
  }
  for (final t in trades) {
    final entryRule = sigRule[t.entrySignalId];
    if (entryRule != null) {
      byRule[entryRule]?.trades.add(t);
    }
    final exitRule = sigRule[t.exitSignalId];
    if (exitRule != null && exitRule != entryRule) {
      byRule[exitRule]?.exitTrades.add(t);
    }
  }

  return [
    for (final acc in byRule.values) _toPerf(acc, equityCurve),
  ];
}

class _Acc {
  final String ruleId;
  final TradeSide side;
  String label;
  int signalCount = 0;
  int accepted = 0;
  int filled = 0;
  final List<TradeRecord> trades = [];
  final List<TradeRecord> exitTrades = [];

  _Acc({required this.ruleId, required this.side, required this.label});
}

RulePerformance _toPerf(_Acc acc, List<EquityPoint> curve) {
  final closed = acc.side == TradeSide.buy ? acc.trades : acc.exitTrades;
  final use = closed.isNotEmpty ? closed : acc.trades;
  final pnls = [for (final t in use) t.netPnL];
  final n = pnls.length;
  final wins = pnls.where((p) => p > 0).toList();
  final losses = pnls.where((p) => p < 0).toList();
  final net = pnls.fold(0.0, (a, b) => a + b);
  final gp = wins.fold(0.0, (a, b) => a + b);
  final gl = losses.fold(0.0, (a, b) => a + b);
  final winRate = n == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(wins.length / n);
  final avg = n == 0
      ? const MetricNum.unavailable()
      : MetricNum.finite(net / n);
  MetricNum pf;
  if (n == 0 || (gp == 0 && gl == 0)) {
    pf = const MetricNum.unavailable();
  } else if (gl == 0 && gp > 0) {
    pf = const MetricNum.infinity();
  } else {
    pf = MetricNum.finite(gp / gl.abs());
  }
  var dd = 0.0;
  for (final t in use) {
    final slice = _ddInRange(curve, t.entryX, t.exitX);
    if (slice > dd) dd = slice;
  }
  return RulePerformance(
    ruleId: acc.ruleId,
    label: acc.label.isEmpty ? acc.ruleId : acc.label,
    side: acc.side,
    signalCount: acc.signalCount,
    acceptedOrderCount: acc.accepted,
    filledCount: acc.filled,
    tradeCount: n,
    winRate: winRate,
    netProfit: net,
    avgTrade: avg,
    profitFactor: pf,
    maxDrawdownContribution: dd,
  );
}

double _ddInRange(List<EquityPoint> curve, int fromX, int toX) {
  var peak = double.negativeInfinity;
  var worst = 0.0;
  for (final p in curve) {
    if (p.x < fromX || p.x > toX) continue;
    if (p.equity > peak) peak = p.equity;
    final d = peak - p.equity;
    if (d > worst) worst = d;
  }
  return worst.isFinite ? worst : 0;
}
