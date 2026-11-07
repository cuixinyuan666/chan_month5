import '../models/kline_bar.dart';
import 'account.dart';
import 'backtest_metrics.dart';
import 'equity_build.dart';
import 'equity_curve.dart';
import 'order_models.dart';
import 'rule_performance.dart';
import 'signal_event.dart';

export 'backtest_metrics.dart';
export 'equity_curve.dart';

/// 回测结果：信号/订单/成交/闭合交易 + 净值曲线 + 绩效。不做 UI。
class BacktestResult {
  final List<SignalEvent> signals;
  final List<Order> orders;
  final List<Fill> fills;
  /// 已闭合交易（未平仓不在这里）
  final List<TradeRecord> trades;
  final List<EquityPoint> equityCurve;
  final BacktestMetrics metrics;
  final OpenPosition? openPosition;
  final AccountState account;
  final double lastPrice;
  final double initialCapital;
  /// 按买卖规则归因；没有信号时为空
  final List<RulePerformance> rulePerformances;

  const BacktestResult({
    required this.signals,
    required this.orders,
    required this.fills,
    required this.trades,
    required this.equityCurve,
    required this.metrics,
    required this.openPosition,
    required this.account,
    required this.lastPrice,
    required this.initialCapital,
    this.rulePerformances = const [],
  });

  List<TradeRecord> get closedTrades => trades;
}

/// 用成交回放净值，再算绩效；账户期末仓位单独记未平仓。
///
/// [computeRulePerf] = false 时跳过「按规则归因」（`computeRulePerformance` 内部对
/// **每笔交易**扫一遍**全净值曲线**，是 O(笔数 × K 数)）。寻优对
/// `rulePerformances` **零消费**（唯一消费者是回测台报告面板），寻优路径传 false。
/// 默认 true，保证回测工作台与既有测试行为一字不变。
BacktestResult buildBacktestResult({
  required List<SignalEvent> signals,
  required List<Order> orders,
  required List<Fill> fills,
  required List<TradeRecord> trades,
  required AccountState account,
  required List<KlineBar> bars,
  required double initialCapital,
  required OpenPosition? openPosition,
  bool computeRulePerf = true,
}) {
  final curve = buildEquityCurve(
    bars: bars,
    fills: fills,
    initialCash: initialCapital,
  );
  final metrics = computeBacktestMetrics(
    initialCapital: initialCapital,
    equityCurve: curve,
    closedTrades: trades,
  );
  final lastPrice = bars.isEmpty ? 0.0 : bars.last.close;
  return BacktestResult(
    signals: signals,
    orders: orders,
    fills: fills,
    trades: trades,
    equityCurve: curve,
    metrics: metrics,
    openPosition: openPosition,
    account: account,
    lastPrice: lastPrice,
    initialCapital: initialCapital,
    rulePerformances: computeRulePerf
        ? computeRulePerformance(
            signals: signals,
            orders: orders,
            trades: trades,
            equityCurve: curve,
          )
        : const <RulePerformance>[],
  );
}
