import 'dart:math' as math;

import '../models/fractal_judgment_event.dart';
import '../models/k1_bar.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/pre_first_fractal_mode.dart';
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
  /// 首分型前的高高/低低口径（2026-11-19 全层同构）：
  /// - `highHigh`：首分型前包含吸收 high/low 都取最大；
  /// - `lowLow`：都取最小；
  /// - `seedBox` / `classic`：保持引擎原有方向吸收（不并框）。
  PreFirstFractalMode mode = PreFirstFractalMode.defaultMode,
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

  /// 首个「正式」分型是否已成立（三元素或截断确认）。
  /// 两元素章不算正式，不能解锁截断。
  /// 两元素盖章之后，后续包含改按组方向正常合并，不再用设置里的高高/低低。
  var firstStandardFxSeen = false;

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
    if (fx == 'TOP' || fx == 'BOTTOM') firstStandardFxSeen = true;
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

  /// 开新组（同 Rust `MergedGroup::new_first`）。
  void pushGroup(K1BarView v, K1Bar b, String t1, String t2, String dir) {
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
  }

  /// 首分型前的「两元素分型」（与 Rust `try_pair_fx_before_first` 同构）：
  /// 该层还没有任何分型时，中组（倒数第二组）high、low 都高于右组 → 顶；
  /// 都低于右组 → 底；其余（含包含/交叉）不判。**只盖章、不改价、不拆组**。
  /// 返回本次是否盖上分型（盖上则当步不再走三元素，与 Rust 返回顺序一致）。
  bool pairFxBeforeFirst(int judgeX) {
    if (fxAt.any((f) => f != 'UNKNOWN')) return false;
    final n = highs.length;
    if (n < 2) return false;
    final m = n - 2;
    final mh = highs[m];
    final ml = lows[m];
    final nh = highs[m + 1];
    final nl = lows[m + 1];
    final String fx;
    if (mh > nh && ml > nl) {
      fx = 'TOP';
    } else if (mh < nh && ml < nl) {
      fx = 'BOTTOM';
    } else {
      return false;
    }
    fxAt[m] = fx;
    onFxEvent(fx, mh, ml);
    judgmentEvents?.add(FractalJudgmentEvent(
      x: judgeX,
      fx: fx,
      fractalX1: x1s[m],
      fractalX2: x2s[m],
      rightX1: x1s[n - 1],
      rightX2: x2s[n - 1],
    ));
    return true;
  }

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

    // 首分型前口径（与 Rust `CombineEngine::feed_guarded` 种子分支同构，2026-11-19）：
    // **禁用截断**——包含关系先并入首组（首组方向恒 Up：高高低高；分型比的是
    // 合并框，不是原始 K），不包含则开新组；两种情况都跑两元素分型。
    if (highs.length == 1) {
      if (dir == 'COMBINE') {
        // 首组方向恒 Up（同 Rust `MergedGroup::new_first(u, MergeDir::Up`）。
        // 首分型前按设置的高高/低低（2026-11-19 全层同构）：低低=都取最小。
        if (!firstStandardFxSeen && mode == PreFirstFractalMode.lowLow) {
          highs[0] = math.min(highs[0], b.high);
          lows[0] = math.min(lows[0], b.low);
        } else {
          highs[0] = math.max(highs[0], b.high);
          lows[0] = math.max(lows[0], b.low);
        }
        x2s[0] = v.viewX2;
        t2s[0] = t2;
        unitCounts[0] += 1;
        endAtLeftHalf[0] = v.endAtLeftHalf;
        continue; // 只剩一组，两元素分型不成立
      }
      pushGroup(v, b, t1, t2, dir);
      // 两元素分型：中组（倒数第二组）vs 右组
      pairFxBeforeFirst(v.viewX2);
      continue;
    }

    if (dir == 'COMBINE') {
      // 二元素盖章前：按设置的高高/低低吸收，禁用截断。
      // 二元素盖章后：包含按该组方向走正常合并（向上高高，向下低低），截断仍等正式分型。
      if (!firstStandardFxSeen) {
        final pairStamped = fxAt.any((f) => f == 'TOP' || f == 'BOTTOM');
        final takeMin = pairStamped
            ? dirs[last] == 'DOWN'
            : mode == PreFirstFractalMode.lowLow ||
                (mode != PreFirstFractalMode.highHigh &&
                    dirs[last] == 'DOWN');
        if (takeMin) {
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
        continue;
      }
      final g = truncGuard();
      // 首个分型确认后 TruncGuard：原实现，不受第一条虚线 leave/一次额度约束
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
        firstStandardFxSeen = true;
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
      pushGroup(v, b, t1, t2, dir);
      // 首分型前先判两元素（Rust 同序：pair 判出即返回，当步不再走三元素）
      if (pairFxBeforeFirst(v.viewX2)) continue;
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
      beforeFirstStandardFx: !firstStandardFxSeen,
    );
  });
}
