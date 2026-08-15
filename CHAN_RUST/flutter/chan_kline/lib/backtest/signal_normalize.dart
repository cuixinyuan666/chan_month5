import 'signal_event.dart';
import 'trade_operand.dart';

/// 一条穿越规则：哪两个变量、什么穿越、归一成买还是卖。
class CrossRule {
  final String ruleId;
  final TradeSide side;
  final String leftId;
  final String rightId;
  final TradeBinaryOp op;

  const CrossRule({
    required this.ruleId,
    required this.side,
    required this.leftId,
    required this.rightId,
    required this.op,
  });

  /// K{n} 收下穿布林下轨 → 买
  factory CrossRule.bollBuy({int kn = 0}) => CrossRule(
        ruleId: 'boll_cross_buy',
        side: TradeSide.buy,
        leftId: 'RAW.K$kn.CLOSE',
        rightId: 'MAIN.K$kn.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
      );

  /// K{n} 收上穿布林上轨 → 卖
  factory CrossRule.bollSell({int kn = 0}) => CrossRule(
        ruleId: 'boll_cross_sell',
        side: TradeSide.sell,
        leftId: 'RAW.K$kn.CLOSE',
        rightId: 'MAIN.K$kn.BOLL.UP',
        op: TradeBinaryOp.crossAbove,
      );
}

/// 把 CROSS 边沿标成 BUY/SELL，不改 discoveryX / 成交钟。
List<SignalEvent> normalizeCrossSignals({
  required List<SignalEvent> hits,
  required CrossRule rule,
}) {
  return [
    for (final e in hits)
      e.copyWith(
        ruleId: rule.ruleId,
        side: rule.side,
        source: '${rule.ruleId}|${e.source}',
      ),
  ];
}
