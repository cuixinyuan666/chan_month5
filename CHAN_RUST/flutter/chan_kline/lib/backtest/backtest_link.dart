import 'backtest_result.dart';
import 'order_models.dart';
import 'signal_event.dart';

/// 信号 → 订单 → 成交 → 交易 的索引。只查已有结果，不重算。
class BacktestLinkIndex {
  final BacktestResult result;
  final Map<String, SignalEvent> _sig;
  final Map<String, Order> _ordBySig;
  final Map<String, Fill> _fillBySig;
  final Map<String, TradeRecord> _tradeByEntry;
  final Map<String, TradeRecord> _tradeByExit;

  BacktestLinkIndex(this.result)
      : _sig = {for (final s in result.signals) s.signalId: s},
        _ordBySig = {for (final o in result.orders) o.signalId: o},
        _fillBySig = {for (final f in result.fills) f.signalId: f},
        _tradeByEntry = {
          for (final t in result.trades) t.entrySignalId: t,
        },
        _tradeByExit = {
          for (final t in result.trades) t.exitSignalId: t,
        };

  SignalEvent? signalById(String id) => _sig[id];

  Order? orderForSignal(String signalId) => _ordBySig[signalId];

  Fill? fillForSignal(String signalId) => _fillBySig[signalId];

  /// 该信号作为入场或出场时对应的闭合交易。
  TradeRecord? tradeForSignal(String signalId) =>
      _tradeByEntry[signalId] ?? _tradeByExit[signalId];

  SignalEvent? entrySignalOf(TradeRecord t) => _sig[t.entrySignalId];

  SignalEvent? exitSignalOf(TradeRecord t) => _sig[t.exitSignalId];

  List<String> highlightIdsForTrade(TradeRecord t) => [
        t.entrySignalId,
        t.exitSignalId,
      ];
}
