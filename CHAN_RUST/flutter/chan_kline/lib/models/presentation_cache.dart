import 'bar_feature_lookup.dart';
import 'chart_indicator.dart';
import 'incremental_lookup.dart';
import 'kline_bar.dart';
import 'kline_combine_bundle.dart';
import 'pipeline_delta.dart';
import '../compute/adjacent_ratio_compute.dart';
import '../compute/class1_bs_compute.dart';
import '../compute/class2_bs_compute.dart';
import '../compute/class_n_bs_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/math_series_freeze_store.dart';
import '../compute/step_rhythm_compute.dart';
import '../compute/zs_signal_compute.dart';
import 'buy1_frame.dart';
import 'buy2_frame.dart';
import 'buy_n_frame.dart';
import 'math_indicator_config.dart';
import 'sell1_frame.dart';
import 'sell2_frame.dart';
import 'sell_n_frame.dart';

/// 把一步 Delta 打进累加仓：历史 bar_features 只追加，结构字段当步全量替换。
/// 与 Rust `apply_pipeline_delta` 同构；不做字段级 patch。
KlineCombineBundle applyPipelineDelta(
  KlineCombineBundle acc,
  PipelineDelta d,
) {
  final expected = acc.barFeatures.length;
  if (d.idx != expected) {
    throw StateError(
      'delta.idx=${d.idx} 必须等于当前 bar_features.len=$expected',
    );
  }
  if (d.barFeature.idx != d.idx) {
    throw StateError(
      'bar_feature.idx=${d.barFeature.idx} 必须等于 delta.idx=${d.idx}',
    );
  }
  final s = d.structure;
  return KlineCombineBundle(
    frames: s.frames,
    k0Confirms: s.k0Confirms,
    barFeatures: [...acc.barFeatures, d.barFeature],
    k0Lines: s.k0Lines,
    k1Analysis: s.k1Analysis,
    k1Bars: s.k1Bars,
    k1CombineFrames: s.k1CombineFrames,
    defaultK0Policy: s.defaultK0Policy,
    defaultSegmentPolicies: s.defaultSegmentPolicies,
    levelSegments: s.levelSegments,
    levelVirtualUnits: s.levelVirtualUnits,
    levels: s.levels,
    zsK0Frames: s.zsK0Frames,
    buy1K0Frames: s.buy1K0Frames,
    sell1K0Frames: s.sell1K0Frames,
    buy2K0Frames: s.buy2K0Frames,
    sell2K0Frames: s.sell2K0Frames,
    buyNK0Frames: s.buyNK0Frames,
    sellNK0Frames: s.sellNK0Frames,
  );
}

/// 展示层累加仓：bundle + 增量 Lookup。
class PresentationCache {
  KlineCombineBundle _bundle = KlineCombineBundle.empty();
  final IncrementalBarFeatureLookup lookupEngine = IncrementalBarFeatureLookup();

  KlineCombineBundle get bundle => _bundle;

  BarFeatureLookup get lookup => lookupEngine.toLookup();

  bool get isEmpty => _bundle.barFeatures.isEmpty;

  int get len => _bundle.barFeatures.length;

  void reset() {
    _bundle = KlineCombineBundle.empty();
    lookupEngine.reset();
  }

  /// 首包或回退：整表 Full Snapshot（Lookup 等 syncLookup 再种，以便带上 History）。
  void seedFromFull(KlineCombineBundle full) {
    _bundle = full;
  }

  void mergeDelta(PipelineDelta d) {
    _bundle = applyPipelineDelta(_bundle, d);
  }

  /// 与当前 [bundle] 对齐增量 Lookup。步退/复位后 engine 已空 → 逐步 replay。
  void syncLookup({
    required List<KlineBar> bars,
    Map<int, List<Buy1Frame>> buy1HistoryByKn = const {},
    Map<int, List<Sell1Frame>> sell1HistoryByKn = const {},
    Map<int, List<Buy2Frame>> buy2HistoryByKn = const {},
    Map<int, List<Sell2Frame>> sell2HistoryByKn = const {},
    Map<int, List<BuyNFrame>> buyNHistoryByKn = const {},
    Map<int, List<SellNFrame>> sellNHistoryByKn = const {},
    Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn = const {},
    Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn = const {},
    Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn = const {},
    Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn = const {},
    Map<int, List<ZsSignalEvent>> zsJudgmentHistoryByKn = const {},
    Map<int, List<ZsSignalEvent>> zsConfirmHistoryByKn = const {},
    Set<SubChartIndicator> subIndicators = const {},
    bool truncationCheck = true,
    MathIndicatorConfig mathIndicatorConfig = const MathIndicatorConfig(),
    MathSeriesFreezeStore? mathFreezeStore,
    DivergenceFreezeStore? diverFreezeStore,
    int maxBsClass = 9,
  }) {
    if (bars.isEmpty) {
      lookupEngine.reset();
      return;
    }
    final last = bars.last.idx;
    if (lookupEngine.isEmpty ||
        lookupEngine.step > last ||
        lookupEngine.step < last - 1) {
      // 首包 / 复位 replay / 跳步：一次 Full 种仓（非逐步热路径）
      lookupEngine.seedFromFull(
        bars: bars,
        bundle: _bundle,
        buy1HistoryByKn: buy1HistoryByKn,
        sell1HistoryByKn: sell1HistoryByKn,
        buy2HistoryByKn: buy2HistoryByKn,
        sell2HistoryByKn: sell2HistoryByKn,
        buyNHistoryByKn: buyNHistoryByKn,
        sellNHistoryByKn: sellNHistoryByKn,
        adjacentRatioHistoryByKn: adjacentRatioHistoryByKn,
        stepRhythmHistoryByKn: stepRhythmHistoryByKn,
        lineSlopeHistoryByKn: lineSlopeHistoryByKn,
        judgmentHistoryByKn: judgmentHistoryByKn,
        zsJudgmentHistoryByKn: zsJudgmentHistoryByKn,
        zsConfirmHistoryByKn: zsConfirmHistoryByKn,
        subIndicators: subIndicators,
        truncationCheck: truncationCheck,
        mathIndicatorConfig: mathIndicatorConfig,
        mathFreezeStore: mathFreezeStore,
        diverFreezeStore: diverFreezeStore,
        maxBsClass: maxBsClass,
      );
      return;
    }
    if (lookupEngine.step == last) return;
    lookupEngine.applyStep(
      bars: bars,
      bundle: _bundle,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
      buy2HistoryByKn: buy2HistoryByKn,
      sell2HistoryByKn: sell2HistoryByKn,
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
      adjacentRatioHistoryByKn: adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: lineSlopeHistoryByKn,
      judgmentHistoryByKn: judgmentHistoryByKn,
      zsJudgmentHistoryByKn: zsJudgmentHistoryByKn,
      zsConfirmHistoryByKn: zsConfirmHistoryByKn,
      subIndicators: subIndicators,
      truncationCheck: truncationCheck,
      mathIndicatorConfig: mathIndicatorConfig,
      mathFreezeStore: mathFreezeStore,
      diverFreezeStore: diverFreezeStore,
      maxBsClass: maxBsClass,
    );
  }
}
