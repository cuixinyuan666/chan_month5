import 'dart:math' as math;

import '../models/level_models.dart';
import 'fx_extend_line_compute.dart';
import 'parent_span_collect.dart';

/// Kn趋势线：段内子线端点拟合支撑/压力（移植旧 `Math/TrendLine.py`）。
///
/// **方案 B·子线层同号**：显示 `K{n}` → 子线=`level==n+1`，父段=`level==n+2`
/// （K0≈旧工程：父=K1连线，子=K0连线）。≥3 子线才拟合。
/// 呈现对齐三型/四型：`FxExtendGroup` + 近邻窗；支撑/压力两条射线。

enum TrendLineSide { inside, outside }

/// 拟合用平面点。
class FitPoint {
  final int x;
  final double y;
  const FitPoint(this.x, this.y);
}

/// 拟合直线：过 anchor 点、给定斜率。
class FitLine {
  final FitPoint anchor;
  final double slope;
  const FitLine(this.anchor, this.slope);

  double yAt(double x) => anchor.y + slope * (x - anchor.x);

  double disTo(FitPoint q) {
    if (slope.isInfinite || slope.isNaN) {
      return (q.x - anchor.x).abs().toDouble();
    }
    return (slope * q.x - q.y + anchor.y - slope * anchor.x).abs() /
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

double _slopeBetween(FitPoint a, FitPoint b) {
  if (a.x == b.x) return double.infinity;
  return (b.y - a.y) / (b.x - a.x);
}

bool _slopeOk(int dir, double slope) {
  if (slope.isNaN) return false;
  if ((dir > 0 && slope < 0) || (dir < 0 && slope > 0)) return false;
  return true;
}

/// 旧 `cal_tl`：从首点扫峰值斜率。
(FitLine line, int idx) _calTl(
  List<FitPoint> cP,
  int dir,
  TrendLineSide side,
) {
  final p = cP.first;
  var peakSlope = _initPeakSlope(dir, side);
  var idx = 1;
  for (var pointIdx = 0; pointIdx < cP.length - 1; pointIdx++) {
    final p2 = cP[pointIdx + 1];
    final slope = _slopeBetween(p, p2);
    if (!_slopeOk(dir, slope)) continue;
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
  return (FitLine(p, peakSlope), idx);
}

/// 点到线距离和最小拟合（≥2 点）；供极贴合线与趋势线共用。
FitLine? calcMinDistFitLine(
  List<FitPoint> points, {
  required int dir,
  required TrendLineSide side,
}) {
  if (points.length < 2) return null;
  if (dir != 1 && dir != -1) return null;

  if (points.length == 2) {
    final a = points[0];
    final b = points[1];
    final slope = _slopeBetween(a, b);
    if (!_slopeOk(dir, slope)) return null;
    return FitLine(a, slope);
  }

  var cP = List<FitPoint>.from(points);
  var bench = double.infinity;
  FitLine? best;
  while (true) {
    final r = _calTl(cP, dir, side);
    final dis = points.fold<double>(0, (s, p) => s + r.$1.disTo(p));
    if (dis < bench) {
      bench = dis;
      best = r.$1;
    }
    cP = cP.sublist(r.$2);
    if (cP.length <= 1) break;
  }
  return best;
}

/// 旧 `CTrendLine.cal`：隔笔取样 + 距离和最小。
FitLine? calcTrendLine(List<TrendLineBi> lst, TrendLineSide side) {
  if (lst.length < 3) return null;
  final lastDir = lst.last.dir;
  if (lastDir != 1 && lastDir != -1) return null;

  // lst[-1::-2]：从末根隔笔倒取
  final sampled = <TrendLineBi>[];
  for (var i = lst.length - 1; i >= 0; i -= 2) {
    sampled.add(lst[i]);
  }
  final allP = <FitPoint>[
    for (final bi in sampled)
      side == TrendLineSide.inside
          ? FitPoint(bi.beginX, bi.beginVal)
          : FitPoint(bi.endX, bi.endVal),
  ];
  if (allP.isEmpty) return null;
  return calcMinDistFitLine(allP, dir: lastDir, side: side);
}

List<TrendLineBi> _collectChildren(
  LevelBundle childLv,
  ParentSpan parent,
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

FxExtendRay? _lineToRay(FitLine line, ParentSpan parent, String kind) {
  if (line.slope.isNaN || line.slope.isInfinite) return null;
  final x0 = parent.endX.toDouble();
  final x1 = parent.beginX.toDouble();
  return FxExtendRay(
    x0: x0,
    y0: line.yAt(x0),
    slope: line.slope,
    kind: kind,
    x1: x1,
    y1: line.yAt(x1),
  );
}

/// 全量父段组（每组支撑+压力）；asOf 截断父/子。
List<FxExtendGroup> calcTrendLineGroupsForLevel({
  required int displayKn,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  // 方案B：子=displayKn，父=displayKn+1
  final childLv = bundleAtLevel(levels, displayKn);
  final parentLv = bundleAtLevel(levels, displayKn + 1);
  if (childLv == null || parentLv == null) return const [];

  final out = <FxExtendGroup>[];
  for (final parent in collectParentSpans(parentLv, asOf)) {
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
