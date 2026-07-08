import 'bi_confirm_signal.dart';

import 'bar_crosshair_feature.dart';

import 'bi_segment.dart';

import 'kline_bar.dart';

import 'kline_combine_frame.dart';

import 'level_models.dart';

import 'seg_analysis.dart';



/// 逐 K 字典式特征索引（ML / 十字线 tooltip 同源，均用 barFeatures 逐步冻结快照）。

class BarFeatureLookup {

  BarFeatureLookup._({required this.byIdx, this.totalLevels = 0});



  final Map<int, Map<String, dynamic>> byIdx;

  /// 穷尽后的 N 段总层数（tooltip 对未诞生层输出占位行）
  final int totalLevels;



  factory BarFeatureLookup.build({

    required List<KlineBar> bars,

    required List<KlineCombineFrame> combineFrames,

    required List<BiConfirmSignal> biConfirms,

    List<BarCrosshairFeature> barFeatures = const [],

    List<BiSegment> biSegments = const [],

    SegAnalysisBundle segAnalysis = const SegAnalysisBundle(),

    List<LevelBundle> levels = const [],

    Set<SubChartIndicator> subIndicators = const {},

  }) {

    final byIdx = <int, Map<String, dynamic>>{};

    final featureByIdx = {for (final f in barFeatures) f.idx: f};

    // 各层确认查表：level_confirms[n][x] = 确认柱值（n段K线合并分型确认，当步冻结）
    // n 段块显示 n+1 层确认（K线块显示 levels[1] 即笔确认，与旧"K线合并分型确认"一致）
    final levelConfirmByX = <int, Map<int, int>>{};
    for (final lv in levels) {
      final m = <int, int>{};
      for (final c in lv.confirms) {
        if (c.value == 1 || c.value == -1) m[c.x] = c.value;
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

        'combine_fx': feat?.combineFx ?? 'UNKNOWN',

        'combine_high': feat?.combineHigh ?? b.high,

        'combine_low': feat?.combineLow ?? b.low,

        'bi_idx': feat?.biIdx,

        'bi_merge_inner_seq': feat?.biMergeInnerSeq ?? 0,

        'bi_merge_count': feat?.biMergeCount ?? 1,

        'bi_open': feat?.biOpen ?? 0,

        'bi_high': feat?.biHigh ?? 0,

        'bi_low': feat?.biLow ?? 0,

        'bi_close': feat?.biClose ?? 0,

        'bi_volume': feat?.biVolume ?? 0,

        'bi_combine_high': feat?.biCombineHigh ?? 0,

        'bi_combine_low': feat?.biCombineLow ?? 0,

        'bi_combine_fx': feat?.biCombineFx ?? 'UNKNOWN',

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



    return BarFeatureLookup._(byIdx: byIdx, totalLevels: levels.length);

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

  static String _fmtOhlcv({
    required double open,
    required double high,
    required double low,
    required double close,
    required num volume,
  }) {
    return 'O${_fmtPrice(open)}/H${_fmtPrice(high)}/L${_fmtPrice(low)}/C${_fmtPrice(close)}/VOL${_fmtVol(volume)}';
  }

  /// 十字线主 tooltip：K 线块 + 全部 N 段块（1段=笔，2段=线段，…穷尽层全量输出）。
  List<String> crosshairTooltipLines(int idx, {required String timePart}) {
    final row = byIdx[idx];
    if (row == null) return const [];

    final weekday = weekdayToW(row['weekday'] as String? ?? '-');
    final mergeInner = row['merge_inner_seq'] ?? 0;

    final open = (row['open'] as num?)?.toDouble() ?? 0;
    final high = (row['high'] as num?)?.toDouble() ?? 0;
    final low = (row['low'] as num?)?.toDouble() ?? 0;
    final close = (row['close'] as num?)?.toDouble() ?? 0;
    final volume = (row['volume'] as num?) ?? 0;
    final combineHigh = (row['combine_high'] as num?)?.toDouble() ?? high;
    final combineLow = (row['combine_low'] as num?)?.toDouble() ?? low;

    // K线合并分型确认（=1段端点确认）：仅 1 / -1 显示数值，0 或空显示空值
    var combineFxConfirm = '';
    final biConfirm = row['bi_confirm'];
    if (biConfirm is Map) {
      final v = biConfirm['value'];
      if (v is num && (v == 1 || v == -1)) {
        combineFxConfirm = '$v';
      }
    }

    final lines = <String>[
      '日期时间:$timePart $weekday',
      'K线[序号]:${row['idx']}',
      'K线:${_fmtOhlcv(open: open, high: high, low: low, close: close, volume: volume)}',
      'K线合并:H${_fmtPrice(combineHigh)}/L${_fmtPrice(combineLow)}',
      'K线合并K线序:$mergeInner',
      'K线合并分型确认:$combineFxConfirm',
      ...crosshairLevelLines(idx),
    ];
    return lines;
  }

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

    if (active.contains(SubChartIndicator.segConfirm)) add('段确认', sub['seg_confirm']);

    if (active.contains(SubChartIndicator.firstSegDir)) add('首段向', sub['first_seg_dir']);

    if (active.contains(SubChartIndicator.fractalPeakDist)) {

      add('K线分型极点距', sub['fractal_peak_dist']);

    }

    return lines;

  }



  /// N 段十字线行（与 ML 同源：逐步冻结 levels 快照；1段=笔，2段=线段，…）。
  /// 每层块模板与 K 线块同构：[序号] / OHLCV / 合并序 / 合并H:L / 合并分型确认。
  /// 未诞生层输出占位行（当时当下历史，不回写）。
  List<String> crosshairLevelLines(int idx) {

    final row = byIdx[idx];

    if (row == null) return const [];

    final snaps = row['levels'];

    final confirms = row['level_confirms'];

    final snapList = snaps is List<LevelSnap> ? snaps : const <LevelSnap>[];

    final total = totalLevels > snapList.length ? totalLevels : snapList.length;

    final lines = <String>[];

    for (var n = 1; n <= total; n++) {

      final snap = n - 1 < snapList.length ? snapList[n - 1] : null;

      // n 段块的"合并分型确认"= n+1 层端点确认（当步冻结，n+1 层不存在则空）
      int? confirmVal;

      if (confirms is Map) {

        final v = confirms[n + 1];

        if (v is int && (v == 1 || v == -1)) confirmVal = v;

      }

      lines.addAll(_levelBlockLines(n, snap, confirmVal));

    }

    return lines;

  }



  List<String> _levelBlockLines(int n, LevelSnap? snap, int? confirmVal) {

    final label = '$n段K线';

    final confirmText = confirmVal == null ? '' : '$confirmVal';

    if (snap == null || snap.unitIdx == null) {

      return [

        '$label[序号]:首$n段确认前',

        '$label:—',

        '$label合并$label序:—',

        '$label合并:—',

        '$label合并分型确认:$confirmText',

      ];

    }

    return [

      '$label[序号]:${snap.unitIdx}',

      '$label:${_fmtOhlcv(

        open: snap.unitOpen,

        high: snap.unitHigh,

        low: snap.unitLow,

        close: snap.unitClose,

        volume: snap.unitVolume,

      )}',

      '$label合并$label序:${snap.mergeInnerSeq}',

      '$label合并:H${_fmtPrice(snap.combineHigh)}/L${_fmtPrice(snap.combineLow)}',

      '$label合并分型确认:$confirmText',

    ];

  }

}


