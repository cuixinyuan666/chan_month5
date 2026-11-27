import 'dart:convert';

import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/search_isolate.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:flutter_test/flutter_test.dart';

/// 并行分片的口径回归（真实数据 002003）。
///
/// 并行只该改变「谁在哪个线程算」，不该改变任何一个数字。
/// 本测试把同一批候选分别用 1 个和 4 个隔离区跑，要求结果逐格完全一致。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  test('并行分片结果与单线程逐格一致', () async {
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
    final cands = buildCandidates(
      pool,
      const CandidateBuildOptions.optimized(maxCandidates: 40),
    );
    expect(cands, isNotEmpty);

    final serial = await runBatchInParallel(
      env: env,
      candidates: cands,
      splitX: splitX,
      maxKn: h.maxKn,
      mode: SearchBatchMode.full,
      workers: 1,
    );
    final parallel = await runBatchInParallel(
      env: env,
      candidates: cands,
      splitX: splitX,
      maxKn: h.maxKn,
      mode: SearchBatchMode.full,
      workers: 4,
    );

    expect(parallel.length, serial.length);
    var compared = 0;
    for (var i = 0; i < serial.length; i++) {
      final a = serial[i].verdict;
      final b = parallel[i].verdict;
      expect(a == null, b == null, reason: '第 $i 条可算性不一致');
      if (a == null || b == null) continue;
      expect(b.name, a.name);
      // 用落盘 JSON 比较：所有指标字段一网打尽，避免漏比。
      expect(
        jsonEncode(b.toJson()),
        jsonEncode(a.toJson()),
        reason: '第 $i 条 ${a.name} 并行与单线程结果不一致',
      );
      compared++;
    }
    expect(compared, greaterThan(0), reason: '至少要有一条可比较的结果');
    // ignore: avoid_print
    print('[并行一致性] 候选 ${cands.length} 条，可比 $compared 条，逐格一致');
  }, timeout: const Timeout(Duration(minutes: 10)));

  test('样本内分片与完整分片的样本内结果一致', () async {
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
    final pool = VariablePool(h.maxKn);
    final cands = buildCandidates(
      pool,
      const CandidateBuildOptions.optimized(maxCandidates: 30),
    );

    final onlyIn = await runBatchInParallel(
      env: env,
      candidates: cands,
      splitX: splitX,
      maxKn: h.maxKn,
      mode: SearchBatchMode.inSampleOnly,
      workers: 2,
    );
    final full = await runBatchInParallel(
      env: env,
      candidates: cands,
      splitX: splitX,
      maxKn: h.maxKn,
      mode: SearchBatchMode.full,
      workers: 2,
    );

    for (var i = 0; i < cands.length; i++) {
      final a = onlyIn[i].inSample;
      final b = full[i].verdict?.inSample;
      expect(a == null, b == null, reason: '第 $i 条可算性不一致');
      if (a == null || b == null) continue;
      expect(a.trades, b.trades);
      expect(a.netProfit, b.netProfit);
      expect(a.winRate, b.winRate);
    }
  }, timeout: const Timeout(Duration(minutes: 10)));
}
