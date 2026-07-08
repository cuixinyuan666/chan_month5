import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import 'default_bi_compute.dart';

/// Dart 回退：与 Rust `bi_virtual_bar_provisional` 同口径（进行中笔 K）。
BiVirtualBar? computeBiVirtualBarProvisional(
  List<KlineBar> bars,
  int beginFractalX1,
  int beginFractalX2,
  int endBarX,
  int dir,
  int segIdx,
) {
  if (bars.isEmpty) return null;
  // 起点取分型极点 K（与笔连线端点同口径）
  final x1c = fractalPoleBarIdx(bars, beginFractalX1, beginFractalX2, -dir) ??
      (beginFractalX1 < beginFractalX2 ? beginFractalX1 : beginFractalX2)
          .clamp(0, bars.length - 1);
  final x2c = endBarX.clamp(0, bars.length - 1);
  if (x2c < x1c) return null;

  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (var i = x1c; i <= x2c; i++) {
    final b = bars[i];
    if (b.high > hi) hi = b.high;
    if (b.low < lo) lo = b.low;
  }
  return BiVirtualBar(
    idx: segIdx,
    dir: dir,
    x1: x1c,
    x2: x2c,
    open: bars[x1c].open,
    high: hi,
    low: lo,
    close: bars[x2c].close,
    confirmX: x2c,
  );
}
