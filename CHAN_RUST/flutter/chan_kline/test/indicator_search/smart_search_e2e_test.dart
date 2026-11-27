import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/search_ranking.dart';
import 'package:chan_kline/indicator_search/search_scoring.dart';
import 'package:chan_kline/indicator_search/smart_search.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 智能寻优的端到端对比（真实数据 002003）。
///
/// 同一批真实 K 线上，旧口径「全量列出、不排名」与新口径「粗筛 + 组合 + 样本外排名」
/// 各跑一遍，比一件事：**排名靠前的那几条，在样本外是否真的更稳**。
///
/// 判据不看绝对收益（样本太小，绝对数字无意义），只看：
/// - 新方法第一名必须是稳健的（样本外笔数够、净利为正、盈利因子不低于 1）；
/// - 新方法前 5 名里稳健的占比，不低于旧方法按同样规则筛出的占比；
/// - 新方法确实产出了「并且」组合，而不只是原候选换了个顺序。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  /// 一条结果是否稳健：样本外笔数够、净利为正、盈利因子不低于 1。
  bool robust(ComboVerdict v) {
    final o = v.outSample;
    if (o.trades < kMinTradesForScore) return false;
    if (o.netProfit <= 0) return false;
    if (o.profitFactor.isFinite && o.profitFactor.value! < 1) return false;
    return true;
  }

  test('真实数据：新方法前几名在样本外比旧全量更稳', () async {
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
    final env = SearchEnv(bars, h, code, period, begin, end);
    final splitX = splitBarIdx(bars);
    final pool = VariablePool(h.maxKn);
    final runner = IndicatorSearchRunner();

    // 旧口径：优化枚举全量列出，不排名（候选顺序即生成顺序）。
    final oldCands = buildCandidates(
      pool,
      const CandidateBuildOptions.optimized(maxCandidates: 2000),
    );
    final oldWatch = Stopwatch()..start();
    final oldVerdicts = <ComboVerdict>[];
    for (final c in oldCands) {
      final v = runner.evaluateCandidate(
        c: c,
        env: env,
        splitX: splitX,
        maxKn: h.maxKn,
      );
      if (v != null) oldVerdicts.add(v);
    }
    oldWatch.stop();

    // 新口径：粗筛 + 组合搜索 + 样本外排名。
    final newWatch = Stopwatch()..start();
    final outcome = await runSmartSearch(
      runner: runner,
      env: env,
      cands: oldCands,
      splitX: splitX,
      maxKn: h.maxKn,
    );
    newWatch.stop();

    // 旧口径按「同样的稳健规则」排序后取前 5，作为对照。
    final oldRanked = rankVerdicts(oldVerdicts);
    final oldTop5 = oldRanked.take(5).toList();
    final newTop5 = outcome.ranked.take(5).toList();

    int robustCount(Iterable<ComboVerdict> xs) =>
        xs.where(robust).length;

    // ignore: avoid_print
    print(
      '[智能寻优对比] 旧全量 ${oldVerdicts.length} 条，'
      '旧前5稳健 ${robustCount(oldTop5.map((r) => r.verdict))}；'
      '新粗筛 ${outcome.beforeScreen}→${outcome.afterScreen}，'
      '组合 ${outcome.combosBuilt}，排名 ${outcome.ranked.length}，'
      '新前5稳健 ${robustCount(newTop5)}',
    );
    // ignore: avoid_print
    print(
      '[耗时] 旧全量 ${oldWatch.elapsedMilliseconds}ms · '
      '新智能 ${newWatch.elapsedMilliseconds}ms · '
      '变化 ${((newWatch.elapsedMilliseconds - oldWatch.elapsedMilliseconds) * 100 / oldWatch.elapsedMilliseconds).toStringAsFixed(0)}%',
    );
    for (final v in newTop5) {
      // ignore: avoid_print
      print(
        '[新前5] ${v.name} 稳健分=${v.rankScore?.toStringAsFixed(3)} '
        '样本外 ${v.outSample.trades}笔 净利${v.outSample.netProfit.toStringAsFixed(0)}',
      );
    }

    // 1) 新方法确实产出结果。
    expect(outcome.ranked, isNotEmpty);
    // 2) 新方法第一名必须稳健（如果整批候选里存在稳健组合）。
    final anyRobust = outcome.ranked.any(robust);
    if (anyRobust) {
      expect(robust(outcome.ranked.first), isTrue,
          reason: '存在稳健组合时，排名第一必须是稳健的');
    }
    // 3) 新前 5 稳健占比不低于旧前 5。
    expect(
      robustCount(newTop5),
      greaterThanOrEqualTo(robustCount(oldTop5.map((r) => r.verdict))),
      reason: '新方法前 5 的稳健占比不应低于旧方法',
    );
    // 4) 组合搜索确实生成了「并且」组合（不是只重排原候选）。
    if (outcome.combosBuilt > 0) {
      expect(
        outcome.ranked.any((v) => v.name.startsWith('组合｜')),
        isTrue,
        reason: '生成了组合就必须出现在排名结果里',
      );
    }
  }, timeout: const Timeout(Duration(minutes: 20)));
}
