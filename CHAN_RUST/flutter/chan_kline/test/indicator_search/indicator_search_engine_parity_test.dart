import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 寻优 [SearchEnv.runAt] 与策略回测工作台同一引擎 [executeStrategyBacktest] 一致。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('SearchEnv 与 executeStrategyBacktest 指标一致', () async {
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
    final cands = buildCandidates(
      VariablePool(h.maxKn),
      const CandidateBuildOptions.legacyFull(),
    );
    final endX = env.outSampleEndX;

    var n = 0;
    for (final c in cands) {
      if (n >= 80) break;
      final cfg = StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst);
      final viaEnv = env.runAt(c.buyAst, c.sellAst, endX);
      final viaBt = executeStrategyBacktest(
        config: cfg,
        scope: BacktestDataScope(
          code: code,
          period: period,
          barCount: endX + 1,
          asOfX: endX,
          beginText: begin,
          endText: end,
        ),
        bars: bars,
        levels: h.levels,
        mathFreeze: h.mathFreeze,
        chanEvents: h.chanEvents,
        zsObjects: h.zsObjects,
        diverRelations: h.diverRelations,
        lineSeries: h.lineSeries,
        chipPeaks: h.chipPeaks,
        bucketStep: 0.1,
        bollN: h.mathConfig.bollN,
        donchianN: h.mathConfig.donchianN,
        regressK: h.mathConfig.regressK,
        maxKn: h.maxKn,
        barFeatures: h.barFeatures,
        mathConfig: h.mathConfig,
      );
      if (!viaBt.ok) {
        expect(viaEnv, isNull);
        continue;
      }
      expect(viaEnv, isNotNull);
      final m = viaBt.result!.metrics;
      final em = viaEnv!.result!.metrics;
      expect(em.totalTrades, m.totalTrades);
      expect(em.netProfit, closeTo(m.netProfit, 1e-6));
      if (m.winRate.value != null) {
        expect(em.winRate.value!, closeTo(m.winRate.value!, 1e-9));
      }
      n++;
    }
    expect(n, greaterThan(20));
  }, timeout: const Timeout(Duration(minutes: 6)));
}
