import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/backtest/condition_ast.dart';

/// 预编译路径 vs 每次重编：对同一买卖条件，回测结果一致（不依赖任何门槛/排名）。
void expectPrecompiledMatchesRunAt({
  required SearchEnv env,
  required StrategyCompileOk compiled,
  required TradeAst buy,
  required TradeAst sell,
  required int endX,
}) {
  final a = env.runAtCompiled(compiled, buy, sell, endX);
  final b = env.runAt(buy, sell, endX);
  if (a == null || b == null) {
    expect(a, b); // 都应为 null 或都非 null
    return;
  }
  expect(a.ok, b.ok);
  final ma = a.result?.metrics;
  final mb = b.result?.metrics;
  if (ma == null || mb == null) {
    expect(ma, mb);
    return;
  }
  expect(ma.totalTrades, mb.totalTrades);
  expect(ma.netProfit, closeTo(mb.netProfit, 1e-6));
  if (ma.winRate.value != null && mb.winRate.value != null) {
    expect(ma.winRate.value!, closeTo(mb.winRate.value!, 1e-9));
  }
}
