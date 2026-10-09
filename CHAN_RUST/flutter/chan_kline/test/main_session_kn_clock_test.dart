import 'dart:io';

import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/chart_line_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/step_freeze/step_freeze_parity_driver.dart';
import 'package:flutter_test/flutter_test.dart';

/// 主图会话口径的 K1+ 采样钟回归（2026-10-09 排查后固化）。
///
/// 背景：动态段逐根在场的采样钟已落地，但**主图会话**（策略回测 / 寻优实际吃的那份冻结）
/// 从没调 `StepFreezeMerger.recordKnClockStep` —— 那一步只存在于
/// `mergeRebuildCombineFreeze`（独立 harness / 机器人验证走的那条链）。
/// 于是主图的采样钟时间线恒为空，回测 / 寻优退回「一段一个点」的最终态（冻段）口径：
/// 默认数据上「K1均线5 下穿 K1未确认中枢中轴」本该在 K0#71 出信号，被推到段尾 K0#74。
///
/// 锁死：①主图合并链产出的信号 == 独立 harness；②采样钟确实逐根在场；
/// ③去掉采样钟必须变（证明这一步不可省）；④主图两条合并链都记了。
const _code = '002003';
const _period = 'tick';
const _begin = '2004/07/19 10:47:00';
const _end = '2004/07/20 13:09:00';

TradeAst _cross(TradeBinaryOp op) => TradeCmpAst(
      left: const TradeVarRef('MAIN.K1.MA.5'),
      right: const TradeVarRef('STRUCTURE.K1.ZS.ACTIVE.CENTER'),
      op: op,
    );

/// 把「主图会话」冻结（StepFreezeSessionState）包成回测 harness。
/// [withClock]=false 时故意不交采样钟 —— 复现回归前的退回冻段口径。
BacktestStepHarnessResult _harnessFromSession(
  StepFreezeAccumulateResult acc, {
  bool withClock = true,
}) {
  final st = acc.state;
  final levels = acc.lastBundle.levels;
  final clock = st.knClockTimeline;
  return BacktestStepHarnessResult.fromMainSession(
    bars: acc.bars,
    levels: levels,
    mathFreeze: st.mathFreezeStore,
    chanEvents: ChanEventStore(
      buy1ByKn: st.buy1HistoryByKn,
      sell1ByKn: st.sell1HistoryByKn,
      buy2ByKn: st.buy2HistoryByKn,
      sell2ByKn: st.sell2HistoryByKn,
      buyNByKn: st.buyNHistoryByKn,
      sellNByKn: st.sellNHistoryByKn,
      zsConfirmByKn: st.zsConfirmHistoryByKn,
      zsJudgmentByKn: st.zsJudgmentHistoryByKn,
      fractalJudgmentByKn: st.judgmentHistoryByKn,
    ),
    zsObjects: st.zsObjectStore,
    diverRelations: st.diverRelationStore,
    lineSeries: ChartLineStore(
      adjacentRatioByKn: st.adjacentRatioHistoryByKn,
      lineSlopeByKn: st.lineSlopeHistoryByKn,
      stepRhythmByKn: st.stepRhythmHistoryByKn,
    ),
    chipPeaks: st.chipPeakStore,
    barFeatures: acc.lastBundle.barFeatures,
    maxKn: chartMaxKn(levels: levels, k0Lines: acc.lastBundle.k0Lines),
    mathConfig: const MathIndicatorConfig(),
    chipBucketStep: 0.1,
    knClock: withClock && !clock.isEmpty ? clock : null,
  );
}

List<int> _buySignalXs(BacktestStepHarnessResult h) {
  final bars = h.bars;
  final run = executeStrategyBacktest(
    config: StrategyConfig(
      buyAst: _cross(TradeBinaryOp.crossBelow),
      sellAst: _cross(TradeBinaryOp.crossAbove),
    ),
    scope: BacktestDataScope(
      code: _code,
      period: _period,
      barCount: bars.length,
      asOfX: bars.last.idx,
      beginText: _begin,
      endText: _end,
    ),
    bars: bars,
    levels: h.levels,
    mathFreeze: h.mathFreeze,
    chanEvents: h.chanEvents,
    zsObjects: h.zsObjects,
    diverRelations: h.diverRelations,
    lineSeries: h.lineSeries,
    chipPeaks: h.chipPeaks,
    maxKn: h.maxKn,
    barFeatures: h.barFeatures,
    mathConfig: h.mathConfig,
    knClock: h.knClock,
  );
  return run.result!.signals
      .where((s) => s.side?.name == 'buy')
      .map((s) => s.discoveryX)
      .toList()
    ..sort();
}

void main() {
  late List<KlineBar> bars;
  late BacktestStepHarnessResult harness;
  late BacktestStepHarnessResult mainSession;

  setUpAll(() async {
    final bridge = ChanBridge.instance;
    bridge.ensureInitialized();
    bars = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: _code,
          beginDate: _begin,
          endDate: _end,
          period: _period,
          tickSource: 'protocol',
        )
        .bars;
    harness = await driveStepHarness(bars);
    mainSession =
        _harnessFromSession(StepFreezeParityDriver().accumulateStepOnly(bars));
  });

  test('主图合并链与独立 harness 的 K1+ 信号一致', () {
    expect(_buySignalXs(mainSession), _buySignalXs(harness),
        reason: '主图会话冻结与独立 harness 必须同口径（合并链少记一步就会分叉）');
  });

  test('主图会话的采样钟逐根在场（不是一段一个点）', () {
    final ends = mainSession.knClock!.sampleEnds(null);
    expect(ends.length, greaterThan(bars.length ~/ 2),
        reason: 'K1+ 采样点应接近每根 K 一根（动态段逐根在场）');
  });

  test('去掉采样钟就退回段尾制、信号被推后（证明这一步不可省）', () {
    final withClock = _buySignalXs(mainSession);
    final without = _buySignalXs(_harnessFromSession(
      StepFreezeParityDriver().accumulateStepOnly(bars),
      withClock: false,
    ));
    expect(withClock, isNotEmpty);
    expect(without, isNotEmpty);
    expect(without, isNot(equals(withClock)),
        reason: '无采样钟 = 冻段口径，信号应与动态段口径不同（否则本测试无意义）');
  });

  test('主图两条合并链都记了采样钟（源码守卫）', () {
    final src = File('lib/main.dart').readAsStringSync();
    expect(RegExp(r'_recordKnClockStep\(bundle\)').allMatches(src).length,
        greaterThanOrEqualTo(2),
        reason: '逐根步进与一次性走完两条合并链都要记 K1+ 采样钟');
  });
}