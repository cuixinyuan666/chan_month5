import 'dart:math' as math;

import '../models/fractal_judgment_event.dart';
import '../models/k1_bar.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import 'k1_bar_view_compute.dart';

/// 十字线 as-of / 主图展示轨：与 Rust `build_k1_combine_frames_with` 同口径
/// （view 坐标 + 半侧锚定 + 截断监察 + 种子框首两单元不做包含）。
/// 展示轨可含冻结 + 进行中/pending（`asOfK1Bars(includeBuilding: true)` 或
/// `asOfLevelVirtualK1Bars`）；永久 L2 feed 仍只认冻结，本函数不回写结构。

List<KlineCombineFrame> computeK1CombineFrames(
  List<KlineBar> bars,
  List<K1Bar> k1Bars, {
  bool truncationCheck = true,
  bool validityCheck = true,
  /// 非空时：分型判断成立当步写入（x=触发单元 viewX2，无整框回填）
  List<FractalJudgmentEvent>? judgmentEvents,
}) {
  if (k1Bars.isEmpty) return const [];

  final views = buildK1BarViews(k1Bars);

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

  /// 与 Rust `trunc_price_step` / `trunc_rewrite_trigger_unit` 同构
  double truncPriceStep(double lastH, double lastL) {
    final span = (lastH - lastL).abs();
    final scale = math.max(math.max(lastL.abs(), lastH.abs()), 1.0);
    return math.max(math.max(span * 1e-4, scale * 1e-8), 1e-8);
  }

  ({double high, double low}) truncRewriteTrigger({
    required bool upLeg,
    required double lastH,
    required double lastL,
    required double uh,
    required double ul,
  }) {
    final step = truncPriceStep(lastH, lastL);
    var high = uh;
    var low = ul;
    if (upLeg) {
      if (high >= lastH) high = lastH - step;
      if (low >= lastL) low = lastL - step;
    } else {
      if (low <= lastL) low = lastL + step;
      if (high <= lastH) high = lastH + step;
    }
    if (high < low) {
      if (upLeg) {
        high = low;
      } else {
        low = high;
      }
    }
    return (high: high, low: low);
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

    // 种子框口径 A：首两单元强制独立，不做包含吸收（对齐 Rust seed_skip_first）
    if (highs.length == 1) {
      final forcedDir = dir == 'COMBINE' ? 'UP' : dir;
      highs.add(b.high);
      lows.add(b.low);
      dirs.add(forcedDir);
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
        // 截断：左框当场分型，本单元改写为第三元素形态后强制断开成新组
        final truncFx = g.upLeg ? 'TOP' : 'BOTTOM';
        fxAt[last] = truncFx;
        onFxEvent(truncFx, highs[last], lows[last]);
        // 截断：分型框=被标分型的左组（与确认 fractal_x1/x2 同口径）
        judgmentEvents?.add(FractalJudgmentEvent(
          x: v.viewX2,
          fx: truncFx,
          truncated: true,
          fractalX1: x1s[last],
          fractalX2: x2s[last],
          rightX1: v.viewX1,
          rightX2: v.viewX2,
        ));
        final forced = g.upLeg ? 'DOWN' : 'UP';
        final rw = truncRewriteTrigger(
          upLeg: g.upLeg,
          lastH: highs[last],
          lastL: lows[last],
          uh: b.high,
          ul: b.low,
        );
        highs.add(rw.high);
        lows.add(rw.low);
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

      // 常规包含吸收：Up 高高/高低，Down 低高/低低（与 Rust absorb 一致，一字线不特殊跳过）
      if (dirs[last] == 'DOWN') {
        highs[last] = math.min(highs[last], b.high);
        lows[last] = math.min(lows[last], b.low);
      } else {
        highs[last] = math.max(highs[last], b.high);
        lows[last] = math.max(lows[last], b.low);
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
          // 判断成立当步 = 第三元素单元右端 K0；框=中组（与确认同口径）
          judgmentEvents?.add(FractalJudgmentEvent(
            x: v.viewX2,
            fx: fx,
            fractalX1: x1s[mid],
            fractalX2: x2s[mid],
            // 第三元素组 K0 跨度（例 asOf=58 → [55,58]）
            rightX1: x1s[highs.length - 1],
            rightX2: x2s[highs.length - 1],
          ));
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
