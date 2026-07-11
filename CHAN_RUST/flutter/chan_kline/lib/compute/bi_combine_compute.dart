import 'dart:math' as math;

import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import 'bi_virtual_bar_view_compute.dart';

/// 十字线 as-of 视图重建专用：与 Rust `build_bi_combine_frames_with` 同口径
/// （view 坐标 + 半侧锚定 + 截断监察）。末态口径由 Rust bundle 直供，此处仅服务
/// 十字线指向历史 K 时的本地重绘，避免高频跨 FFI。

List<KlineCombineFrame> computeBiCombineFrames(
  List<KlineBar> bars,
  List<BiVirtualBar> biBars, {
  bool truncationCheck = true,
  bool validityCheck = true,
}) {
  if (biBars.isEmpty) return const [];

  final views = buildBiVirtualBarViews(biBars);

  String combineDir(double ha, double la, double hb, double lb) {
    if (ha >= hb && la <= lb) return 'COMBINE';
    if (ha <= hb && la >= lb) return 'COMBINE';
    if (ha > hb && la > lb) return 'DOWN';
    if (ha < hb && la < lb) return 'UP';
    return 'COMBINE';
  }

  void updateFx(
    List<double> highs,
    List<double> lows,
    List<String> fxAt,
    int mid,
  ) {
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

  // 截断状态机（与 Rust TruncReplayState / LevelState 同构）
  String? anchorFx;
  var anchorHigh = 0.0;
  var anchorLow = 0.0;
  double? lastBottomLow;
  double? lastTopHigh;

  bool truncHit({
    required bool upLeg,
    required double refPrice,
    required double lastH,
    required double lastL,
    required double uh,
    required double ul,
  }) {
    if (upLeg) return uh >= lastH && ul < refPrice;
    return ul <= lastL && uh > refPrice;
  }

  ({bool upLeg, double refPrice})? truncGuard() {
    if (!truncationCheck || anchorFx == null) return null;
    if (anchorFx == 'BOTTOM' && lastBottomLow != null) {
      return (upLeg: true, refPrice: lastBottomLow!);
    }
    if (anchorFx == 'TOP' && lastTopHigh != null) {
      return (upLeg: false, refPrice: lastTopHigh!);
    }
    return null;
  }

  void onFxEvent(String fx, double high, double low) {
    if (fx == 'UNKNOWN') return;
    if (fx == 'BOTTOM') lastBottomLow = low;
    if (fx == 'TOP') lastTopHigh = high;
    if (anchorFx == null) {
      anchorFx = fx;
      anchorHigh = high;
      anchorLow = low;
      return;
    }
    if (anchorFx == fx) return; // 同向丢弃
    final ok = !validityCheck
        ? true
        : (anchorFx == 'BOTTOM' && fx == 'TOP')
            ? high > anchorLow
            : (anchorFx == 'TOP' && fx == 'BOTTOM')
                ? low < anchorHigh
                : false;
    if (ok) {
      anchorFx = fx;
      anchorHigh = high;
      anchorLow = low;
    }
  }

  final highs = <double>[];
  final lows = <double>[];
  final dirs = <String>[];
  final x1s = <int>[];
  final x2s = <int>[];
  final t1s = <String>[];
  final t2s = <String>[];
  final unitCounts = <int>[];
  final fxAt = <String>[];
  final endAtLeftHalf = <bool>[];
  final startAtRightHalf = <bool>[];

  for (final v in views) {
    final b = v.bar;
    final t1 = (v.viewX1 >= 0 && v.viewX1 < bars.length)
        ? bars[v.viewX1].timeText
        : '';
    final t2 = (v.viewX2 >= 0 && v.viewX2 < bars.length)
        ? bars[v.viewX2].timeText
        : '';

    if (highs.isEmpty) {
      highs.add(b.high);
      lows.add(b.low);
      dirs.add('COMBINE');
      x1s.add(v.viewX1);
      x2s.add(v.viewX2);
      t1s.add(t1);
      t2s.add(t2);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
      endAtLeftHalf.add(v.endAtLeftHalf);
      startAtRightHalf.add(v.startAtRightHalf);
      continue;
    }

    final last = highs.length - 1;
    final dir = combineDir(highs[last], lows[last], b.high, b.low);

    if (dir == 'COMBINE') {
      final g = truncGuard();
      if (g != null &&
          truncHit(
            upLeg: g.upLeg,
            refPrice: g.refPrice,
            lastH: highs[last],
            lastL: lows[last],
            uh: b.high,
            ul: b.low,
          )) {
        // 截断：左框当场分型，本单元强制断开成新组
        final truncFx = g.upLeg ? 'TOP' : 'BOTTOM';
        fxAt[last] = truncFx;
        onFxEvent(truncFx, highs[last], lows[last]);
        final forced = g.upLeg ? 'DOWN' : 'UP';
        highs.add(b.high);
        lows.add(b.low);
        dirs.add(forced);
        x1s.add(v.viewX1);
        x2s.add(v.viewX2);
        t1s.add(t1);
        t2s.add(t2);
        unitCounts.add(1);
        fxAt.add('UNKNOWN');
        endAtLeftHalf.add(v.endAtLeftHalf);
        startAtRightHalf.add(v.startAtRightHalf);
        continue;
      }

      // 常规包含吸收（doji 保护与 Rust absorb 一致）
      if (dirs[last] == 'DOWN') {
        if ((b.high - b.low).abs() > 1e-12 ||
            (b.low - lows[last]).abs() > 1e-12) {
          highs[last] = math.min(highs[last], b.high);
          lows[last] = math.min(lows[last], b.low);
        }
      } else {
        if ((b.high - b.low).abs() > 1e-12 ||
            (b.high - highs[last]).abs() > 1e-12) {
          highs[last] = math.max(highs[last], b.high);
          lows[last] = math.max(lows[last], b.low);
        }
      }
      x2s[last] = v.viewX2;
      t2s[last] = t2;
      unitCounts[last] += 1;
      endAtLeftHalf[last] = v.endAtLeftHalf;
    } else {
      highs.add(b.high);
      lows.add(b.low);
      dirs.add(dir);
      x1s.add(v.viewX1);
      x2s.add(v.viewX2);
      t1s.add(t1);
      t2s.add(t2);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
      endAtLeftHalf.add(v.endAtLeftHalf);
      startAtRightHalf.add(v.startAtRightHalf);
      if (highs.length >= 3) {
        final mid = highs.length - 2;
        updateFx(highs, lows, fxAt, mid);
        final fx = fxAt[mid];
        if (fx == 'TOP' || fx == 'BOTTOM') {
          onFxEvent(fx, highs[mid], lows[mid]);
        }
      }
    }
  }

  var viewCursor = 0;
  return List.generate(highs.length, (i) {
    final cnt = unitCounts[i];
    final frameStart = cnt > 1 ? false : views[viewCursor].startAtRightHalf;
    final frameEnd = cnt > 1 ? false : views[viewCursor].endAtLeftHalf;
    viewCursor += cnt;
    return KlineCombineFrame(
      x1: x1s[i],
      x2: x2s[i],
      t1: t1s[i],
      t2: t2s[i],
      high: highs[i],
      low: lows[i],
      fx: fxAt[i],
      count: cnt,
      endAtLeftHalf: frameEnd,
      startAtRightHalf: frameStart,
    );
  });
}
