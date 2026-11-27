import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('runInOutFromSingleFull 预编译与重编内外段一致', () async {
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

    var n = 0;
    for (final c in cands) {
      if (n >= 60) break;
      final comp = compileStrategyConfig(
        StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst),
        maxKn: h.maxKn,
      );
      if (comp is! StrategyCompileOk) continue;
      final a = env.runInOutFromSingleFull(null, c.buyAst, c.sellAst, splitX);
      final b = env.runInOutFromSingleFull(comp, c.buyAst, c.sellAst, splitX);
      if (a == null) {
        expect(b, isNull);
        continue;
      }
      expect(b, isNotNull);
      expect(b!.inSample.trades, a.inSample.trades);
      expect(b.outSample.trades, a.outSample.trades);
      expect(b.inSample.netProfit, closeTo(a.inSample.netProfit, 1e-6));
      expect(b.outSample.netProfit, closeTo(a.outSample.netProfit, 1e-6));
      n++;
    }
    expect(n, greaterThan(15));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
