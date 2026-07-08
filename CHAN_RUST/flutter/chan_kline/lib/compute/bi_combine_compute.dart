import 'dart:math' as math;



import '../models/bi_virtual_bar.dart';

import '../models/kline_bar.dart';

import '../models/kline_combine_frame.dart';

import 'bi_virtual_bar_view_compute.dart';



/// 十字线 as-of 视图重建专用：与 Rust `build_bi_combine_frames` 同口径
/// （view 坐标 + 半侧锚定）。末态口径由 Rust bundle 直供，此处仅服务
/// 十字线指向历史 K 时的本地重绘，避免高频跨 FFI。

List<KlineCombineFrame> computeBiCombineFrames(

  List<KlineBar> bars,

  List<BiVirtualBar> biBars,

) {

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

    } else {

      final last = highs.length - 1;

      final dir = combineDir(highs[last], lows[last], b.high, b.low);

      if (dir == 'COMBINE') {

        // doji 保护：与 Rust HlMergedKlc.try_add 一致，避免退化单元干扰极值

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

          updateFx(highs, lows, fxAt, highs.length - 2);

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


