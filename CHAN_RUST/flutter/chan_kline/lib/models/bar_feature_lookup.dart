import 'bi_confirm_signal.dart';

import 'bar_crosshair_feature.dart';

import 'bi_segment.dart';

import 'kline_bar.dart';

import 'kline_combine_frame.dart';

import 'seg_analysis.dart';



/// 逐 K 字典式特征索引（ML / 十字线 tooltip 同源，均用 barFeatures 逐步冻结 bi_*）。

class BarFeatureLookup {

  BarFeatureLookup._({required this.byIdx});



  final Map<int, Map<String, dynamic>> byIdx;



  factory BarFeatureLookup.build({

    required List<KlineBar> bars,

    required List<KlineCombineFrame> combineFrames,

    required List<BiConfirmSignal> biConfirms,

    List<BarCrosshairFeature> barFeatures = const [],

    List<BiSegment> biSegments = const [],

    SegAnalysisBundle segAnalysis = const SegAnalysisBundle(),

    Set<SubChartIndicator> subIndicators = const {},

  }) {

    final byIdx = <int, Map<String, dynamic>>{};

    final featureByIdx = {for (final f in barFeatures) f.idx: f};



    for (final b in bars) {

      final feat = featureByIdx[b.idx];

      byIdx[b.idx] = {

        'idx': b.idx,

        'time_ms': b.timeMs,

        'time_text': b.timeText,

        'weekday': feat?.weekday ?? '-',

        'merge_inner_seq': feat?.mergeInnerSeq ?? 1,

        'merge_count': feat?.mergeCount ?? 1,

        'combine_fx': feat?.combineFx ?? 'UNKNOWN',

        'combine_high': feat?.combineHigh ?? b.high,

        'combine_low': feat?.combineLow ?? b.low,

        'bi_idx': feat?.biIdx,

        'bi_merge_inner_seq': feat?.biMergeInnerSeq ?? 1,

        'bi_merge_count': feat?.biMergeCount ?? 1,

        'bi_open': feat?.biOpen ?? 0,

        'bi_high': feat?.biHigh ?? 0,

        'bi_low': feat?.biLow ?? 0,

        'bi_close': feat?.biClose ?? 0,

        'bi_volume': feat?.biVolume ?? 0,

        'bi_combine_high': feat?.biCombineHigh ?? 0,

        'bi_combine_low': feat?.biCombineLow ?? 0,

        'bi_combine_fx': feat?.biCombineFx ?? 'UNKNOWN',

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

    for (final f in combineFrames) {

      for (var x = f.x1; x <= f.x2; x++) {

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

      }

    }



    if (subIndicators.contains(SubChartIndicator.klineCombine)) {

      for (final row in byIdx.values) {

        (row['sub'] as Map<String, dynamic>)['combine_fx'] = row['combine_fx'];

        (row['sub'] as Map<String, dynamic>)['combine_count'] = row['merge_count'];

      }

    }



    for (final sig in biConfirms) {

      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});

      row['bi_confirm'] = {

        'x': sig.x,

        'fx': sig.fx,

        'value': sig.value,

        'fractal_x1': sig.fractalX1,

        'fractal_x2': sig.fractalX2,

      };

      if (subIndicators.contains(SubChartIndicator.biConfirm)) {

        (row['sub'] as Map<String, dynamic>)['bi_confirm_value'] = sig.value;

      }

    }



    for (final sig in segAnalysis.segConfirms) {

      if (sig.fx != 'TOP' && sig.fx != 'BOTTOM') continue;

      if (sig.value == 0) continue;

      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});

      row['seg_confirm_signal'] = {

        'x': sig.x,

        'fx': sig.fx,

        'value': sig.value,

        'peak_bi_idx': sig.peakBiIdx,

        'fractal_x1': sig.fractalX1,

        'fractal_x2': sig.fractalX2,

      };

      if (subIndicators.contains(SubChartIndicator.segConfirm)) {

        (row['sub'] as Map<String, dynamic>)['seg_confirm'] = sig.value;

      }

    }



    for (final seg in biSegments) {

      for (var x = seg.beginConfirmX; x <= seg.endConfirmX; x++) {

        final row = byIdx.putIfAbsent(x, () => {'idx': x});

        row['bi_segment'] = {

          'idx': seg.idx,

          'dir': seg.dir,

          'begin_confirm_x': seg.beginConfirmX,

          'end_confirm_x': seg.endConfirmX,

          'prev_idx': seg.prevIdx,

          'next_idx': seg.nextIdx,

        };

      }

    }



    for (final snap in segAnalysis.barSubSnapshots) {

      final row = byIdx.putIfAbsent(snap.idx, () => {'idx': snap.idx});

      row['seg_snapshot'] = {

        'building_seg_dir': snap.buildingSegDir,

        'first_seg_dir': snap.firstSegDir,

        'seg_confirm': snap.segConfirm,
      };

      if (subIndicators.contains(SubChartIndicator.firstSegDir) &&

          snap.firstSegDir != 0) {

        (row['sub'] as Map<String, dynamic>)['first_seg_dir'] = snap.firstSegDir;

      }

      if (subIndicators.contains(SubChartIndicator.segConfirm) &&

          snap.segConfirm != 0) {

        (row['sub'] as Map<String, dynamic>)['seg_confirm'] = snap.segConfirm;

      }

    }



    if (subIndicators.contains(SubChartIndicator.volume)) {

      for (final row in byIdx.values) {

        (row['sub'] as Map<String, dynamic>)['volume'] = row['volume'];

      }

    }



    if (subIndicators.contains(SubChartIndicator.fractalPeakDist)) {

      for (final f in barFeatures) {

        final row = byIdx.putIfAbsent(f.idx, () => {'idx': f.idx});

        (row['sub'] as Map<String, dynamic>)['fractal_peak_dist'] =

            f.fractalPeakDist;

      }

    }



    return BarFeatureLookup._(byIdx: byIdx);

  }



  Map<String, dynamic>? operator [](int idx) => byIdx[idx];

  Map<String, dynamic>? at(int idx) => byIdx[idx];



  List<String> crosshairSubLines(int idx, Set<SubChartIndicator> active) {

    final row = byIdx[idx];

    if (row == null) return const [];

    final sub = row['sub'];

    if (sub is! Map || sub.isEmpty) return const [];

    final lines = <String>[];

    void add(String label, dynamic v) {

      if (v == null) return;

      if (v == 0 && (label == '段确认' || label == '首段向')) {

        return;

      }

      lines.add('$label: $v');

    }

    if (active.contains(SubChartIndicator.biConfirm)) add('笔确认', sub['bi_confirm_value']);

    if (active.contains(SubChartIndicator.segConfirm)) add('段确认', sub['seg_confirm']);

    if (active.contains(SubChartIndicator.firstSegDir)) add('首段向', sub['first_seg_dir']);

    if (active.contains(SubChartIndicator.fractalPeakDist)) {

      add('K线分型极点距', sub['fractal_peak_dist']);

    }

    return lines;

  }



  /// 笔 K 十字线行（与 ML 同源：barFeatures 逐步冻结 bi_*；首笔确认前占位）。

  List<String> crosshairBiLines(int idx) {

    final row = byIdx[idx];

    if (row == null) return const [];

    final biIdx = row['bi_idx'];

    if (biIdx == null) {

      return const [

        '笔K线[序号]：首笔确认前',

        '笔K线[合并内序]：—',

        '笔K线[O/H/L/C/VOL]：—',

        '合并笔K线[H/L]：—',

      ];

    }

    String fmt(double v) => v.toStringAsFixed(2);

    final vol = row['bi_volume'];

    final volText = vol is num && vol == vol.roundToDouble()

        ? vol.toInt().toString()

        : (vol as num?)?.toStringAsFixed(2) ?? '0';

    final inner = row['bi_merge_inner_seq'] ?? 1;

    final mergeCnt = row['bi_merge_count'] ?? 1;

    final lines = <String>[

      '笔K线[序号]：#${(biIdx as num).toInt() + 1}',

      '笔K线[合并内序]：$inner/$mergeCnt',

      '笔K线[O/H/L/C/VOL]：'

          '${fmt((row['bi_open'] as num?)?.toDouble() ?? 0)}/'

          '${fmt((row['bi_high'] as num?)?.toDouble() ?? 0)}/'

          '${fmt((row['bi_low'] as num?)?.toDouble() ?? 0)}/'

          '${fmt((row['bi_close'] as num?)?.toDouble() ?? 0)}/'

          '$volText',

      '合并笔K线[H/L]：'

          '${fmt((row['bi_combine_high'] as num?)?.toDouble() ?? 0)}/'

          '${fmt((row['bi_combine_low'] as num?)?.toDouble() ?? 0)}',

    ];

    final biFx = row['bi_combine_fx'];

    if (biFx is String && biFx != 'UNKNOWN') {

      lines.add('合并笔K线[分型]：$biFx');

    }

    final biConfirm = row['bi_confirm'];

    if (biConfirm is Map) {

      final v = biConfirm['value'];

      final fx = biConfirm['fx'];

      if (v is num && v != 0 && fx is String) {

        final sign = v > 0 ? '+$v' : '$v';

        lines.add('笔确认当步：$fx $sign（冻结）');

      }

    }

    return lines;

  }

}


