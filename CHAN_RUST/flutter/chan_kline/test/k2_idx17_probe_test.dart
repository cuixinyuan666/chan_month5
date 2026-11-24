import 'dart:io';

import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/compute/first_fractal_rule.dart';
import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/compute/k1_combine_compute.dart';
import 'package:chan_kline/compute/pre_first_fractal_compute.dart';
import 'package:chan_kline/models/k1_bar.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:flutter_test/flutter_test.dart';

class _Probe {
  _Probe(this.bars, this.bundle, {required this.asOf});

  final List<KlineBar> bars;
  final KlineCombineBundle bundle;
  final int asOf;

  static const mode = PreFirstFractalMode.highHigh;
  static const subWindow = true;
  static const earlyDynamicUnit = true;
  static const truncationCheck = true;

  final memo = <int, List<KlineCombineFrame>>{};

  List<KlineCombineFrame> dropCovered(List<KlineCombineFrame> frames) {
    if (frames.length <= 1) return frames;
    final kept = <KlineCombineFrame>[];
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      var covered = false;
      for (var j = i + 1; j < frames.length; j++) {
        final g = frames[j];
        if (g.x1 <= f.x1 && g.x2 >= f.x2) {
          covered = true;
          break;
        }
      }
      if (!covered) kept.add(f);
    }
    return kept.isEmpty ? frames : kept;
  }

  List<K1Bar> dropDegenerateSeed(List<K1Bar> units) {
    final hasSpan = units.any((u) => u.x2 > u.x1);
    if (!hasSpan) return units;
    final kept = units.where((u) => u.x2 > u.x1 || u.high != u.low).toList();
    return kept.isEmpty ? units : kept;
  }

  LevelBundle? bundleAt(int level) {
    for (final b in bundle.levels) {
      if (b.level == level) return b;
    }
    return null;
  }

  List<K1Bar> boxedUnits(List<K1Bar> units, LevelBundle b, int asOfX) {
    if (units.isEmpty || bars.isEmpty) return units;
    LevelConfirm? firstFx;
    for (final c in b.confirms) {
      if (c.used) {
        firstFx = c;
        break;
      }
    }
    if (firstFx == null) return units;
    return boxedFirstFractalCandleBars(
      units: units,
      bars: bars,
      firstFractalX1: firstFx.fractalX1,
      firstFractalX2: firstFx.fractalX2,
      asOf: asOfX,
    );
  }

  bool pairFxStamped(int displayKn) {
    if (displayKn < 0) return false;
    final frames = displayCombineFrames(displayKn);
    if (frames.isEmpty) return false;
    final fx = frames.first.fx;
    return fx == 'TOP' || fx == 'BOTTOM';
  }

  List<K1Bar>? openingSpanOfParent(int parentKn, int asOfX) {
    final parentLevel = parentKn - 1;
    if (parentLevel < 0 || asOfX < 0) return null;
    final b = bundleAt(parentLevel);
    if (b == null) return null;
    final raw = asOfLevelVirtualK1Bars(
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      level: parentLevel,
      asOf: asOfX,
      includeBuilding: true,
    );
    final shown = boxedUnits(raw, b, asOfX);
    if (shown.isEmpty) return null;
    var x1 = shown.first.x1;
    var x2 = shown.first.x2;
    var high = shown.first.high;
    var low = shown.first.low;
    for (final u in shown) {
      if (u.x1 < x1) x1 = u.x1;
      if (u.x2 > x2) x2 = u.x2;
      if (u.high > high) high = u.high;
      if (u.low < low) low = u.low;
    }
    final open = shown.first.open.clamp(low, high).toDouble();
    final close = shown.last.close.clamp(low, high).toDouble();
    final confirmed = k2SecondDynamicBar(parentKn, asOfX) != null;
    return <K1Bar>[
      K1Bar(
        idx: 0,
        dir: 1,
        x1: x1,
        x2: x2,
        open: open,
        high: high,
        low: low,
        close: close,
        confirmX: confirmed ? asOfX : asOfX + 1,
      ),
    ];
  }

  List<KlineCombineFrame> displayCombineFrames(int displayKn) {
    final cached = memo[displayKn];
    if (cached != null) return cached;
    List<KlineCombineFrame> frames;
    if (displayKn <= 0) {
      frames = applyPreFirstFractalMode(
        bundle.frames,
        mode: mode,
        subWindow: subWindow,
        earlyDynamicUnit: earlyDynamicUnit,
      );
    } else {
      frames = levelDisplayCombineFrames(displayKn);
      if (frames.isEmpty && displayKn == 1) {
        frames = bundle.k1CombineFrames;
      }
    }
    frames = dropCovered(frames);
    memo[displayKn] = frames;
    return frames;
  }

  List<K1Bar> knDynamicLegs(int parentDisplayKn, int asOfX) {
    if (parentDisplayKn < 0 || asOfX < 0 || bars.isEmpty) return const [];
    final frames = displayCombineFrames(parentDisplayKn);
    if (frames.length < 2) return const [];
    final legs = <K1Bar>[];
    for (var j = 2; j <= frames.length; j++) {
      final anchor = frames[j - 1];
      final afx = anchor.fx;
      if ((afx != 'TOP' && afx != 'BOTTOM') || anchor.x2 <= anchor.x1) break;
      final anchorTop = afx == 'TOP';
      final polePrice = anchorTop ? anchor.high : anchor.low;
      final poleIdx = barWithPrice(anchor.x1, anchor.x2, polePrice,
          useHigh: anchorTop);
      if (poleIdx < 0) break;
      final dirUp = !anchorTop;
      K1Bar? leg;
      if (j < frames.length) {
        final endFrame = frames[j];
        final efx = endFrame.fx;
        if ((efx == 'TOP' || efx == 'BOTTOM') && endFrame.x2 > endFrame.x1) {
          final endPrice = dirUp ? endFrame.high : endFrame.low;
          final endIdx = barWithPrice(endFrame.x1, endFrame.x2, endPrice,
              useHigh: dirUp);
          if (endIdx < 0) break;
          leg = K1Bar(
            idx: j,
            dir: dirUp ? 1 : -1,
            x1: poleIdx < endIdx ? poleIdx : endIdx,
            x2: poleIdx > endIdx ? poleIdx : endIdx,
            open: polePrice,
            high: polePrice > endPrice ? polePrice : endPrice,
            low: polePrice < endPrice ? polePrice : endPrice,
            close: endPrice,
            confirmX: endIdx,
          );
        }
      }
      leg ??= openEndedDynamicLeg(
        idx: j,
        dir: dirUp ? 1 : -1,
        poleIdx: poleIdx,
        polePrice: polePrice,
        asOfX: asOfX,
      );
      if (leg == null) break;
      legs.add(leg);
    }
    return legs;
  }

  K1Bar? openEndedDynamicLeg({
    required int idx,
    required int dir,
    required int poleIdx,
    required double polePrice,
    required int asOfX,
  }) {
    int? extremeIdx;
    double? extremePrice;
    if (dir > 0) {
      var hi = double.negativeInfinity;
      for (var i = poleIdx; i <= asOfX && i < bars.length; i++) {
        if (bars[i].high > hi) {
          hi = bars[i].high;
          extremeIdx = i;
          extremePrice = hi;
        }
      }
    } else {
      var lo = double.infinity;
      for (var i = poleIdx; i <= asOfX && i < bars.length; i++) {
        if (bars[i].low < lo) {
          lo = bars[i].low;
          extremeIdx = i;
          extremePrice = lo;
        }
      }
    }
    if (extremeIdx == null || extremePrice == null || extremeIdx <= poleIdx) {
      return null;
    }
    return K1Bar(
      idx: idx,
      dir: dir,
      x1: poleIdx,
      x2: extremeIdx,
      open: polePrice,
      high: polePrice > extremePrice ? polePrice : extremePrice,
      low: polePrice < extremePrice ? polePrice : extremePrice,
      close: extremePrice,
      confirmX: asOfX + 1,
    );
  }

  int barWithPrice(int x1, int x2, double price, {required bool useHigh}) {
    if (bars.isEmpty) return -1;
    final a = x1 < 0 ? 0 : x1;
    var b = x2;
    if (b >= bars.length) b = bars.length - 1;
    if (a > b || a >= bars.length) return -1;
    for (var i = a; i <= b; i++) {
      final p = useHigh ? bars[i].high : bars[i].low;
      if ((p - price).abs() < 1e-9) return i;
    }
    return -1;
  }

  K1Bar? k2SecondDynamicBar(int parentDisplayKn, int asOfX) {
    if (parentDisplayKn < 0 || asOfX < 0 || bars.isEmpty) return null;
    final frames = displayCombineFrames(parentDisplayKn);
    if (frames.length < 2) return null;
    final first = frames.first;
    final right = frames[1];
    if (first.x2 <= first.x1) return null;
    final fx = first.fx;
    if (fx != 'TOP' && fx != 'BOTTOM') return null;
    final top = fx == 'TOP';
    final polePrice = top ? first.high : first.low;
    final endPrice = top ? right.low : right.high;
    final poleIdx = barWithPrice(first.x1, first.x2, polePrice, useHigh: top);
    final endIdx = barWithPrice(right.x1, right.x2, endPrice, useHigh: !top);
    if (poleIdx < 0 || endIdx < 0) return null;
    final rightFixed = right.fx == 'TOP' || right.fx == 'BOTTOM';
    return K1Bar(
      idx: 1,
      dir: top ? -1 : 1,
      x1: poleIdx < endIdx ? poleIdx : endIdx,
      x2: poleIdx > endIdx ? poleIdx : endIdx,
      open: polePrice,
      high: polePrice > endPrice ? polePrice : endPrice,
      low: polePrice < endPrice ? polePrice : endPrice,
      close: endPrice,
      confirmX: rightFixed ? endIdx : asOfX + 1,
    );
  }

  List<KlineCombineFrame> levelDisplayCombineFrames(int kn) {
    final unitLevel = kn - 1;
    final b = bundleAt(unitLevel);
    if (b == null) return const [];
    final barsForCombine = bars.where((x) => x.idx <= asOf).toList();
    var virtualUnits = asOfLevelVirtualK1Bars(
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      level: unitLevel,
      asOf: asOf,
      includeBuilding: true,
    );
    if (virtualUnits.isEmpty || barsForCombine.isEmpty) return const [];

    if (earlyDynamicUnit && kn >= 1) {
      final parentFrames = displayCombineFrames(kn - 1);
      if (parentFrames.isNotEmpty) {
        final dyn = buildPreFirstDynamicK1Bars(
          bars: bars,
          parentFrames: parentFrames,
          asOf: asOf,
        );
        if (dyn.isNotEmpty) {
          final parentHead = parentFrames.first;
          if (mode == PreFirstFractalMode.highHigh ||
              mode == PreFirstFractalMode.lowLow) {
            virtualUnits = dropDegenerateSeed(virtualUnits);
            if (unitLevel >= 1) {
              final chain = preFirstDynChain(unitLevel, asOf);
              if (chain != null) {
                virtualUnits = chain;
              } else {
                final spanned = openingSpanOfParent(unitLevel, asOf);
                virtualUnits =
                    (spanned != null && spanned.isNotEmpty) ? spanned : dyn;
              }
            } else if (dyn.length == 2 && !fxIsUnknownCodeUnit(parentHead.fx)) {
              final end = parentHead.x2;
              virtualUnits = [
                for (final u in virtualUnits)
                  if (u.x1 <= end && u.x2 > end)
                      K1Bar(
                        idx: u.idx,
                        dir: u.dir,
                        x1: u.x1,
                        x2: end,
                        open: u.open,
                        high: u.high,
                        low: u.low,
                        close: u.close,
                        confirmX: u.confirmX,
                      )
                    else
                      u,
              ];
              final hasSecond = virtualUnits.any((u) => u.x1 >= end);
              if (!hasSecond) {
                virtualUnits = <K1Bar>[...virtualUnits, dyn[1]];
              }
            }
          }
        }
      }
    }

    if (kn >= 2 && earlyDynamicUnit) {
      final ready = pairFxStamped(kn - 2);
      final spanned = openingSpanOfParent(kn - 1, asOf);
      if (!ready || spanned == null) return const [];
    }

    if (kn == 2) {
      // ignore: avoid_print
      print('kn=2 virtualUnits=${virtualUnits.length}');
      for (final u in virtualUnits) {
        // ignore: avoid_print
        print('   unit ${fmtUnit(u)}');
      }
    }
    final displayFrames = computeK1CombineFrames(
      barsForCombine,
      virtualUnits,
      truncationCheck: truncationCheck,
      mode: mode,
    );
    if (displayFrames.isEmpty) return const [];
    return applyPreFirstFractalMode(
      displayFrames,
      mode: mode,
      subWindow: subWindow,
      earlyDynamicUnit: earlyDynamicUnit,
    );
  }

  /// K2 窗口蜡烛（unitLevel=1）最终 K1Bar 列表（含 _withK2Dynamic 补的第 1 根及续接腿）。
  /// 镜像 `_levelUnitViewsForLevel` + `_withK2Dynamic` 的最终 K1Bar 列表。
  /// [unitLevel] 是结构层：K2 窗口=1，K3 窗口=2，K1 窗口=0。
  List<K1Bar> knCandleUnits(int unitLevel) {
    final b = bundleAt(unitLevel);
    if (b == null) return const [];
    var virtualUnits = asOfLevelVirtualK1Bars(
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      level: unitLevel,
      asOf: asOf,
      includeBuilding: true,
    );
    List<K1Bar>? candleDyn;
    var waitConfirm = false;
    if (earlyDynamicUnit && unitLevel >= 1) {
      final parentFrames = displayCombineFrames(unitLevel);
      if (parentFrames.isNotEmpty) {
        final dyn = buildPreFirstDynamicK1Bars(
          bars: bars,
          parentFrames: parentFrames,
          asOf: asOf,
        );
        if (dyn.isNotEmpty) {
          candleDyn = dyn;
          final parentHead = parentFrames.first;
          final parentPreFirst = parentHead.beforeFirstStandardFx ||
              fxIsUnknownCodeUnit(parentHead.fx);
          if (virtualUnits.isEmpty) {
            virtualUnits = dyn;
          } else if (!parentPreFirst &&
              virtualUnits.length == 1 &&
              dyn.length == 2 &&
              !fxIsUnknownCodeUnit(parentHead.fx)) {
            virtualUnits = <K1Bar>[...virtualUnits, dyn[1]];
          }
        }
      }
    }
    if (earlyDynamicUnit && unitLevel >= 1) {
      final ready = pairFxStamped(unitLevel - 1);
      if (!ready) {
        waitConfirm = true;
        virtualUnits = const [];
      } else {
        final spanned = openingSpanOfParent(unitLevel, asOf);
        if (spanned != null) {
          virtualUnits = spanned;
        } else if (candleDyn != null && candleDyn.isNotEmpty) {
          virtualUnits = candleDyn;
        }
      }
    }
    if (waitConfirm) return const [];
    final boxed = boxedUnits(virtualUnits, b, asOf);
    if (boxed.length != 1) return boxed;
    final second = k2SecondDynamicBar(unitLevel, asOf);
    if (second == null) return boxed;
    final legs = knDynamicLegs(unitLevel, asOf);
    final chain = <K1Bar>[second, ...legs];
    final head = boxed.single;
    final cut = chain.first.x1;
    final headEnd = head.x2 > cut && head.x1 <= cut ? cut : head.x2;
    final headBar = K1Bar(
      idx: head.idx,
      dir: head.dir,
      x1: head.x1,
      x2: headEnd,
      open: head.open,
      high: head.high,
      low: head.low,
      close: head.close,
      confirmX: head.confirmX,
    );
    return <K1Bar>[headBar, ...chain];
  }

  /// 镜像 widget `_preFirstDynChain`：开口跨度 + idx=1 + 续接腿。
  List<K1Bar>? preFirstDynChain(int unitLevel, int asOfX) {
    if (unitLevel < 1 || asOfX < 0) return null;
    final spanned = openingSpanOfParent(unitLevel, asOfX);
    if (spanned == null || spanned.isEmpty) return null;
    final second = k2SecondDynamicBar(unitLevel, asOfX);
    if (second == null) return null;
    final legs = knDynamicLegs(unitLevel, asOfX);
    final head = spanned.first;
    final cut = second.x1;
    final headEnd = head.x2 > cut && head.x1 <= cut ? cut : head.x2;
    final headBar = K1Bar(
      idx: head.idx,
      dir: head.dir,
      x1: head.x1,
      x2: headEnd,
      open: head.open,
      high: head.high,
      low: head.low,
      close: head.close,
      confirmX: head.confirmX,
    );
    return <K1Bar>[headBar, second, ...legs];
  }

  /// 镜像 `_drawOneLevelLines` + `_drawBuildingLevelLine`（level=displayKn）。
  void dumpLevelLines(int level, int asOfX) {
    final b = bundleAt(level);
    if (b == null) {
      // ignore: avoid_print
      print('asOf=$asOfX level=$level no bundle');
      return;
    }
    final segments = asOfLevelSegments(
      levels: bundle.levels,
      level: level,
      asOf: asOfX,
    );
    // ignore: avoid_print
    print('asOf=$asOfX level=$level segments=${segments.length} '
        'confirms=${b.confirms.where((c) => c.used).length}');
    for (final s in segments) {
      // ignore: avoid_print
      print('   seg idx=${s.idx} pole=${s.beginPoleX}..${s.endPoleX} '
          'fx=${s.beginFractalX1}..${s.endFractalX1} dir=${s.dir} '
          'cx=${s.beginConfirmX}..${s.endConfirmX}');
    }
    final virtualUnits = asOfLevelVirtualK1Bars(
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      level: level,
      asOf: asOfX,
      includeBuilding: true,
      includePreAnchor: true,
    );
    final frozenIdx = <int>{for (final s in segments) s.idx};
    final liveJudgments = collectFractalJudgmentEvents(
      kn: level,
      bars: bars,
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      asOf: asOfX,
      truncationCheck: true,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: asOfX,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      levelConfirms: b.confirms,
      liveJudgments: liveJudgments,
      seedBeforeFirstPoleSolid: level != 1,
    );
    // ignore: avoid_print
    print('   buildingLines=${lines.length} '
        'liveJs=${liveJudgments.map((j) => '${j.fx}@${j.x}').join(',')}');
    for (final l in lines) {
      // ignore: avoid_print
      print('   dir=${l.dir} solid=${l.asSolid} '
          'begin=(${l.begin.barIdx},${l.begin.price}) end=(${l.end.barIdx},${l.end.price}) '
          'src=${l.beginSrc}->${l.endSrc} unitIdx=${l.unitIdx}');
    }
    final candles = knCandleUnits(level - 1);
    // ignore: avoid_print
    print('   K$level candleUnits=${candles.length}');
    for (final u in candles) {
      // ignore: avoid_print
      print('      ${fmtUnit(u)}');
    }
    final frames = displayCombineFrames(level);
    // ignore: avoid_print
    print('   displayKn=$level frames=${frames.length} '
        'firstFx=${frames.isEmpty ? '-' : frames.first.fx} pre=${frames.isEmpty ? '-' : frames.first.beforeFirstStandardFx}');
    for (final f in frames) {
      // ignore: avoid_print
      print('      ${fmtFrame(f)}');
    }
  }

  /// 镜像 `_drawBuildingK0Line` + `_drawPreFirstFractalTipLines`（displayKn=0）。
  void dumpK0Lines(int asOfX) {
    final virtualUnits = asOfK1Bars(
      bars: bars,
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      defaultK0Policy: bundle.defaultK0Policy,
      asOf: asOfX,
      includeBuilding: true,
    );
    final frozenIdx = <int>{
      for (final s in asOfLevelSegments(
        levels: bundle.levels,
        level: 0,
        asOf: asOfX,
      ))
        s.idx,
    };
    final liveJudgments = collectFractalJudgmentEvents(
      kn: 0,
      bars: bars,
      levels: bundle.levels,
      barFeatures: bundle.barFeatures,
      asOf: asOfX,
      truncationCheck: true,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: asOfX,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      k0Confirms: bundle.k0Confirms,
      liveJudgments: liveJudgments,
    );
    // ignore: avoid_print
    print('asOf=$asOfX buildingLines=${lines.length} '
        'liveJs=${liveJudgments.map((j) => '${j.fx}@${j.x}').join(',')}');
    for (final l in lines) {
      // ignore: avoid_print
      print('   dir=${l.dir} solid=${l.asSolid} '
          'begin=(${l.begin.barIdx},${l.begin.price}) end=(${l.end.barIdx},${l.end.price}) '
          'src=${l.beginSrc}->${l.endSrc} unitIdx=${l.unitIdx}');
    }
    final frames = displayCombineFrames(0);
    if (frames.length >= 2) {
      final first = frames.first;
      final second = frames[1];
      final top = first.fx == 'TOP';
      final bIdx = _poleIdx(first.x1, first.x2, useHigh: top);
      final eIdx = _poleIdx(second.x1, second.x2, useHigh: !top);
      // ignore: avoid_print
      print('   tipLine: first.fx=${first.fx} '
          'pole0=${top ? first.low : first.high}@${bIdx} '
          'pole1=${top ? second.high : second.low}@${eIdx}');
    }
  }

  int _poleIdx(int x1, int x2, {required bool useHigh}) {
    final a = x1 < 0 ? 0 : x1;
    var b = x2;
    if (b >= bars.length) b = bars.length - 1;
    if (a > b || a >= bars.length) return -1;
    var best = a;
    var bp = useHigh ? double.negativeInfinity : double.infinity;
    for (var i = a; i <= b; i++) {
      final p = useHigh ? bars[i].high : bars[i].low;
      if (useHigh ? p > bp : p < bp) {
        bp = p;
        best = i;
      }
    }
    return best;
  }

  String fmtFrame(KlineCombineFrame f) =>
      'x=${f.x1}..${f.x2} h=${f.high} l=${f.low} fx=${f.fx} cnt=${f.count} pre=${f.beforeFirstStandardFx}';

  String fmtUnit(K1Bar u) =>
      'idx=${u.idx} x=${u.x1}..${u.x2} o=${u.open} h=${u.high} l=${u.low} c=${u.close} cx=${u.confirmX}';
}

void main() {
  late List<KlineBar> bars;

  setUpAll(() async {
    final bridge = ChanBridge.instance;
    bridge.ensureInitialized();
    final raw = File('../../../a_Data/test/custom.1m.csv').readAsStringSync();
    final lines = raw.trim().split('\n');
    bars = [];
    for (var i = 1; i < lines.length; i++) {
      final p = lines[i].trim().split(',');
      if (p.length < 6) continue;
      bars.add(KlineBar(
        idx: bars.length,
        timeMs: 0,
        timeText: p[0],
        open: double.parse(p[1]),
        high: double.parse(p[2]),
        low: double.parse(p[3]),
        close: double.parse(p[4]),
        volume: double.parse(p[5]),
        amount: 0,
      ));
    }
    expect(bars.length, greaterThan(14));
  });

  _Probe probeAt(int asOf) {
    final bundle = ChanBridge.instance.buildKlineCombineBundle(
      bars.sublist(0, asOf + 1),
      truncationCheck: true,
      earlyDynamicUnit: true,
      preFirstHighHigh: true,
    );
    return _Probe(bars, bundle, asOf: asOf);
  }

  void dump(String tag, _Probe probe, {int maxKn = 2}) {
    for (final b in probe.bundle.levels) {
      final a = b.activeUnit;
      // ignore: avoid_print
      print(
          '$tag level=${b.level} activeUnit=${a == null ? 'null' : 'idx=${a.idx} x=${a.x1}..${a.x2} cx=${a.confirmX}'} unitBars=${b.unitBars.length}');
    }
    for (var kn = 0; kn <= maxKn; kn++) {
      final frames = probe.displayCombineFrames(kn);
      // ignore: avoid_print
      print('$tag displayKn=$kn frames=${frames.length}');
      for (final f in frames) {
        // ignore: avoid_print
        print('   ${probe.fmtFrame(f)}');
      }
    }
    for (var ul = 1; ul <= maxKn; ul++) {
      final candles = probe.knCandleUnits(ul);
      // ignore: avoid_print
      print('$tag K${ul + 1} candle units=${candles.length}');
      for (final u in candles) {
        // ignore: avoid_print
        print('   ${probe.fmtUnit(u)}');
      }
    }
  }

  test('K0 idx=4 / idx=17 子窗口 K2 状态探针', () {
    for (final a in [2, 4, 12, 13, 14]) {
      dump('asOf=$a', probeAt(a), maxKn: 3);
    }
    probeAt(2).dumpK0Lines(2);
    probeAt(3).dumpK0Lines(3);
  });

  test('K0 idx=29/30 K2 连线探针', () {
    for (final a in [28, 29, 30, 31]) {
      probeAt(a).dumpLevelLines(2, a);
    }
  });

  test('K0 idx=30 截断核查探针', () {
    final p = probeAt(30);
    for (final b in p.bundle.levels) {
      // ignore: avoid_print
      print('level=${b.level} confirms:');
      for (final c in b.confirms) {
        if (c.x < 10 || c.x > 40) continue;
        // ignore: avoid_print
        print('   x=${c.x} fx=${c.fx} trunc=${c.truncated} used=${c.used} '
            'fxRange=${c.fractalX1}..${c.fractalX2} h=${c.fractalHigh} l=${c.fractalLow}');
      }
    }
    // level-0 单元（K1 蜡烛）x20..33
    final b0 = p.bundleAt(0);
    if (b0 != null) {
      // ignore: avoid_print
      print('level0 unitBars x20..33:');
      for (final u in b0.unitBars) {
        if (u.x2 < 20 || u.x1 > 33) continue;
        // ignore: avoid_print
        print('   idx=${u.idx} x=${u.x1}..${u.x2} o=${u.open} h=${u.high} '
            'l=${u.low} c=${u.close} cx=${u.confirmX}');
      }
    }
    // level-1 单元（K2 蜡烛）全文
    final b1 = p.bundleAt(1);
    if (b1 != null) {
      // ignore: avoid_print
      print('level1 unitBars:');
      for (final u in b1.unitBars) {
        // ignore: avoid_print
        print('   idx=${u.idx} x=${u.x1}..${u.x2} o=${u.open} h=${u.high} '
            'l=${u.low} c=${u.close} cx=${u.confirmX}');
      }
    }
  });
}
