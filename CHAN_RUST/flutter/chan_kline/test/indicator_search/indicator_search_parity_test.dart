import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_parity_helpers.dart';

void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';
  const gate = PassGate(minWinRate: 0.60, minPayoff: 1.5, minTrades: 2);
  const parityLimit = 400;

  test('寻优 Runner 与旧循环对拍（skipOosEarly=false）', () {
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
    expect(bars.length, greaterThan(100));

    final h = driveStepHarness(bars);
    final cands = buildCandidates(
      VariablePool(h.maxKn),
      const CandidateBuildOptions.legacyFull(),
    );
    final env = SearchEnv(bars, h, code, period, begin, end);
    final splitX = splitIndexOf(bars.length);
    final outEndX = env.outSampleEndX;
    final runner = IndicatorSearchRunner();

    final n = cands.length < parityLimit ? cands.length : parityLimit;
    for (var i = 0; i < n; i++) {
      final c = cands[i];
      final v = runner.evaluateCandidate(
        c: c,
        env: env,
        splitX: splitX,
        outEndX: outEndX,
        gate: gate,
        maxKn: h.maxKn,
        skipOosEarly: false,
      );
      expectVerdictMatchesLegacyLoop(
        c: c,
        env: env,
        splitX: splitX,
        outEndX: outEndX,
        gate: gate,
        maxKn: h.maxKn,
        skipOosEarly: false,
        viaRunner: v,
      );
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
