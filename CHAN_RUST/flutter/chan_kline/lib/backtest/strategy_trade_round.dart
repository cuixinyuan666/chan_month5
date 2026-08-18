import 'backtest_result.dart';
import 'order_models.dart';
import 'signal_event.dart';

/// 策略回合：买1+卖1 为一组，买2+卖2 为一组；期末仍持仓只有买N。
class StrategyRoundIndex {
  final Map<String, int> roundBySignalId;

  const StrategyRoundIndex({this.roundBySignalId = const {}});

  static const empty = StrategyRoundIndex();

  int? roundFor(String signalId) => roundBySignalId[signalId];

  String sideLabel(SignalEvent s) {
    final side = s.side;
    if (side == null) return '-';
    return strategySideLabel(side, round: roundFor(s.signalId));
  }

  String tradeGroupLabel(TradeRecord t) {
    final round = roundFor(t.entrySignalId) ?? roundFor(t.exitSignalId);
    if (round == null) return t.tradeId;
    return '买$round→卖$round';
  }

  String tradeGroupShort(TradeRecord t) {
    final round = roundFor(t.entrySignalId) ?? roundFor(t.exitSignalId);
    if (round == null) return t.tradeId;
    return '组$round';
  }
}

StrategyRoundIndex buildStrategyRoundIndex(BacktestResult result) {
  final roundBySignal = <String, int>{};
  for (var i = 0; i < result.trades.length; i++) {
    final round = i + 1;
    final t = result.trades[i];
    roundBySignal[t.entrySignalId] = round;
    roundBySignal[t.exitSignalId] = round;
  }
  final open = result.openPosition;
  if (open != null) {
    final round = result.trades.length + 1;
    roundBySignal[open.entrySignalId] = round;
  }
  return StrategyRoundIndex(roundBySignalId: roundBySignal);
}

String strategySideLabel(TradeSide side, {int? round}) {
  if (round != null && round > 0) {
    return side == TradeSide.buy ? '买$round' : '卖$round';
  }
  return side == TradeSide.buy ? '买' : '卖';
}
