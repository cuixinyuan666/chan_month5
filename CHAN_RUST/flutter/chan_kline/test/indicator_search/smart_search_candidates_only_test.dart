import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/chart_line_store.dart';
import 'package:chan_kline/backtest/chip_peak_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/divergence_relation_store.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/backtest/zhongshu_object_store.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/smart_search.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:flutter_test/flutter_test.dart';

/// 计优「拿去寻优」的候选隔离回归。
///
/// candidateOverride 只跳过枚举；智能寻优若仍做样本内粗筛和再拼组合，
/// 用户点「拿去寻优」后看到的就不是自己选的那几条。candidatesOnly 必须
/// 原样评估全部候选，不粗筛、不再拼组合。
void main() {
  test('candidatesOnly 原样评估全部候选，不粗筛、不再拼组合', () async {
    final cands = [
      ComboCand('A', _buy(), _sell()),
      ComboCand('B', _buy(), _sell()),
    ];
    final runner = _FakeRunner();

    final outcome = await runSmartSearch(
      runner: runner,
      env: _env(),
      cands: cands,
      splitX: 1,
      maxKn: 1,
      candidatesOnly: true,
    );

    expect(outcome.beforeScreen, 2);
    expect(outcome.afterScreen, 2,
        reason: 'candidatesOnly 不能像普通智能寻优那样把 0 成交候选筛掉');
    expect(outcome.combosBuilt, 0, reason: '不能再拼组合');
    expect(outcome.ranked.map((r) => r.name).toList(), ['A', 'B']);
    expect(runner.fullCalls, 2);
    expect(runner.inSampleCalls, 0, reason: '不该再跑样本内粗筛');
  });
}

TradeAst _buy() => TradeCmpAst(
      left: TradeVarRef('CLOSE'),
      right: TradeConstRef(1),
      op: TradeBinaryOp.gt,
    );

TradeAst _sell() => TradeCmpAst(
      left: TradeVarRef('CLOSE'),
      right: TradeConstRef(2),
      op: TradeBinaryOp.lt,
    );

SearchEnv _env() {
  final bars = [
    for (var i = 0; i < 2; i++)
      KlineBar(
        idx: i,
        timeMs: i * 60000,
        timeText: '2004/07/19 09:30:00',
        open: 100,
        high: 101,
        low: 99,
        close: 100,
        volume: 1000,
        amount: 2000,
      ),
  ];
  final h = BacktestStepHarnessResult(
    bars: bars,
    levels: const [],
    mathFreeze: MathSeriesFreezeStore(),
    chanEvents: const ChanEventStore(),
    zsObjects: ZhongshuObjectStore(),
    diverRelations: DivergenceRelationStore(),
    lineSeries: const ChartLineStore(),
    chipPeaks: ChipPeakFreezeStore(),
    barFeatures: const [],
    maxKn: 1,
    mathConfig: const MathIndicatorConfig(),
  );
  return SearchEnv(
    bars,
    h,
    '000001',
    '1m',
    '2004/07/19 09:30:00',
    '2004/07/19 09:31:00',
    align: const SearchWorkbenchAlign(),
  );
}

class _FakeRunner extends IndicatorSearchRunner {
  int fullCalls = 0;
  int inSampleCalls = 0;

  @override
  SegmentMetrics? evaluateInSample({
    required ComboCand c,
    required SearchEnv env,
    required int splitX,
    required int maxKn,
  }) {
    inSampleCalls++;
    return SegmentMetrics.empty;
  }

  @override
  ComboVerdict? evaluateCandidate({
    required ComboCand c,
    required SearchEnv env,
    required int splitX,
    required int maxKn,
  }) {
    fullCalls++;
    return _verdict(c, splitX);
  }

  @override
  ComboVerdict? evaluateCandidateWithRealCost({
    required ComboCand c,
    required SearchEnv env,
    required int splitX,
    required int maxKn,
  }) =>
      _verdict(c, splitX);

  ComboVerdict _verdict(ComboCand c, int splitX) => ComboVerdict(
        name: c.name,
        buyText: '买',
        sellText: '卖',
        inSample: SegmentMetrics.empty,
        outSample: SegmentMetrics.empty,
        buyAst: c.buyAst,
        sellAst: c.sellAst,
        splitX: splitX,
      );
}
