import 'dart:math' as math;

import '../models/bar_crosshair_feature.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import 'bi_virtual_bar_compute.dart';
import 'bi_virtual_bar_provisional_compute.dart';
import 'default_bi_compute.dart';

class _HlMergeUnit {
  const _HlMergeUnit({
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
  });

  final int x1;
  final int x2;
  final double high;
  final double low;
}

class _BiCombineSnap {
  const _BiCombineSnap({
    required this.biMergeInnerSeq,
    required this.biMergeCount,
    required this.biCombineHigh,
    required this.biCombineLow,
    required this.biCombineFx,
  });

  final int biMergeInnerSeq;
  final int biMergeCount;
  final double biCombineHigh;
  final double biCombineLow;
  final String biCombineFx;
}

/// 合并笔 K 逐步状态（与 Rust `HlCombineStepState` 同口径，含 bi idx 追踪）。
class _HlCombineStepState {
  final highs = <double>[];
  final lows = <double>[];
  final dirs = <String>[];
  final x1s = <int>[];
  final x2s = <int>[];
  final unitCounts = <int>[];
  final fxAt = <String>[];
  final unitBiIdxs = <int>[];
  bool provisional = false;

  _HlCombineStepState clone() {
    final c = _HlCombineStepState();
    c.highs.addAll(highs);
    c.lows.addAll(lows);
    c.dirs.addAll(dirs);
    c.x1s.addAll(x1s);
    c.x2s.addAll(x2s);
    c.unitCounts.addAll(unitCounts);
    c.fxAt.addAll(fxAt);
    c.unitBiIdxs.addAll(unitBiIdxs);
    c.provisional = provisional;
    return c;
  }

  String _combineDir(double ha, double la, double hb, double lb) {
    if (ha >= hb && la <= lb) return 'COMBINE';
    if (ha <= hb && la >= lb) return 'COMBINE';
    if (ha > hb && la > lb) return 'DOWN';
    if (ha < hb && la < lb) return 'UP';
    return 'COMBINE';
  }

  void feedPermanent(_HlMergeUnit u, int biIdx) {
    if (provisional) {
      highs.removeLast();
      lows.removeLast();
      dirs.removeLast();
      x1s.removeLast();
      x2s.removeLast();
      unitCounts.removeLast();
      fxAt.removeLast();
      if (unitBiIdxs.isNotEmpty) unitBiIdxs.removeLast();
      provisional = false;
    }
    _feed(u, biIdx);
  }

  void updateProvisional(_HlMergeUnit u, int biIdx) {
    if (provisional && highs.isNotEmpty) {
      _replaceLastWith(u, biIdx);
    } else {
      provisional = true;
      _feed(u, biIdx);
    }
  }

  void _replaceLastWith(_HlMergeUnit u, int biIdx) {
    final last = highs.length - 1;
    if (last == 0) {
      highs[0] = u.high;
      lows[0] = u.low;
      x1s[0] = u.x1;
      x2s[0] = u.x2;
      unitCounts[0] = 1;
      if (unitBiIdxs.isNotEmpty) {
        unitBiIdxs[0] = biIdx;
      } else {
        unitBiIdxs.add(biIdx);
      }
      return;
    }
    final prevIdx = last - 1;
    final dir = _combineDir(highs[prevIdx], lows[prevIdx], u.high, u.low);
    if (dir == 'COMBINE') {
      if (dirs[prevIdx] == 'DOWN') {
        if ((u.high - u.low).abs() > 1e-12 ||
            (u.low - lows[prevIdx]).abs() > 1e-12) {
          highs[prevIdx] = math.min(highs[prevIdx], u.high);
          lows[prevIdx] = math.min(lows[prevIdx], u.low);
        }
      } else {
        if ((u.high - u.low).abs() > 1e-12 ||
            (u.high - highs[prevIdx]).abs() > 1e-12) {
          highs[prevIdx] = math.max(highs[prevIdx], u.high);
          lows[prevIdx] = math.max(lows[prevIdx], u.low);
        }
      }
      x2s[prevIdx] = u.x2;
      unitCounts[prevIdx] += 1;
      highs.removeLast();
      lows.removeLast();
      dirs.removeLast();
      x1s.removeLast();
      x2s.removeLast();
      unitCounts.removeLast();
      fxAt.removeLast();
      if (unitBiIdxs.isNotEmpty) unitBiIdxs.removeLast();
      provisional = false;
      unitBiIdxs.add(biIdx);
    } else {
      highs[last] = u.high;
      lows[last] = u.low;
      dirs[last] = dir;
      x1s[last] = u.x1;
      x2s[last] = u.x2;
      unitCounts[last] = 1;
      if (unitBiIdxs.isNotEmpty) {
        unitBiIdxs[last] = biIdx;
      }
    }
  }

  void _feed(_HlMergeUnit u, int biIdx) {
    if (highs.isEmpty) {
      highs.add(u.high);
      lows.add(u.low);
      dirs.add('COMBINE');
      x1s.add(u.x1);
      x2s.add(u.x2);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
      unitBiIdxs.add(biIdx);
      return;
    }
    final last = highs.length - 1;
    final dir = _combineDir(highs[last], lows[last], u.high, u.low);
    if (dir == 'COMBINE') {
      if (dirs[last] == 'DOWN') {
        if ((u.high - u.low).abs() > 1e-12 ||
            (u.low - lows[last]).abs() > 1e-12) {
          highs[last] = math.min(highs[last], u.high);
          lows[last] = math.min(lows[last], u.low);
        }
      } else {
        if ((u.high - u.low).abs() > 1e-12 ||
            (u.high - highs[last]).abs() > 1e-12) {
          highs[last] = math.max(highs[last], u.high);
          lows[last] = math.max(lows[last], u.low);
        }
      }
      x2s[last] = u.x2;
      unitCounts[last] += 1;
      unitBiIdxs.add(biIdx);
      return;
    }
    highs.add(u.high);
    lows.add(u.low);
    dirs.add(dir);
    x1s.add(u.x1);
    x2s.add(u.x2);
    unitCounts.add(1);
    fxAt.add('UNKNOWN');
    unitBiIdxs.add(biIdx);
    if (highs.length >= 3) {
      _updateFx(highs.length - 2);
    }
  }

  void _updateFx(int mid) {
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

  _BiCombineSnap crosshairSnapshot(int activeBiIdx) {
    if (highs.isEmpty) {
      return const _BiCombineSnap(
        biMergeInnerSeq: 1,
        biMergeCount: 1,
        biCombineHigh: 0,
        biCombineLow: 0,
        biCombineFx: 'UNKNOWN',
      );
    }
    final lastKlc = highs.length - 1;
    final cnt = unitCounts[lastKlc].clamp(1, 1 << 30);
    var unitStart = 0;
    for (var i = 0; i < lastKlc; i++) {
      unitStart += unitCounts[i];
    }
    var innerSeq = cnt;
    for (var j = 0; j < cnt; j++) {
      final ui = unitStart + j;
      if (ui < unitBiIdxs.length && unitBiIdxs[ui] == activeBiIdx) {
        innerSeq = j + 1;
        break;
      }
    }
    final fx = lastKlc < fxAt.length ? fxAt[lastKlc] : 'UNKNOWN';
    return _BiCombineSnap(
      biMergeInnerSeq: innerSeq,
      biMergeCount: cnt,
      biCombineHigh: highs[lastKlc],
      biCombineLow: lows[lastKlc],
      biCombineFx: fx,
    );
  }
}

_HlMergeUnit _unitFromVb(BiVirtualBar vb) => _HlMergeUnit(
      x1: vb.x1,
      x2: vb.x2,
      high: vb.high,
      low: vb.low,
    );

double _biVolume(List<KlineBar> bars, int x1, int x2) {
  if (bars.isEmpty) return 0;
  final a = x1 < x2 ? x1 : x2;
  final b = x1 > x2 ? x1 : x2;
  final aC = a.clamp(0, bars.length - 1);
  final bC = b.clamp(0, bars.length - 1);
  var vol = 0.0;
  for (var i = aC; i <= bC; i++) {
    vol += bars[i].volume;
  }
  return vol;
}

BiVirtualBar? _provisionalFromLastConfirm(
  List<KlineBar> bars,
  List<BiConfirmSignal> biConfirms,
  int barX,
  int segIdx,
) {
  BiConfirmSignal? last;
  for (final c in biConfirms) {
    if (c.fx == 'TOP' || c.fx == 'BOTTOM') last = c;
  }
  if (last == null || last.x > barX) return null;
  final dir = last.fx == 'BOTTOM' ? 1 : -1;
  return computeBiVirtualBarProvisional(
    bars,
    last.fractalX1,
    last.fractalX2,
    barX,
    dir,
    segIdx,
  );
}

BiVirtualBar? _provisionalBiAt(
  List<KlineBar> bars,
  List<BiSegment> biSegments,
  List<BiConfirmSignal> biConfirms,
  int barX,
  int nextBi,
) {
  if (nextBi < biSegments.length) {
    final seg = biSegments[nextBi];
    if (!seg.isBootstrap &&
        seg.beginConfirmX <= barX &&
        barX < seg.endConfirmX) {
      return computeBiVirtualBarProvisional(
        bars,
        seg.beginFractalX1,
        seg.beginFractalX2,
        barX,
        seg.dir,
        seg.idx,
      );
    }
    return null;
  }
  return _provisionalFromLastConfirm(
    bars,
    biConfirms,
    barX,
    biSegments.length,
  );
}

BiVirtualBar? _confirmedBiAt(
  List<KlineBar> bars,
  List<BiSegment> biSegments,
  int barX,
) {
  for (var i = biSegments.length - 1; i >= 0; i--) {
    final seg = biSegments[i];
    if (seg.endConfirmX > barX) continue;
    final vb = computeBiVirtualBars(bars, [seg]).firstOrNull;
    if (vb != null && vb.x1 <= barX && barX <= vb.x2) return vb;
  }
  return null;
}

BiVirtualBar? _segmentVbEndedAtBar(
  List<KlineBar> bars,
  List<BiSegment> biSegments,
  int barX,
) {
  for (final seg in biSegments) {
    if (seg.endConfirmX == barX) {
      return computeBiVirtualBars(bars, [seg]).firstOrNull;
    }
  }
  return null;
}

BiVirtualBar? _activeBiAt(
  List<KlineBar> bars,
  List<BiSegment> biSegments,
  List<BiConfirmSignal> biConfirms,
  int barX,
  int nextBi,
) {
  return _segmentVbEndedAtBar(bars, biSegments, barX) ??
      _provisionalBiAt(bars, biSegments, biConfirms, barX, nextBi) ??
      _confirmedBiAt(bars, biSegments, barX);
}

BarCrosshairFeature _copyWithBi(
  BarCrosshairFeature f, {
  int? biIdx,
  bool clearBiIdx = false,
  int? biMergeInnerSeq,
  int? biMergeCount,
  double? biOpen,
  double? biHigh,
  double? biLow,
  double? biClose,
  double? biVolume,
  double? biCombineHigh,
  double? biCombineLow,
  String? biCombineFx,
}) {
  return BarCrosshairFeature(
    idx: f.idx,
    weekday: f.weekday,
    mergeInnerSeq: f.mergeInnerSeq,
    mergeCount: f.mergeCount,
    combineFx: f.combineFx,
    combineHigh: f.combineHigh,
    combineLow: f.combineLow,
    fractalPeakDist: f.fractalPeakDist,
    biIdx: clearBiIdx ? null : (biIdx ?? f.biIdx),
    biMergeInnerSeq: biMergeInnerSeq ?? f.biMergeInnerSeq,
    biMergeCount: biMergeCount ?? f.biMergeCount,
    biOpen: biOpen ?? f.biOpen,
    biHigh: biHigh ?? f.biHigh,
    biLow: biLow ?? f.biLow,
    biClose: biClose ?? f.biClose,
    biVolume: biVolume ?? f.biVolume,
    biCombineHigh: biCombineHigh ?? f.biCombineHigh,
    biCombineLow: biCombineLow ?? f.biCombineLow,
    biCombineFx: biCombineFx ?? f.biCombineFx,
  );
}

/// Dart 回退：与 Rust `enrich_bi_crosshair_fields` 同口径（逐K当下）。
List<BarCrosshairFeature> enrichBiCrosshairFields(
  List<KlineBar> bars,
  List<BarCrosshairFeature> features,
  List<BiSegment> biSegments,
  List<BiConfirmSignal> biConfirms,
  String defaultBiPolicy,
) {
  if (features.isEmpty || bars.isEmpty) return features;
  final mergeState = _HlCombineStepState();
  var nextBi = 0;
  final limit = math.min(bars.length, features.length);
  final out = <BarCrosshairFeature>[];

  for (var barX = 0; barX < limit; barX++) {
    while (nextBi < biSegments.length &&
        biSegments[nextBi].endConfirmX == barX) {
      final seg = biSegments[nextBi];
      final vb = computeBiVirtualBars(bars, [seg]).first;
      mergeState.feedPermanent(_unitFromVb(vb), seg.idx);
      nextBi++;
    }

    var active = _activeBiAt(bars, biSegments, biConfirms, barX, nextBi);
    if (active == null && defaultBiPolicy == 'pending') {
      active = buildPreConfirmDefaultBi(bars, barX);
    }
    final snapState = mergeState.clone();
    final prov = _provisionalBiAt(bars, biSegments, biConfirms, barX, nextBi);
    if (prov != null) {
      snapState.updateProvisional(_unitFromVb(prov), prov.idx);
    }

    final f = features[barX];
    if (active != null) {
      final snap = snapState.crosshairSnapshot(active.idx);
      out.add(
        _copyWithBi(
          f,
          biIdx: active.idx,
          biMergeInnerSeq: snap.biMergeInnerSeq,
          biMergeCount: snap.biMergeCount,
          biOpen: active.open,
          biHigh: active.high,
          biLow: active.low,
          biClose: active.close,
          biVolume: _biVolume(bars, active.x1, active.x2),
          biCombineHigh: snap.biCombineHigh,
          biCombineLow: snap.biCombineLow,
          biCombineFx: snap.biCombineFx,
        ),
      );
    } else {
      out.add(
        _copyWithBi(
          f,
          clearBiIdx: true,
          biMergeInnerSeq: 1,
          biMergeCount: 1,
          biOpen: 0,
          biHigh: 0,
          biLow: 0,
          biClose: 0,
          biVolume: 0,
          biCombineHigh: 0,
          biCombineLow: 0,
          biCombineFx: 'UNKNOWN',
        ),
      );
    }
  }

  if (out.length < features.length) {
    out.addAll(features.sublist(out.length));
  }
  return out;
}
