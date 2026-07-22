import 'dart:math' as math;

import '../models/fractal_judgment_event.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';

/// 十字线 as-of 视图重建专用：与 Rust `CombineEngine` 喂分钟 K 同口径
/// （包含合并 + 三元素分型 + 截断监察）。调用方传入 `bars[idx<=asOf]` 切片。
/// 半侧标志恒 false（与 `frames_from_engine` 一致）。

List<KlineCombineFrame> computeK0CombineFrames(
  List<KlineBar> bars, {
  bool truncationCheck = true,
  bool validityCheck = true,
  /// 非空时：分型判断成立当步写入（x=触发当步 K0，无整框回填）
  List<FractalJudgmentEvent>? judgmentEvents,
}) {
  if (bars.isEmpty) return const [];

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

  for (final b in bars) {
    final x = b.idx;
    final t = b.timeText;

    if (highs.isEmpty) {
      highs.add(b.high);
      lows.add(b.low);
      dirs.add('COMBINE');
      x1s.add(x);
      x2s.add(x);
      t1s.add(t);
      t2s.add(t);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
      continue;
    }

    final last = highs.length - 1;
    final dir = combineDir(highs[last], lows[last], b.high, b.low);

    // 种子框口径 A：首两根 K0 强制独立，不做包含吸收（对齐 Rust seed_skip_first）
    if (highs.length == 1) {
      final forcedDir = dir == 'COMBINE' ? 'UP' : dir;
      highs.add(b.high);
      lows.add(b.low);
      dirs.add(forcedDir);
      x1s.add(x);
      x2s.add(x);
      t1s.add(t);
      t2s.add(t);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
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
          x: x,
          fx: truncFx,
          truncated: true,
          fractalX1: x1s[last],
          fractalX2: x2s[last],
          rightX1: x,
          rightX2: x,
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
        x1s.add(x);
        x2s.add(x);
        t1s.add(t);
        t2s.add(t);
        unitCounts.add(1);
        fxAt.add('UNKNOWN');
        continue;
      }

      // 常规包含吸收：Up 高高/高低，Down 低高/低低
      if (dirs[last] == 'DOWN') {
        highs[last] = math.min(highs[last], b.high);
        lows[last] = math.min(lows[last], b.low);
      } else {
        highs[last] = math.max(highs[last], b.high);
        lows[last] = math.max(lows[last], b.low);
      }
      x2s[last] = x;
      t2s[last] = t;
      unitCounts[last] += 1;
    } else {
      highs.add(b.high);
      lows.add(b.low);
      dirs.add(dir);
      x1s.add(x);
      x2s.add(x);
      t1s.add(t);
      t2s.add(t);
      unitCounts.add(1);
      fxAt.add('UNKNOWN');
      if (highs.length >= 3) {
        final mid = highs.length - 2;
        updateFx(highs, lows, fxAt, mid);
        final fx = fxAt[mid];
        if (fx == 'TOP' || fx == 'BOTTOM') {
          onFxEvent(fx, highs[mid], lows[mid]);
          // 判断成立当步 = 第三元素刚入场的这根 K；框=中组（与确认同口径）
          judgmentEvents?.add(FractalJudgmentEvent(
            x: x,
            fx: fx,
            fractalX1: x1s[mid],
            fractalX2: x2s[mid],
            // 第三元素组：K0 单根，右组=[x,x]，不与中组共用
            rightX1: x1s[highs.length - 1],
            rightX2: x2s[highs.length - 1],
          ));
        }
      }
    }
  }

  return List.generate(highs.length, (i) {
    return KlineCombineFrame(
      x1: x1s[i],
      x2: x2s[i],
      t1: t1s[i],
      t2: t2s[i],
      high: highs[i],
      low: lows[i],
      fx: fxAt[i],
      count: unitCounts[i],
      endAtLeftHalf: false,
      startAtRightHalf: false,
    );
  });
}
