import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:flutter_test/flutter_test.dart';

void expectVerdictMatchesLegacyLoop({
  required ComboCand c,
  required SearchEnv env,
  required int splitX,
  required PassGate gate,
  required int maxKn,
  required bool skipOosEarly,
  required ComboVerdict? viaRunner,
}) {
  final comp = compileStrategyConfig(
    StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst),
    maxKn: maxKn,
  );
  if (comp is StrategyCompileIllegal) {
    expect(viaRunner, isNull);
    return;
  }
  final seg = env.runInOutFromSingleFull(
    null,
    c.buyAst,
    c.sellAst,
    splitX,
  );
  if (seg == null) {
    expect(viaRunner, isNull);
    return;
  }
  final rIn = seg.inSample;
  final rank = rankScoreOf(rIn, minTrades: gate.minTrades);
  final rOut = seg.outSample;
  final skipOos =
      skipOosEarly && (rank == 0 || !gate.okSegment(rIn));
  final ok = gate.okSegment(rIn) && !skipOos && gate.okSegment(rOut);

  expect(viaRunner, isNotNull);
  final v = viaRunner!;
  expect(v.name, c.name);
  expect(v.inRankScore, closeTo(rank, 1e-9));
  expect(v.passed, ok);
  expect(v.outSampleSkipped, skipOos);
  expect(v.inSample.trades, rIn.trades);
  expect(v.inSample.netProfit, closeTo(rIn.netProfit, 1e-6));
  expect(v.outSample.trades, rOut.trades);
  expect(v.outSample.netProfit, closeTo(rOut.netProfit, 1e-6));
  if (rIn.winRate != null) {
    expect(v.inSample.winRate, closeTo(rIn.winRate!, 1e-9));
  }
  if (rOut.winRate != null) {
    expect(v.outSample.winRate, closeTo(rOut.winRate!, 1e-9));
  }
}

void expectPrecompiledMatchesRunAt({
  required SearchEnv env,
  required StrategyCompileOk compiled,
  required TradeAst buy,
  required TradeAst sell,
  required int endX,
}) {
  final a = env.runAt(buy, sell, endX);
  final b = env.runAtCompiled(compiled, buy, sell, endX);
  if (a == null) {
    expect(b, isNull);
    return;
  }
  expect(b, isNotNull);
  expect(b!.trades, a.trades);
  expect(b.netProfit, closeTo(a.netProfit, 1e-6));
  if (a.winRate != null) {
    expect(b.winRate, closeTo(a.winRate!, 1e-9));
  }
  if (a.payoff != null && a.payoff!.isInfinite) {
    expect(b.payoff?.isInfinite, isTrue);
  } else if (a.payoff != null) {
    expect(b.payoff, closeTo(a.payoff!, 1e-9));
  }
}
