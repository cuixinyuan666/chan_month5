import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/key_point_to_search_bridge.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优 → 寻优的真实数据端到端（002003）。
///
/// 钉死两件事：① 面板上的全样本组合能翻译成可编译的买卖条件；
/// ② 「拿去寻优」的生产路径只用切点前已确认的关键点重新拟合。
///
/// 第 ② 条用真实数据对照：全样本分界（旧口径）会把切点后的顶底均值
/// 带进条件，在样本外造出成交；切点前拟合在本数据集上的样本外成交
/// 必须少于全样本对照组（零成交不是收益判据 —— 它只说明分界没有偷看后 30%）。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('真实数据：切点前拟合的计优组合不再沿用全样本分界', () async {
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

    // 面板上的组合是全样本事后统计；「拿去寻优」走的是切点前重新拟合。
    final splitX = splitBarIdx(bars);
    final cands = bridgeCandidatesAsOf(
      bars: bars,
      levels: h.levels,
      lookup: lookup,
      settings: const KeyPointStatSettings(),
      asOf: splitX,
      code: code,
      period: period,
      beginText: begin,
      endText: end,
      maxKn: h.maxKn,
    );
    expect(cands, isNotEmpty, reason: '切点前应能拟合出可翻译的组合');

    final env = SearchEnv(bars, h, code, period, begin, end);
    final runner = IndicatorSearchRunner();
    var preIn = 0;
    var preOut = 0;
    for (final cand in cands) {
      expect(cand.name, startsWith('计优组合｜'));
      final compiled = runner.compileOk(cand, h.maxKn);
      expect(compiled, isNotNull, reason: '翻译出的候选必须能编译：${cand.name}');
      final v = runner.evaluateCandidate(
        c: cand,
        env: env,
        splitX: splitX,
        maxKn: h.maxKn,
      );
      if (v == null) continue;
      preIn += v.inSample.trades;
      if (v.outSample.trades > 0) preOut++;
    }
    expect(preIn, greaterThan(0), reason: '切点前拟合至少要有一条候选在样本内成交');

    // 对照组：全样本拟合（旧口径）会把切点后的顶底均值带进分界。
    // 旧路径在样本外有成交，正是「样本外不是真样本外」的实证。
    final fullCands = candidatesFromResult(result);
    var fullOut = 0;
    for (final cand in fullCands) {
      final compiled = runner.compileOk(cand, h.maxKn);
      if (compiled == null) continue;
      final v = runner.evaluateCandidate(
        c: cand,
        env: env,
        splitX: splitX,
        maxKn: h.maxKn,
      );
      if (v != null && v.outSample.trades > 0) fullOut++;
    }
    // 预锚动态单元取「高高」后，本数据集切点前拟合的样本外成交由 0 变为 2；
    // 关键是仍少于全样本对照组（旧口径前视污染），说明分界没有偷看后 30%。
    expect(preOut, lessThan(fullOut),
        reason: '切点前拟合的样本外成交应少于全样本拟合（旧口径前视污染）');
    expect(fullOut, greaterThan(0),
        reason: '全样本对照组应复现旧口径的样本外成交（前视污染）');
  });
}
