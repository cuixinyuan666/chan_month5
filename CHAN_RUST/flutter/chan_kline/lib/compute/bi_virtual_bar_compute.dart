import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';

/// Dart 回退：与 Rust `build_bi_virtual_bars` 同口径。
List<BiVirtualBar> computeBiVirtualBars(
  List<KlineBar> bars,
  List<BiSegment> segments,
) {
  if (bars.isEmpty || segments.isEmpty) return const [];

  (double open, double high, double low, double close) hlRange(int x1, int x2) {
    final a = x1 < x2 ? x1 : x2;
    final b = x1 > x2 ? x1 : x2;
    final aClamped = a.clamp(0, bars.length - 1);
    final bClamped = b.clamp(0, bars.length - 1);
    var hi = double.negativeInfinity;
    var lo = double.infinity;
    for (var i = aClamped; i <= bClamped; i++) {
      final bar = bars[i];
      if (bar.high > hi) hi = bar.high;
      if (bar.low < lo) lo = bar.low;
    }
    return (bars[aClamped].open, hi, lo, bars[bClamped].close);
  }

  final out = <BiVirtualBar>[];
  for (final seg in segments) {
    final x1 = seg.beginFractalX1 < seg.beginFractalX2
        ? seg.beginFractalX1
        : seg.beginFractalX2;
    final x2 = seg.endFractalX1 > seg.endFractalX2
        ? seg.endFractalX1
        : seg.endFractalX2;
    final (open, high, low, close) = hlRange(x1, x2);
    out.add(
      BiVirtualBar(
        idx: seg.idx,
        dir: seg.dir,
        x1: x1,
        x2: x2,
        open: open,
        high: high,
        low: low,
        close: close,
        confirmX: seg.endConfirmX,
      ),
    );
  }
  return out;
}
