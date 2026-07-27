import '../models/level_models.dart';
import '../models/zs_frame.dart';

/// 中枢算法（对齐 Rust `ZSAlgo`；Auto 已放弃）
enum ZSAlgoKind {
  /// ≥3 连续段互相重叠
  normal,
  /// 首末段重叠即可（中段可跨越）
  overSeg,
}

/// 十字线 as-of 视图重建专用：与 Rust `find_zs` + `zs_to_frames` 同口径。
/// 调用方应只传入**已确认冻结**段（`asOfLevelSegments`，`endConfirmX <= asOf`）。
///
/// 默认口径（对齐 Rust `ZSConfig::default` + 指定 algo）：
/// - Normal：≥3 连续段互相重叠（`min(high) > max(low)`）
/// - OverSeg：首末段重叠即可
/// - 离开-返回延伸 + 相邻 [ZG,ZD] combine 合并
/// - 不做 one_bi_zs

class _ZS {
  int startIdx;
  int endIdx;
  int startSeg;
  int endSeg;
  double zg; // max(low) 下沿价
  double zd; // min(high) 上沿价
  int dir;
  bool isNineSegUpgrade;
  final List<int> memberSegs;

  _ZS({
    required this.startIdx,
    required this.endIdx,
    required this.startSeg,
    required this.endSeg,
    required this.zg,
    required this.zd,
    required this.dir,
    required this.isNineSegUpgrade,
    required this.memberSegs,
  });
}

List<ZSFrame> computeZSFrames(
  List<LevelSegmentN> segs,
  int level, {
  ZSAlgoKind algo = ZSAlgoKind.normal,
}) {
  if (segs.length < 3) return const [];

  final zsList = _findZs(segs, algo);
  return _zsToFrames(zsList, segs, level);
}

List<_ZS> _findZs(List<LevelSegmentN> segs, ZSAlgoKind algo) {
  final n = segs.length;
  final zsList = <_ZS>[];
  _ZS? cur;
  var i = 0;
  while (i < n) {
    var extended = false;
    if (cur != null) {
      if (_segOverlaps(cur.zg, cur.zd, segs[i])) {
        _extendZs(cur, segs, i);
        extended = true;
      } else if (i + 1 < n && _segOverlaps(cur.zg, cur.zd, segs[i + 1])) {
        // 离开-返回：离开段跳过，返回段纳入
        _extendZs(cur, segs, i + 1);
        i += 1;
        extended = true;
      }
    }
    if (extended) {
      i += 1;
      continue;
    }
    if (cur != null) {
      zsList.add(cur);
      cur = null;
      // segs[i]（离开段）作为新候选起点，不前进
    }
    final z = _tryConstructFrom(segs, i, algo);
    if (z != null) {
      final len = z.memberSegs.length;
      cur = z;
      i += len;
    } else {
      i += 1;
    }
  }
  if (cur != null) {
    zsList.add(cur);
  }
  _tryCombine(zsList, segs);
  return zsList;
}

bool _segOverlaps(double zg, double zd, LevelSegmentN u) =>
    u.high >= zg && u.low <= zd;

(double, double) _rangeOf(List<LevelSegmentN> segs, List<int> members) {
  var zg = double.negativeInfinity;
  var zd = double.infinity;
  for (final m in members) {
    final s = segs[m];
    if (s.low > zg) zg = s.low;
    if (s.high < zd) zd = s.high;
  }
  return (zg, zd);
}

_ZS _makeZs(List<int> members, List<LevelSegmentN> segs) {
  final (zg, zd) = _rangeOf(segs, members);
  final startSeg = members.first;
  final endSeg = members.last;
  final first = segs[startSeg];
  return _ZS(
    startIdx: first.idx,
    endIdx: segs[endSeg].idx,
    startSeg: startSeg,
    endSeg: endSeg,
    zg: zg,
    zd: zd,
    dir: first.dir,
    isNineSegUpgrade: members.length >= 9,
    memberSegs: List<int>.from(members),
  );
}

void _extendZs(_ZS z, List<LevelSegmentN> segs, int pos) {
  z.memberSegs.add(pos);
  final s = segs[pos];
  if (s.low > z.zg) z.zg = s.low;
  if (s.high < z.zd) z.zd = s.high;
  z.endSeg = pos;
  z.endIdx = s.idx;
  z.isNineSegUpgrade = z.memberSegs.length >= 9;
}

_ZS? _tryConstructFrom(List<LevelSegmentN> segs, int start, ZSAlgoKind algo) {
  if (start + 3 > segs.length) return null;
  final a = segs[start];
  final b = segs[start + 1];
  final c = segs[start + 2];
  final bool ok;
  switch (algo) {
    case ZSAlgoKind.normal:
      // 三者互相重叠：min(high) > max(low)
      final minHigh = _min3(a.high, b.high, c.high);
      final maxLow = _max3(a.low, b.low, c.low);
      ok = minHigh > maxLow;
      break;
    case ZSAlgoKind.overSeg:
      // 首末重叠即可
      final minHigh = a.high < c.high ? a.high : c.high;
      final maxLow = a.low > c.low ? a.low : c.low;
      ok = minHigh > maxLow;
      break;
  }
  if (!ok) return null;
  return _makeZs([start, start + 1, start + 2], segs);
}

bool _rangesOverlap(double lo1, double hi1, double lo2, double hi2) =>
    lo1 <= hi2 && lo2 <= hi1;

void _tryCombine(List<_ZS> zsList, List<LevelSegmentN> segs) {
  var changed = true;
  while (changed) {
    changed = false;
    var k = 0;
    while (k + 1 < zsList.length) {
      final a = zsList[k];
      final b = zsList[k + 1];
      if (_rangesOverlap(a.zg, a.zd, b.zg, b.zd)) {
        zsList[k] = _mergeTwo(a, b, segs);
        zsList.removeAt(k + 1);
        changed = true;
      } else {
        k += 1;
      }
    }
  }
}

_ZS _mergeTwo(_ZS a, _ZS b, List<LevelSegmentN> segs) {
  final members = <int>{...a.memberSegs, ...b.memberSegs}.toList()..sort();
  final z = _makeZs(members, segs);
  z.dir = a.dir; // 取前者方向（与 Rust merge_two 一致）
  return z;
}

List<ZSFrame> _zsToFrames(
  List<_ZS> zsList,
  List<LevelSegmentN> segs,
  int level,
) {
  final byIdx = <int, LevelSegmentN>{
    for (final s in segs) s.idx: s,
  };
  final out = <ZSFrame>[];
  for (var i = 0; i < zsList.length; i++) {
    final z = zsList[i];
    final s = byIdx[z.startIdx];
    final e = byIdx[z.endIdx];
    if (s == null || e == null) continue;
    final x1 =
        s.beginPoleX < e.beginPoleX ? s.beginPoleX : e.beginPoleX;
    final x2 = s.endPoleX > e.endPoleX ? s.endPoleX : e.endPoleX;
    out.add(ZSFrame(
      seq: i + 1,
      x1: x1,
      x2: x2,
      high: z.zd, // ZD 上沿（更高价）
      low: z.zg, // ZG 下沿（更低价）
      level: level,
      count: z.memberSegs.length,
      dir: z.dir,
      isNineSegUpgrade: z.isNineSegUpgrade,
      isSure: true,
    ));
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
