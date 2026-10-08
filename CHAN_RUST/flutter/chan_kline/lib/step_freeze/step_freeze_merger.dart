import '../compute/adjacent_ratio_compute.dart';
import '../compute/bs_verdict_compute.dart';
import '../compute/class1_bs_compute.dart';
import '../compute/class2_bs_compute.dart';
import '../compute/class_n_bs_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/kn_clock_timeline.dart';
import '../compute/line_slope_compute.dart';
import '../compute/math_series_freeze_store.dart';
import '../compute/step_rhythm_compute.dart';
import '../compute/zs_signal_compute.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bs_verdict_frame.dart';
import '../models/buy1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/chart_indicator.dart';
import '../models/chip_config.dart';
import '../models/k0_line.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import '../models/sell1_frame.dart';
import '../models/sell2_frame.dart';
import '../models/sell_n_frame.dart';
import 'step_freeze_session_state.dart';

/// `_rebuildCombine` 冻结合并链（主图与机器人验证共用）。
class StepFreezeMerger {
  /// 记一步的 K1+ 采样钟快照（asOf 当时的已确认段增量 + 正在生长的那段）。
  ///
  /// 条件求值用它还原「当时那一段走到哪」，从而让动态段中途成立的 K1+ 穿越信号
  /// 在当根就能判定，而不是被最终态段划分推到段尾。详见 [KnClockTimeline]。
  static void recordKnClockStep({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required int stepIdx,
  }) {
    final u0 = level0Units(bundle.levels);
    final t = state.knClockTimeline;
    // 时间线按步长单调；重复步（回刷同一步）直接跳过，避免重复累加增量。
    if (!t.isEmpty && t.lastAsOf >= stepIdx) return;
    final seen = state.knClockSeenUnits;
    final fresh = seen < u0.unitBars.length
        ? u0.unitBars.sublist(seen)
        : const <LevelUnitBar>[];
    state.knClockSeenUnits = u0.unitBars.length;
    t.record(stepIdx, newlyConfirmed: fresh, activeUnit: u0.activeUnit);
  }

  static int? activeSegIdxForKn(KlineCombineBundle bundle, int kn) {
    if (kn <= 0) return null;
    for (final lv in bundle.levels) {
      if (lv.level == kn - 1) return lv.activeUnit?.idx;
    }
    return null;
  }

  /// 对齐 `_rebuildCombine` 在 `!skipFreezeMerge && !asofKeep` 时的合并顺序。
  static Map<int, Set<int>> mergeRebuildCombineFreeze({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required List<KlineBar> bars,
    required int stepIdx,
    required List<K0Line> k0Lines,
    required bool truncationCheck,
    MathIndicatorConfig mathConfig = const MathIndicatorConfig(),
    ChipConfig chipConfig = const ChipConfig(),
    bool copyForPaint = true,
    bool ingestChip = true,
  }) {
    mergeJudgmentHistory(
      state: state,
      bars: bars,
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      k0Lines: k0Lines,
      stepIdx: stepIdx,
      truncationCheck: truncationCheck,
      copyForPaint: copyForPaint,
    );
    mergeBsHistory(
      state: state,
      bundle: bundle,
      stepIdx: stepIdx,
      copyForPaint: copyForPaint,
    );
    final zsConfirmed = mergeZsSignalHistory(
      state: state,
      bundle: bundle,
      stepIdx: stepIdx,
      copyForPaint: copyForPaint,
    );
    recordKnClockStep(state: state, bundle: bundle, stepIdx: stepIdx);
    mergeRatioAndRhythm(
      state: state,
      bundle: bundle,
      bars: bars,
      stepIdx: stepIdx,
      truncationCheck: truncationCheck,
      copyForPaint: copyForPaint,
    );
    mergeMathFreeze(
      state: state,
      bundle: bundle,
      bars: bars,
      stepIdx: stepIdx,
      truncationCheck: truncationCheck,
      mathConfig: mathConfig,
      chipConfig: chipConfig,
      ingestChip: ingestChip,
    );
    mergeDivergenceFreeze(
      state: state,
      bundle: bundle,
      bars: bars,
      stepIdx: stepIdx,
      mathConfig: mathConfig,
      confirmedX1ByKn: zsConfirmed,
    );
    return zsConfirmed;
  }

  static void mergeJudgmentHistory({
    required StepFreezeSessionState state,
    required List<KlineBar> bars,
    required List<LevelBundle> levels,
    required List<BarCrosshairFeature> barFeatures,
    required List<K0Line> k0Lines,
    required int stepIdx,
    required bool truncationCheck,
    bool copyForPaint = true,
  }) {
    if (bars.isEmpty) return;
    final maxKnProbe = chartMaxKn(levels: levels, k0Lines: k0Lines);
    final knHi = maxKnProbe < 1 ? 1 : maxKnProbe;
    final nextHistory = copyForPaint
        ? <int, List<FractalJudgmentEvent>>{
            for (final e in state.judgmentHistoryByKn.entries)
              e.key: List<FractalJudgmentEvent>.from(e.value),
          }
        : state.judgmentHistoryByKn;
    for (var kn = 0; kn < knHi; kn++) {
      final log = nextHistory.putIfAbsent(kn, () => <FractalJudgmentEvent>[]);
      mergeFractalJudgmentEventLog(
        log,
        collectFractalJudgmentEvents(
          kn: kn,
          bars: bars,
          levels: levels,
          barFeatures: barFeatures,
          truncationCheck: truncationCheck,
        ),
      );
    }
    state.judgmentHistoryByKn = nextHistory;
  }

  static Map<int, Set<int>> mergeZsSignalHistory({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required int stepIdx,
    bool copyForPaint = true,
  }) {
    final discoveryX = stepIdx < 0 ? 0 : stepIdx;
    final nextJudge = copyForPaint
        ? <int, List<ZsSignalEvent>>{
            for (final e in state.zsJudgmentHistoryByKn.entries)
              e.key: List<ZsSignalEvent>.from(e.value),
          }
        : state.zsJudgmentHistoryByKn;
    final nextConfirm = copyForPaint
        ? <int, List<ZsSignalEvent>>{
            for (final e in state.zsConfirmHistoryByKn.entries)
              e.key: List<ZsSignalEvent>.from(e.value),
          }
        : state.zsConfirmHistoryByKn;
    final confirmedByKn = <int, Set<int>>{};
    final collected = collectZsFramesByKn(bundle);
    state.zsObjectStore.ingestCollected(collected, asOf: discoveryX);
    for (final e in collected.entries) {
      final cLog = nextConfirm.putIfAbsent(e.key, () => <ZsSignalEvent>[]);
      final confirmed = mergeZsConfirmEventLog(
        cLog,
        e.value,
        kn: e.key,
        discoveryX: discoveryX,
      );
      confirmedByKn[e.key] = confirmed;
      final jLog = nextJudge.putIfAbsent(e.key, () => <ZsSignalEvent>[]);
      mergeZsJudgmentEventLog(
        jLog,
        e.value,
        kn: e.key,
        discoveryX: discoveryX,
        confirmedX1ThisStep: confirmed,
      );
    }
    state.zsJudgmentHistoryByKn = nextJudge;
    state.zsConfirmHistoryByKn = nextConfirm;
    return confirmedByKn;
  }

  static void mergeBsHistory({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required int stepIdx,
    bool copyForPaint = true,
  }) {
    final discoveryX = stepIdx < 0 ? 0 : stepIdx;
    final nextBuy = copyForPaint
        ? <int, List<Buy1Frame>>{
            for (final e in state.buy1HistoryByKn.entries)
              e.key: List<Buy1Frame>.from(e.value),
          }
        : state.buy1HistoryByKn;
    final nextSell = copyForPaint
        ? <int, List<Sell1Frame>>{
            for (final e in state.sell1HistoryByKn.entries)
              e.key: List<Sell1Frame>.from(e.value),
          }
        : state.sell1HistoryByKn;
    final nextBuy2 = copyForPaint
        ? <int, List<Buy2Frame>>{
            for (final e in state.buy2HistoryByKn.entries)
              e.key: List<Buy2Frame>.from(e.value),
          }
        : state.buy2HistoryByKn;
    final nextSell2 = copyForPaint
        ? <int, List<Sell2Frame>>{
            for (final e in state.sell2HistoryByKn.entries)
              e.key: List<Sell2Frame>.from(e.value),
          }
        : state.sell2HistoryByKn;
    final nextBuyN = copyForPaint
        ? <int, List<BuyNFrame>>{
            for (final e in state.buyNHistoryByKn.entries)
              e.key: List<BuyNFrame>.from(e.value),
          }
        : state.buyNHistoryByKn;
    final nextSellN = copyForPaint
        ? <int, List<SellNFrame>>{
            for (final e in state.sellNHistoryByKn.entries)
              e.key: List<SellNFrame>.from(e.value),
          }
        : state.sellNHistoryByKn;
    for (final e in collectBuy1EventsByKn(bundle).entries) {
      mergeBuy1EventLog(
        nextBuy.putIfAbsent(e.key, () => <Buy1Frame>[]),
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectSell1EventsByKn(bundle).entries) {
      mergeSell1EventLog(
        nextSell.putIfAbsent(e.key, () => <Sell1Frame>[]),
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectBuy2EventsByKn(bundle).entries) {
      mergeBuy2EventLog(
        nextBuy2.putIfAbsent(e.key, () => <Buy2Frame>[]),
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectSell2EventsByKn(bundle).entries) {
      mergeSell2EventLog(
        nextSell2.putIfAbsent(e.key, () => <Sell2Frame>[]),
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectBuyNEventsByKn(bundle).entries) {
      mergeBuyNEventLog(
        nextBuyN.putIfAbsent(e.key, () => <BuyNFrame>[]),
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: activeSegIdxForKn(bundle, e.key),
      );
    }
    for (final e in collectSellNEventsByKn(bundle).entries) {
      mergeSellNEventLog(
        nextSellN.putIfAbsent(e.key, () => <SellNFrame>[]),
        e.value,
        discoveryX: discoveryX,
        activeSegIdx: activeSegIdxForKn(bundle, e.key),
      );
    }
    state.buy1HistoryByKn = nextBuy;
    state.sell1HistoryByKn = nextSell;
    state.buy2HistoryByKn = nextBuy2;
    state.sell2HistoryByKn = nextSell2;
    state.buyNHistoryByKn = nextBuyN;
    state.sellNHistoryByKn = nextSellN;

    final nextVerdict = copyForPaint
        ? <int, List<BsVerdictFrame>>{
            for (final e in state.bsVerdictHistoryByKn.entries)
              e.key: List<BsVerdictFrame>.from(e.value),
          }
        : state.bsVerdictHistoryByKn;
    for (final e in collectBsVerdictByKn(bundle).entries) {
      mergeBsVerdictLog(
        nextVerdict.putIfAbsent(e.key, () => <BsVerdictFrame>[]),
        e.value,
      );
    }
    state.bsVerdictHistoryByKn = nextVerdict;
  }

  static void mergeRatioAndRhythm({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required List<KlineBar> bars,
    required int stepIdx,
    required bool truncationCheck,
    bool copyForPaint = true,
  }) {
    final displayX = stepIdx < 0 ? 0 : stepIdx;
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    final maxDisplayKn = maxKn <= 0 ? -1 : maxKn - 1;
    if (maxDisplayKn < 0) return;
    mergeAdjacentRatioForStep(
      historyByKn: state.adjacentRatioHistoryByKn,
      levels: bundle.levels,
      displayX: displayX,
      maxDisplayKn: maxDisplayKn,
      bars: bars,
      barFeatures: bundle.barFeatures,
      truncationCheck: truncationCheck,
    );
    mergeStepRhythmForStep(
      historyByKn: state.stepRhythmHistoryByKn,
      stateByKn: state.stepRhythmStateByKn,
      levels: bundle.levels,
      displayX: displayX,
      maxDisplayKn: maxDisplayKn,
      bars: bars,
      barFeatures: bundle.barFeatures,
      truncationCheck: truncationCheck,
    );
    mergeLineSlopeForStep(
      historyByKn: state.lineSlopeHistoryByKn,
      levels: bundle.levels,
      displayX: displayX,
      maxDisplayKn: maxDisplayKn,
      bars: bars,
      barFeatures: bundle.barFeatures,
      truncationCheck: truncationCheck,
    );
    if (!copyForPaint) return;
    state.adjacentRatioHistoryByKn = {
      for (final e in state.adjacentRatioHistoryByKn.entries)
        e.key: List<AdjacentRatioPoint>.from(e.value),
    };
    state.stepRhythmHistoryByKn = {
      for (final e in state.stepRhythmHistoryByKn.entries)
        e.key: List<StepRhythmLinePoint>.from(e.value),
    };
    state.lineSlopeHistoryByKn = {
      for (final e in state.lineSlopeHistoryByKn.entries)
        e.key: List<LineSlopePoint>.from(e.value),
    };
  }

  static void mergeMathFreeze({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required List<KlineBar> bars,
    required int stepIdx,
    required bool truncationCheck,
    required MathIndicatorConfig mathConfig,
    required ChipConfig chipConfig,
    bool ingestChip = true,
    int? asOf,
  }) {
    if (bars.isEmpty) return;
    final displayX = asOf ?? (stepIdx < 0 ? 0 : stepIdx);
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    mergeMathSeriesForStep(
      store: state.mathFreezeStore,
      bars: bars,
      levels: bundle.levels,
      config: mathConfig,
      maxDisplayKn: maxKn,
      asOf: displayX,
      barFeatures: bundle.barFeatures,
      truncationCheck: truncationCheck,
    );
    if (!ingestChip) return;
    ingestAllChipPeakSchemes(
      state: state,
      asOf: displayX,
      bars: bars,
      chipConfig: chipConfig,
    );
  }

  static void ingestAllChipPeakSchemes({
    required StepFreezeSessionState state,
    required int asOf,
    required List<KlineBar> bars,
    required ChipConfig chipConfig,
  }) {
    final bucketStep = chipConfig.bucketStep;
    state.chipPeakStore.ingestThrough(
      asOf: asOf,
      bars: bars,
      bucketStep: bucketStep,
      rank: chipConfig.peakRankSpatialConfig,
    );
    state.chipPeakStore.ingestThrough(
      asOf: asOf,
      bars: bars,
      bucketStep: bucketStep,
      rank: chipConfig.peakRankVolumeConfig,
    );
    state.chipPeakStore.ingestThrough(
      asOf: asOf,
      bars: bars,
      bucketStep: bucketStep,
      rank: chipConfig.peakRankPureConfig,
    );
  }

  static void mergeDivergenceFreeze({
    required StepFreezeSessionState state,
    required KlineCombineBundle bundle,
    required List<KlineBar> bars,
    required int stepIdx,
    required MathIndicatorConfig mathConfig,
    Map<int, Set<int>> confirmedX1ByKn = const {},
    int? asOf,
  }) {
    if (bars.isEmpty) return;
    final displayX = asOf ?? (stepIdx < 0 ? 0 : stepIdx);
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    mergeDivergenceForStep(
      store: state.diverFreezeStore,
      mathStore: state.mathFreezeStore,
      bars: bars,
      levels: bundle.levels,
      zsK0Frames: bundle.zsK0Frames,
      config: mathConfig,
      maxDisplayKn: maxKn,
      asOf: displayX,
      confirmedX1ByKn: confirmedX1ByKn,
    );
    final zsByKn = collectZsFramesByKn(bundle);
    for (var kn = 0; kn <= maxKn; kn++) {
      state.diverRelationStore.ingestFromFreeze(
        displayKn: kn,
        asOf: displayX,
        freeze: state.diverFreezeStore,
        zsFrames: zsByKn[kn] ?? const [],
      );
    }
  }
}
