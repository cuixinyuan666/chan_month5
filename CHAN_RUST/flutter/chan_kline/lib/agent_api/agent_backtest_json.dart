/// @file lib/agent_api/agent_backtest_json.dart
/// @brief 回测结果的 Agent JSON 输出（纯 Dart，只做序列化，不重算任何口径）。
///
/// 口径：
/// - `metrics` = 回测台报告面板用的 `BacktestMetrics`（引擎原值，字段下划线命名）；
/// - `segment` = `computeSegmentMetrics` 单段全量指标（与寻优 verdicts 同一序列化）；
/// - `trades` 由宿主分页返回（`agentTradeJson`）。
///
/// 这里**不改变**任何指标计算：全部直接读 `executeStrategyBacktest` 的结果。
import '../backtest/backtest_metrics.dart';
import '../backtest/backtest_run.dart';
import '../backtest/equity_curve.dart';
import '../backtest/order_models.dart';
import '../backtest/strategy_config.dart';
import '../indicator_search/search_core.dart' show segmentMetricsToJson;

/// 指标三态 → JSON：有限数=数字，∞=`"inf"`，不可用=`null`。
Object? agentMetricNumJson(MetricNum m) {
  if (m.isInfinity) return 'inf';
  if (m.isFinite) return m.value;
  return null;
}

/// 单条闭合交易（与回测台「成交明细」同源字段）。
Map<String, dynamic> agentTradeJson(TradeRecord t) => {
      'trade_id': t.tradeId,
      'entry_signal_id': t.entrySignalId,
      'exit_signal_id': t.exitSignalId,
      'entry_x': t.entryX,
      'exit_x': t.exitX,
      'entry_price': t.entryPrice,
      'exit_price': t.exitPrice,
      'quantity': t.quantity,
      'gross_pnl': t.grossPnL,
      'commission': t.commission,
      'slippage': t.slippage,
      'net_pnl': t.netPnL,
    };

/// 未平仓（没有则 null）。
Map<String, dynamic>? agentOpenPositionJson(OpenPosition? p) {
  if (p == null) return null;
  return {
    'entry_signal_id': p.entrySignalId,
    'entry_x': p.entryX,
    'avg_cost': p.avgCost,
    'quantity': p.quantity,
    'market_value': p.marketValue,
    'unrealized_pnl': p.unrealizedPnL,
  };
}

/// 回测台报告面板的指标（`BacktestMetrics` 全字段）。
Map<String, dynamic> agentBacktestMetricsJson(BacktestMetrics m) => {
      'initial_capital': m.initialCapital,
      'final_equity': m.finalEquity,
      'net_profit': m.netProfit,
      'return_pct': agentMetricNumJson(m.returnPct),
      'total_trades': m.totalTrades,
      'winning_trades': m.winningTrades,
      'losing_trades': m.losingTrades,
      'win_rate': agentMetricNumJson(m.winRate),
      'gross_profit': m.grossProfit,
      'gross_loss': m.grossLoss,
      'average_win': agentMetricNumJson(m.averageWin),
      'average_loss': agentMetricNumJson(m.averageLoss),
      'profit_factor': agentMetricNumJson(m.profitFactor),
      'payoff_ratio': agentMetricNumJson(m.payoffRatio),
      'expectancy': agentMetricNumJson(m.expectancy),
      'peak_equity': m.peakEquity,
      'trough_equity': m.troughEquity,
      'drawdown': m.drawdown,
      'drawdown_pct': m.drawdownPct,
      'max_drawdown': m.maxDrawdown,
      'max_drawdown_pct': m.maxDrawdownPct,
      'max_drawdown_start_x': m.maxDrawdownStartX,
      'max_drawdown_end_x': m.maxDrawdownEndX,
      'recovery_x': m.recoveryX,
      'max_consecutive_wins': m.maxConsecutiveWins,
      'max_consecutive_losses': m.maxConsecutiveLosses,
      'largest_win': agentMetricNumJson(m.largestWin),
      'largest_loss': agentMetricNumJson(m.largestLoss),
    };

/// 一次回测的完整摘要（不含 trades 明细，明细由宿主分页）。
///
/// 失败时 `ok:false` + `error`，与回测台的失败提示同源。
Map<String, dynamic> agentBacktestRunJson(BacktestRun run) {
  final head = {
    'run_id': run.runId,
    'engine_version': run.engineVersion,
    'started_at': run.startedAt.millisecondsSinceEpoch,
    'buy_text': run.strategyConfig.buyLabel,
    'sell_text': run.strategyConfig.sellLabel,
    'scope': agentBacktestScopeJson(run.sourceRange),
    'config': agentStrategyConfigJson(run.strategyConfig),
  };
  final r = run.result;
  if (run.error != null || r == null) {
    return {'ok': false, 'error': run.error ?? '无回测结果', ...head};
  }
  final segment = computeSegmentMetrics(
    r.trades,
    r.equityCurve,
    r.initialCapital,
  );
  return {
    'ok': true,
    ...head,
    'metrics': agentBacktestMetricsJson(r.metrics),
    'segment': segmentMetricsToJson(segment),
    'summary': {
      'signals': r.signals.length,
      'orders': r.orders.length,
      'fills': r.fills.length,
      'trades': r.trades.length,
      'equity_points': r.equityCurve.length,
    },
    'open_position': agentOpenPositionJson(r.openPosition),
  };
}

/// 数据范围（当时走到第几根，不是另算行情）。
Map<String, dynamic> agentBacktestScopeJson(BacktestDataScope s) => {
      'code': s.code,
      'period': s.period,
      'bar_count': s.barCount,
      'as_of_x': s.asOfX,
      'begin': s.beginText,
      'end': s.endText,
    };

/// 撮合/仓位参数（agent 覆盖后回显，便于对拍）。
Map<String, dynamic> agentStrategyConfigJson(StrategyConfig c) => {
      'quantity': c.quantity,
      'initial_capital': c.initialCapital,
      'commission_rate': c.commissionRate,
      'slippage_amount': c.slippageAmount,
      'fill_price_mode': c.fillPriceMode.name,
    };
