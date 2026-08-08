import 'k0_confirm_signal.dart';
import 'bar_crosshair_feature.dart';
import 'buy1_frame.dart';
import 'sell1_frame.dart';
import 'buy2_frame.dart';
import 'sell2_frame.dart';
import 'buy_n_frame.dart';
import 'sell_n_frame.dart';
import 'k0_line.dart';
import 'kline_bar.dart';
import 'chart_indicator.dart';
import 'kline_combine_frame.dart';
import 'level_models.dart';
import 'k1_analysis.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/zs_signal_compute.dart';
import '../compute/class1_bs_compute.dart';
import '../compute/class2_bs_compute.dart';
import '../compute/class_n_bs_compute.dart';
import '../compute/kn_volume_series_compute.dart';
import '../compute/adjacent_ratio_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/fx_extend_line_compute.dart';
import '../compute/trend_line_compute.dart';
import '../compute/trend_model_compute.dart';
import '../compute/math_classic_compute.dart';
import '../compute/demark_compute.dart';
import '../compute/divergence_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../compute/math_series_freeze_store.dart';
import '../compute/step_rhythm_compute.dart';
import '../compute/profile_peak_classify.dart';
import 'divergence_algo.dart';
import 'math_indicator_config.dart';
import 'zs_frame.dart';

/// 十字线 tooltip 一行：键值 / 层级分隔线 / 同层内容分隔线。
class CrosshairTooltipRow {
  const CrosshairTooltipRow.kv(this.label, this.value)
      : isSeparator = false,
        isStar = false;
  const CrosshairTooltipRow.separator()
      : label = '',
        value = '',
        isSeparator = true,
        isStar = false;
  const CrosshairTooltipRow.starSeparator()
      : label = '',
        value = '',
        isSeparator = false,
        isStar = true;

  final String label;
  final String value;
  final bool isSeparator;
  final bool isStar;

  /// 扁平字符串（测试/历史快照用）
  String get flat {
    if (isSeparator) return '===============================';
    if (isStar) return '-。-。-。-。-。-。-。-。-。-';
    return '$label:$value';
  }

  /// 数字值外接方形框，便于与字符串区分
  static String boxNum(dynamic v) => v == null ? '【—】' : '【$v】';

  /// 复合字符串中所有数字（含小数）外接方形框
  /// 例：O11.89/H11.90 → O【11.89】/H【11.90】
  static final _numRe = RegExp(r'(\d+\.?\d*)');
  static String boxNumInString(String s) =>
      s.replaceAllMapped(_numRe, (m) => '【${m.group(0)}】');
}

/// 逐 K 字典式特征索引（ML / 十字线 tooltip 同源，均用 barFeatures 逐步冻结快照）。
class BarFeatureLookup {
  BarFeatureLookup._({
    required this.byIdx,
    this.totalLevels = 0,
    this.zsAfterK0 = const [],
    this.knZsAfterKn = const {},
  });

  final Map<int, Map<String, dynamic>> byIdx;

  /// 穷尽后的 N 段总层数（tooltip 对未诞生层输出占位行）
  final int totalLevels;

  /// 十字线：K0 块后追加的中枢 ZG/ZD 行
  final List<CrosshairTooltipRow> zsAfterK0;

  /// 十字线：各 Kn 块后追加的中枢 ZG/ZD 行
  final Map<int, List<CrosshairTooltipRow>> knZsAfterKn;

  factory BarFeatureLookup.empty() =>
      BarFeatureLookup._(byIdx: const <int, Map<String, dynamic>>{});

  factory BarFeatureLookup.build({
    required List<KlineBar> bars,
    required List<KlineCombineFrame> combineFrames,
    required List<K0ConfirmSignal> k0Confirms,
    List<BarCrosshairFeature> barFeatures = const [],
    List<K0Line> k0Lines = const [],
    K1AnalysisBundle k1Analysis = const K1AnalysisBundle(),
    List<LevelBundle> levels = const [],
    Map<int, List<Buy1Frame>> buy1HistoryByKn = const {},
    Map<int, List<Sell1Frame>> sell1HistoryByKn = const {},
    Map<int, List<Buy2Frame>> buy2HistoryByKn = const {},
    Map<int, List<Sell2Frame>> sell2HistoryByKn = const {},
    Map<int, List<BuyNFrame>> buyNHistoryByKn = const {},
    Map<int, List<SellNFrame>> sellNHistoryByKn = const {},
    Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn = const {},
    Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn = const {},
    Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn = const {},
    List<Buy1Frame> buy1K0Frames = const [],
    List<Sell1Frame> sell1K0Frames = const [],
    List<Buy2Frame> buy2K0Frames = const [],
    List<Sell2Frame> sell2K0Frames = const [],
    List<BuyNFrame> buyNK0Frames = const [],
    List<SellNFrame> sellNK0Frames = const [],
    Set<SubChartIndicator> subIndicators = const {},
    bool truncationCheck = true,
    /// 分型判断会话事件日志（有则优先；扫全部历史点）
    Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn = const {},
    /// 中枢判断/确定会话历史（与中枢同号）
    Map<int, List<ZsSignalEvent>> zsJudgmentHistoryByKn = const {},
    Map<int, List<ZsSignalEvent>> zsConfirmHistoryByKn = const {},
    /// 当步截断位（idx）：与副图指标 _drawKnFractalJudgmentSubChart 的 maxX=segAsOf 一致，
    /// 十字线激活时传入 widget.segAsOf，使 tooltip 分型判断与副图同源同截断。
    int? asOf,
    List<CrosshairTooltipRow> zsAfterK0 = const [],
    Map<int, List<CrosshairTooltipRow>> knZsAfterKn = const {},
    MathIndicatorConfig mathIndicatorConfig = const MathIndicatorConfig(),
    MathSeriesFreezeStore? mathFreezeStore,
    DivergenceFreezeStore? diverFreezeStore,
    List<ZSFrame> zsK0Frames = const [],
  }) {
    final trendModelConfig = mathIndicatorConfig.asTrendModel;
    final byIdx = <int, Map<String, dynamic>>{};

    final featureByIdx = {for (final f in barFeatures) f.idx: f};

    // 各层确认查表：level_confirms[structureLevel][x]（方案B：0=K0连线）
    final levelConfirmByX = <int, Map<int, LevelConfirm>>{};
    for (final lv in levels) {
      final m = <int, LevelConfirm>{};
      for (final c in lv.confirms) {
        if (c.value == 1 || c.value == -1) m[c.x] = c;
      }
      levelConfirmByX[lv.level] = m;
    }

    for (final b in bars) {
      final feat = featureByIdx[b.idx];
      byIdx[b.idx] = {
        'idx': b.idx,
        'time_ms': b.timeMs,
        'time_text': b.timeText,
        'weekday': feat?.weekday ?? '-',
        'merge_inner_seq': feat?.mergeInnerSeq ?? 0,
        'merge_count': feat?.mergeCount ?? 1,
        'merge_box_seq': feat?.mergeBoxSeq ?? -1,
        'combine_fx': feat?.combineFx ?? 'UNKNOWN',
        'combine_high': feat?.combineHigh ?? b.high,
        'combine_low': feat?.combineLow ?? b.low,
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
            if (e.value.containsKey(b.idx)) e.key: e.value[b.idx]!,
        },
        'open': b.open,
        'high': b.high,
        'low': b.low,
        'close': b.close,
        'volume': b.volume,
        'amount': b.amount,
        if (b.metrics.isNotEmpty) 'metrics': Map<String, dynamic>.from(b.metrics),
        'sub': <String, dynamic>{},
      };
    }

    // 合并线框仅结构展示；十字线/ML 的 fx、count 取自 barFeatures 逐步口径
    // GG/DD=组内原始区间极值（原始K高低，逐K当下、无未来函数）；MG/MD=合并框框体高低点
    final barByIdx = {for (final b in bars) b.idx: b};
    for (final f in combineFrames) {
      var rangeHigh = double.negativeInfinity;
      var rangeLow = double.infinity;
      for (var x = f.x1; x <= f.x2; x++) {
        final b = barByIdx[x];
        if (b != null) {
          if (b.high > rangeHigh) rangeHigh = b.high;
          if (b.low < rangeLow) rangeLow = b.low;
        }
        final row = byIdx.putIfAbsent(x, () => {'idx': x});
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

    // 方案B：tooltip Kn 块号 = structure+1；键用 display
    for (final lv in levels) {
      final displayKn = lv.level + 1;
      for (final f in lv.combineFrames) {
        for (var x = f.x1; x <= f.x2; x++) {
          final row = byIdx.putIfAbsent(x, () => {'idx': x});
          row['combine_box_$displayKn'] = {'high': f.high, 'low': f.low};
        }
      }
    }

    // 各层 Kn合并 GG/DD：按 snap.level==structure 查找（勿再用下标 n-1）
    for (final lv in levels) {
      final displayKn = lv.level + 1;
      var curStart = -2;
      var rangeHigh = double.negativeInfinity;
      var rangeLow = double.infinity;
      for (final b in bars) {
        final row = byIdx[b.idx];
        if (row == null) continue;
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
        if (snap == null || snap.unitIdx == null || snap.combineX1 < 0) {
          curStart = -2;
          continue;
        }
        if (snap.combineX1 != curStart) {
          curStart = snap.combineX1;
          rangeHigh = double.negativeInfinity;
          rangeLow = double.infinity;
        }
        if (snap.unitHigh > rangeHigh) rangeHigh = snap.unitHigh;
        if (snap.unitLow < rangeLow) rangeLow = snap.unitLow;
        row['combine_range_high_$displayKn'] = rangeHigh;
        row['combine_range_low_$displayKn'] = rangeLow;
      }
    }

    for (final sig in k0Confirms) {
      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});
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
        // 方案B：kn=0=K0分型，回退源旧 k0_confirm
        (row['sub'] as Map<String, dynamic>)['k0_confirm_value'] = sig.value;
      }
    }

    for (final sig in k1Analysis.k1Confirms) {
      if (sig.fx != 'TOP' && sig.fx != 'BOTTOM') continue;
      if (sig.value == 0) continue;
      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});
      row['k1_confirm_signal'] = {
        'x': sig.x,
        'fx': sig.fx,
        'value': sig.value,
        'peak_k1_idx': sig.peakK1Idx,
        'fractal_x1': sig.fractalX1,
        'fractal_x2': sig.fractalX2,
      };
    }

    for (final seg in k0Lines) {
      for (var x = seg.beginConfirmX; x <= seg.endConfirmX; x++) {
        final row = byIdx.putIfAbsent(x, () => {'idx': x});
        row['k0_line'] = {
          'idx': seg.idx,
          'dir': seg.dir,
          'begin_confirm_x': seg.beginConfirmX,
          'end_confirm_x': seg.endConfirmX,
          'prev_idx': seg.prevIdx,
          'next_idx': seg.nextIdx,
        };
      }
    }

    for (final snap in k1Analysis.barSubSnapshots) {
      final row = byIdx.putIfAbsent(snap.idx, () => {'idx': snap.idx});
      row['k1_snapshot'] = {
        'building_seg_dir': snap.buildingSegDir,
        'first_seg_dir': snap.firstSegDir,
        'k1_confirm': snap.k1Confirm,
      };
      // 已删副图「首K1向 / K2确认」：快照字段仍保留供其它用途
    }

    // Kn成交量：K0=原生；Kn=下层增量累加步进（与副图绘制同源）。
    // 另写 B/S/G 三分解供 tooltip（G=gray）；副图叠柱仍用 volume_/既有 buy 系列。
    {
      final allVol = computeAllKnVolumeSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allBuy = computeAllKnBuyVolumeBsgSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allSell = computeAllKnSellVolumeSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allGray = computeAllKnGrayVolumeSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      for (final e in allVol.entries) {
        final series = e.value;
        final buyS = allBuy[e.key] ?? const <double>[];
        final sellS = allSell[e.key] ?? const <double>[];
        final grayS = allGray[e.key] ?? const <double>[];
        for (var i = 0; i < bars.length; i++) {
          final row =
              byIdx.putIfAbsent(bars[i].idx, () => {'idx': bars[i].idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          sub['volume_${e.key}'] = i < series.length ? series[i] : 0.0;
          sub['buy_volume_${e.key}'] = i < buyS.length ? buyS[i] : 0.0;
          sub['sell_volume_${e.key}'] = i < sellS.length ? sellS[i] : 0.0;
          sub['gray_volume_${e.key}'] = i < grayS.length ? grayS[i] : 0.0;
        }
      }
    }

    // Kn笔数：与成交量同结构；另写 B/S/G 供 tooltip（应显尽显，不依赖副图勾选）。
    {
      final allTick = computeAllKnTickCountSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allBuyTick = computeAllKnBuyTickCountSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allSellTick = computeAllKnSellTickCountSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allGrayTick = computeAllKnGrayTickCountSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      for (final e in allTick.entries) {
        final series = e.value;
        final buySeries = allBuyTick[e.key] ?? const <double>[];
        final sellSeries = allSellTick[e.key] ?? const <double>[];
        final graySeries = allGrayTick[e.key] ?? const <double>[];
        for (var i = 0; i < bars.length; i++) {
          final row =
              byIdx.putIfAbsent(bars[i].idx, () => {'idx': bars[i].idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          sub['tick_count_${e.key}'] =
              i < series.length ? series[i] : 0.0;
          sub['buy_tick_count_${e.key}'] =
              i < buySeries.length ? buySeries[i] : 0.0;
          sub['sell_tick_count_${e.key}'] =
              i < sellSeries.length ? sellSeries[i] : 0.0;
          sub['gray_tick_count_${e.key}'] =
              i < graySeries.length ? graySeries[i] : 0.0;
        }
      }
    }

    // Kn一类BS：只扫会话历史（含动态 active 各 K0 颗粒度点）；禁止 asOf 重算消点。
    // 踩坑：history 若缺本步 x，十字 asOf=当前步会 sellAtAsOf=null（26有点、27空）。
    {
      // 兼容：未传 history 时回退 K0 帧（旧调用）
      final buyHist = Map<int, List<Buy1Frame>>.from(buy1HistoryByKn);
      final sellHist = Map<int, List<Sell1Frame>>.from(sell1HistoryByKn);
      if (buyHist.isEmpty && buy1K0Frames.isNotEmpty) {
        buyHist[0] = buy1K0Frames;
      }
      if (sellHist.isEmpty && sell1K0Frames.isNotEmpty) {
        sellHist[0] = sell1K0Frames;
      }
      // 禁 levels 末态帧兜底（会破「不回写」）；history 空 → tip 【0】

      final barCount = bars.isEmpty ? 0 : bars.last.idx + 1;
      final kns = <int>{...buyHist.keys, ...sellHist.keys};
      for (final kn in kns) {
        final buySeries = expandBuy1LabelsToSeries(
          buyHist[kn] ?? const [],
          barCount,
          maxX: asOf,
        );
        final sellSeries = expandSell1LabelsToSeries(
          sellHist[kn] ?? const [],
          barCount,
          maxX: asOf,
        );
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (b.idx >= 0 &&
              b.idx < buySeries.length &&
              buySeries[b.idx] != null) {
            sub['buy1_$kn'] = buySeries[b.idx];
          }
          if (b.idx >= 0 &&
              b.idx < sellSeries.length &&
              sellSeries[b.idx] != null) {
            sub['sell1_$kn'] = sellSeries[b.idx];
          }
        }
      }
    }

    // Kn二类BS：与一类同构冻结（会话历史优先）
    {
      final buyHist = Map<int, List<Buy2Frame>>.from(buy2HistoryByKn);
      final sellHist = Map<int, List<Sell2Frame>>.from(sell2HistoryByKn);
      if (buyHist.isEmpty && buy2K0Frames.isNotEmpty) {
        buyHist[0] = buy2K0Frames;
      }
      if (sellHist.isEmpty && sell2K0Frames.isNotEmpty) {
        sellHist[0] = sell2K0Frames;
      }
      // 禁 levels 末态帧兜底

      final barCount = bars.isEmpty ? 0 : bars.last.idx + 1;
      final kns = <int>{...buyHist.keys, ...sellHist.keys};
      for (final kn in kns) {
        final buySeries = expandBuy2LabelsToSeries(
          buyHist[kn] ?? const [],
          barCount,
          maxX: asOf,
        );
        final sellSeries = expandSell2LabelsToSeries(
          sellHist[kn] ?? const [],
          barCount,
          maxX: asOf,
        );
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (b.idx >= 0 &&
              b.idx < buySeries.length &&
              buySeries[b.idx] != null) {
            sub['buy2_$kn'] = buySeries[b.idx];
          }
          if (b.idx >= 0 &&
              b.idx < sellSeries.length &&
              sellSeries[b.idx] != null) {
            sub['sell2_$kn'] = sellSeries[b.idx];
          }
        }
      }
    }

    // Kn三类+BS：按 cls 分键 buyN_${kn}_$cls
    {
      final buyHist = Map<int, List<BuyNFrame>>.from(buyNHistoryByKn);
      final sellHist = Map<int, List<SellNFrame>>.from(sellNHistoryByKn);
      if (buyHist.isEmpty && buyNK0Frames.isNotEmpty) {
        buyHist[0] = buyNK0Frames;
      }
      if (sellHist.isEmpty && sellNK0Frames.isNotEmpty) {
        sellHist[0] = sellNK0Frames;
      }
      // 禁 levels 末态帧兜底

      final barCount = bars.isEmpty ? 0 : bars.last.idx + 1;
      final kns = <int>{...buyHist.keys, ...sellHist.keys};
      final classes = <int>{};
      for (final list in buyHist.values) {
        for (final e in list) {
          classes.add(e.cls);
        }
      }
      for (final list in sellHist.values) {
        for (final e in list) {
          classes.add(e.cls);
        }
      }
      // tooltip 应显尽显：N类至少算到 9，不依赖副图勾选
      for (var cls = 3; cls <= 9; cls++) {
        classes.add(cls);
      }
      for (final ind in subIndicators) {
        if (ind.kind == SubIndicatorKind.buyN && ind.bsClass != null) {
          classes.add(ind.bsClass!);
        }
      }
      for (final kn in kns) {
        for (final cls in classes) {
          final buySeries = expandBuyNLabelsToSeries(
            buyHist[kn] ?? const [],
            barCount,
            maxX: asOf,
            cls: cls,
          );
          final sellSeries = expandSellNLabelsToSeries(
            sellHist[kn] ?? const [],
            barCount,
            maxX: asOf,
            cls: cls,
          );
          for (final b in bars) {
            final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
            final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
                as Map<String, dynamic>;
            if (b.idx >= 0 &&
                b.idx < buySeries.length &&
                buySeries[b.idx] != null) {
              sub['buyN_${kn}_$cls'] = buySeries[b.idx];
            }
            if (b.idx >= 0 &&
                b.idx < sellSeries.length &&
                sellSeries[b.idx] != null) {
              sub['sellN_${kn}_$cls'] = sellSeries[b.idx];
            }
          }
        }
      }
    }

    // 方案B：峰距键与 display 对齐；K0→_0；structure L≥1 → fractal_peak_dist_L
    for (final f in barFeatures) {
      final row = byIdx.putIfAbsent(f.idx, () => {'idx': f.idx});
      final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
          as Map<String, dynamic>;
      sub['fractal_peak_dist'] = f.fractalPeakDist;
      sub['fractal_peak_dist_0'] = f.fractalPeakDist;
    }
    for (final bundle in levels) {
      // structure 0=K0连线，峰距已由 barFeatures 写好，跳过覆盖
      if (bundle.level < 1 || bars.isEmpty) continue;
      final series = _peakDistSeries(bars.length, bundle.confirms);
      for (var i = 0; i < bars.length; i++) {
        final row = byIdx.putIfAbsent(bars[i].idx, () => {'idx': bars[i].idx});
        (row['sub'] as Map<String, dynamic>)['fractal_peak_dist_${bundle.level}'] =
            series[i];
      }
    }

    // 方案B：分型判断 kn=0..levels.length（0=K0；L=structure L 的 Kn连线分型）
    // tooltip 与副图同源：judgmentHistoryByKn[kn] + asOf 截断。
    if (bars.isNotEmpty) {
      for (var kn = 0; kn <= levels.length; kn++) {
        final history = judgmentHistoryByKn[kn];
        final fxSeries = history != null && history.isNotEmpty
            ? expandJudgmentEventsToSeries(history, bars.last.idx + 1,
                maxX: asOf)
            : const <String>[];
        final truncSeries = history != null && history.isNotEmpty
            ? expandJudgmentEventsToTruncSeries(history, bars.last.idx + 1,
                maxX: asOf)
            : const <bool>[];
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final fx = b.idx >= 0 && b.idx < fxSeries.length
              ? fxSeries[b.idx]
              : 'UNKNOWN';
          (row['sub'] as Map<String, dynamic>)['fractal_judgment_$kn'] = fx;
          final trunc = b.idx >= 0 && b.idx < truncSeries.length
              ? truncSeries[b.idx]
              : false;
          (row['sub'] as Map<String, dynamic>)['fractal_judgment_trunc_$kn'] =
              trunc;
        }
      }
    }

    // Kn中枢判断/确定：会话历史写入 sub（与副图同源；asOf 截断）
    if (bars.isNotEmpty) {
      final barCount = bars.last.idx + 1;
      for (final e in zsJudgmentHistoryByKn.entries) {
        final series =
            expandZsSignalToSeries(e.value, barCount, maxX: asOf);
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          sub['zs_judgment_${e.key}'] =
              b.idx >= 0 && b.idx < series.length ? series[b.idx] : 0;
        }
      }
      for (final e in zsConfirmHistoryByKn.entries) {
        final series =
            expandZsSignalToSeries(e.value, barCount, maxX: asOf);
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          sub['zs_confirm_${e.key}'] =
              b.idx >= 0 && b.idx < series.length ? series[b.idx] : 0;
        }
      }
    }

    // Kn相邻比例 / 步进节奏 / 连线斜率：会话历史写入 sub（与副图同源；动态计算口径）
    if (bars.isNotEmpty) {
      final barCount = bars.last.idx + 1;
      for (final e in adjacentRatioHistoryByKn.entries) {
        final series = expandAdjacentRatioToSeries(e.value, barCount, maxX: asOf);
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (b.idx >= 0 &&
              b.idx < series.length &&
              series[b.idx] != null) {
            sub['adjacent_ratio_${e.key}'] = series[b.idx];
          }
        }
      }
      for (final e in stepRhythmHistoryByKn.entries) {
        for (final b in bars) {
          if (asOf != null && b.idx > asOf) continue;
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          // 同 K0 可多条节奏（0-0/0-1…）；tooltip 按动态名逐行显
          final at = e.value.where((p) => p.x == b.idx).toList();
          sub['step_rhythm_lines_${e.key}'] = [
            for (final p in at)
              {
                'label': p.label,
                'value': p.value,
                'ratio': p.ratio,
                'dir': p.dir,
              },
          ];
          sub['step_rhythm_${e.key}'] =
              formatStepRhythmReadout(e.value, b.idx);
        }
      }
      for (final e in lineSlopeHistoryByKn.entries) {
        final series = expandLineSlopeToSeries(e.value, barCount, maxX: asOf);
        for (final b in bars) {
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (b.idx >= 0 &&
              b.idx < series.length &&
              series[b.idx] != null) {
            sub['line_slope_${e.key}'] = series[b.idx];
          }
        }
      }
    }

    // Kn三型平移 / 四型对线 / 趋势线 / 数学 / 背驰：按柱 asOf 取近邻窗读数
    if (bars.isNotEmpty &&
        (k0Confirms.isNotEmpty ||
            levels.isNotEmpty ||
            zsK0Frames.isNotEmpty)) {
      var maxD = 0;
      var maxLevel = 0;
      for (final lv in levels) {
        final d = lv.level - 1;
        if (d > maxD) maxD = d;
        if (lv.level > maxLevel) maxLevel = lv.level;
      }
      for (var dkn = 0; dkn <= maxD; dkn++) {
        for (final b in bars) {
          if (asOf != null && b.idx > asOf) continue;
          final poles = collectLevelFxPoles(
            displayKn: dkn,
            bars: bars,
            k0Confirms: k0Confirms,
            levels: levels,
            asOf: b.idx,
          );
          // tip 读数=延长线落到本根 K0 的价格（非斜率）
          final tPx = triplePriceReadout(
            calcAllTripleGroups(poles),
            atX: b.idx,
            focusX: b.idx,
          );
          final q = quadPriceReadout(
            calcAllQuadGroups(poles),
            atX: b.idx,
            focusX: b.idx,
          );
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (tPx != null) sub['fx_triple_price_$dkn'] = tPx;
          if (q.top != null) sub['fx_quad_top_price_$dkn'] = q.top;
          if (q.bottom != null) sub['fx_quad_bottom_price_$dkn'] = q.bottom;
        }
      }
      // 趋势线：需父层 level=dkn+2，故 dkn 最大 maxLevel-2
      final trendMaxD = maxLevel >= 2 ? maxLevel - 2 : -1;
      for (var dkn = 0; dkn <= trendMaxD; dkn++) {
        for (final b in bars) {
          if (asOf != null && b.idx > asOf) continue;
          final tl = trendLinePriceReadout(
            calcTrendLineGroupsForLevel(
              displayKn: dkn,
              levels: levels,
              asOf: b.idx,
            ),
            atX: b.idx,
            focusX: b.idx,
          );
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (tl.support != null) {
            sub['trend_support_price_$dkn'] = tl.support;
          }
          if (tl.resistance != null) {
            sub['trend_resist_price_$dkn'] = tl.resistance;
          }
        }
      }

      // 均线 / 通道：优先读会话冻结仓（Kn≥1 禁整表回写）
      final meanMaxD = maxLevel;
      for (var dkn = 0; dkn <= meanMaxD; dkn++) {
        final means = mathFreezeStore?.mean(dkn) ??
            computeMeanSeriesForLevel(
              displayKn: dkn,
              bars: bars,
              levels: levels,
              periods: trendModelConfig.meanPeriods,
              asOf: asOf,
            );
        final chans = mathFreezeStore?.channel(dkn) ??
            computeChannelSeriesForLevel(
              displayKn: dkn,
              bars: bars,
              levels: levels,
              periods: trendModelConfig.channelPeriods,
              asOf: asOf,
            );
        for (final b in bars) {
          if (asOf != null && b.idx > asOf) continue;
          final row = byIdx.putIfAbsent(b.idx, () => {'idx': b.idx});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          final meanParts = <String>[];
          for (final t in (means.keys.toList()..sort())) {
            final series = means[t]!;
            if (b.idx >= 0 && b.idx < series.length && series[b.idx] != null) {
              final v = series[b.idx]!;
              sub['mean_${dkn}_$t'] = v;
              meanParts.add('$t:${v.toStringAsFixed(2)}');
            }
          }
          if (meanParts.isNotEmpty) {
            sub['mean_text_$dkn'] = meanParts.join(' ');
          }
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
        }
      }

      // MACD/BOLL/RSI/KDJ/Demark：优先读会话冻结仓
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
                levels: levels,
                config: mathIndicatorConfig,
                asOf: asOf,
              );
        final demark = mathFreezeStore?.demark(dkn) ??
            computeDemarkForLevel(
              displayKn: dkn,
              bars: bars,
              levels: levels,
              config: mathIndicatorConfig,
              asOf: asOf,
            );
        for (final b in bars) {
          if (asOf != null && b.idx > asOf) continue;
          final i = b.idx;
          final row = byIdx.putIfAbsent(i, () => {'idx': i});
          final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
              as Map<String, dynamic>;
          if (i >= 0 && i < classic.macd.dif.length) {
            final dif = classic.macd.dif[i];
            final dea = classic.macd.dea[i];
            final hist = classic.macd.macd[i];
            if (dif != null) sub['macd_dif_$dkn'] = dif;
            if (dea != null) sub['macd_dea_$dkn'] = dea;
            if (hist != null) sub['macd_hist_$dkn'] = hist;
          }
          if (i >= 0 && i < classic.boll.mid.length) {
            final mid = classic.boll.mid[i];
            final up = classic.boll.up[i];
            final down = classic.boll.down[i];
            if (mid != null) sub['boll_mid_$dkn'] = mid;
            if (up != null) sub['boll_up_$dkn'] = up;
            if (down != null) sub['boll_down_$dkn'] = down;
          }
          if (i >= 0 && i < classic.rsi.length) {
            final rsi = classic.rsi[i];
            if (rsi != null) sub['rsi_$dkn'] = rsi;
          }
          if (i >= 0 && i < classic.kdj.k.length) {
            final k = classic.kdj.k[i];
            final d = classic.kdj.d[i];
            final j = classic.kdj.j[i];
            if (k != null) sub['kdj_k_$dkn'] = k;
            if (d != null) sub['kdj_d_$dkn'] = d;
            if (j != null) sub['kdj_j_$dkn'] = j;
          }
          if (i >= 0 && i < demark.marksAt.length) {
            final marks = demark.marksAt[i];
            if (marks != null && marks.isNotEmpty) {
              sub['demark_text_$dkn'] = formatDemarkMarks(marks);
            }
          }
        }

        // 背驰：优先读冻结仓；无仓再现场算（本层力度）
        final frozenDiver = diverFreezeStore?.level(dkn);
        final diverMap = frozenDiver != null
            ? truncateDivergenceMap(frozenDiver, bars.length, asOf: asOf)
            : computeDivergenceForLevel(
                displayKn: dkn,
                bars: bars,
                levels: levels,
                zsK0Frames: zsK0Frames,
                config: mathIndicatorConfig,
                asOf: asOf,
                mathFreezeStore: mathFreezeStore,
              );
        for (final algo in DivergenceAlgoMeta.all) {
          final series = diverMap[algo];
          if (series == null) continue;
          for (final b in bars) {
            if (asOf != null && b.idx > asOf) continue;
            final i = b.idx;
            final row = byIdx.putIfAbsent(i, () => {'idx': i});
            final sub = row.putIfAbsent('sub', () => <String, dynamic>{})
                as Map<String, dynamic>;
            if (i >= 0 && i < series.inAt.length) {
              final vin = series.inAt[i];
              final vout = series.outAt[i];
              final vr = series.ratioAt[i];
              final vf = series.diverAt[i];
              if (vin != null) {
                sub[diverFeatureKey(algo, 'in', dkn)] = vin;
              }
              if (vout != null) {
                sub[diverFeatureKey(algo, 'out', dkn)] = vout;
              }
              if (vr != null) {
                sub[diverFeatureKey(algo, 'ratio', dkn)] = vr;
              }
              sub[diverFeatureKey(algo, 'flag', dkn)] = vf;
            }
          }
        }
      }
    }

    return BarFeatureLookup._(
      byIdx: byIdx,
      totalLevels: levels.length,
      zsAfterK0: zsAfterK0,
      knZsAfterKn: knZsAfterKn,
    );
  }

  Map<String, dynamic>? operator [](int idx) => byIdx[idx];

  Map<String, dynamic>? at(int idx) => byIdx[idx];

  /// 星期中文 → w1..w7（周一=w1 … 周六=w6，周日=w7）。
  static String weekdayToW(String weekday) {
    const map = {
      '周一': 'w1',
      '周二': 'w2',
      '周三': 'w3',
      '周四': 'w4',
      '周五': 'w5',
      '周六': 'w6',
      '周日': 'w7',
    };
    return map[weekday] ?? weekday;
  }

  static String _fmtPrice(double v) => v.toStringAsFixed(2);

  static String _fmtVol(num vol) => vol == vol.roundToDouble()
      ? vol.toInt().toString()
      : vol.toStringAsFixed(2);

  /// Demark 单标记文案：S1…S9 / C1…C13 / 完成买|完成卖
  static String formatDemarkMark(DemarkMark m) {
    if (m.type == 'complete') {
      return m.dir < 0 ? '完成买' : '完成卖';
    }
    final prefix = m.type == 'setup' ? 'S' : 'C';
    return '$prefix${m.idx}';
  }

  /// Demark 标记文案：多标记空格拼接（十字 tip）。
  static String formatDemarkMarks(List<DemarkMark> marks) {
    return orderDemarkMarksForPaint(marks).map(formatDemarkMark).join(' ');
  }

  /// setup → countdown → 完成信号（同 K0 多标记上下排）。
  static List<DemarkMark> orderDemarkMarksForPaint(List<DemarkMark> marks) {
    int rank(String t) {
      if (t == 'setup') return 0;
      if (t == 'countdown') return 1;
      return 2;
    }

    final out = List<DemarkMark>.from(marks);
    out.sort((a, b) {
      final c = rank(a.type).compareTo(rank(b.type));
      if (c != 0) return c;
      return a.idx.compareTo(b.idx);
    });
    return out;
  }

  /// VOL/笔数 B/S/G 片段（G=gray）；经 boxNumInString 后为 B【】/S【】/G【】。
  static String _fmtBsg({required num b, required num s, required num g}) =>
      'B${_fmtVol(b)}/S${_fmtVol(s)}/G${_fmtVol(g)}';

  /// OHLC 独立；成交量另起「Kn成交量」行（B/S/G）。
  static String _fmtOhlc({
    required double open,
    required double high,
    required double low,
    required double close,
  }) {
    return 'O${_fmtPrice(open)}/H${_fmtPrice(high)}/L${_fmtPrice(low)}/C${_fmtPrice(close)}';
  }

  /// 同层类别块用 `-。-` 拼接；层末不挂尾分隔（下一层只用 ===）。
  static List<CrosshairTooltipRow> _joinCategories(
      List<List<CrosshairTooltipRow>> cats) {
    final nonempty = [for (final c in cats) if (c.isNotEmpty) c];
    final out = <CrosshairTooltipRow>[];
    for (var i = 0; i < nonempty.length; i++) {
      if (i > 0) out.add(const CrosshairTooltipRow.starSeparator());
      out.addAll(nonempty[i]);
    }
    return out;
  }

  ({num b, num s, num g}) _volBsg(Map? sub, int kn, {num? totalFallback}) {
    final b = (sub?['buy_volume_$kn'] as num?) ?? 0;
    final s = (sub?['sell_volume_$kn'] as num?) ?? 0;
    final g = (sub?['gray_volume_$kn'] as num?) ?? 0;
    if (b == 0 && s == 0 && g == 0 && totalFallback != null) {
      return (b: 0, s: 0, g: totalFallback);
    }
    return (b: b, s: s, g: g);
  }

  ({num b, num s, num g}) _tickBsg(Map? sub, int kn) {
    return (
      b: (sub?['buy_tick_count_$kn'] as num?) ?? 0,
      s: (sub?['sell_tick_count_$kn'] as num?) ?? 0,
      g: (sub?['gray_tick_count_$kn'] as num?) ?? 0,
    );
  }

  static List<CrosshairTooltipRow> _peakCategoryRows(
    String prefix,
    List<ProfilePeakRow> peaks,
  ) {
    if (peaks.isEmpty) return const [];
    return [
      for (final p in peaks)
        CrosshairTooltipRow.kv(p.label(prefix), p.valueText()),
    ];
  }

  /// 十字线主 tooltip 结构化行（表格渲染用）。
  /// 应显尽显：不按副图/主图勾选过滤；层内用 `-。-`，层间只用 `===`。
  /// [chipPeaks]/[tickPeaks] 仅 K0：筹码峰 / 笔数峰动态名。
  List<CrosshairTooltipRow> crosshairTooltipRows(
    int idx, {
    required String timePart,
    Set<SubChartIndicator> subIndicators = const {},
    List<ProfilePeakRow> chipPeaks = const [],
    List<ProfilePeakRow> tickPeaks = const [],
  }) {
    final row = byIdx[idx];
    if (row == null) return const [];

    final weekday = weekdayToW(row['weekday'] as String? ?? '-');
    final mergeInner = row['merge_inner_seq'] ?? 0;
    final mergeBoxSeq = row['merge_box_seq'] ?? 0;

    final open = (row['open'] as num?)?.toDouble() ?? 0;
    final high = (row['high'] as num?)?.toDouble() ?? 0;
    final low = (row['low'] as num?)?.toDouble() ?? 0;
    final close = (row['close'] as num?)?.toDouble() ?? 0;
    final subMap = row['sub'] is Map ? row['sub'] as Map : null;
    final vol0 = (subMap?['volume_0'] as num?) ?? ((row['volume'] as num?) ?? 0);
    final vBsg = _volBsg(subMap, 0, totalFallback: vol0);
    final tBsg = _tickBsg(subMap, 0);
    final combineHigh = (row['combine_high'] as num?)?.toDouble() ?? high;
    final combineLow = (row['combine_low'] as num?)?.toDouble() ?? low;
    final rangeHigh = (row['combine_range_high'] as num?)?.toDouble();
    final rangeLow = (row['combine_range_low'] as num?)?.toDouble();

    // 原始K分型确认（=k0_confirms）；仅 ±1 显示，截断加"(截断)"，未确认为 0
    var combineFxConfirm = '0';
    final k0Confirm = row['k0_confirm'];
    if (k0Confirm is Map) {
      final v = k0Confirm['value'];
      if (v is num && (v == 1 || v == -1)) {
        combineFxConfirm = k0Confirm['truncated'] == true ? '$v(截断)' : '$v';
      }
    }
    // 方案B：K0分型判断与副图 kn=0 同源
    var combineFxJudge = '0';
    final fx0 = subMap?['fractal_judgment_0'];
    if (fx0 == 'TOP') {
      combineFxJudge =
          subMap?['fractal_judgment_trunc_0'] == true ? '-1(截断)' : '-1';
    } else if (fx0 == 'BOTTOM') {
      combineFxJudge =
          subMap?['fractal_judgment_trunc_0'] == true ? '1(截断)' : '1';
    }

    final k0Core = <CrosshairTooltipRow>[
      CrosshairTooltipRow.kv('K0 idx', CrosshairTooltipRow.boxNum(row['idx'])),
      CrosshairTooltipRow.kv(
        'K0',
        CrosshairTooltipRow.boxNumInString(_fmtOhlc(
          open: open,
          high: high,
          low: low,
          close: close,
        )),
      ),
      CrosshairTooltipRow.kv(
        'K0成交量',
        CrosshairTooltipRow.boxNumInString(
            _fmtBsg(b: vBsg.b, s: vBsg.s, g: vBsg.g)),
      ),
      CrosshairTooltipRow.kv(
        'K0笔数',
        CrosshairTooltipRow.boxNumInString(
            _fmtBsg(b: tBsg.b, s: tBsg.s, g: tBsg.g)),
      ),
    ];
    final k0Merge = <CrosshairTooltipRow>[
      ..._mergeRows(
        label: 'K0合并',
        gg: rangeHigh ?? combineHigh,
        dd: rangeLow ?? combineLow,
        mg: _frameBox(row['combine'], fallback: combineHigh),
        md: _frameBox(row['combine'], fallback: combineLow, useLow: true),
      ),
      CrosshairTooltipRow.kv(
          'K0合并K0 idx', CrosshairTooltipRow.boxNum(mergeInner)),
      CrosshairTooltipRow.kv('K0合并 idx',
          mergeBoxSeq >= 0 ? CrosshairTooltipRow.boxNum(mergeBoxSeq) : '未成框'),
      CrosshairTooltipRow.kv(
          'K0分型确认', CrosshairTooltipRow.boxNum(combineFxConfirm)),
      CrosshairTooltipRow.kv(
          'K0分型判断', CrosshairTooltipRow.boxNum(combineFxJudge)),
    ];
    // subIndicators 参数保留兼容；显示侧忽略勾选，按层应显尽显
    final k0Cats = _levelCategoryExtras(idx, 0);
    final chipPeakRows = _peakCategoryRows('K0筹码峰', chipPeaks);
    final tickPeakRows = _peakCategoryRows('K0笔数峰', tickPeaks);

    final out = <CrosshairTooltipRow>[
      CrosshairTooltipRow.kv('日期时间', '$timePart     $weekday'),
      const CrosshairTooltipRow.separator(),
      ..._joinCategories([
        k0Core,
        chipPeakRows,
        tickPeakRows,
        k0Merge,
        zsAfterK0,
        k0Cats.fxExtra,
        k0Cats.bs,
        k0Cats.ratioRhythm,
      ]),
      ..._levelBlockRows(idx),
    ];
    return out;
  }

  /// 扁平字符串列表（测试/历史快照兼容）。
  List<String> crosshairTooltipLines(int idx, {required String timePart}) {
    return crosshairTooltipRows(idx, timePart: timePart).map((e) => e.flat).toList();
  }

  List<String> crosshairSubLines(int idx, Set<SubChartIndicator> active) {
    return crosshairSubRows(idx, active).map((e) => e.flat).toList();
  }

  List<CrosshairTooltipRow> crosshairSubRows(
    int idx,
    Set<SubChartIndicator> active,
  ) {
    final row = byIdx[idx];
    if (row == null) return const [];
    final sub = row['sub'];
    if (sub is! Map || sub.isEmpty) return const [];

    final lines = <CrosshairTooltipRow>[];
    void add(String label, dynamic v) {
      if (v == null) return;
      lines.add(CrosshairTooltipRow.kv(label, '$v'));
    }

    for (final ind in active) {
      if (ind.kind == SubIndicatorKind.volume) {
        final key = 'volume_${ind.kn}';
        if (sub.containsKey(key)) {
          add(ind.label, sub[key]);
        } else if (ind.kn <= 0) {
          // 回退：旧 volume 字段
          add(ind.label, sub['volume'] ?? row['volume']);
        }
      }
      // Kn笔数：优先真实 tick_count（Rust 第4列求和）；无则回退买笔数标记不显示
      if (ind.kind == SubIndicatorKind.tickCount) {
        final key = 'tick_count_${ind.kn}';
        if (sub.containsKey(key)) {
          final v = sub[key];
          add(ind.label, v);
        }
      }
      // 筹码已迁设置面板控制（仅K0），不走副图读数
      if (ind.kind == SubIndicatorKind.fractalConfirm) {
        dynamic v;
        var truncated = false;
        // 方案B：kn==0→k0；kn≥1→level_confirms[kn]
        if (ind.kn == 0) {
          v = sub['k0_confirm_value'];
          final bc = row['k0_confirm'];
          if (bc is Map) truncated = bc['truncated'] == true;
        } else {
          final confirms = row['level_confirms'];
          if (confirms is Map && confirms.containsKey(ind.kn)) {
            final c = confirms[ind.kn];
            if (c is LevelConfirm) {
              v = c.value;
              truncated = c.truncated;
            } else if (c is Map) {
              v = c['value'];
              truncated = c['truncated'] == true;
            }
          }
        }
        add(ind.label, v == null ? '0' : (truncated ? '$v(截断)' : '$v'));
      }
      if (ind.kind == SubIndicatorKind.fractalJudgment) {
        final fx = sub['fractal_judgment_${ind.kn}'];
        // 与主 tooltip K 块同口径：TOP→-1，BOTTOM→+1，未确认(UNKNOWN)→0；
        // 截断加"(截断)"。使副图 tooltip 行 / 副图读数框 与主 K 块一致（不再用 TOP/BOTTOM 串）。
        String v;
        if (fx == 'TOP') {
          v = '-1';
        } else if (fx == 'BOTTOM') {
          v = '1';
        } else {
          v = '0';
        }
        final truncated = sub['fractal_judgment_trunc_${ind.kn}'] == true;
        add(ind.label, truncated ? '$v(截断)' : v);
      }
      if (ind.kind == SubIndicatorKind.zsConfirm) {
        add(ind.label, sub['zs_confirm_${ind.kn}'] ?? 0);
      }
      if (ind.kind == SubIndicatorKind.zsJudgment) {
        add(ind.label, sub['zs_judgment_${ind.kn}'] ?? 0);
      }
      if (ind.kind == SubIndicatorKind.fractalPeakDist) {
        // 方案B：kn==0 优先 feat；kn≥1 读 fractal_peak_dist_{kn}
        if (ind.kn == 0) {
          add(ind.label, sub['fractal_peak_dist_0'] ?? sub['fractal_peak_dist']);
        } else if (sub.containsKey('fractal_peak_dist_${ind.kn}')) {
          add(ind.label, sub['fractal_peak_dist_${ind.kn}']);
        }
      }
      if (ind.kind == SubIndicatorKind.truncation) {
        // 方案B：kn==0 只读 k0_confirm；kn≥1 读 level_confirms[kn]
        dynamic v;
        if (ind.kn == 0) {
          final bc = row['k0_confirm'];
          if (bc is Map && bc['truncated'] == true) {
            v = bc['value'];
          }
        } else {
          final confirms = row['level_confirms'];
          if (confirms is Map && confirms.containsKey(ind.kn)) {
            final c = confirms[ind.kn];
            if (c is LevelConfirm && c.truncated) {
              v = c.value;
            } else if (c is Map && c['truncated'] == true) {
              v = c['value'];
            }
          }
        }
        add(ind.label, v);
      }
      if (ind.kind == SubIndicatorKind.buy1) {
        final buy = sub['buy1_${ind.kn}'];
        final sell = sub['sell1_${ind.kn}'];
        if (buy != null || sell != null) {
          final parts = <String>[
            if (buy != null) '$buy',
            if (sell != null) '$sell',
          ];
          add(ind.label, parts.join(' '));
        } else {
          add(ind.label, null);
        }
      }
      if (ind.kind == SubIndicatorKind.buy2) {
        final buy = sub['buy2_${ind.kn}'];
        final sell = sub['sell2_${ind.kn}'];
        if (buy != null || sell != null) {
          final parts = <String>[
            if (buy != null) '$buy',
            if (sell != null) '$sell',
          ];
          add(ind.label, parts.join(' '));
        } else {
          add(ind.label, null);
        }
      }
      if (ind.kind == SubIndicatorKind.buyN) {
        final cls = ind.bsClass ?? 3;
        final buy = sub['buyN_${ind.kn}_$cls'];
        final sell = sub['sellN_${ind.kn}_$cls'];
        if (buy != null || sell != null) {
          final parts = <String>[
            if (buy != null) '$buy',
            if (sell != null) '$sell',
          ];
          add(ind.label, parts.join(' '));
        } else {
          add(ind.label, null);
        }
      }
      if (ind.kind == SubIndicatorKind.adjacentRatio) {
        final v = sub['adjacent_ratio_${ind.kn}'];
        if (v is num) {
          add(ind.label, v.toStringAsFixed(3));
        } else {
          add(ind.label, '0');
        }
      }
      if (ind.kind == SubIndicatorKind.stepRhythm) {
        add(ind.label, sub['step_rhythm_${ind.kn}'] ?? '0');
      }
      if (ind.kind == SubIndicatorKind.lineSlope) {
        final v = sub['line_slope_${ind.kn}'];
        if (v is num) {
          add(ind.label, v.toStringAsFixed(4));
        } else {
          add(ind.label, '0');
        }
      }
      if (ind.kind == SubIndicatorKind.macd) {
        final dif = sub['macd_dif_${ind.kn}'];
        final dea = sub['macd_dea_${ind.kn}'];
        final hist = sub['macd_hist_${ind.kn}'];
        if (dif is num || dea is num || hist is num) {
          final parts = <String>[
            if (dif is num) 'DIF${dif.toStringAsFixed(3)}',
            if (dea is num) 'DEA${dea.toStringAsFixed(3)}',
            if (hist is num) 'MACD${hist.toStringAsFixed(3)}',
          ];
          add(ind.label, parts.join('/'));
        } else {
          add(ind.label, '0');
        }
      }
      if (ind.kind == SubIndicatorKind.rsi) {
        final v = sub['rsi_${ind.kn}'];
        add(ind.label, v is num ? v.toStringAsFixed(2) : '0');
      }
      if (ind.kind == SubIndicatorKind.divergence && ind.diverAlgo != null) {
        final algo = ind.diverAlgo!;
        final vin = sub[diverFeatureKey(algo, 'in', ind.kn)];
        final vout = sub[diverFeatureKey(algo, 'out', ind.kn)];
        final vr = sub[diverFeatureKey(algo, 'ratio', ind.kn)];
        final vf = sub[diverFeatureKey(algo, 'flag', ind.kn)];
        if (vin is num || vout is num || vr is num || vf is num) {
          final parts = <String>[
            if (vin is num) 'in${vin.toStringAsFixed(4)}',
            if (vout is num) 'out${vout.toStringAsFixed(4)}',
            if (vr is num) 'r${vr.toStringAsFixed(4)}',
            'd${vf is num ? vf.toInt() : 0}',
          ];
          add(ind.label, parts.join('/'));
        } else {
          add(ind.label, '0');
        }
      }
      if (ind.kind == SubIndicatorKind.kdj) {
        final k = sub['kdj_k_${ind.kn}'];
        final d = sub['kdj_d_${ind.kn}'];
        final j = sub['kdj_j_${ind.kn}'];
        if (k is num || d is num || j is num) {
          final parts = <String>[
            if (k is num) 'K${k.toStringAsFixed(2)}',
            if (d is num) 'D${d.toStringAsFixed(2)}',
            if (j is num) 'J${j.toStringAsFixed(2)}',
          ];
          add(ind.label, parts.join('/'));
        } else {
          add(ind.label, '0');
        }
      }
    }
    return lines;
  }

  /// Kn 块（K1=K0连线，K2=K1连线，…）；每层前仅 `===`（不挂类别尾分隔）。
  List<CrosshairTooltipRow> _levelBlockRows(int idx) {
    final row = byIdx[idx];
    if (row == null) return const [];

    final snaps = row['levels'];
    final confirms = row['level_confirms'];
    final sub = row['sub'];
    final snapList = snaps is List<LevelSnap> ? snaps : const <LevelSnap>[];
    final total = totalLevels > snapList.length ? totalLevels : snapList.length;
    final subMap = sub is Map ? sub : null;

    final lines = <CrosshairTooltipRow>[];
    // 方案B：Kn块 n=1..；snap.level==n-1；分型确认/判断键=structure n（Kn连线）
    for (var n = 1; n <= total; n++) {
      LevelSnap? snap;
      for (final s in snapList) {
        if (s.level == n - 1) {
          snap = s;
          break;
        }
      }
      int? confirmVal;
      var confirmTruncated = false;
      if (confirms is Map) {
        final v = confirms[n];
        if (v is LevelConfirm && (v.value == 1 || v.value == -1)) {
          confirmVal = v.value;
          confirmTruncated = v.truncated;
        }
      }
      int? judgeVal;
      var judgeTruncated = false;
      final fx = subMap?['fractal_judgment_$n'];
      if (fx == 'TOP') {
        judgeVal = -1;
      } else if (fx == 'BOTTOM') {
        judgeVal = 1;
      }
      if (judgeVal != null) {
        judgeTruncated = subMap?['fractal_judgment_trunc_$n'] == true;
      }
      final knVol = (subMap?['volume_$n'] as num?) ?? snap?.unitVolume;
      final vBsg = _volBsg(subMap, n, totalFallback: knVol);
      final tBsg = _tickBsg(subMap, n);
      lines.add(const CrosshairTooltipRow.separator());
      final box = row['combine_box_$n'];
      final cats = _levelCategoryExtras(idx, n);
      lines.addAll(_levelBlockRowsFor(
        n,
        snap,
        confirmVal,
        confirmTruncated,
        judgeVal,
        judgeTruncated,
        buyVol: vBsg.b,
        sellVol: vBsg.s,
        grayVol: vBsg.g,
        buyTick: tBsg.b,
        sellTick: tBsg.s,
        grayTick: tBsg.g,
        combineBoxHigh: _frameBox(box, fallback: snap?.combineHigh ?? 0),
        combineBoxLow:
            _frameBox(box, fallback: snap?.combineLow ?? 0, useLow: true),
        gg: (row['combine_range_high_$n'] as num?)?.toDouble(),
        dd: (row['combine_range_low_$n'] as num?)?.toDouble(),
        fxExtra: cats.fxExtra,
        bs: cats.bs,
        ratioRhythm: cats.ratioRhythm,
      ));
    }
    return lines;
  }

  /// 兼容旧调用：扁平 Kn 行。
  List<String> crosshairLevelLines(int idx) {
    return _levelBlockRows(idx)
        .where((e) => !e.isSeparator)
        .map((e) => e.flat)
        .toList();
  }

  List<CrosshairTooltipRow> _levelBlockRowsFor(
    int n,
    LevelSnap? snap,
    int? confirmVal,
    bool confirmTruncated,
    int? judgeVal,
    bool judgeTruncated, {
    required num buyVol,
    required num sellVol,
    required num grayVol,
    required num buyTick,
    required num sellTick,
    required num grayTick,
    double? combineBoxHigh,
    double? combineBoxLow,
    double? gg,
    double? dd,
    List<CrosshairTooltipRow> fxExtra = const [],
    List<CrosshairTooltipRow> bs = const [],
    List<CrosshairTooltipRow> ratioRhythm = const [],
  }) {
    final label = 'K$n';
    final confirmText = confirmVal == null
        ? '0'
        : (confirmTruncated ? '$confirmVal(截断)' : '$confirmVal');
    final judgeText = judgeVal == null
        ? '0'
        : (judgeTruncated ? '$judgeVal(截断)' : '$judgeVal');

    final List<CrosshairTooltipRow> core;
    final List<CrosshairTooltipRow> merge;
    if (snap == null || snap.unitIdx == null) {
      core = [
        CrosshairTooltipRow.kv('$label idx', '首K$n确认前'),
        CrosshairTooltipRow.kv(label, '—'),
        CrosshairTooltipRow.kv(
          '$label成交量',
          CrosshairTooltipRow.boxNumInString(
              _fmtBsg(b: buyVol, s: sellVol, g: grayVol)),
        ),
        CrosshairTooltipRow.kv(
          '$label笔数',
          CrosshairTooltipRow.boxNumInString(
              _fmtBsg(b: buyTick, s: sellTick, g: grayTick)),
        ),
      ];
      merge = [
        CrosshairTooltipRow.kv('$label合并', '—'),
        CrosshairTooltipRow.kv('$label合并$label idx', '—'),
        CrosshairTooltipRow.kv('$label合并 idx', '—'),
        CrosshairTooltipRow.kv(
            '$label分型确认', CrosshairTooltipRow.boxNum(confirmText)),
        CrosshairTooltipRow.kv(
            '$label分型判断', CrosshairTooltipRow.boxNum(judgeText)),
      ];
    } else {
      core = [
        CrosshairTooltipRow.kv(
            '$label idx', CrosshairTooltipRow.boxNum(snap.unitIdx)),
        CrosshairTooltipRow.kv(
          label,
          CrosshairTooltipRow.boxNumInString(_fmtOhlc(
            open: snap.unitOpen,
            high: snap.unitHigh,
            low: snap.unitLow,
            close: snap.unitClose,
          )),
        ),
        CrosshairTooltipRow.kv(
          '$label成交量',
          CrosshairTooltipRow.boxNumInString(
              _fmtBsg(b: buyVol, s: sellVol, g: grayVol)),
        ),
        CrosshairTooltipRow.kv(
          '$label笔数',
          CrosshairTooltipRow.boxNumInString(
              _fmtBsg(b: buyTick, s: sellTick, g: grayTick)),
        ),
      ];
      merge = [
        ..._mergeRows(
          label: '$label合并',
          gg: gg ?? snap.combineHigh,
          dd: dd ?? snap.combineLow,
          mg: combineBoxHigh ?? snap.combineHigh,
          md: combineBoxLow ?? snap.combineLow,
        ),
        CrosshairTooltipRow.kv('$label合并$label idx',
            CrosshairTooltipRow.boxNum(snap.mergeInnerSeq)),
        CrosshairTooltipRow.kv(
            '$label合并 idx',
            snap.mergeBoxSeq >= 0
                ? CrosshairTooltipRow.boxNum(snap.mergeBoxSeq)
                : '未成框'),
        CrosshairTooltipRow.kv(
            '$label分型确认', CrosshairTooltipRow.boxNum(confirmText)),
        CrosshairTooltipRow.kv(
            '$label分型判断', CrosshairTooltipRow.boxNum(judgeText)),
      ];
    }

    return _joinCategories([
      core,
      merge,
      knZsAfterKn[n] ?? const [],
      fxExtra,
      bs,
      ratioRhythm,
    ]);
  }

  /// 层内其它类别：极点距/截断 | X类BS | 比例+节奏（应显尽显，数值一律【】）。
  ({
    List<CrosshairTooltipRow> fxExtra,
    List<CrosshairTooltipRow> bs,
    List<CrosshairTooltipRow> ratioRhythm,
  }) _levelCategoryExtras(int idx, int displayKn) {
    final empty = (
      fxExtra: const <CrosshairTooltipRow>[],
      bs: const <CrosshairTooltipRow>[],
      ratioRhythm: const <CrosshairTooltipRow>[],
    );
    final row = byIdx[idx];
    if (row == null) return empty;
    final sub = row['sub'] is Map ? row['sub'] as Map : null;

    CrosshairTooltipRow kv(String label, String value) =>
        CrosshairTooltipRow.kv(label, value);

    // —— 极点距 / 截断 —— 方案B：键与 display 对齐
    final fxExtra = <CrosshairTooltipRow>[];
    dynamic peak;
    if (displayKn == 0) {
      peak = sub?['fractal_peak_dist_0'] ?? sub?['fractal_peak_dist'];
    } else {
      peak = sub == null ? null : sub['fractal_peak_dist_$displayKn'];
    }
    fxExtra.add(kv(
        'K$displayKn分型极点距', CrosshairTooltipRow.boxNum(peak ?? 0)));

    dynamic truncV;
    final confirms = row['level_confirms'];
    if (displayKn == 0) {
      final bc = row['k0_confirm'];
      if (bc is Map && bc['truncated'] == true) {
        truncV = bc['value'];
      }
    } else if (confirms is Map && confirms.containsKey(displayKn)) {
      final c = confirms[displayKn];
      if (c is LevelConfirm && c.truncated) {
        truncV = c.value;
      } else if (c is Map && c['truncated'] == true) {
        truncV = c['value'];
      }
    }
    fxExtra.add(
        kv('K$displayKn截断', CrosshairTooltipRow.boxNum(truncV ?? 0)));

    // —— X类BS（独立类别）——
    String bsVal(dynamic buy, dynamic sell) {
      if (buy == null && sell == null) return CrosshairTooltipRow.boxNum(0);
      final parts = <String>[
        if (buy != null) CrosshairTooltipRow.boxNum(buy),
        if (sell != null) CrosshairTooltipRow.boxNum(sell),
      ];
      return parts.join(' ');
    }

    final bs = <CrosshairTooltipRow>[
      kv('K$displayKn一类BS',
          bsVal(sub?['buy1_$displayKn'], sub?['sell1_$displayKn'])),
      kv('K$displayKn二类BS',
          bsVal(sub?['buy2_$displayKn'], sub?['sell2_$displayKn'])),
      for (var cls = 3; cls <= 9; cls++)
        kv(
          'K$displayKn${bsClassChinese(cls)}类BS',
          bsVal(sub?['buyN_${displayKn}_$cls'],
              sub?['sellN_${displayKn}_$cls']),
        ),
    ];

    // —— 比例 / 节奏 / 连线斜率（独立类别；节奏按 0-0 动态多行）——
    final ratioRhythm = <CrosshairTooltipRow>[];
    final ar = sub?['adjacent_ratio_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn比例',
      CrosshairTooltipRow.boxNum(
          ar is num ? ar.toStringAsFixed(3) : 0),
    ));
    final rhythmLines = sub?['step_rhythm_lines_$displayKn'];
    if (rhythmLines is List && rhythmLines.isNotEmpty) {
      for (final raw in rhythmLines) {
        if (raw is! Map) continue;
        final name = '${raw['label'] ?? '0-0'}';
        final v = raw['value'];
        final text = v is num ? v.toStringAsFixed(3) : '$v';
        ratioRhythm.add(kv(
          'K$displayKn节奏$name',
          CrosshairTooltipRow.boxNum(text),
        ));
      }
    } else {
      ratioRhythm.add(
          kv('K$displayKn节奏', CrosshairTooltipRow.boxNum(0)));
    }
    final slope = sub?['line_slope_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn连线斜率',
      CrosshairTooltipRow.boxNum(
          slope is num ? slope.toStringAsFixed(4) : 0),
    ));
    // 三型平移 / 四型对线：延长线落到本根 K0 的价格
    final triple = sub?['fx_triple_price_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn三型平移线',
      CrosshairTooltipRow.boxNum(
          triple is num ? triple.toStringAsFixed(2) : 0),
    ));
    final qTop = sub?['fx_quad_top_price_$displayKn'];
    final qBot = sub?['fx_quad_bottom_price_$displayKn'];
    if (qTop is num || qBot is num) {
      final parts = <String>[
        if (qTop is num) '顶${qTop.toStringAsFixed(2)}',
        if (qBot is num) '底${qBot.toStringAsFixed(2)}',
      ];
      ratioRhythm.add(kv(
        'K$displayKn四型对线',
        CrosshairTooltipRow.boxNum(parts.join(' ')),
      ));
    } else {
      ratioRhythm.add(
          kv('K$displayKn四型对线', CrosshairTooltipRow.boxNum(0)));
    }
    // 趋势线：支撑/压力延长线落到本根 K0 的价格
    final tSup = sub?['trend_support_price_$displayKn'];
    final tRes = sub?['trend_resist_price_$displayKn'];
    if (tSup is num || tRes is num) {
      final parts = <String>[
        if (tSup is num) '撑${tSup.toStringAsFixed(2)}',
        if (tRes is num) '压${tRes.toStringAsFixed(2)}',
      ];
      ratioRhythm.add(kv(
        'K$displayKn趋势线',
        CrosshairTooltipRow.boxNum(parts.join(' ')),
      ));
    } else {
      ratioRhythm.add(
          kv('K$displayKn趋势线', CrosshairTooltipRow.boxNum(0)));
    }
    final meanText = sub?['mean_text_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn均线',
      CrosshairTooltipRow.boxNum(meanText is String ? meanText : 0),
    ));
    final chanText = sub?['channel_text_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn通道',
      CrosshairTooltipRow.boxNum(chanText is String ? chanText : 0),
    ));
    // MACD / 布林 / RSI / KDJ / Demark
    final macdDif = sub?['macd_dif_$displayKn'];
    final macdDea = sub?['macd_dea_$displayKn'];
    final macdHist = sub?['macd_hist_$displayKn'];
    if (macdDif is num || macdDea is num || macdHist is num) {
      final parts = <String>[
        if (macdDif is num) 'DIF${macdDif.toStringAsFixed(3)}',
        if (macdDea is num) 'DEA${macdDea.toStringAsFixed(3)}',
        if (macdHist is num) 'MACD${macdHist.toStringAsFixed(3)}',
      ];
      ratioRhythm.add(kv('K$displayKn MACD', CrosshairTooltipRow.boxNum(parts.join('/'))));
    } else {
      ratioRhythm.add(kv('K$displayKn MACD', CrosshairTooltipRow.boxNum(0)));
    }
    final bMid = sub?['boll_mid_$displayKn'];
    final bUp = sub?['boll_up_$displayKn'];
    final bDn = sub?['boll_down_$displayKn'];
    if (bMid is num || bUp is num || bDn is num) {
      final parts = <String>[
        if (bMid is num) 'M${bMid.toStringAsFixed(2)}',
        if (bUp is num) 'U${bUp.toStringAsFixed(2)}',
        if (bDn is num) 'D${bDn.toStringAsFixed(2)}',
      ];
      ratioRhythm.add(kv('K$displayKn布林', CrosshairTooltipRow.boxNum(parts.join('/'))));
    } else {
      ratioRhythm.add(kv('K$displayKn布林', CrosshairTooltipRow.boxNum(0)));
    }
    final rsi = sub?['rsi_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn RSI',
      CrosshairTooltipRow.boxNum(rsi is num ? rsi.toStringAsFixed(2) : 0),
    ));
    final kdjK = sub?['kdj_k_$displayKn'];
    final kdjD = sub?['kdj_d_$displayKn'];
    final kdjJ = sub?['kdj_j_$displayKn'];
    if (kdjK is num || kdjD is num || kdjJ is num) {
      final parts = <String>[
        if (kdjK is num) 'K${kdjK.toStringAsFixed(2)}',
        if (kdjD is num) 'D${kdjD.toStringAsFixed(2)}',
        if (kdjJ is num) 'J${kdjJ.toStringAsFixed(2)}',
      ];
      ratioRhythm.add(kv('K$displayKn KDJ', CrosshairTooltipRow.boxNum(parts.join('/'))));
    } else {
      ratioRhythm.add(kv('K$displayKn KDJ', CrosshairTooltipRow.boxNum(0)));
    }
    final demarkText = sub?['demark_text_$displayKn'];
    ratioRhythm.add(kv(
      'K$displayKn Demark',
      CrosshairTooltipRow.boxNum(demarkText is String ? demarkText : 0),
    ));
    // 背驰 12 算法：in/out/ratio/diver(1|-1|0)
    for (final algo in DivergenceAlgoMeta.all) {
      final vin = sub?[diverFeatureKey(algo, 'in', displayKn)];
      final vout = sub?[diverFeatureKey(algo, 'out', displayKn)];
      final vr = sub?[diverFeatureKey(algo, 'ratio', displayKn)];
      final vf = sub?[diverFeatureKey(algo, 'flag', displayKn)];
      if (vin is num || vout is num || vr is num || vf is num) {
        final parts = <String>[
          if (vin is num) 'in${vin.toStringAsFixed(4)}',
          if (vout is num) 'out${vout.toStringAsFixed(4)}',
          if (vr is num) 'r${vr.toStringAsFixed(4)}',
          'd${vf is num ? vf.toInt() : 0}',
        ];
        ratioRhythm.add(kv(
          'K$displayKn背驰_${algo.key}',
          CrosshairTooltipRow.boxNum(parts.join('/')),
        ));
      } else {
        ratioRhythm.add(kv(
          'K$displayKn背驰_${algo.key}',
          CrosshairTooltipRow.boxNum(0),
        ));
      }
    }

    return (fxExtra: fxExtra, bs: bs, ratioRhythm: ratioRhythm);
  }

  /// 合并行：GG/DD=组内原始区间极值（原始K高低 max/min，逐K当下、无未来函数）；MG/MD=合并框框体高低点（M=merge）。
  List<CrosshairTooltipRow> _mergeRows({
    required String label,
    required double gg,
    required double dd,
    required double mg,
    required double md,
  }) {
    return [
      CrosshairTooltipRow.kv(
        label,
        CrosshairTooltipRow.boxNumInString(
            'GG${_fmtPrice(gg)}/DD${_fmtPrice(dd)}/MG${_fmtPrice(mg)}/MD${_fmtPrice(md)}'),
      ),
    ];
  }

  /// 取合并框框体高低点（row['combine'] / row['combine_box_n']）；无框体时回退极值。
  static double _frameBox(dynamic box, {required double fallback, bool useLow = false}) {
    if (box is Map) {
      final v = box[useLow ? 'low' : 'high'];
      if (v is num) return v.toDouble();
    }
    return fallback;
  }

  /// 由确认列表生成逐 K 极点距（确认当步起算；不含极点 K；对齐副图/Rust）。
  static List<int> _peakDistSeries(int barCount, List<LevelConfirm> confirms) {
    final out = List<int>.filled(barCount, 0);
    if (barCount <= 0) return out;
    var ptr = 0;
    int? extreme;
    for (var i = 0; i < barCount; i++) {
      while (ptr < confirms.length && confirms[ptr].x <= i) {
        final c = confirms[ptr];
        if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.poleX >= 0) {
          extreme = c.poleX;
        }
        ptr++;
      }
      out[i] = extreme == null ? 0 : i - extreme;
    }
    return out;
  }
}
