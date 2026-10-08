import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/adjacent_ratio_compute.dart';
import 'package:chan_kline/compute/bs_verdict_compute.dart';
import 'package:chan_kline/models/bs_verdict_frame.dart';
import 'package:chan_kline/compute/class1_bs_compute.dart';
import 'package:chan_kline/compute/class2_bs_compute.dart';
import 'package:chan_kline/compute/class_n_bs_compute.dart';
import 'package:chan_kline/compute/divergence_freeze_store.dart';
import 'package:chan_kline/compute/kn_clock_timeline.dart';
import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/compute/line_slope_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/compute/step_rhythm_compute.dart';
import 'package:chan_kline/compute/zs_signal_compute.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/chart_line_store.dart';
import 'package:chan_kline/backtest/chip_peak_store.dart';
import 'package:chan_kline/backtest/divergence_relation_store.dart';
import 'package:chan_kline/backtest/zhongshu_object_store.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/buy2_frame.dart';
import 'package:chan_kline/models/buy_n_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/sell2_frame.dart';
import 'package:chan_kline/models/sell_n_frame.dart';

/// 与主界面步进同口径：连续单步冻结 → 供策略回测 / 指标寻优批量扫描复用。
class BacktestStepHarnessResult {
  final List<KlineBar> bars;
  final List<LevelBundle> levels;
  final MathSeriesFreezeStore mathFreeze;
  final ChanEventStore chanEvents;
  final ZhongshuObjectStore zsObjects;
  final DivergenceRelationStore diverRelations;
  final ChartLineStore lineSeries;
  final ChipPeakFreezeStore chipPeaks;
  final List<BarCrosshairFeature> barFeatures;
  final int maxKn;
  final MathIndicatorConfig mathConfig;
  final double chipBucketStep;

  /// K1+ 采样钟的 asOf 当时段划分时间线（动态段口径）；null=退回最终态口径。
  final KnClockTimeline? knClock;

  const BacktestStepHarnessResult({
    required this.bars,
    required this.levels,
    required this.mathFreeze,
    required this.chanEvents,
    required this.zsObjects,
    required this.diverRelations,
    required this.lineSeries,
    required this.chipPeaks,
    required this.barFeatures,
    required this.maxKn,
    required this.mathConfig,
    this.chipBucketStep = 0.1,
    this.knClock,
  });

  /// 主界面当前会话已步进冻结仓（与策略回测工作台同源，寻优不再 replay harness）。
  factory BacktestStepHarnessResult.fromMainSession({
    required List<KlineBar> bars,
    required List<LevelBundle> levels,
    required MathSeriesFreezeStore mathFreeze,
    required ChanEventStore chanEvents,
    required ZhongshuObjectStore zsObjects,
    required DivergenceRelationStore diverRelations,
    required ChartLineStore lineSeries,
    required ChipPeakFreezeStore chipPeaks,
    required List<BarCrosshairFeature> barFeatures,
    required int maxKn,
    required MathIndicatorConfig mathConfig,
    required double chipBucketStep,
    KnClockTimeline? knClock,
  }) {
    return BacktestStepHarnessResult(
      bars: bars,
      levels: levels,
      mathFreeze: mathFreeze,
      chanEvents: chanEvents,
      zsObjects: zsObjects,
      diverRelations: diverRelations,
      lineSeries: lineSeries,
      chipPeaks: chipPeaks,
      barFeatures: barFeatures,
      maxKn: maxKn,
      mathConfig: mathConfig,
      chipBucketStep: chipBucketStep,
      knClock: knClock,
    );
  }
}

int? _activeSegIdx(KlineCombineBundle bundle, int kn) {
  if (kn <= 0) return null;
  for (final lv in bundle.levels) {
    if (lv.level == kn - 1) return lv.activeUnit?.idx;
  }
  return null;
}

List<LevelBundle> _levelsWithFrozenBs({
  required List<LevelBundle> levels,
  required Map<int, List<Buy1Frame>> buy1,
  required Map<int, List<Sell1Frame>> sell1,
  required Map<int, List<Buy2Frame>> buy2,
  required Map<int, List<Sell2Frame>> sell2,
  required Map<int, List<BuyNFrame>> buyN,
  required Map<int, List<SellNFrame>> sellN,
  required Map<int, List<BsVerdictFrame>> verdict,
}) {
  final with1 = levelsWithFrozenClass1Bs(
    levels,
    buy1HistoryByKn: buy1,
    sell1HistoryByKn: sell1,
  );
  final with2 = levelsWithFrozenClass2Bs(
    with1,
    buy2HistoryByKn: buy2,
    sell2HistoryByKn: sell2,
  );
  final withN = levelsWithFrozenClassNBs(
    with2,
    buyNHistoryByKn: buyN,
    sellNHistoryByKn: sellN,
  );
  return levelsWithFrozenBsVerdict(withN, historyByKn: verdict);
}

/// 连续单步冻结（无进度回调）。
void _ingestChipPeakSchemes({
  required ChipPeakFreezeStore store,
  required int asOf,
  required List<KlineBar> bars,
  required ChipConfig chipConfig,
}) {
  store.ingestThrough(
    asOf: asOf,
    bars: bars,
    bucketStep: chipConfig.bucketStep,
    rank: chipConfig.peakRankSpatialConfig,
  );
  store.ingestThrough(
    asOf: asOf,
    bars: bars,
    bucketStep: chipConfig.bucketStep,
    rank: chipConfig.peakRankVolumeConfig,
  );
  store.ingestThrough(
    asOf: asOf,
    bars: bars,
    bucketStep: chipConfig.bucketStep,
    rank: chipConfig.peakRankPureConfig,
  );
}

/// 连续单步冻结（无进度回调、不交出事件循环）。
Future<BacktestStepHarnessResult> driveStepHarness(
  List<KlineBar> bars, {
  MathIndicatorConfig mathConfig = const MathIndicatorConfig(),
  ChipConfig? chipConfig,
  bool truncationCheck = true,
}) {
  return driveStepHarnessWithProgress(
    bars,
    mathConfig: mathConfig,
    chipConfig: chipConfig,
    truncationCheck: truncationCheck,
    uiYield: false,
  );
}

/// 与 [driveStepHarness] 同口径，可上报步进进度。
Future<BacktestStepHarnessResult> driveStepHarnessWithProgress(
  List<KlineBar> bars, {
  MathIndicatorConfig mathConfig = const MathIndicatorConfig(),
  ChipConfig? chipConfig,
  bool truncationCheck = true,
  void Function(int done, int total)? onProgress,
  int progressEvery = 50,
  bool uiYield = true,
}) async {
  final chipBucketStep = chipConfig?.bucketStep ?? 0.1;
  final sess = ChanPipelineSession.create(
    preferDelta: true,
    truncationCheck: truncationCheck,
  );
  final buy1 = <int, List<Buy1Frame>>{};
  final sell1 = <int, List<Sell1Frame>>{};
  final buy2 = <int, List<Buy2Frame>>{};
  final sell2 = <int, List<Sell2Frame>>{};
  final buyN = <int, List<BuyNFrame>>{};
  final sellN = <int, List<SellNFrame>>{};
  final verdict = <int, List<BsVerdictFrame>>{};
  final judgment = <int, List<FractalJudgmentEvent>>{};
  final zsJudge = <int, List<ZsSignalEvent>>{};
  final zsConfirm = <int, List<ZsSignalEvent>>{};
  final ratio = <int, List<AdjacentRatioPoint>>{};
  final slope = <int, List<LineSlopePoint>>{};
  final rhythm = <int, List<StepRhythmLinePoint>>{};
  final rhythmState = <int, StepRhythmState>{};
  final mathFreeze = MathSeriesFreezeStore();
  final diverFreeze = DivergenceFreezeStore();
  final diverRelations = DivergenceRelationStore();
  final zsObjects = ZhongshuObjectStore();
  final chipPeaks = ChipPeakFreezeStore();
  final knClockRec = KnClockTimelineRecorder();
  final growing = <KlineBar>[];
  KlineCombineBundle last = KlineCombineBundle.empty();
  final total = bars.length;

  for (var step = 0; step < total; step++) {
    growing.add(bars[step]);
    last = sess.syncTo(growing);
    // K1+ 采样钟：记下这一步「当时」的段划分（动态段口径）
    final u0 = level0Units(last.levels);
    knClockRec.record(step, u0.unitBars, u0.activeUnit);
    final maxKn = chartMaxKn(levels: last.levels, k0Lines: last.k0Lines);
    final knHi = maxKn < 1 ? 1 : maxKn;
    final maxDisplayKn = maxKn <= 0 ? -1 : maxKn - 1;

    for (var kn = 0; kn < knHi; kn++) {
      mergeFractalJudgmentEventLog(
        judgment.putIfAbsent(kn, () => <FractalJudgmentEvent>[]),
        collectFractalJudgmentEvents(
          kn: kn,
          bars: growing,
          levels: last.levels,
          barFeatures: last.barFeatures,
          truncationCheck: truncationCheck,
        ),
      );
    }

    for (final e in collectBuy1EventsByKn(last).entries) {
      mergeBuy1EventLog(
        buy1.putIfAbsent(e.key, () => <Buy1Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(last, e.key),
      );
    }
    for (final e in collectSell1EventsByKn(last).entries) {
      mergeSell1EventLog(
        sell1.putIfAbsent(e.key, () => <Sell1Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(last, e.key),
      );
    }
    for (final e in collectBuy2EventsByKn(last).entries) {
      mergeBuy2EventLog(
        buy2.putIfAbsent(e.key, () => <Buy2Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(last, e.key),
      );
    }
    for (final e in collectSell2EventsByKn(last).entries) {
      mergeSell2EventLog(
        sell2.putIfAbsent(e.key, () => <Sell2Frame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(last, e.key),
      );
    }
    for (final e in collectBuyNEventsByKn(last).entries) {
      mergeBuyNEventLog(
        buyN.putIfAbsent(e.key, () => <BuyNFrame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(last, e.key),
      );
    }
    for (final e in collectSellNEventsByKn(last).entries) {
      mergeSellNEventLog(
        sellN.putIfAbsent(e.key, () => <SellNFrame>[]),
        e.value,
        discoveryX: step,
        activeSegIdx: _activeSegIdx(last, e.key),
      );
    }
    for (final e in collectBsVerdictByKn(last).entries) {
      mergeBsVerdictLog(
        verdict.putIfAbsent(e.key, () => <BsVerdictFrame>[]),
        e.value,
      );
    }

    final zs = collectZsFramesByKn(last);
    zsObjects.ingestCollected(zs, asOf: step);
    final confirmedByKn = <int, Set<int>>{};
    for (final e in zs.entries) {
      final confirmed = mergeZsConfirmEventLog(
        zsConfirm.putIfAbsent(e.key, () => <ZsSignalEvent>[]),
        e.value,
        kn: e.key,
        discoveryX: step,
      );
      confirmedByKn[e.key] = confirmed;
      mergeZsJudgmentEventLog(
        zsJudge.putIfAbsent(e.key, () => <ZsSignalEvent>[]),
        e.value,
        kn: e.key,
        discoveryX: step,
        confirmedX1ThisStep: confirmed,
      );
    }

    if (maxDisplayKn >= 0) {
      mergeAdjacentRatioForStep(
        historyByKn: ratio,
        levels: last.levels,
        displayX: step,
        maxDisplayKn: maxDisplayKn,
        bars: growing,
        barFeatures: last.barFeatures,
        truncationCheck: truncationCheck,
      );
      mergeLineSlopeForStep(
        historyByKn: slope,
        levels: last.levels,
        displayX: step,
        maxDisplayKn: maxDisplayKn,
        bars: growing,
        barFeatures: last.barFeatures,
        truncationCheck: truncationCheck,
      );
      mergeStepRhythmForStep(
        historyByKn: rhythm,
        stateByKn: rhythmState,
        levels: last.levels,
        displayX: step,
        maxDisplayKn: maxDisplayKn,
        bars: growing,
        barFeatures: last.barFeatures,
        truncationCheck: truncationCheck,
      );
    }

    mergeMathSeriesForStep(
      store: mathFreeze,
      bars: growing,
      levels: last.levels,
      config: mathConfig,
      maxDisplayKn: maxKn,
      asOf: step,
      barFeatures: last.barFeatures,
      truncationCheck: truncationCheck,
    );
    mergeDivergenceForStep(
      store: diverFreeze,
      mathStore: mathFreeze,
      bars: growing,
      levels: last.levels,
      zsK0Frames: last.zsK0Frames,
      config: mathConfig,
      maxDisplayKn: maxKn,
      asOf: step,
      confirmedX1ByKn: confirmedByKn,
    );
    for (var kn = 0; kn <= maxKn; kn++) {
      diverRelations.ingestFromFreeze(
        displayKn: kn,
        asOf: step,
        freeze: diverFreeze,
        zsFrames: zs[kn] ?? const [],
      );
    }

    if (chipConfig != null) {
      _ingestChipPeakSchemes(
        store: chipPeaks,
        asOf: step,
        bars: growing,
        chipConfig: chipConfig,
      );
    }

    final reportProgress = onProgress != null &&
        (step == 0 || step == total - 1 || step % progressEvery == 0);
    if (reportProgress) {
      onProgress!(step + 1, total);
    }
    if (uiYield && reportProgress) {
      await Future<void>.delayed(Duration.zero);
    }
  }

  sess.dispose();
  final maxKn = chartMaxKn(levels: last.levels, k0Lines: last.k0Lines);
  final frozenLevels = _levelsWithFrozenBs(
    levels: last.levels,
    buy1: buy1,
    sell1: sell1,
    buy2: buy2,
    sell2: sell2,
    buyN: buyN,
    sellN: sellN,
    verdict: verdict,
  );

  return BacktestStepHarnessResult(
    bars: growing,
    levels: frozenLevels,
    knClock: knClockRec.timeline,
    mathFreeze: mathFreeze,
    chanEvents: ChanEventStore(
      buy1ByKn: buy1,
      sell1ByKn: sell1,
      buy2ByKn: buy2,
      sell2ByKn: sell2,
      buyNByKn: buyN,
      sellNByKn: sellN,
      zsConfirmByKn: zsConfirm,
      zsJudgmentByKn: zsJudge,
      fractalJudgmentByKn: judgment,
      k0FractalConfirms: last.k0Confirms,
    ),
    zsObjects: zsObjects,
    diverRelations: diverRelations,
    lineSeries: ChartLineStore(
      adjacentRatioByKn: ratio,
      lineSlopeByKn: slope,
      stepRhythmByKn: rhythm,
    ),
    chipPeaks: chipPeaks,
    barFeatures: last.barFeatures,
    maxKn: maxKn,
    mathConfig: mathConfig,
    chipBucketStep: chipBucketStep,
  );
}
