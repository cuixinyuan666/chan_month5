import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/key_point_to_search_bridge.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优 → 寻优的真实数据端到端（002003）。
///
/// 钉死整条链：真实冻结账上算出的组合区分度，能翻译成可编译的买卖条件，
/// 并且在样本外真的能成交 —— 不是只在合成数据上好看。
///
/// 判据只看链路是否成立（有组合、能翻译、能编译、样本外有成交），
/// 不把某一档收益写死：绝对数字随行情变，写死会把测试变成脆测试。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('真实数据：计优组合能翻译成寻优候选并在样本外成交', () async {
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

    final h = await driveStepHarness(bars);
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      barFeatures: h.barFeatures,
      levels: h.levels,
      mathFreezeStore: h.mathFreeze,
    );
    final collect = collectKeyPoints(
      bars: bars,
      levels: h.levels,
      asOf: bars.last.idx,
    );
    expect(collect.keyPoints, isNotEmpty, reason: '真实数据应能收集到转折点');

    final result = KeyPointStatRunner.run(
      lookup: lookup,
      collect: collect,
      settings: const KeyPointStatSettings(),
      code: code,
      period: period,
      beginText: begin,
      endText: end,
      barCount: bars.length,
      maxKn: h.maxKn,
    );
    expect(result.comboContrasts, isNotEmpty,
        reason: '真实指标账上应能算出组合区分度');

    // 组合只能来自指标账，不能混进 close/volume 这类顶层价格列。
    for (final c in result.comboContrasts) {
      for (final k in c.metricKeys) {
        expect(k, startsWith('sub.'),
            reason: '组合里混进了非指标键：$k');
      }
    }

    final midpoints = <String, double>{
      for (final c in result.contrasts)
        if (c.topMean.isFinite && c.bottomMean.isFinite)
          c.metricKey: (c.topMean + c.bottomMean) / 2,
    };
    final env = SearchEnv(bars, h, code, period, begin, end);
    final runner = IndicatorSearchRunner();
    final splitX = (bars.length * 0.7).floor();

    var translated = 0;
    var tradedOutSample = 0;
    for (final c in result.comboContrasts) {
      final cand = searchCandidateFromCombo(c, midpoints);
      if (cand == null) continue;
      translated++;
      final compiled = runner.compileOk(cand, h.maxKn);
      expect(compiled, isNotNull, reason: '翻译出的候选必须能编译：${cand.name}');
      final v = runner.evaluateCandidate(
        c: cand,
        env: env,
        splitX: splitX,
        maxKn: h.maxKn,
      );
      if (v != null && v.outSample.trades > 0) tradedOutSample++;
    }

    expect(translated, greaterThan(0), reason: '至少要有一条组合能翻译成候选');
    expect(tradedOutSample, greaterThan(0),
        reason: '至少有一条候选在样本外真的成交（否则桥接没有实战价值）');
  });
}
