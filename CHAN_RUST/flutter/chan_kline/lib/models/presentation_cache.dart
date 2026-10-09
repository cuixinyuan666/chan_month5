import 'bar_feature_lookup.dart';
import 'chart_indicator.dart';
import 'incremental_lookup.dart';
import 'kline_bar.dart';
import 'kline_combine_bundle.dart';
import 'bar_crosshair_feature.dart';
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
    bsVerdictK0Frames: s.bsVerdictK0Frames,
  );
}

/// 展示层累加仓：bundle + 增量 Lookup。
class PresentationCache {
  KlineCombineBundle _bundle = KlineCombineBundle.empty();
  final IncrementalBarFeatureLookup lookupEngine = IncrementalBarFeatureLookup();
  /// 可增长特征表：delta 只追加，禁止每步拷整段。
  final List<BarCrosshairFeature> _feats = [];

  /// 每步当步仓（与当时 Full asOf 同构）。十字回看用这份，禁止再打一遍无状态 Full。
  /// 只留最近 [_maxAsOfSnaps] 步，避免超长序列把所有历史结构都钉在内存里。
  final Map<int, KlineCombineBundle> _asOfByIdx = {};
  static const int _maxAsOfSnaps = 4096;

  KlineCombineBundle get bundle => _bundle;

  BarFeatureLookup get lookup => lookupEngine.toLookup();

  bool get isEmpty => _bundle.barFeatures.isEmpty;

  int get len => _bundle.barFeatures.length;

  int get asOfSnapshotCount => _asOfByIdx.length;

  void reset() {
    _bundle = KlineCombineBundle.empty();
    lookupEngine.reset();
    _asOfByIdx.clear();
    _feats.clear();
  }

  /// 十字/步退 asOf：命中当步仓则返回当时快照（末根永远用当前仓）。
  /// [withBarFeatures] 仅步退展示需要；十字只要结构，避免每根再拷前缀。
  KlineCombineBundle? snapshotAt(int asOf, {bool withBarFeatures = false}) {
    if (_bundle.barFeatures.isEmpty) return null;
    final last = _bundle.barFeatures.last.idx;
    if (asOf == last) return _bundle;
    if (asOf > last || asOf < 0) return null;
    final slim = _asOfByIdx[asOf];
    if (slim == null) return null;
    if (!withBarFeatures) return slim;
    final feats = _bundle.barFeatures;
    final n = asOf + 1;
    if (n <= feats.length && feats[n - 1].idx == asOf) {
      return slim.withBarFeatures(feats.sublist(0, n));
    }
    return slim.withBarFeatures(
      feats.where((f) => f.idx <= asOf).toList(),
    );
  }

  /// 钉当步结构（含 BS 框）；不钉逐根 bar_features，避免 1+2+…+n 把内存撑爆。
  static KlineCombineBundle _slimAsOf(KlineCombineBundle b) {
    return KlineCombineBundle(
      frames: b.frames,
      k0Confirms: b.k0Confirms,
      k0Lines: b.k0Lines,
      k1Analysis: b.k1Analysis,
      k1Bars: b.k1Bars,
      k1CombineFrames: b.k1CombineFrames,
      defaultK0Policy: b.defaultK0Policy,
      defaultSegmentPolicies: b.defaultSegmentPolicies,
      levelSegments: b.levelSegments,
      levelVirtualUnits: b.levelVirtualUnits,
      levels: b.levels,
      zsK0Frames: b.zsK0Frames,
      buy1K0Frames: b.buy1K0Frames,
      sell1K0Frames: b.sell1K0Frames,
      buy2K0Frames: b.buy2K0Frames,
      sell2K0Frames: b.sell2K0Frames,
      buyNK0Frames: b.buyNK0Frames,
      sellNK0Frames: b.sellNK0Frames,
      bsVerdictK0Frames: b.bsVerdictK0Frames,
    );
  }

  void _rememberAsOf(KlineCombineBundle b) {
    if (b.barFeatures.isEmpty) return;
    _asOfByIdx[b.barFeatures.last.idx] = _slimAsOf(b);
    if (_asOfByIdx.length <= _maxAsOfSnaps) return;
    final keys = _asOfByIdx.keys.toList()..sort();
    final drop = _asOfByIdx.length - _maxAsOfSnaps + 512;
    for (var i = 0; i < drop && i < keys.length; i++) {
      _asOfByIdx.remove(keys[i]);
    }
  }

  /// 首包或回退：整表 Full Snapshot（Lookup 等 syncLookup 再种，以便带上 History）。
  void seedFromFull(KlineCombineBundle full) {
    _feats
      ..clear()
      ..addAll(full.barFeatures);
    _bundle = full.withBarFeatures(_feats);
    _rememberAsOf(_bundle);
  }

  void mergeDelta(PipelineDelta d) {
    if (d.idx == _feats.length) {
      _feats.add(d.barFeature);
      _bundle = d.structure.withBarFeatures(_feats);
      _rememberAsOf(_bundle);
      return;
    }
    _bundle = applyPipelineDelta(_bundle, d);
    _feats
      ..clear()
      ..addAll(_bundle.barFeatures);
    _rememberAsOf(_bundle);
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
    if (lookupEngine.isEmpty || lookupEngine.step < last - 1) {
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
    // 步退：引擎仍是更长前缀，结构用 asOf 仓，禁止 Full 种仓把 UI 卡死
    if (lookupEngine.step >= last) return;
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
