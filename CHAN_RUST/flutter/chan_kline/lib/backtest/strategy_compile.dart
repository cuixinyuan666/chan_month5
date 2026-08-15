import 'signal_normalize.dart';
import 'strategy_config.dart';
import 'trade_operand.dart';

/// 策略编译：每条腿必须过同层同钟门禁，失败则根本不进 CROSS。
sealed class StrategyCompileResult {
  const StrategyCompileResult();
}

final class StrategyCompileOk extends StrategyCompileResult {
  final CrossRule buyRule;
  final CrossRule sellRule;

  const StrategyCompileOk({
    required this.buyRule,
    required this.sellRule,
  });
}

final class StrategyCompileIllegal extends StrategyCompileResult {
  final String reason;
  const StrategyCompileIllegal(this.reason);
}

/// 把第一版布林穿越策略编成买/卖规则。混层在这里就会被挡住。
StrategyCompileResult compileBollCrossStrategy(
  StrategyConfig config, {
  int maxKn = 8,
}) {
  if (config.buyKn < 0 || config.sellKn < 0) {
    return const StrategyCompileIllegal('层号不能为负');
  }
  if (config.buyKn > maxKn || config.sellKn > maxKn) {
    return StrategyCompileIllegal(
      '所选层超出当前图上最大层 K$maxKn，请改选更低的层',
    );
  }
  final buy = compileBinaryOp(
    leftId: config.buyCloseId,
    rightId: config.buyBollId,
    op: TradeBinaryOp.crossBelow,
    maxKn: maxKn,
  );
  if (buy is TradeExprIllegal) {
    return StrategyCompileIllegal('买入条件：${buy.reason}');
  }
  final sell = compileBinaryOp(
    leftId: config.sellCloseId,
    rightId: config.sellBollId,
    op: TradeBinaryOp.crossAbove,
    maxKn: maxKn,
  );
  if (sell is TradeExprIllegal) {
    return StrategyCompileIllegal('卖出条件：${sell.reason}');
  }
  return StrategyCompileOk(
    buyRule: CrossRule.bollBuy(kn: config.buyKn),
    sellRule: CrossRule.bollSell(kn: config.sellKn),
  );
}
