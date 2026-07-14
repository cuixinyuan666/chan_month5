import 'bi_confirm_signal.dart';

import 'bar_crosshair_feature.dart';

import 'bi_segment.dart';

import 'kline_bar.dart';

import 'chart_indicator.dart';
import 'kline_combine_frame.dart';

import 'level_models.dart';

import 'seg_analysis.dart';



/// 十字线 tooltip 一行：键值 或 层级分隔线。
class CrosshairTooltipRow {
  const CrosshairTooltipRow.kv(this.label, this.value) : isSeparator = false;
  const CrosshairTooltipRow.separator()
      : label = '',
        value = '',
        isSeparator = true;

  final String label;
  final String value;
  final bool isSeparator;

  /// 扁平字符串（测试/历史快照用）
  String get flat {
    if (isSeparator) return '===============================';
    return '$label:$value';
  }
}

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

    // 各层确认查表：level_confirms[n][x] = Kn 合并分型确认（当步冻结；含截断）
    // Kn 块显示 K(n+1) 端点确认（K0 块显示 levels[1]=K1 确认，旧称「K线合并分型确认」）
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



    for (final sig in biConfirms) {

      final row = byIdx.putIfAbsent(sig.x, () => {'idx': sig.x});

      row['bi_confirm'] = {

        'x': sig.x,

        'fx': sig.fx,

        'value': sig.value,

        'fractal_x1': sig.fractalX1,

        'fractal_x2': sig.fractalX2,

        'truncated': sig.truncated,

      };

      if (subIndicators.any((e) =>
          e.kind == SubIndicatorKind.fractalConfirm && e.kn == 1)) {
        // kn=1（最低层）回退源：旧 bi_confirm（K0 原始K分型）
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

      // 已删副图「首K1向 / K2确认」：快照字段仍保留供其它用途

    }



    if (subIndicators.any((e) => e.kind == SubIndicatorKind.volume)) {
      for (final row in byIdx.values) {
        (row['sub'] as Map<String, dynamic>)['volume'] = row['volume'];
      }
    }



    if (subIndicators.any((e) =>
        e.kind == SubIndicatorKind.fractalPeakDist && e.kn == 1)) {
      // kn=1（最低层）回退源：旧 bi 极点距（barFeatures）
      for (final f in barFeatures) {
        final row = byIdx.putIfAbsent(f.idx, () => {'idx': f.idx});
        (row['sub'] as Map<String, dynamic>)['fractal_peak_dist'] =
            f.fractalPeakDist;
      }
    }

    // Kn>=1 极点距：由该层 confirms 当步起算（与副图折线同口径；level=kn）
    for (final ind in subIndicators) {
      if (ind.kind != SubIndicatorKind.fractalPeakDist || ind.kn < 1) {
        continue;
      }
      LevelBundle? bundle;
      for (final lv in levels) {
        if (lv.level == ind.kn) {
          bundle = lv;
          break;
        }
      }
      if (bundle == null || bars.isEmpty) continue;
      final series = _peakDistSeries(bars.length, bundle.confirms);
      for (var i = 0; i < bars.length; i++) {
        final row = byIdx.putIfAbsent(bars[i].idx, () => {'idx': bars[i].idx});
        (row['sub'] as Map<String, dynamic>)['fractal_peak_dist_${ind.kn}'] =
            series[i];
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

  /// 十字线主 tooltip 结构化行（表格渲染用）。
  List<CrosshairTooltipRow> crosshairTooltipRows(
    int idx, {
    required String timePart,
    Set<SubChartIndicator> subIndicators = const {},
  }) {
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

    // K0分型确认（=K1 端点确认）：仅 ±1 显示；截断加"(截断)"
    var combineFxConfirm = '';
    final biConfirm = row['bi_confirm'];
    if (biConfirm is Map) {
      final v = biConfirm['value'];
      if (v is num && (v == 1 || v == -1)) {
        combineFxConfirm = biConfirm['truncated'] == true ? '$v(截断)' : '$v';
      }
    }

    final out = <CrosshairTooltipRow>[
      CrosshairTooltipRow.kv('日期时间', '$timePart     $weekday'),
      const CrosshairTooltipRow.separator(),
      CrosshairTooltipRow.kv('K0[No.]', '${row['idx']}'),
      CrosshairTooltipRow.kv(
        'K0',
        _fmtOhlcv(open: open, high: high, low: low, close: close, volume: volume),
      ),
      CrosshairTooltipRow.kv(
        'K0合并',
        'H${_fmtPrice(combineHigh)}/L${_fmtPrice(combineLow)}',
      ),
      CrosshairTooltipRow.kv('K0合并K0序', '$mergeInner'),
      CrosshairTooltipRow.kv('K0分型确认', combineFxConfirm),
      ..._levelBlockRows(idx),
    ];

    final subs = crosshairSubRows(idx, subIndicators);
    if (subs.isNotEmpty) {
      out.add(const CrosshairTooltipRow.separator());
      out.addAll(subs);
    }
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
      if (ind.kind == SubIndicatorKind.fractalConfirm) {
        final confirms = row['level_confirms'];
        dynamic v;
        if (confirms is Map && confirms.containsKey(ind.kn)) {
          // 主路径：level=kn 的确认（K1/笔=level1，K2/线段=level2…）
          final c = confirms[ind.kn];
          if (c is LevelConfirm) {
            v = c.value;
          } else if (c is Map) {
            v = c['value'];
          }
        } else if (ind.kn == 1) {
          // 回退：无 levels 时用旧 bi_confirm（K0 原始K分型）
          v = sub['bi_confirm_value'];
        }
        add(ind.label, v);
      }
      if (ind.kind == SubIndicatorKind.fractalPeakDist) {
        if (sub.containsKey('fractal_peak_dist_${ind.kn}')) {
          add(ind.label, sub['fractal_peak_dist_${ind.kn}']);
        } else if (ind.kn == 1) {
          // 回退：无 levels 时用旧 bi 极点距
          add(ind.label, sub['fractal_peak_dist']);
        }
      }
      if (ind.kind == SubIndicatorKind.truncation) {
        // 截断触发当步：有 truncated 确认才显示方向值（level=kn）
        final confirms = row['level_confirms'];
        dynamic v;
        if (confirms is Map && confirms.containsKey(ind.kn)) {
          final c = confirms[ind.kn];
          if (c is LevelConfirm && c.truncated) {
            v = c.value;
          } else if (c is Map && c['truncated'] == true) {
            v = c['value'];
          }
        } else if (ind.kn == 1) {
          // 回退：无 levels 时用旧 bi_confirm 截断
          final bc = row['bi_confirm'];
          if (bc is Map && bc['truncated'] == true) {
            v = bc['value'];
          }
        }
        add(ind.label, v);
      }
    }
    return lines;
  }

  /// Kn 块（K1=笔，K2=线段，…）；每层前加分隔线。
  List<CrosshairTooltipRow> _levelBlockRows(int idx) {
    final row = byIdx[idx];
    if (row == null) return const [];

    final snaps = row['levels'];
    final confirms = row['level_confirms'];
    final snapList = snaps is List<LevelSnap> ? snaps : const <LevelSnap>[];
    final total = totalLevels > snapList.length ? totalLevels : snapList.length;

    final lines = <CrosshairTooltipRow>[];
    for (var n = 1; n <= total; n++) {
      final snap = n - 1 < snapList.length ? snapList[n - 1] : null;
      // Kn 块「分型确认」= K(n+1) 端点确认（当步冻结）
      int? confirmVal;
      var confirmTruncated = false;
      if (confirms is Map) {
        final v = confirms[n + 1];
        if (v is LevelConfirm && (v.value == 1 || v.value == -1)) {
          confirmVal = v.value;
          confirmTruncated = v.truncated;
        }
      }
      lines.add(const CrosshairTooltipRow.separator());
      lines.addAll(_levelBlockRowsFor(n, snap, confirmVal, confirmTruncated));
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
  ) {
    final label = 'K$n';
    final confirmText = confirmVal == null
        ? ''
        : (confirmTruncated ? '$confirmVal(截断)' : '$confirmVal');

    if (snap == null || snap.unitIdx == null) {
      return [
        CrosshairTooltipRow.kv('$label[No.]', '首K$n确认前'),
        CrosshairTooltipRow.kv(label, '—'),
        CrosshairTooltipRow.kv('$label合并$label序', '—'),
        CrosshairTooltipRow.kv('$label合并', '—'),
        CrosshairTooltipRow.kv('$label分型确认', confirmText),
      ];
    }

    return [
      CrosshairTooltipRow.kv('$label[No.]', '${snap.unitIdx}'),
      CrosshairTooltipRow.kv(
        label,
        _fmtOhlcv(
          open: snap.unitOpen,
          high: snap.unitHigh,
          low: snap.unitLow,
          close: snap.unitClose,
          volume: snap.unitVolume,
        ),
      ),
      CrosshairTooltipRow.kv('$label合并$label序', '${snap.mergeInnerSeq}'),
      CrosshairTooltipRow.kv(
        '$label合并',
        'H${_fmtPrice(snap.combineHigh)}/L${_fmtPrice(snap.combineLow)}',
      ),
      CrosshairTooltipRow.kv('$label分型确认', confirmText),
    ];
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


