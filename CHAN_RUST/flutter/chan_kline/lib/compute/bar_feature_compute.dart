import 'dart:math' as math;



import '../models/bar_crosshair_feature.dart';

import '../models/bi_confirm_signal.dart';

import '../models/bi_segment.dart';

import '../models/kline_bar.dart';

import '../models/kline_combine_frame.dart';



const _weekdayCn = ['周日', '周一', '周二', '周三', '周四', '周五', '周六'];



/// Dart 回退：与 Rust `build_bar_crosshair_features_stepwise` 同口径（逐K当下）。

List<BarCrosshairFeature> computeBarCrosshairFeatures(

  List<KlineBar> bars,

  List<KlineCombineFrame> frames, // 保留签名兼容；逐步口径不再用末态 frames

) {

  final steps = _buildBarCombineStepStates(bars);

  return List.generate(bars.length, (i) {

    final b = bars[i];

    final st = i < steps.length ? steps[i] : _StepState();

    return BarCrosshairFeature(

      idx: b.idx,

      weekday: _weekdayFromBar(b),

      mergeInnerSeq: st.mergeInnerSeq,

      mergeCount: st.mergeCount,

      combineFx: st.combineFx,

      combineHigh: st.combineHigh,

      combineLow: st.combineLow,

    );

  });

}



class _StepState {

  int mergeInnerSeq = 1;

  int mergeCount = 1;

  String combineFx = 'UNKNOWN';

  double combineHigh = 0;

  double combineLow = 0;

}



List<_StepState> _buildBarCombineStepStates(List<KlineBar> bars) {

  if (bars.isEmpty) return const [];

  final out = <_StepState>[];

  final highs = <double>[];

  final lows = <double>[];

  final dirs = <String>[]; // UP/DOWN（与 Rust KlineDir 对齐）

  final unitCounts = <int>[];

  final fxConfirmAt = <int?>[];

  final fxAt = <String>[];



  String combineDir(double ha, double la, double hb, double lb) {

    if (ha >= hb && la <= lb) return 'COMBINE';

    if (ha <= hb && la >= lb) return 'COMBINE';

    if (ha > hb && la > lb) return 'DOWN';

    if (ha < hb && la < lb) return 'UP';

    return 'COMBINE';

  }



  void tryCombine(int last, KlineBar bar) {

    if (dirs[last] == 'UP') {

      if ((bar.high - bar.low).abs() > 1e-12 ||

          (bar.high - highs[last]).abs() > 1e-12) {

        highs[last] = math.max(highs[last], bar.high);

        lows[last] = math.max(lows[last], bar.low);

      }

    } else if (dirs[last] == 'DOWN') {

      if ((bar.high - bar.low).abs() > 1e-12 ||

          (bar.low - lows[last]).abs() > 1e-12) {

        highs[last] = math.min(highs[last], bar.high);

        lows[last] = math.min(lows[last], bar.low);

      }

    }

  }



  void updateFx(int mid) {

    if (mid < 1 || mid + 1 >= highs.length) return;

    final preH = highs[mid - 1];

    final preL = lows[mid - 1];

    final selfH = highs[mid];

    final selfL = lows[mid];

    final nextH = highs[mid + 1];

    final nextL = lows[mid + 1];

    var fx = 'UNKNOWN';

    if (preH < selfH && nextH < selfH && preL < selfL && nextL < selfL) {

      fx = 'TOP';

    } else if (preH > selfH && nextH > selfH && preL > selfL && nextL > selfL) {

      fx = 'BOTTOM';

    }

    fxAt[mid] = fx;

  }



  for (var i = 0; i < bars.length; i++) {

    final bar = bars[i];

    if (highs.isEmpty) {

      highs.add(bar.high);

      lows.add(bar.low);

      dirs.add('UP');

      unitCounts.add(1);

      fxConfirmAt.add(null);

      fxAt.add('UNKNOWN');

    } else {

      final last = highs.length - 1;

      final dir = combineDir(highs[last], lows[last], bar.high, bar.low);

      if (dir == 'COMBINE') {

        tryCombine(last, bar);

        unitCounts[last] += 1;

      } else {

        highs.add(bar.high);

        lows.add(bar.low);

        dirs.add(dir);

        unitCounts.add(1);

        fxConfirmAt.add(null);

        fxAt.add('UNKNOWN');

        if (highs.length >= 3) {

          final mid = highs.length - 2;

          updateFx(mid);

          if (fxAt[mid] != 'UNKNOWN') {

            fxConfirmAt[mid] = i;

          }

        }

      }

    }



    final klcIdx = highs.length - 1;

    final mergeCount = unitCounts[klcIdx];

    final confirmAt = fxConfirmAt[klcIdx];

    final combineFx =

        confirmAt != null && confirmAt <= i ? fxAt[klcIdx] : 'UNKNOWN';

    out.add(_StepState()

      ..mergeInnerSeq = mergeCount

      ..mergeCount = mergeCount

      ..combineFx = combineFx

      ..combineHigh = highs[klcIdx]

      ..combineLow = lows[klcIdx]);

  }

  return out;

}



String _weekdayFromBar(KlineBar bar) {

  if (bar.timeMs > 0) {

    final dt = DateTime.fromMillisecondsSinceEpoch(bar.timeMs, isUtc: true).toLocal();

    return _weekdayCn[dt.weekday % 7];

  }

  final text = bar.timeText.trim();

  if (text.length >= 10) {

    final parts = text.substring(0, 10).split('/');

    if (parts.length == 3) {

      final y = int.tryParse(parts[0]);

      final m = int.tryParse(parts[1]);

      final d = int.tryParse(parts[2]);

      if (y != null && m != null && d != null) {

        final dt = DateTime(y, m, d);

        return _weekdayCn[dt.weekday % 7];

      }

    }

  }

  return '-';

}



/// 首笔确认引导：在 [0..=首次分型极点K] 内取反向极值 K。
int? bootstrapReverseExtremeBarIdx(List<KlineBar> bars, BiConfirmSignal endConf) {
  final endI = fractalExtremeBarIdx(bars, endConf);
  if (endI == null || bars.isEmpty || endI >= bars.length) return null;
  if (endConf.fx == 'TOP') {
    var trough = double.infinity;
    for (var j = 0; j <= endI; j++) {
      trough = math.min(trough, bars[j].low);
    }
    for (var j = 0; j <= endI; j++) {
      if ((bars[j].low - trough).abs() < 1e-12) return j;
    }
  } else if (endConf.fx == 'BOTTOM') {
    var peak = double.negativeInfinity;
    for (var j = 0; j <= endI; j++) {
      peak = math.max(peak, bars[j].high);
    }
    for (var j = 0; j <= endI; j++) {
      if ((bars[j].high - peak).abs() < 1e-12) return j;
    }
  }
  return null;
}

List<BiSegment> _buildBiSegmentsFromPairs(List<BiConfirmSignal> valid) {
  if (valid.length < 2) return const [];
  final segments = <BiSegment>[];
  for (var i = 1; i < valid.length; i++) {
    final prev = valid[i - 1];
    final curr = valid[i];
    if (prev.fx == curr.fx) continue;
    final dir = prev.fx == 'BOTTOM' && curr.fx == 'TOP'
        ? 1
        : prev.fx == 'TOP' && curr.fx == 'BOTTOM'
            ? -1
            : 0;
    if (dir == 0) continue;
    final idx = segments.length;
    segments.add(
      BiSegment(
        idx: idx,
        dir: dir,
        beginConfirmX: prev.x,
        endConfirmX: curr.x,
        beginFractalX1: prev.fractalX1,
        beginFractalX2: prev.fractalX2,
        endFractalX1: curr.fractalX1,
        endFractalX2: curr.fractalX2,
        prevIdx: idx > 0 ? idx - 1 : null,
        nextIdx: null,
      ),
    );
  }
  for (var i = 0; i < segments.length - 1; i++) {
    final s = segments[i];
    segments[i] = BiSegment(
      idx: s.idx,
      dir: s.dir,
      beginConfirmX: s.beginConfirmX,
      endConfirmX: s.endConfirmX,
      beginFractalX1: s.beginFractalX1,
      beginFractalX2: s.beginFractalX2,
      endFractalX1: s.endFractalX1,
      endFractalX2: s.endFractalX2,
      prevIdx: s.prevIdx,
      nextIdx: i + 1,
      isBootstrap: s.isBootstrap,
    );
  }
  return segments;
}

/// Dart 回退：与 Rust `build_bi_segments` 同口径。
List<BiSegment> computeBiSegments(
  List<KlineBar> bars,
  List<BiConfirmSignal> confirms,
) {
  final valid = confirms.where((c) => c.fx == 'TOP' || c.fx == 'BOTTOM').toList();
  if (valid.length >= 2) {
    return _buildBiSegmentsFromPairs(valid);
  }
  if (valid.length == 1 && bars.isNotEmpty) {
    final first = valid.first;
    final virtualK = bootstrapReverseExtremeBarIdx(bars, first);
    if (virtualK != null) {
      final dir = first.fx == 'TOP' ? 1 : -1;
      return [
        BiSegment(
          idx: 0,
          dir: dir,
          beginConfirmX: first.x,
          endConfirmX: first.x,
          beginFractalX1: virtualK,
          beginFractalX2: virtualK,
          endFractalX1: first.fractalX1,
          endFractalX2: first.fractalX2,
          isBootstrap: true,
        ),
      ];
    }
  }
  return const [];
}



/// 分型合并框内极点 K：TOP 取首个 high 极值，BOTTOM 取首个 low 极值。

int? fractalExtremeBarIdx(List<KlineBar> bars, BiConfirmSignal conf) {

  final x1 = conf.fractalX1 < 0 ? 0 : conf.fractalX1;

  final x2 = conf.fractalX2 < 0 ? 0 : conf.fractalX2;

  if (bars.isEmpty || x1 > x2 || x2 >= bars.length) return null;

  if (conf.fx == 'TOP') {

    var peak = double.negativeInfinity;

    for (var j = x1; j <= x2; j++) {

      peak = math.max(peak, bars[j].high);

    }

    for (var j = x1; j <= x2; j++) {

      if ((bars[j].high - peak).abs() < 1e-12) return j;

    }

  } else if (conf.fx == 'BOTTOM') {

    var trough = double.infinity;

    for (var j = x1; j <= x2; j++) {

      trough = math.min(trough, bars[j].low);

    }

    for (var j = x1; j <= x2; j++) {

      if ((bars[j].low - trough).abs() < 1e-12) return j;

    }

  }

  return null;

}



/// 逐 K 填充 K线分型极点距（与 Rust `enrich_fractal_peak_dist` 同口径；不含极点 K）。

List<BarCrosshairFeature> enrichFractalPeakDist(

  List<KlineBar> bars,

  List<BarCrosshairFeature> features,

  List<BiConfirmSignal> biConfirms,

) {

  if (features.isEmpty) return features;

  var confirmPtr = 0;

  int? extremeIdx;



  final out = <BarCrosshairFeature>[];

  for (var i = 0; i < features.length; i++) {

    while (confirmPtr < biConfirms.length && biConfirms[confirmPtr].x <= i) {

      extremeIdx = fractalExtremeBarIdx(bars, biConfirms[confirmPtr]);

      confirmPtr++;

    }

    final dist = extremeIdx == null ? 0 : i - extremeIdx;

    final f = features[i];

    out.add(

      BarCrosshairFeature(

        idx: f.idx,

        weekday: f.weekday,

        mergeInnerSeq: f.mergeInnerSeq,

        mergeCount: f.mergeCount,

        combineFx: f.combineFx,

        combineHigh: f.combineHigh,

        combineLow: f.combineLow,

        fractalPeakDist: dist,

        biIdx: f.biIdx,

        biMergeInnerSeq: f.biMergeInnerSeq,

        biMergeCount: f.biMergeCount,

        biOpen: f.biOpen,

        biHigh: f.biHigh,

        biLow: f.biLow,

        biClose: f.biClose,

        biVolume: f.biVolume,

        biCombineHigh: f.biCombineHigh,

        biCombineLow: f.biCombineLow,

        biCombineFx: f.biCombineFx,

      ),

    );

  }

  return out;

}

