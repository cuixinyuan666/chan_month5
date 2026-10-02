import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_parity_helpers.dart';

/// 预编译回测路径 vs 每次重编：分数一致。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('runAtCompiled 与 runAt 对拍', () async {
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
    final cands =
        buildCandidates(VariablePool(h.maxKn), const CandidateBuildOptions.legacyFull());
    final splitX = bars.length ~/ 2;
    final endX = env.outSampleEndX;
    var n = 0;
    for (final c in cands) {
      if (n >= 200) break;
      final comp = compileStrategyConfig(
        StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst),
        maxKn: h.maxKn,
      );
      if (comp is! StrategyCompileOk) continue;
      n++;
      expectPrecompiledMatchesRunAt(
        env: env,
        compiled: comp,
        buy: c.buyAst,
        sell: c.sellAst,
        endX: splitX,
      );
      expectPrecompiledMatchesRunAt(
        env: env,
        compiled: comp,
        buy: c.buyAst,
        sell: c.sellAst,
        endX: endX,
      );
    }
    expect(n, greaterThan(30));
  }, timeout: const Timeout(Duration(minutes: 8)));
}
