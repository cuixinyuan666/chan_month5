import '../models/kuaduan_frame.dart';
import '../models/level_models.dart';

/// 十字线 as-of 视图重建专用：与 Rust `find_kuaduan` + `level_kuaduan_frames` 同口径。
/// 调用方应只传入**已确认冻结**段（`asOfLevelSegments`，`endConfirmX <= asOf`）。

List<KuaDuanFrame> computeKuaduanFrames(
  List<LevelSegmentN> segs,
  int level,
) {
  if (segs.length < 3) return const [];

  final out = <KuaDuanFrame>[];
  var i = 0;
  while (i + 2 < segs.length) {
    final a = segs[i];
    final b = segs[i + 1];
    final c = segs[i + 2];
    // 三重叠：max(low) ≤ min(high)
    var zg = _max3(a.low, b.low, c.low); // 最高的低
    var zd = _min3(a.high, b.high, c.high); // 最低的高
    if (zg <= zd) {
      var endSeg = i + 2;
      var j = i + 3;
      // 延伸：下一段仍与 [ZG, ZD] 相交则纳入（部分相交也延伸，勿要求包住）
      while (j < segs.length &&
          segs[j].high >= zg &&
          segs[j].low <= zd) {
        final u = segs[j];
        if (u.low > zg) zg = u.low;
        if (u.high < zd) zd = u.high;
        endSeg = j;
        j += 1;
      }
      final s = segs[i];
      final e = segs[endSeg];
      // x 锚定：首/末段极点 K 包络（与 Rust kuaduan_to_frames 一致）
      final x1 =
          s.beginPoleX < e.beginPoleX ? s.beginPoleX : e.beginPoleX;
      final x2 = s.endPoleX > e.endPoleX ? s.endPoleX : e.endPoleX;
      out.add(KuaDuanFrame(
        seq: out.length + 1,
        x1: x1,
        x2: x2,
        high: zd, // ZD 上沿（更高价）
        low: zg, // ZG 下沿（更低价）
        level: level,
        count: endSeg - i + 1,
      ));
      // 脱离：从延伸末段下一根起新种子
      i = j;
    } else {
      i += 1;
    }
  }
  return out;
}

double _max3(double a, double b, double c) {
  var m = a;
  if (b > m) m = b;
  if (c > m) m = c;
  return m;
}

double _min3(double a, double b, double c) {
  var m = a;
  if (b < m) m = b;
  if (c < m) m = c;
  return m;
}
