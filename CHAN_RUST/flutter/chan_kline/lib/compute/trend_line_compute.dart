import 'dart:math' as math;

import '../models/level_models.dart';
import 'fx_extend_line_compute.dart';

/// Kn趋势线：段内子线端点拟合支撑/压力（移植旧 `Math/TrendLine.py`）。
///
/// **方案 B·子线层同号**：显示 `K{n}` → 子线=`level==n+1`，父段=`level==n+2`
/// （K0≈旧工程：父=K1连线，子=K0连线）。≥3 子线才拟合。
/// 呈现对齐三型/四型：`FxExtendGroup` + 近邻窗；支撑/压力两条射线。

enum TrendLineSide { inside, outside }

class _TlPoint {
  final int x;
  final double y;
  const _TlPoint(this.x, this.y);

  double slopeTo(_TlPoint p) {
    if (x == p.x) return double.infinity;
    return (y - p.y) / (x - p.x);
  }
}

class _TlLine {
  final _TlPoint p;
  final double slope;
  const _TlLine(this.p, this.slope);

  double disTo(_TlPoint q) {
    if (slope.isInfinite || slope.isNaN) {
      return (q.x - p.x).abs().toDouble();
    }
    return (slope * q.x - q.y + p.y - slope * p.x).abs() /
        math.sqrt(slope * slope + 1);
  }
}

/// 拟合用子线（旧笔：begin/end 极点价）。
class TrendLineBi {
  final int beginX;
  final int endX;
  final double beginVal;
  final double endVal;
  final int dir; // +1 up / -1 down

  const TrendLineBi({
    required this.beginX,
    required this.endX,
    required this.beginVal,
    required this.endVal,
    required this.dir,
  });
}

LevelBundle? _bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

double _segBeginVal(LevelSegmentN s) {
  if (s.dir > 0) {
    return s.beginFractalLow != 0 || s.beginFractalHigh != 0
        ? s.beginFractalLow
        : s.low;
  }
  if (s.dir < 0) {
    return s.beginFractalHigh != 0 || s.beginFractalLow != 0
        ? s.beginFractalHigh
        : s.high;
  }
  return s.open;
}

double _segEndVal(LevelSegmentN s) {
  if (s.dir > 0) {
    return s.endFractalHigh != 0 || s.endFractalLow != 0
        ? s.endFractalHigh
        : s.high;
  }
  if (s.dir < 0) {
    return s.endFractalLow != 0 || s.endFractalHigh != 0
        ? s.endFractalLow
        : s.low;
  }
  return s.close;
}

TrendLineBi _fromSeg(LevelSegmentN s) {
  return TrendLineBi(
    beginX: s.beginPoleX,
    endX: s.endPoleX,
    beginVal: _segBeginVal(s),
    endVal: _segEndVal(s),
    dir: s.dir,
  );
}

TrendLineBi? _fromActive(LevelUnitBar act) {
  if (act.dir != 1 && act.dir != -1) return null;
  if (act.x1 < 0 || act.x2 < 0) return null;
  return TrendLineBi(
    beginX: act.x1,
    endX: act.x2,
    beginVal: act.dir > 0 ? act.low : act.high,
    endVal: act.dir > 0 ? act.high : act.low,
    dir: act.dir,
  );
}

double _initPeakSlope(int dir, TrendLineSide side) {
  if (side == TrendLineSide.inside) return 0;
  if (dir > 0) return double.infinity;
  return double.negativeInfinity;
}

/// 旧 `cal_tl`：从首点扫峰值斜率。
({_TlLine line, int idx}) _calTl(
  List<_TlPoint> cP,
  int dir,
  TrendLineSide side,
) {
  final p = cP.first;
  var peakSlope = _initPeakSlope(dir, side);
  var idx = 1;
  for (var pointIdx = 0; pointIdx < cP.length - 1; pointIdx++) {
    final p2 = cP[pointIdx + 1];
    final slope = p.slopeTo(p2);
    if ((dir > 0 && slope < 0) || (dir < 0 && slope > 0)) continue;
    if (side == TrendLineSide.inside) {
      if ((dir > 0 && slope > peakSlope) || (dir < 0 && slope < peakSlope)) {
        peakSlope = slope;
        idx = pointIdx + 1;
      }
    } else {
      if ((dir > 0 && slope < peakSlope) || (dir < 0 && slope > peakSlope)) {
        peakSlope = slope;
        idx = pointIdx + 1;
      }
    }
  }
  return (line: _TlLine(p, peakSlope), idx: idx);
}

/// 旧 `CTrendLine.cal`：隔笔取样 + 距离和最小。
_TlLine? calcTrendLine(List<TrendLineBi> lst, TrendLineSide side) {
  if (lst.length < 3) return null;
  final lastDir = lst.last.dir;
  if (lastDir != 1 && lastDir != -1) return null;

  // lst[-1::-2]：从末根隔笔倒取
  final sampled = <TrendLineBi>[];
  for (var i = lst.length - 1; i >= 0; i -= 2) {
    sampled.add(lst[i]);
  }
  final allP = <_TlPoint>[
    for (final bi in sampled)
      side == TrendLineSide.inside
          ? _TlPoint(bi.beginX, bi.beginVal)
          : _TlPoint(bi.endX, bi.endVal),
  ];
  if (allP.isEmpty) return null;

  var cP = List<_TlPoint>.from(allP);
  var bench = double.infinity;
  _TlLine? best;
  while (true) {
    final r = _calTl(cP, lastDir, side);
    final dis = allP.fold<double>(0, (s, p) => s + r.line.disTo(p));
    if (dis < bench) {
      bench = dis;
      best = r.line;
    }
    cP = cP.sublist(r.idx);
    if (cP.length <= 1) break;
  }
  return best;
}

/// 父段区间（冻段或 active）。
class _ParentSpan {
  final int beginX;
  final int endX;
  final int confirmMax;
  final int idx;

  const _ParentSpan({
    required this.beginX,
    required this.endX,
    required this.confirmMax,
    required this.idx,
  });
}

List<_ParentSpan> _collectParents(LevelBundle parentLv, int? asOf) {
  final out = <_ParentSpan>[];
  for (final s in parentLv.segments) {
    if (s.dir != 1 && s.dir != -1) continue;
    if (asOf != null && s.endConfirmX > asOf) continue;
    if (s.beginPoleX < 0 || s.endPoleX < 0) continue;
    out.add(_ParentSpan(
      beginX: math.min(s.beginPoleX, s.endPoleX),
      endX: math.max(s.beginPoleX, s.endPoleX),
      confirmMax: s.endConfirmX,
      idx: s.idx,
    ));
  }
  final act = parentLv.activeUnit;
  if (act != null && (act.dir == 1 || act.dir == -1)) {
    if (asOf == null || act.x1 <= asOf) {
      final lo = math.min(act.x1, act.x2);
      final hi = asOf != null ? math.min(math.max(act.x1, act.x2), asOf) : math.max(act.x1, act.x2);
      if (lo >= 0 && hi >= lo) {
        final i = out.indexWhere((e) => e.idx == act.idx);
        final span = _ParentSpan(
          beginX: lo,
          endX: hi,
          confirmMax: asOf ?? act.x2,
          idx: act.idx,
        );
        if (i >= 0) {
          out[i] = span;
        } else {
          out.add(span);
        }
      }
    }
  }
  out.sort((a, b) {
    final c = a.beginX.compareTo(b.beginX);
    return c != 0 ? c : a.idx.compareTo(b.idx);
  });
  return out;
}

List<TrendLineBi> _collectChildren(
  LevelBundle childLv,
  _ParentSpan parent,
  int? asOf,
) {
  final raw = <TrendLineBi>[];
  for (final s in childLv.segments) {
    if (s.dir != 1 && s.dir != -1) continue;
    if (asOf != null && s.endConfirmX > asOf) continue;
    if (s.beginPoleX < 0 || s.endPoleX < 0) continue;
    final lo = math.min(s.beginPoleX, s.endPoleX);
    final hi = math.max(s.beginPoleX, s.endPoleX);
    // 子线落在父段区间内（含端点共享）
    if (lo >= parent.beginX && hi <= parent.endX) {
      raw.add(_fromSeg(s));
    }
  }
  final actUnit = childLv.activeUnit;
  if (actUnit != null) {
    final act = _fromActive(actUnit);
    if (act != null && (asOf == null || act.beginX <= asOf)) {
      final lo = math.min(act.beginX, act.endX);
      final hi = math.max(act.beginX, act.endX);
      if (lo >= parent.beginX && hi <= parent.endX) {
        final i = raw.indexWhere(
          (e) => e.beginX == act.beginX && e.endX == act.endX,
        );
        if (i >= 0) {
          raw[i] = act;
        } else {
          raw.add(act);
        }
      }
    }
  }
  raw.sort((a, b) {
    final c = a.beginX.compareTo(b.beginX);
    return c != 0 ? c : a.endX.compareTo(b.endX);
  });
  return raw;
}

FxExtendRay? _lineToRay(_TlLine line, _ParentSpan parent, String kind) {
  if (line.slope.isNaN || line.slope.isInfinite) return null;
  double yAt(double x) => line.p.y + line.slope * (x - line.p.x);
  final x0 = parent.endX.toDouble();
  final x1 = parent.beginX.toDouble();
  return FxExtendRay(
    x0: x0,
    y0: yAt(x0),
    slope: line.slope,
    kind: kind,
    x1: x1,
    y1: yAt(x1),
  );
}

/// 全量父段组（每组支撑+压力）；asOf 截断父/子。
List<FxExtendGroup> calcTrendLineGroupsForLevel({
  required int displayKn,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  final childLv = _bundleAtLevel(levels, displayKn + 1);
  final parentLv = _bundleAtLevel(levels, displayKn + 2);
  if (childLv == null || parentLv == null) return const [];

  final out = <FxExtendGroup>[];
  for (final parent in _collectParents(parentLv, asOf)) {
    final children = _collectChildren(childLv, parent, asOf);
    if (children.length < 3) continue;
    final support = calcTrendLine(children, TrendLineSide.inside);
    final resist = calcTrendLine(children, TrendLineSide.outside);
    final rays = <FxExtendRay>[
      if (support != null) ?_lineToRay(support, parent, 'support'),
      if (resist != null) ?_lineToRay(resist, parent, 'resistance'),
    ];
    if (rays.isEmpty) continue;
    out.add(FxExtendGroup(
      poleMinX: parent.beginX,
      poleMaxX: parent.endX,
      confirmMax: parent.confirmMax,
      rays: rays,
    ));
  }
  return out;
}

/// tip：近邻父段的支撑/压力延长线落到 [atX] 的价格。
({double? support, double? resistance}) trendLinePriceReadout(
  List<FxExtendGroup> groups, {
  required int atX,
  int? focusX,
}) {
  final sel = selectFxExtendGroups(groups, focusX: focusX ?? atX);
  if (sel.isEmpty) return (support: null, resistance: null);
  double? support;
  double? resistance;
  for (final r in sel.first.rays) {
    if (r.kind == 'support') support = rayPriceAt(r, atX);
    if (r.kind == 'resistance') resistance = rayPriceAt(r, atX);
  }
  return (support: support, resistance: resistance);
}
