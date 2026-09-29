import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('外段闭合交易 entryX 严格大于 splitX', () async {
    final bridge = ChanBridge.instance;
    bridge.ensureInitialized();
    final bars = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: code,
          beginDate: begin,
          endDate: end,
          period: period,
          tickSource: 'protocol',
        )
        .bars;
    final h = await driveStepHarness(bars);
    final env = SearchEnv(bars, h, code, period, begin, end);
    final splitX = splitBarIdx(bars);
    final cands = buildCandidates(
      VariablePool(h.maxKn),
      const CandidateBuildOptions.legacyFull(),
    );
    final runner = IndicatorSearchRunner();
    const gate = PassGate(minTrades: 2);

    var checked = 0;
    for (final c in cands) {
      if (checked >= 120) break;
      final comp = compileStrategyConfig(
        StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst),
        maxKn: h.maxKn,
      );
      if (comp is! StrategyCompileOk) continue;
      final all = env.allClosedTradesFromFull(comp, c.buyAst, c.sellAst);
      if (all == null) continue;
      final oosTrades = outSampleClosedTradesList(all, splitX);
      final insTrades = inSampleClosedTrades(all, splitX);
      final cross = crossSplitClosedTrades(all, splitX);
      for (final t in oosTrades) {
        expect(t.entryX, greaterThan(splitX));
      }
      for (final t in insTrades) {
        expect(t.entryX, lessThanOrEqualTo(splitX));
        expect(t.exitX, lessThanOrEqualTo(splitX));
      }
      for (final t in cross) {
        expect(
          insTrades.contains(t) || oosTrades.contains(t),
          isFalse,
        );
      }
      final v = runner.evaluateCandidate(
        c: c,
        env: env,
        splitX: splitX,
        gate: gate,
        maxKn: h.maxKn,
        skipOosEarly: false,
      );
      if (v != null && v.outSample.trades > 0) {
        expect(v.outSample.trades, oosTrades.length);
      }
      checked++;
    }
    expect(checked, greaterThan(20));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
