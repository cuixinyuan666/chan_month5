import 'condition_eval.dart';
import 'strategy_config.dart';

/// 策略编译：买/卖两棵 AST 都必须过同层同钟门禁，失败则根本不进求值。
sealed class StrategyCompileResult {
  const StrategyCompileResult();
}

final class StrategyCompileOk extends StrategyCompileResult {
  final CompiledCond buy;
  final CompiledCond sell;

  const StrategyCompileOk({
    required this.buy,
    required this.sell,
  });
}

final class StrategyCompileIllegal extends StrategyCompileResult {
  final String reason;
  const StrategyCompileIllegal(this.reason);
}

/// 把买/卖 AST 编成可求值树。混层在这里就会被挡住。
StrategyCompileResult compileStrategyConfig(
  StrategyConfig config, {
  int maxKn = 8,
}) {
  final buy = compileConditionAst(config.buyAst, maxKn: maxKn);
  if (buy is CondCompileIllegal) {
    return StrategyCompileIllegal('买入条件：${buy.reason}');
  }
  final sell = compileConditionAst(config.sellAst, maxKn: maxKn);
  if (sell is CondCompileIllegal) {
    return StrategyCompileIllegal('卖出条件：${sell.reason}');
  }
  return StrategyCompileOk(
    buy: (buy as CondCompileOk).root,
    sell: (sell as CondCompileOk).root,
  );
}

/// 兼容旧测试名：现在走通用 AST 编译。
StrategyCompileResult compileBollCrossStrategy(
  StrategyConfig config, {
  int maxKn = 8,
}) =>
    compileStrategyConfig(config, maxKn: maxKn);
