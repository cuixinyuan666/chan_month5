import 'dart:math' as math;

import '../models/bi_confirm_signal.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import '../models/seg_analysis.dart';
import 'bi_virtual_bar_compute.dart';
import 'bi_virtual_bar_provisional_compute.dart';

/// 合并笔 K 逐步喂入状态（方案 A：支持进行中笔 K 更新）。
class _HlCombineStepState {
  final highs = <double>[];
  final lows = <double>[];
  final dirs = <String>[];
  final x1s = <int>[];
  final x2s = <int>[];
  final unitCounts = <int>[];
  final fxAt = <String>[];
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

  _FxHit? _midFxHit() {
    if (highs.length < 3) return null;
    final mid = highs.length - 2;
    final fx = fxAt[mid];
    if (fx != 'TOP' && fx != 'BOTTOM') return null;
    return _FxHit(
      fx: fx,
      fractalX1: x1s[mid],
      fractalX2: x2s[mid],
      fractalHigh: highs[mid],
      fractalLow: lows[mid],
    );
  }

  _FxHit? feedPermanent(_HlMergeUnit u) {
    if (provisional) {
      highs.removeLast();
      lows.removeLast();
      dirs.removeLast();
      x1s.removeLast();
      x2s.removeLast();
      unitCounts.removeLast();
      fxAt.removeLast();
      provisional = false;
    }
    return _feed(u);
  }

  _FxHit? updateProvisional(_HlMergeUnit u) {
    if (provisional && highs.isNotEmpty) {
      _replaceLastWith(u);
      return _midFxHit();
    }
    provisional = true;
    return _feed(u);
  }

  void clearProvisional() {
    if (!provisional) return;
    highs.removeLast();
    lows.removeLast();
    dirs.removeLast();
    x1s.removeLast();
    x2s.removeLast();
    unitCounts.removeLast();
    fxAt.removeLast();
    provisional = false;
  }

  void _replaceLastWith(_HlMergeUnit u) {
    final last = highs.length - 1;
    if (last == 0) {
      highs[0] = u.high;
      lows[0] = u.low;
      x1s[0] = u.x1;
      x2s[0] = u.x2;
      unitCounts[0] = 1;
      return;
    }
    final prevIdx = last - 1;
    final dir = _combineDir(
      highs[prevIdx],
      lows[prevIdx],
      u.high,
      u.low,
    );
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
      provisional = false;
    } else {
      highs[last] = u.high;
      lows[last] = u.low;
      dirs[last] = dir;
      x1s[last] = u.x1;
      x2s[last] = u.x2;
      unitCounts[last] = 1;
    }
    if (highs.length >= 3) {
      _updateFx(highs.length - 2);
    }
  }

  _FxHit? _feed(_HlMergeUnit u) {
    if (highs.isEmpty) {
      highs.add(u.high);
      lows.add(u.low);
      dirs.add('COMBINE');
      x1s.add(u.x1);
      x2s.add(u.x2);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
      return null;
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
      return null;
    }
    highs.add(u.high);
    lows.add(u.low);
    dirs.add(dir);
    x1s.add(u.x1);
    x2s.add(u.x2);
    unitCounts.add(1);
    fxAt.add('UNKNOWN');
    if (highs.length >= 3) {
      _updateFx(highs.length - 2);
      return _midFxHit();
    }
    return null;
  }
}

class _HlMergeUnit {
  final int x1;
  final int x2;
  final double high;
  final double low;

  const _HlMergeUnit({
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
  });
}

class _FxHit {
  final String fx;
  final int fractalX1;
  final int fractalX2;
  final double fractalHigh;
  final double fractalLow;

  const _FxHit({
    required this.fx,
    required this.fractalX1,
    required this.fractalX2,
    required this.fractalHigh,
    required this.fractalLow,
  });
}

_HlMergeUnit _unitFromVb(BiVirtualBar vb) => _HlMergeUnit(
      x1: vb.x1,
      x2: vb.x2,
      high: vb.high,
      low: vb.low,
    );

({_HlMergeUnit unit, int peakIdx})? _provisionalFromLastConfirm(
  List<KlineBar> bars,
  List<BiConfirmSignal> biConfirms,
  int barX,
  int peakIdx,
) {
  final valid = biConfirms
      .where((c) => c.fx == 'TOP' || c.fx == 'BOTTOM')
      .toList();
  if (valid.isEmpty) return null;
  final last = valid.last;
  if (last.x > barX) return null;
  final dir = last.fx == 'BOTTOM' ? 1 : -1;
  final vb = computeBiVirtualBarProvisional(
    bars,
    last.fractalX1,
    last.fractalX2,
    barX,
    dir,
    peakIdx,
  );
  if (vb == null) return null;
  return (unit: _unitFromVb(vb), peakIdx: peakIdx);
}

/// 当步进行中笔 K 单元（方案 A）。
({_HlMergeUnit unit, int peakIdx})? _provisionalUnitAt(
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
      final vb = computeBiVirtualBarProvisional(
        bars,
        seg.beginFractalX1,
        seg.beginFractalX2,
        barX,
        seg.dir,
        seg.idx,
      );
      if (vb == null) return null;
      return (unit: _unitFromVb(vb), peakIdx: seg.idx);
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

int _tryEmitSegConfirm(
  List<SegConfirmSignal> segConfirms,
  Set<String> frozen,
  int barX,
  _FxHit fx,
  int peakBiIdx,
  int Function() readFirstSegDir,
  void Function(int) writeFirstSegDir,
  List<FirstSegDirSignal> firstSegDirSignals,
  int Function() readBuildingSegDir,
  void Function(int) writeBuildingSegDir,
) {
  final key = '${fx.fractalX1}|${fx.fractalX2}|${fx.fx}';
  if (frozen.contains(key)) return 0;
  frozen.add(key);
  final endedSegDir = fx.fx == 'TOP' ? 1 : -1;
  final value = fx.fx == 'TOP' ? -1 : 1;
  segConfirms.add(
    SegConfirmSignal(
      x: barX,
      fx: fx.fx,
      value: value,
      endedSegDir: endedSegDir,
      peakBiIdx: peakBiIdx,
      fractalX1: fx.fractalX1,
      fractalX2: fx.fractalX2,
      fractalHigh: fx.fractalHigh,
      fractalLow: fx.fractalLow,
    ),
  );
  if (readFirstSegDir() == 0) {
    writeFirstSegDir(endedSegDir);
    firstSegDirSignals.add(FirstSegDirSignal(x: barX, dir: endedSegDir));
  }
  writeBuildingSegDir(-endedSegDir);
  return value;
}

/// Dart 回退：与 Rust `build_seg_analysis` 同口径（方案 A 进行中笔 K）。
SegAnalysisBundle computeSegAnalysis(
  List<KlineBar> bars,
  List<BiSegment> biSegments, [
  List<BiConfirmSignal> biConfirms = const [],
]) {
  if (bars.isEmpty) {
    return SegAnalysisBundle.empty();
  }

  final virtualBars = computeBiVirtualBars(bars, biSegments);
  final vbBySegIdx = {for (final v in virtualBars) v.idx: v};

  final mergeState = _HlCombineStepState();
  final segConfirms = <SegConfirmSignal>[];
  final frozenFractals = <String>{};
  final firstSegDirSignals = <FirstSegDirSignal>[];
  var firstSegDir = 0;
  var buildingSegDir = 0;
  var nextBi = 0;
  final barSnapshots = <BarSubSnapshot>[];

  for (var barX = 0; barX < bars.length; barX++) {
    var segConfirmVal = 0;

    while (nextBi < biSegments.length &&
        biSegments[nextBi].endConfirmX == barX) {
      final seg = biSegments[nextBi];
      final vb = vbBySegIdx[seg.idx] ??
          computeBiVirtualBars(bars, [seg]).firstOrNull;
      if (vb != null) {
        final hit = mergeState.feedPermanent(_unitFromVb(vb));
        if (hit != null) {
          segConfirmVal = _tryEmitSegConfirm(
            segConfirms,
            frozenFractals,
            barX,
            hit,
            seg.idx,
            () => firstSegDir,
            (v) => firstSegDir = v,
            firstSegDirSignals,
            () => buildingSegDir,
            (v) => buildingSegDir = v,
          );
        }
      }
      nextBi += 1;
    }

    final prov = _provisionalUnitAt(
      bars,
      biSegments,
      biConfirms,
      barX,
      nextBi,
    );
    if (prov != null) {
      // 方案 A：仅在临时状态探测进行中笔K分型，不污染永久合并链
      final early = mergeState.clone();
      final hit = early.updateProvisional(prov.unit);
      if (hit != null) {
        segConfirmVal = _tryEmitSegConfirm(
          segConfirms,
          frozenFractals,
          barX,
          hit,
          prov.peakIdx,
          () => firstSegDir,
          (v) => firstSegDir = v,
          firstSegDirSignals,
          () => buildingSegDir,
          (v) => buildingSegDir = v,
        );
      }
    }

    barSnapshots.add(
      BarSubSnapshot(
        idx: barX,
        buildingSegDir: buildingSegDir,
        firstSegDir: firstSegDir,
        segConfirm: segConfirmVal,
      ),
    );
  }

  final segLines = _buildSegLinesFromConfirms(segConfirms);

  return SegAnalysisBundle(
    segConfirms: segConfirms,
    firstSegDirSignals: firstSegDirSignals,
    segLines: segLines,
    barSubSnapshots: barSnapshots,
    buildingSegDir: buildingSegDir,
    firstSegDir: firstSegDir,
  );
}

List<SegLine> _buildSegLinesFromConfirms(List<SegConfirmSignal> confirms) {
  final valid =
      confirms.where((c) => c.fx == 'TOP' || c.fx == 'BOTTOM').toList();
  if (valid.length < 2) return const [];

  final lines = <SegLine>[];
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
    final beginPrice =
        dir > 0 ? prev.fractalLow : prev.fractalHigh;
    final endPrice = dir > 0 ? curr.fractalHigh : curr.fractalLow;
    final beginCx = (prev.fractalX1 + prev.fractalX2) ~/ 2;
    final endCx = (curr.fractalX1 + curr.fractalX2) ~/ 2;
    lines.add(
      SegLine(
        idx: lines.length,
        dir: dir,
        beginX: beginCx,
        endX: endCx,
        beginFractalX1: prev.fractalX1,
        beginFractalX2: prev.fractalX2,
        endFractalX1: curr.fractalX1,
        endFractalX2: curr.fractalX2,
        beginPrice: beginPrice,
        endPrice: endPrice,
      ),
    );
  }
  return lines;
}
