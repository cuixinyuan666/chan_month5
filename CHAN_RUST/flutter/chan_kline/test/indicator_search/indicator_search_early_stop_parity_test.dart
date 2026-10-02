import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

import 'search_parity_helpers.dart';

/// 早停开关：与手写循环同口径（含 empty 样本外）。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';
  const gate = PassGate(minTrades: 2);

  test('skipOosEarly true/false 均对拍手写循环', () async {
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
    final splitX = splitBarIdx(bars);
    final runner = IndicatorSearchRunner();

    for (var i = 0; i < 250 && i < cands.length; i++) {
      final c = cands[i];
      for (final skip in [false, true]) {
        final v = runner.evaluateCandidate(
          c: c,
          env: env,
          splitX: splitX,
          gate: gate,
          maxKn: h.maxKn,
          skipOosEarly: skip,
        );
        expectVerdictMatchesLegacyLoop(
          c: c,
          env: env,
          splitX: splitX,
          gate: gate,
          maxKn: h.maxKn,
          skipOosEarly: skip,
          viaRunner: v,
        );
      }
    }
  }, timeout: const Timeout(Duration(minutes: 12)));
}
