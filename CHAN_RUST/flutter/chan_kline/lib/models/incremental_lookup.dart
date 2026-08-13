import '../compute/adjacent_ratio_compute.dart';
import '../compute/class_n_bs_compute.dart';
import '../compute/demark_compute.dart';
import '../compute/divergence_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/fx_extend_line_compute.dart';
import '../compute/kn_volume_series_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/math_classic_compute.dart';
import '../compute/math_series_freeze_store.dart';
import '../compute/step_rhythm_compute.dart';
import '../compute/trend_line_compute.dart';
import '../compute/trend_model_compute.dart';
import '../ml/ml_bs_code.dart';
import 'bar_feature_lookup.dart';
import 'buy1_frame.dart';
import 'buy2_frame.dart';
import 'buy_n_frame.dart';
import 'chart_indicator.dart';
import 'k0_confirm_signal.dart';
import 'k0_line.dart';
import 'kline_bar.dart';
import 'kline_combine_bundle.dart';
import 'kline_combine_frame.dart';
import 'level_models.dart';
import 'math_indicator_config.dart';
import 'sell1_frame.dart';
import 'sell2_frame.dart';
import 'sell_n_frame.dart';
import 'zs_frame.dart';
import '../compute/zs_signal_compute.dart';

/// 增量 Lookup：只写脏区间。全量组黄金参考仍是 [BarFeatureLookup.build]。
class IncrementalBarFeatureLookup {
  final Map<int, Map<String, dynamic>> byIdx = {};
  int _step = -1;
  int totalLevels = 0;
  int maxBsClass = 9;
  int _gen = 0;

  final Set<String> _sureZs = {};
  final Map<String, ({int x1, int x2, int kn})> _unsureZs = {};
  final Set<String> _writtenHist = {};
  MathIndicatorConfig _mathCfg = const MathIndicatorConfig();
  MathSeriesFreezeStore? _mathFreeze;
  DivergenceFreezeStore? _diverFreeze;

  int get gen => _gen;
  int get step => _step;
  bool get isEmpty => byIdx.isEmpty;

  void reset() {
    byIdx.clear();
    _step = -1;
    totalLevels = 0;
    maxBsClass = 9;
    _sureZs.clear();
    _unsureZs.clear();
    _writtenHist.clear();
    _mathCfg = const MathIndicatorConfig();
    _mathFreeze = null;
    _diverFreeze = null;
    _gen++;
  }

  BarFeatureLookup toLookup({
    List<CrosshairTooltipRow> zsAfterK0 = const [],
    Map<int, List<CrosshairTooltipRow>> knZsAfterKn = const {},
  }) {
    return BarFeatureLookup.fromCached(
      byIdx: byIdx,
      totalLevels: totalLevels,
      zsAfterK0: zsAfterK0,
      knZsAfterKn: knZsAfterKn,
      maxBsClass: maxBsClass,
    );
  }

  /// 首包/回退：一次性 Full build 种仓（N=1 或 snapshot 回填）。
  void seedFromFull({
    required List<KlineBar> bars,
    required KlineCombineBundle bundle,
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
    final full = BarFeatureLookup.build(
      bars: bars,
      combineFrames: bundle.frames,
      k0Confirms: bundle.k0Confirms,
      barFeatures: bundle.barFeatures,
      k0Lines: bundle.k0Lines,
      k1Analysis: bundle.k1Analysis,
      levels: bundle.levels,
      k1CombineFrames: bundle.k1CombineFrames,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
      buy2HistoryByKn: buy2HistoryByKn,
      sell2HistoryByKn: sell2HistoryByKn,
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
      adjacentRatioHistoryByKn: adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: lineSlopeHistoryByKn,
      buy1K0Frames: bundle.buy1K0Frames,
      sell1K0Frames: bundle.sell1K0Frames,
      buy2K0Frames: bundle.buy2K0Frames,
      sell2K0Frames: bundle.sell2K0Frames,
      buyNK0Frames: bundle.buyNK0Frames,
      sellNK0Frames: bundle.sellNK0Frames,
      subIndicators: subIndicators,
      truncationCheck: truncationCheck,
      judgmentHistoryByKn: judgmentHistoryByKn,
      zsJudgmentHistoryByKn: zsJudgmentHistoryByKn,
      zsConfirmHistoryByKn: zsConfirmHistoryByKn,
      asOf: bars.isEmpty ? null : bars.last.idx,
      mathIndicatorConfig: mathIndicatorConfig,
      mathFreezeStore: mathFreezeStore,
      diverFreezeStore: diverFreezeStore,
      zsK0Frames: bundle.zsK0Frames,
      maxBsClass: maxBsClass,
    );
    byIdx
      ..clear()
      ..addAll({for (final e in full.byIdx.entries) e.key: e.value});
    _step = bars.isEmpty ? -1 : bars.last.idx;
    totalLevels = full.totalLevels;
    this.maxBsClass = full.maxBsClass;
    _sureZs.clear();
    _unsureZs.clear();
    _writtenHist.clear();
    _bindMath(
      mathIndicatorConfig: mathIndicatorConfig,
      mathFreezeStore: mathFreezeStore,
      diverFreezeStore: diverFreezeStore,
    );
    _captureZsState(bundle);
    _markWrittenHistory(
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
    );
    _gen++;
  }

  /// 只更新当步脏区间。要求 [bars.last.idx] == 上一根 + 1。
  void applyStep({
    required List<KlineBar> bars,
    required KlineCombineBundle bundle,
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
    if (bars.isEmpty) return;
    final bar = bars.last;
    final x = bar.idx;
    if (byIdx.isEmpty) {
      seedFromFull(
        bars: bars,
        bundle: bundle,
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
    if (x != _step + 1) {
      throw StateError('applyStep expected idx=${_step + 1}, got $x (reset+replay on step-back)');
    }
    final featByIdx = {for (final f in bundle.barFeatures) f.idx: f};
    final feat = featByIdx[x];
    final levelConfirmByX = <int, Map<int, LevelConfirm>>{};
    for (final lv in bundle.levels) {
      final m = <int, LevelConfirm>{};
      for (final c in lv.confirms) {
        if (c.value == 1 || c.value == -1) m[c.x] = c;
      }
      levelConfirmByX[lv.level] = m;
    }

    byIdx[x] = {
      'idx': x,
      'time_ms': bar.timeMs,
      'time_text': bar.timeText,
      'weekday': feat?.weekday ?? '-',
      'merge_inner_seq': feat?.mergeInnerSeq ?? 0,
      'merge_count': feat?.mergeCount ?? 1,
      'merge_box_seq': feat?.mergeBoxSeq ?? -1,
      'combine_fx': feat?.combineFx ?? 'UNKNOWN',
      'combine_high': feat?.combineHigh ?? bar.high,
      'combine_low': feat?.combineLow ?? bar.low,
      'k1_idx': feat?.k1Idx,
      'k1_merge_inner_seq': feat?.k1MergeInnerSeq ?? 0,
      'k1_merge_count': feat?.k1MergeCount ?? 1,
      'k1_open': feat?.k1Open ?? 0,
      'k1_high': feat?.k1High ?? 0,
      'k1_low': feat?.k1Low ?? 0,
      'k1_close': feat?.k1Close ?? 0,
      'k1_volume': feat?.k1Volume ?? 0,
      'k1_combine_high': feat?.k1CombineHigh ?? 0,
      'k1_combine_low': feat?.k1CombineLow ?? 0,
      'k1_combine_fx': feat?.k1CombineFx ?? 'UNKNOWN',
      'levels': feat?.levels ?? const <LevelSnap>[],
      'level_confirms': {
        for (final e in levelConfirmByX.entries)
          if (e.value.containsKey(x)) e.key: e.value[x]!,
      },
      'open': bar.open,
      'high': bar.high,
      'low': bar.low,
      'close': bar.close,
      'volume': bar.volume,
      'amount': bar.amount,
      if (bar.metrics.isNotEmpty) 'metrics': Map<String, dynamic>.from(bar.metrics),
      'sub': <String, dynamic>{},
    };

    final barByIdx = {for (final b in bars) b.idx: b};
    _patchLastCombine(bundle.frames, barByIdx, x);
    _patchKnCombineBoxes(bundle, x);
    _writeKnCombineRangeAtX(bundle, bars, x);
    _writeK0ConfirmAtX(bundle.k0Confirms, x, subIndicators);
    _writeK1ConfirmAtX(bundle, x);
    _writeK0LineAtX(bundle.k0Lines, x);
    _writeK1SnapshotAtX(bundle, x);
    _writeVolumeTickAll(bars, bundle);
    _writeBsAtX(
      x: x,
      buy1HistoryByKn: buy1HistoryByKn,
      sell1HistoryByKn: sell1HistoryByKn,
      buy2HistoryByKn: buy2HistoryByKn,
      sell2HistoryByKn: sell2HistoryByKn,
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
      buy1K0: bundle.buy1K0Frames,
      sell1K0: bundle.sell1K0Frames,
      buy2K0: bundle.buy2K0Frames,
      sell2K0: bundle.sell2K0Frames,
      buyNK0: bundle.buyNK0Frames,
      sellNK0: bundle.sellNK0Frames,
      subIndicators: subIndicators,
    );
    _writePeakDistAll(bundle, bars);
    _writeJudgmentLayerInit(bundle);
    _writeJudgmentAtX(bundle, judgmentHistoryByKn, x);
    _writeZsSignalsAtX(zsJudgmentHistoryByKn, zsConfirmHistoryByKn, x);
    _writeRatioRhythmSlopeAtX(
      adjacentRatioHistoryByKn: adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: lineSlopeHistoryByKn,
      x: x,
    );
    _writeTripleQuadTrendAtX(
      bars: bars,
      bundle: bundle,
      x: x,
    );
    _writeMathAll(
      bars: bars,
      bundle: bundle,
      asOf: x,
      mathIndicatorConfig: mathIndicatorConfig,
      mathFreezeStore: mathFreezeStore,
      diverFreezeStore: diverFreezeStore,
    );
    _writeZsDirty(bundle, x);

    totalLevels = bundle.levels.length;
    var bsClassHi = maxBsClass < 3 ? 3 : maxBsClass;
    final observed = maxBuyNClassObserved(
      buyNHistoryByKn: buyNHistoryByKn,
      sellNHistoryByKn: sellNHistoryByKn,
    );
    if (observed > bsClassHi) bsClassHi = observed;
    if (bsClassHi < 9) bsClassHi = 9;
    this.maxBsClass = bsClassHi;
    _bindMath(
      mathIndicatorConfig: mathIndicatorConfig,
      mathFreezeStore: mathFreezeStore,
      diverFreezeStore: diverFreezeStore,
    );
    _step = x;
    _gen++;
  }

  /// asOf 视图：冻结格只读 x<=asOf；结构用 asOf bundle 覆盖；三型只算 asOf 柱。
  BarFeatureLookup asOfView({
    required int asOf,
    required KlineCombineBundle asOfBundle,
    required List<KlineBar> prefixBars,
    List<CrosshairTooltipRow> zsAfterK0 = const [],
    Map<int, List<CrosshairTooltipRow>> knZsAfterKn = const {},
  }) {
    final view = <int, Map<String, dynamic>>{};
    for (final e in byIdx.entries) {
      if (e.key > asOf) continue;
      final row = Map<String, dynamic>.from(e.value);
      final sub = e.value['sub'];
      if (sub is Map) {
        row['sub'] = Map<String, dynamic>.from(sub);
      }
      view[e.key] = row;
    }
    final barByIdx = {for (final b in prefixBars) b.idx: b};
    for (final f in asOfBundle.frames) {
      var rangeHigh = double.negativeInfinity;
      var rangeLow = double.infinity;
      for (var xi = f.x1; xi <= f.x2; xi++) {
        if (xi > asOf) continue;
        final b = barByIdx[xi];
        if (b != null) {
          if (b.high > rangeHigh) rangeHigh = b.high;
          if (b.low < rangeLow) rangeLow = b.low;
        }
        final row = view.putIfAbsent(xi, () => {'idx': xi, 'sub': <String, dynamic>{}});
        row['combine'] = {
          'x1': f.x1,
          'x2': f.x2,
          'high': f.high,
          'low': f.low,
          'fx': f.fx,
          'count': f.count,
          'in_merge': f.count > 1,
        };
        if (rangeHigh.isFinite && rangeLow.isFinite) {
          row['combine_range_high'] = rangeHigh;
          row['combine_range_low'] = rangeLow;
        }
      }
    }
    for (final lv in asOfBundle.levels) {
      if (lv.level < 1) continue;
      for (final f in lv.combineFrames) {
        for (var xi = f.x1; xi <= f.x2; xi++) {
          if (xi > asOf) continue;
          final row = view.putIfAbsent(xi, () => {'idx': xi, 'sub': <String, dynamic>{}});
          row['combine_box_${lv.level}'] = {'high': f.high, 'low': f.low};
        }
      }
    }
    for (final f in asOfBundle.k1CombineFrames) {
      for (var xi = f.x1; xi <= f.x2; xi++) {
        if (xi > asOf) continue;
        final row = view.putIfAbsent(xi, () => {'idx': xi, 'sub': <String, dynamic>{}});
        row['combine_box_1'] = {'high': f.high, 'low': f.low};
      }
    }
    void paintZs(ZSFrame f, int kn) {
      for (var xi = f.x1; xi <= f.x2; xi++) {
        if (xi > asOf) continue;
        final row = view[xi];
        if (row == null) continue;
        final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
            as Map<String, dynamic>;
        sub['zs_high_$kn'] = f.high;
        sub['zs_low_$kn'] = f.low;
        sub['zs_sure_$kn'] = f.isSure ? 1 : 0;
        sub['zs_seq_$kn'] = f.seq;
      }
    }

    for (final f in asOfBundle.zsK0Frames) {
      paintZs(f, 0);
    }
    for (final lv in asOfBundle.levels) {
      for (final f in lv.zsFrames) {
        final kn = f.level >= 0 ? f.level : (lv.level + 1);
        paintZs(f, kn);
      }
    }
    _writeTripleQuadTrendInto(
      byIdx: view,
      bars: prefixBars,
      bundle: asOfBundle,
      x: asOf,
    );
    // asOf 当前柱 Math 按短前缀重算（对齐 Full asOf）；禁止全表三型。
    _writeMathAll(
      bars: prefixBars,
      bundle: asOfBundle,
      asOf: asOf,
      mathIndicatorConfig: _mathCfg,
      mathFreezeStore: _mathFreeze,
      diverFreezeStore: _diverFreeze,
      into: view,
    );
    return BarFeatureLookup.fromCached(
      byIdx: view,
      totalLevels: asOfBundle.levels.length,
      zsAfterK0: zsAfterK0,
      knZsAfterKn: knZsAfterKn,
      maxBsClass: maxBsClass,
    );
  }

  Map<String, dynamic> _sub(int x) {
    final row = byIdx.putIfAbsent(x, () => {'idx': x});
    return row.putIfAbsent('sub', () => <String, dynamic>{}) as Map<String, dynamic>;
  }

  void _patchLastCombine(
    List<KlineCombineFrame> frames,
    Map<int, KlineBar> barByIdx,
    int x,
  ) {
    if (frames.isEmpty) return;
    final f = frames.last;
    var rangeHigh = double.negativeInfinity;
    var rangeLow = double.infinity;
    for (var xi = f.x1; xi <= f.x2 && xi <= x; xi++) {
      final b = barByIdx[xi];
      if (b != null) {
        if (b.high > rangeHigh) rangeHigh = b.high;
        if (b.low < rangeLow) rangeLow = b.low;
      }
      final row = byIdx.putIfAbsent(xi, () => {'idx': xi, 'sub': <String, dynamic>{}});
      row['combine'] = {
        'x1': f.x1,
        'x2': f.x2,
        'high': f.high,
        'low': f.low,
        'fx': f.fx,
        'count': f.count,
        'in_merge': f.count > 1,
      };
      if (xi == x && rangeHigh.isFinite && rangeLow.isFinite) {
        row['combine_range_high'] = rangeHigh;
        row['combine_range_low'] = rangeLow;
      }
    }
  }

  void _patchKnCombineBoxes(KlineCombineBundle bundle, int x) {
    for (final lv in bundle.levels) {
      if (lv.level < 1 || lv.combineFrames.isEmpty) continue;
      final f = lv.combineFrames.last;
      for (var xi = f.x1; xi <= f.x2 && xi <= x; xi++) {
        final row = byIdx.putIfAbsent(xi, () => {'idx': xi, 'sub': <String, dynamic>{}});
        row['combine_box_${lv.level}'] = {'high': f.high, 'low': f.low};
      }
    }
    if (bundle.k1CombineFrames.isNotEmpty) {
      final f = bundle.k1CombineFrames.last;
      for (var xi = f.x1; xi <= f.x2 && xi <= x; xi++) {
        final row = byIdx.putIfAbsent(xi, () => {'idx': xi, 'sub': <String, dynamic>{}});
        row['combine_box_1'] = {'high': f.high, 'low': f.low};
      }
    }
  }

  void _writeKnCombineRangeAtX(
    KlineCombineBundle bundle,
    List<KlineBar> bars,
    int x,
  ) {
    final row = byIdx[x];
    if (row == null) return;
    for (final lv in bundle.levels) {
      final displayKn = lv.level + 1;
      final snaps = row['levels'];
      LevelSnap? snap;
      if (snaps is List<LevelSnap>) {
        for (final s in snaps) {
          if (s.level == lv.level) {
            snap = s;
            break;
          }
        }
      }
      if (snap == null || snap.unitIdx == null || snap.combineX1 < 0) continue;
      var rangeHigh = snap.unitHigh;
      var rangeLow = snap.unitLow;
      final prev = x > 0 ? byIdx[x - 1] : null;
      if (prev != null) {
        final ps = prev['levels'];
        LevelSnap? pSnap;
        if (ps is List<LevelSnap>) {
          for (final s in ps) {
            if (s.level == lv.level) {
              pSnap = s;
              break;
            }
          }
        }
        if (pSnap != null && pSnap.combineX1 == snap.combineX1) {
          final ph = prev['combine_range_high_$displayKn'];
          final pl = prev['combine_range_low_$displayKn'];
          if (ph is num) rangeHigh = rangeHigh > ph.toDouble() ? rangeHigh : ph.toDouble();
          if (pl is num) rangeLow = rangeLow < pl.toDouble() ? rangeLow : pl.toDouble();
        }
      }
      row['combine_range_high_$displayKn'] = rangeHigh;
      row['combine_range_low_$displayKn'] = rangeLow;
    }
  }

  void _writeK0ConfirmAtX(
    List<K0ConfirmSignal> confirms,
    int x,
    Set<SubChartIndicator> subIndicators,
  ) {
    for (final sig in confirms) {
      if (sig.x != x) continue;
      final row = byIdx.putIfAbsent(x, () => {'idx': x, 'sub': <String, dynamic>{}});
      row['k0_confirm'] = {
        'x': sig.x,
        'fx': sig.fx,
        'value': sig.value,
        'fractal_x1': sig.fractalX1,
        'fractal_x2': sig.fractalX2,
        'truncated': sig.truncated,
      };
      if (subIndicators.any((e) =>
          e.kind == SubIndicatorKind.fractalConfirm && e.kn == 0)) {
        _sub(x)['k0_confirm_value'] = sig.value;
      }
    }
  }

  void _writeK1ConfirmAtX(KlineCombineBundle bundle, int x) {
    for (final sig in bundle.k1Analysis.k1Confirms) {
      if (sig.x != x) continue;
      if (sig.fx != 'TOP' && sig.fx != 'BOTTOM') continue;
      if (sig.value == 0) continue;
      byIdx.putIfAbsent(x, () => {'idx': x, 'sub': <String, dynamic>{}})['k1_confirm_signal'] = {
        'x': sig.x,
        'fx': sig.fx,
        'value': sig.value,
        'peak_k1_idx': sig.peakK1Idx,
        'fractal_x1': sig.fractalX1,
        'fractal_x2': sig.fractalX2,
      };
    }
  }

  void _writeK0LineAtX(List<K0Line> lines, int x) {
    for (var i = lines.length - 1; i >= 0; i--) {
      final seg = lines[i];
      if (x < seg.beginConfirmX || x > seg.endConfirmX) continue;
      byIdx.putIfAbsent(x, () => {'idx': x, 'sub': <String, dynamic>{}})['k0_line'] = {
        'idx': seg.idx,
        'dir': seg.dir,
        'begin_confirm_x': seg.beginConfirmX,
        'end_confirm_x': seg.endConfirmX,
        'prev_idx': seg.prevIdx,
        'next_idx': seg.nextIdx,
      };
      break;
    }
  }

  void _writeK1SnapshotAtX(KlineCombineBundle bundle, int x) {
    for (final snap in bundle.k1Analysis.barSubSnapshots) {
      if (snap.idx != x) continue;
      byIdx.putIfAbsent(x, () => {'idx': x, 'sub': <String, dynamic>{}})['k1_snapshot'] = {
        'building_seg_dir': snap.buildingSegDir,
        'first_seg_dir': snap.firstSegDir,
        'k1_confirm': snap.k1Confirm,
      };
    }
  }

  void _writeVolumeTickAll(List<KlineBar> bars, KlineCombineBundle bundle) {
    void paint(
      Map<int, List<double>> all, {
      required String prefix,
    }) {
      for (final e in all.entries) {
        final series = e.value;
        for (var i = 0; i < bars.length; i++) {
          final xi = bars[i].idx;
          _sub(xi)['${prefix}_${e.key}'] =
              i < series.length ? series[i] : 0.0;
        }
      }
    }

    paint(
      computeAllKnVolumeSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'volume',
    );
    paint(
      computeAllKnBuyVolumeBsgSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'buy_volume',
    );
    paint(
      computeAllKnSellVolumeSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'sell_volume',
    );
    paint(
      computeAllKnGrayVolumeSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'gray_volume',
    );
    paint(
      computeAllKnTickCountSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'tick_count',
    );
    paint(
      computeAllKnBuyTickCountSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'buy_tick_count',
    );
    paint(
      computeAllKnSellTickCountSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'sell_tick_count',
    );
    paint(
      computeAllKnGrayTickCountSeries(
        bars: bars,
        levels: bundle.levels,
        barFeatures: bundle.barFeatures,
      ),
      prefix: 'gray_tick_count',
    );
  }

  void _writeBsAtX({
    required int x,
    required Map<int, List<Buy1Frame>> buy1HistoryByKn,
    required Map<int, List<Sell1Frame>> sell1HistoryByKn,
    required Map<int, List<Buy2Frame>> buy2HistoryByKn,
    required Map<int, List<Sell2Frame>> sell2HistoryByKn,
    required Map<int, List<BuyNFrame>> buyNHistoryByKn,
    required Map<int, List<SellNFrame>> sellNHistoryByKn,
    required List<Buy1Frame> buy1K0,
    required List<Sell1Frame> sell1K0,
    required List<Buy2Frame> buy2K0,
    required List<Sell2Frame> sell2K0,
    required List<BuyNFrame> buyNK0,
    required List<SellNFrame> sellNK0,
    required Set<SubChartIndicator> subIndicators,
  }) {
    final buy1 = Map<int, List<Buy1Frame>>.from(buy1HistoryByKn);
    final sell1 = Map<int, List<Sell1Frame>>.from(sell1HistoryByKn);
    if (buy1.isEmpty && buy1K0.isNotEmpty) buy1[0] = buy1K0;
    if (sell1.isEmpty && sell1K0.isNotEmpty) sell1[0] = sell1K0;
    final sub = _sub(x);
    for (final kn in {...buy1.keys, ...sell1.keys}) {
      for (final p in buy1[kn] ?? const <Buy1Frame>[]) {
        if (p.x != x) continue;
        final k = 'b1|$kn|${p.segIdx}|${p.label}|$x';
        if (_writtenHist.add(k)) {
          sub['buy1_$kn'] = p.label;
          sub['buy1_${kn}_code'] = MlBsCode.encode(p.label);
        }
      }
      for (final p in sell1[kn] ?? const <Sell1Frame>[]) {
        if (p.x != x) continue;
        final k = 's1|$kn|${p.segIdx}|${p.label}|$x';
        if (_writtenHist.add(k)) {
          sub['sell1_$kn'] = p.label;
          sub['sell1_${kn}_code'] = MlBsCode.encode(p.label);
        }
      }
    }
    final buy2 = Map<int, List<Buy2Frame>>.from(buy2HistoryByKn);
    final sell2 = Map<int, List<Sell2Frame>>.from(sell2HistoryByKn);
    if (buy2.isEmpty && buy2K0.isNotEmpty) buy2[0] = buy2K0;
    if (sell2.isEmpty && sell2K0.isNotEmpty) sell2[0] = sell2K0;
    for (final kn in {...buy2.keys, ...sell2.keys}) {
      for (final p in buy2[kn] ?? const <Buy2Frame>[]) {
        if (p.x != x) continue;
        final k = 'b2|$kn|${p.segIdx}|${p.label}|$x';
        if (_writtenHist.add(k)) {
          sub['buy2_$kn'] = p.label;
          sub['buy2_${kn}_code'] = MlBsCode.encode(p.label);
        }
      }
      for (final p in sell2[kn] ?? const <Sell2Frame>[]) {
        if (p.x != x) continue;
        final k = 's2|$kn|${p.segIdx}|${p.label}|$x';
        if (_writtenHist.add(k)) {
          sub['sell2_$kn'] = p.label;
          sub['sell2_${kn}_code'] = MlBsCode.encode(p.label);
        }
      }
    }
    final buyN = Map<int, List<BuyNFrame>>.from(buyNHistoryByKn);
    final sellN = Map<int, List<SellNFrame>>.from(sellNHistoryByKn);
    if (buyN.isEmpty && buyNK0.isNotEmpty) buyN[0] = buyNK0;
    if (sellN.isEmpty && sellNK0.isNotEmpty) sellN[0] = sellNK0;
    for (final kn in {...buyN.keys, ...sellN.keys}) {
      for (final p in buyN[kn] ?? const <BuyNFrame>[]) {
        if (p.x != x) continue;
        final k = 'bn|$kn|${p.cls}|${p.segIdx}|${p.label}|$x';
        if (_writtenHist.add(k)) {
          sub['buyN_${kn}_${p.cls}'] = p.label;
          sub['buyN_${kn}_${p.cls}_code'] = MlBsCode.encode(p.label);
        }
      }
      for (final p in sellN[kn] ?? const <SellNFrame>[]) {
        if (p.x != x) continue;
        final k = 'sn|$kn|${p.cls}|${p.segIdx}|${p.label}|$x';
        if (_writtenHist.add(k)) {
          sub['sellN_${kn}_${p.cls}'] = p.label;
          sub['sellN_${kn}_${p.cls}_code'] = MlBsCode.encode(p.label);
        }
      }
    }
  }

  void _writePeakDistAll(KlineCombineBundle bundle, List<KlineBar> bars) {
    for (final f in bundle.barFeatures) {
      if (bars.isNotEmpty && f.idx > bars.last.idx) continue;
      final sub = _sub(f.idx);
      sub['fractal_peak_dist'] = f.fractalPeakDist;
      sub['fractal_peak_dist_0'] = f.fractalPeakDist;
    }
    for (final lv in bundle.levels) {
      if (lv.level < 1) continue;
      for (final b in bars) {
        var extreme = 0;
        var has = false;
        for (final c in lv.confirms) {
          if (c.x > b.idx) break;
          if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.poleX >= 0) {
            extreme = c.poleX;
            has = true;
          }
        }
        _sub(b.idx)['fractal_peak_dist_${lv.level}'] =
            has ? b.idx - extreme : 0;
      }
    }
  }

  void _writeJudgmentLayerInit(KlineCombineBundle bundle) {
    for (final x in byIdx.keys) {
      final sub = _sub(x);
      for (var kn = 0; kn <= bundle.levels.length; kn++) {
        sub.putIfAbsent('fractal_judgment_$kn', () => 'UNKNOWN');
        sub.putIfAbsent('fractal_judgment_trunc_$kn', () => false);
      }
    }
  }

  void _writeJudgmentAtX(
    KlineCombineBundle bundle,
    Map<int, List<FractalJudgmentEvent>> history,
    int x,
  ) {
    final sub = _sub(x);
    for (var kn = 0; kn <= bundle.levels.length; kn++) {
      sub['fractal_judgment_$kn'] = 'UNKNOWN';
      sub['fractal_judgment_trunc_$kn'] = false;
      final events = history[kn];
      if (events == null) continue;
      for (final e in events) {
        if (e.x != x) continue;
        if (e.fx != 'TOP' && e.fx != 'BOTTOM') continue;
        sub['fractal_judgment_$kn'] = e.fx;
        sub['fractal_judgment_trunc_$kn'] = e.truncated;
      }
    }
  }

  void _writeZsSignalsAtX(
    Map<int, List<ZsSignalEvent>> judgment,
    Map<int, List<ZsSignalEvent>> confirm,
    int x,
  ) {
    final sub = _sub(x);
    for (final e in judgment.entries) {
      var v = 0;
      for (final ev in e.value) {
        if (ev.x == x && ev.value != 0) v = ev.value;
      }
      sub['zs_judgment_${e.key}'] = v;
    }
    for (final e in confirm.entries) {
      var v = 0;
      for (final ev in e.value) {
        if (ev.x == x && ev.value != 0) v = ev.value;
      }
      sub['zs_confirm_${e.key}'] = v;
    }
  }

  void _writeRatioRhythmSlopeAtX({
    required Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn,
    required Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn,
    required Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn,
    required int x,
  }) {
    final sub = _sub(x);
    for (final e in adjacentRatioHistoryByKn.entries) {
      for (final p in e.value) {
        if (p.x != x) continue;
        sub['adjacent_ratio_${e.key}'] = p.ratio;
      }
    }
    for (final e in stepRhythmHistoryByKn.entries) {
      final at = e.value.where((p) => p.x == x).toList();
      sub['step_rhythm_lines_${e.key}'] = [
        for (final p in at)
          {
            'label': p.label,
            'labelInt': _rhythmLabelToInt(p.label),
            'value': p.value,
            'ratio': p.ratio,
            'dir': p.dir,
            'dirInt': p.dir == 'up' ? 1 : (p.dir == 'down' ? -1 : 0),
          },
      ];
      sub['step_rhythm_${e.key}'] = formatStepRhythmReadout(e.value, x);
    }
    for (final e in lineSlopeHistoryByKn.entries) {
      for (final p in e.value) {
        if (p.x != x) continue;
        sub['line_slope_${e.key}'] = p.slope;
      }
    }
  }

  int _rhythmLabelToInt(String? label) {
    if (label == null || label.isEmpty) return 0;
    final m = RegExp(r'^(\d+)-(\d+)$').firstMatch(label);
    if (m == null) return 0;
    return int.parse(m.group(1)!) * 10 + int.parse(m.group(2)!);
  }

  void _writeTripleQuadTrendAtX({
    required List<KlineBar> bars,
    required KlineCombineBundle bundle,
    required int x,
  }) {
    _writeTripleQuadTrendInto(byIdx: byIdx, bars: bars, bundle: bundle, x: x);
  }

  static void _writeTripleQuadTrendInto({
    required Map<int, Map<String, dynamic>> byIdx,
    required List<KlineBar> bars,
    required KlineCombineBundle bundle,
    required int x,
  }) {
    if (bars.isEmpty) return;
    if (bundle.k0Confirms.isEmpty &&
        bundle.levels.isEmpty &&
        bundle.zsK0Frames.isEmpty) {
      return;
    }
    var maxLevel = 0;
    for (final lv in bundle.levels) {
      if (lv.level > maxLevel) maxLevel = lv.level;
    }
    final row = byIdx.putIfAbsent(x, () => {'idx': x});
    final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
        as Map<String, dynamic>;
    for (var dkn = 0; dkn <= maxLevel; dkn++) {
      final poles = collectLevelFxPoles(
        displayKn: dkn,
        bars: bars,
        k0Confirms: bundle.k0Confirms,
        levels: bundle.levels,
        asOf: x,
      );
      final tPx = triplePriceReadout(
        calcAllTripleGroups(poles),
        atX: x,
        focusX: x,
      );
      final q = quadPriceReadout(
        calcAllQuadGroups(poles),
        atX: x,
        focusX: x,
      );
      if (tPx != null) sub['fx_triple_price_$dkn'] = tPx;
      if (q.top != null) sub['fx_quad_top_price_$dkn'] = q.top;
      if (q.bottom != null) sub['fx_quad_bottom_price_$dkn'] = q.bottom;
    }
    final trendMaxD = maxLevel >= 1 ? maxLevel - 1 : -1;
    for (var dkn = 0; dkn <= trendMaxD; dkn++) {
      final tl = trendLinePriceReadout(
        calcTrendLineGroupsForLevel(
          displayKn: dkn,
          levels: bundle.levels,
          asOf: x,
        ),
        atX: x,
        focusX: x,
      );
      if (tl.support != null) sub['trend_support_price_$dkn'] = tl.support;
      if (tl.resistance != null) sub['trend_resist_price_$dkn'] = tl.resistance;
    }
  }

  void _bindMath({
    required MathIndicatorConfig mathIndicatorConfig,
    MathSeriesFreezeStore? mathFreezeStore,
    DivergenceFreezeStore? diverFreezeStore,
  }) {
    _mathCfg = mathIndicatorConfig;
    _mathFreeze = mathFreezeStore;
    _diverFreeze = diverFreezeStore;
  }

  void _writeMathAll({
    required List<KlineBar> bars,
    required KlineCombineBundle bundle,
    required int asOf,
    required MathIndicatorConfig mathIndicatorConfig,
    MathSeriesFreezeStore? mathFreezeStore,
    DivergenceFreezeStore? diverFreezeStore,
    Map<int, Map<String, dynamic>>? into,
  }) {
    if (bars.isEmpty) return;
    if (bundle.k0Confirms.isEmpty &&
        bundle.levels.isEmpty &&
        bundle.zsK0Frames.isEmpty) {
      return;
    }
    var maxLevel = 0;
    for (final lv in bundle.levels) {
      if (lv.level > maxLevel) maxLevel = lv.level;
    }
    final trendModelConfig = mathIndicatorConfig.asTrendModel;
    final dest = into ?? byIdx;
    void atBar(int x, void Function(Map<String, dynamic> sub) fn) {
      final row = dest.putIfAbsent(x, () => {'idx': x});
      fn(row.putIfAbsent('sub', () => <String, dynamic>{})
          as Map<String, dynamic>);
    }

    final meanMaxD = maxLevel + 1;
    for (var dkn = 0; dkn <= meanMaxD; dkn++) {
      final means = mathFreezeStore?.mean(dkn) ??
          computeMeanSeriesForLevel(
            displayKn: dkn,
            bars: bars,
            levels: bundle.levels,
            periods: trendModelConfig.meanPeriods,
            asOf: asOf,
          );
      final chans = mathFreezeStore?.channel(dkn) ??
          computeChannelSeriesForLevel(
            displayKn: dkn,
            bars: bars,
            levels: bundle.levels,
            periods: trendModelConfig.channelPeriods,
            asOf: asOf,
          );
      for (final b in bars) {
        if (b.idx > asOf) continue;
        atBar(b.idx, (sub) {
          final meanParts = <String>[];
          for (final t in (means.keys.toList()..sort())) {
            final series = means[t]!;
            if (b.idx >= 0 && b.idx < series.length && series[b.idx] != null) {
              final v = series[b.idx]!;
              sub['mean_${dkn}_$t'] = v;
              meanParts.add('$t:${v.toStringAsFixed(2)}');
            }
          }
          if (meanParts.isNotEmpty) sub['mean_text_$dkn'] = meanParts.join(' ');
          final chanParts = <String>[];
          for (final t in (chans.keys.toList()..sort())) {
            final pair = chans[t]!;
            final hi = b.idx < pair.max.length ? pair.max[b.idx] : null;
            final lo = b.idx < pair.min.length ? pair.min[b.idx] : null;
            if (hi != null) sub['channel_max_${dkn}_$t'] = hi;
            if (lo != null) sub['channel_min_${dkn}_$t'] = lo;
            if (hi != null || lo != null) {
              chanParts.add(
                '$t:${hi != null ? hi.toStringAsFixed(2) : "-"}/'
                '${lo != null ? lo.toStringAsFixed(2) : "-"}',
              );
            }
          }
          if (chanParts.isNotEmpty) {
            sub['channel_text_$dkn'] = chanParts.join(' ');
          }
        });
      }
    }
    for (var dkn = 0; dkn <= maxLevel; dkn++) {
      final classicFrozenMacd = mathFreezeStore?.macd(dkn);
      final classicFrozenBoll = mathFreezeStore?.boll(dkn);
      final classicFrozenRsi = mathFreezeStore?.rsi(dkn);
      final classicFrozenKdj = mathFreezeStore?.kdj(dkn);
      final classic = (classicFrozenMacd != null &&
              classicFrozenBoll != null &&
              classicFrozenRsi != null &&
              classicFrozenKdj != null)
          ? (
              macd: classicFrozenMacd,
              boll: classicFrozenBoll,
              rsi: classicFrozenRsi,
              kdj: classicFrozenKdj,
            )
          : computeClassicMathForLevel(
              displayKn: dkn,
              bars: bars,
              levels: bundle.levels,
              config: mathIndicatorConfig,
              asOf: asOf,
            );
      final demark = mathFreezeStore?.demark(dkn) ??
          computeDemarkForLevel(
            displayKn: dkn,
            bars: bars,
            levels: bundle.levels,
            config: mathIndicatorConfig,
            asOf: asOf,
          );
      final frozenDiver = diverFreezeStore?.level(dkn);
      final diverMap = frozenDiver != null
          ? truncateDivergenceMap(frozenDiver, bars.length, asOf: asOf)
          : computeDivergenceForLevel(
              displayKn: dkn,
              bars: bars,
              levels: bundle.levels,
              zsK0Frames: bundle.zsK0Frames,
              config: mathIndicatorConfig,
              asOf: asOf,
              mathFreezeStore: mathFreezeStore,
            );
      for (final b in bars) {
        if (b.idx > asOf) continue;
        final x = b.idx;
        atBar(x, (sub) {
          if (x >= 0 && x < classic.macd.dif.length) {
            final dif = classic.macd.dif[x];
            final dea = classic.macd.dea[x];
            final hist = classic.macd.macd[x];
            if (dif != null) sub['macd_dif_$dkn'] = dif;
            if (dea != null) sub['macd_dea_$dkn'] = dea;
            if (hist != null) sub['macd_hist_$dkn'] = hist;
          }
          if (x >= 0 && x < classic.boll.mid.length) {
            final mid = classic.boll.mid[x];
            final up = classic.boll.up[x];
            final down = classic.boll.down[x];
            if (mid != null) sub['boll_mid_$dkn'] = mid;
            if (up != null) sub['boll_up_$dkn'] = up;
            if (down != null) sub['boll_down_$dkn'] = down;
          }
          if (x >= 0 && x < classic.rsi.length) {
            final rsi = classic.rsi[x];
            if (rsi != null) sub['rsi_$dkn'] = rsi;
          }
          if (x >= 0 && x < classic.kdj.k.length) {
            final k = classic.kdj.k[x];
            final d = classic.kdj.d[x];
            final j = classic.kdj.j[x];
            if (k != null) sub['kdj_k_$dkn'] = k;
            if (d != null) sub['kdj_d_$dkn'] = d;
            if (j != null) sub['kdj_j_$dkn'] = j;
          }
          if (x >= 0 && x < demark.marksAt.length) {
            final marks = demark.marksAt[x];
            if (marks != null && marks.isNotEmpty) {
              sub['demark_text_$dkn'] =
                  BarFeatureLookup.formatDemarkMarks(marks);
              sub['demark_marks_$dkn'] = [
                for (final m in marks)
                  {
                    'type': m.type == 'setup'
                        ? 0
                        : (m.type == 'countdown' ? 1 : 2),
                    'dir': m.dir,
                    'idx': m.idx,
                  },
              ];
            }
          }
          for (final algo in DivergenceAlgoMeta.all) {
            final series = diverMap[algo];
            if (series == null) continue;
            if (x >= 0 && x < series.inAt.length) {
              final vin = series.inAt[x];
              final vout = series.outAt[x];
              final vr = series.ratioAt[x];
              final vf = series.diverAt[x];
              if (vin != null) sub[diverFeatureKey(algo, 'in', dkn)] = vin;
              if (vout != null) {
                sub[diverFeatureKey(algo, 'out', dkn)] = vout;
              }
              if (vr != null) sub[diverFeatureKey(algo, 'ratio', dkn)] = vr;
              sub[diverFeatureKey(algo, 'flag', dkn)] = vf;
            }
          }
        });
      }
    }
  }

  void _writeZsDirty(KlineCombineBundle bundle, int x) {
    void paint(ZSFrame f, int kn) {
      for (var xi = f.x1; xi <= f.x2 && xi <= x; xi++) {
        final row = byIdx[xi];
        if (row == null) continue;
        final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
            as Map<String, dynamic>;
        sub['zs_high_$kn'] = f.high;
        sub['zs_low_$kn'] = f.low;
        sub['zs_sure_$kn'] = f.isSure ? 1 : 0;
        sub['zs_seq_$kn'] = f.seq;
      }
    }

    void clear(int x1, int x2, int kn) {
      for (var xi = x1; xi <= x2; xi++) {
        final row = byIdx[xi];
        if (row == null) continue;
        final sub = row['sub'];
        if (sub is Map<String, dynamic> && sub['zs_seq_$kn'] != null) {
          // 只清本 seq 覆盖；若已被别的框盖住，后面 paint 会写回
        }
      }
    }

    void handle(ZSFrame f, int kn) {
      final key = '$kn|${f.seq}';
      if (f.isSure) {
        if (!_sureZs.contains(key)) {
          paint(f, kn);
          _sureZs.add(key);
        }
        _unsureZs.remove(key);
        return;
      }
      final prev = _unsureZs[key];
      if (prev != null) clear(prev.x1, prev.x2, kn);
      paint(f, kn);
      _unsureZs[key] = (x1: f.x1, x2: f.x2, kn: kn);
    }

    for (final f in bundle.zsK0Frames) {
      handle(f, 0);
    }
    for (final lv in bundle.levels) {
      for (final f in lv.zsFrames) {
        final kn = f.level >= 0 ? f.level : (lv.level + 1);
        handle(f, kn);
      }
    }
  }

  void _captureZsState(KlineCombineBundle bundle) {
    void add(ZSFrame f, int kn) {
      final key = '$kn|${f.seq}';
      if (f.isSure) {
        _sureZs.add(key);
      } else {
        _unsureZs[key] = (x1: f.x1, x2: f.x2, kn: kn);
      }
    }

    for (final f in bundle.zsK0Frames) {
      add(f, 0);
    }
    for (final lv in bundle.levels) {
      for (final f in lv.zsFrames) {
        final kn = f.level >= 0 ? f.level : (lv.level + 1);
        add(f, kn);
      }
    }
  }

  void _markWrittenHistory({
    required Map<int, List<Buy1Frame>> buy1HistoryByKn,
    required Map<int, List<Sell1Frame>> sell1HistoryByKn,
    required Map<int, List<Buy2Frame>> buy2HistoryByKn,
    required Map<int, List<Sell2Frame>> sell2HistoryByKn,
    required Map<int, List<BuyNFrame>> buyNHistoryByKn,
    required Map<int, List<SellNFrame>> sellNHistoryByKn,
    required Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn,
    required Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn,
    required Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn,
    required Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn,
    required Map<int, List<ZsSignalEvent>> zsJudgmentHistoryByKn,
    required Map<int, List<ZsSignalEvent>> zsConfirmHistoryByKn,
  }) {
    for (final e in buy1HistoryByKn.entries) {
      for (final p in e.value) {
        _writtenHist.add('b1|${e.key}|${p.segIdx}|${p.label}|${p.x}');
      }
    }
    for (final e in sell1HistoryByKn.entries) {
      for (final p in e.value) {
        _writtenHist.add('s1|${e.key}|${p.segIdx}|${p.label}|${p.x}');
      }
    }
    for (final e in buy2HistoryByKn.entries) {
      for (final p in e.value) {
        _writtenHist.add('b2|${e.key}|${p.segIdx}|${p.label}|${p.x}');
      }
    }
    for (final e in sell2HistoryByKn.entries) {
      for (final p in e.value) {
        _writtenHist.add('s2|${e.key}|${p.segIdx}|${p.label}|${p.x}');
      }
    }
    for (final e in buyNHistoryByKn.entries) {
      for (final p in e.value) {
        _writtenHist.add('bn|${e.key}|${p.cls}|${p.segIdx}|${p.label}|${p.x}');
      }
    }
    for (final e in sellNHistoryByKn.entries) {
      for (final p in e.value) {
        _writtenHist.add('sn|${e.key}|${p.cls}|${p.segIdx}|${p.label}|${p.x}');
      }
    }
  }
}
