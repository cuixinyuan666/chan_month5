import 'dart:math' as math;

import '../models/k0_confirm_signal.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'chart_view_compute.dart';

/// Kn三型平移线 / Kn四型对线：确认分型极点几何（纯 Flutter）。
///
/// 方案B全层同构：displayKn → K0=`k0Confirms`；Kn≥1 → `levels[level==displayKn].confirms`
/// 确认序滑动窗（三型3 / 四型4）；绘制默认只显最新窗，十字则显近邻窗；tip 同口径。

/// 分型极点（极点 K0 索引 + 价；confirmX=确认步）。
class FxPole {
  final int x;
  final double price;
  final String fx; // TOP / BOTTOM
  final int confirmX;

  const FxPole({
    required this.x,
    required this.price,
    required this.fx,
    required this.confirmX,
  });
}

/// 延伸射线：自 (x0,y0) 以 slope 向右；可选弦端 (x1,y1)。
class FxExtendRay {
  final double x0;
  final double y0;
  final double slope;
  /// triple / topPair / bottomPair
  final String kind;
  final double? x1;
  final double? y1;

  const FxExtendRay({
    required this.x0,
    required this.y0,
    required this.slope,
    required this.kind,
    this.x1,
    this.y1,
  });
}

/// 一个合格滑动窗（多条射线共享同一极点区间）。
class FxExtendGroup {
  final int poleMinX;
  final int poleMaxX;
  final int confirmMax;
  final List<FxExtendRay> rays;

  const FxExtendGroup({
    required this.poleMinX,
    required this.poleMaxX,
    required this.confirmMax,
    required this.rays,
  });

  int get midX => (poleMinX + poleMaxX) ~/ 2;

  /// 焦点到窗区间的距离（落在窗内=0）。
  int distTo(int focusX) {
    if (focusX < poleMinX) return poleMinX - focusX;
    if (focusX > poleMaxX) return focusX - poleMaxX;
    return 0;
  }
}

LevelBundle? _bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

/// 收集该显示层确认分型极点（按确认 x 升序；asOf 截断）。
List<FxPole> collectLevelFxPoles({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  if (bars.isEmpty) return const [];
  final out = <FxPole>[];

  if (displayKn <= 0) {
    final ordered = [...k0Confirms]..sort((a, b) => a.x.compareTo(b.x));
    for (final c in ordered) {
      if (c.fx != 'TOP' && c.fx != 'BOTTOM') continue;
      if (asOf != null && c.x > asOf) continue;
      final poleIdx = resolvePoleBarIdx(
        bars: bars,
        fx: c.fx,
        fractalX1: c.fractalX1,
        fractalX2: c.fractalX2,
      );
      if (poleIdx == null) continue;
      final price = poleBarPrice(bars, poleIdx, c.fx);
      if (price == null) continue;
      out.add(FxPole(
        x: poleIdx,
        price: price,
        fx: c.fx,
        confirmX: c.x,
      ));
    }
  } else {
    // 方案B：Kn≥1 取 structure level==displayKn
    final lv = _bundleAtLevel(levels, displayKn);
    if (lv == null) return const [];
    final ordered = [...lv.confirms]..sort((a, b) => a.x.compareTo(b.x));
    for (final c in ordered) {
      if (c.fx != 'TOP' && c.fx != 'BOTTOM') continue;
      if (asOf != null && c.x > asOf) continue;
      final poleIdx = resolvePoleBarIdx(
        bars: bars,
        poleX: c.poleX,
        fx: c.fx,
        fractalX1: c.fractalX1,
        fractalX2: c.fractalX2,
      );
      if (poleIdx == null) continue;
      final price = poleBarPrice(bars, poleIdx, c.fx);
      if (price == null) continue;
      out.add(FxPole(
        x: poleIdx,
        price: price,
        fx: c.fx,
        confirmX: c.x,
      ));
    }
  }
  return out;
}

/// 三型平移：取 [poles] 前三极点须两同+一异；两同定斜率，过异型向右。
FxExtendRay? calcTripleParallelRay(List<FxPole> poles) {
  if (poles.length < 3) return null;
  final win = poles.sublist(0, 3);
  final tops = win.where((e) => e.fx == 'TOP').toList();
  final bottoms = win.where((e) => e.fx == 'BOTTOM').toList();
  List<FxPole> same;
  FxPole odd;
  if (tops.length == 2 && bottoms.length == 1) {
    same = tops;
    odd = bottoms.first;
  } else if (bottoms.length == 2 && tops.length == 1) {
    same = bottoms;
    odd = tops.first;
  } else {
    return null;
  }
  same.sort((a, b) => a.x.compareTo(b.x));
  final dx = (same[1].x - same[0].x).toDouble();
  if (dx.abs() < 1) return null;
  final slope = (same[1].price - same[0].price) / dx;
  return FxExtendRay(
    x0: odd.x.toDouble(),
    y0: odd.price,
    slope: slope,
    kind: 'triple',
  );
}

/// 三型：滑动窗长 3 → 窗组列表。
List<FxExtendGroup> calcAllTripleGroups(List<FxPole> poles) {
  if (poles.length < 3) return const [];
  final out = <FxExtendGroup>[];
  for (var i = 0; i + 3 <= poles.length; i++) {
    final win = poles.sublist(i, i + 3);
    final r = calcTripleParallelRay(win);
    if (r == null) continue;
    var lo = win.first.x;
    var hi = win.first.x;
    var cMax = win.first.confirmX;
    for (final p in win) {
      lo = math.min(lo, p.x);
      hi = math.max(hi, p.x);
      cMax = math.max(cMax, p.confirmX);
    }
    out.add(FxExtendGroup(
      poleMinX: lo,
      poleMaxX: hi,
      confirmMax: cMax,
      rays: [r],
    ));
  }
  return out;
}

List<FxExtendRay> calcAllTripleParallelRays(List<FxPole> poles) {
  return [
    for (final g in calcAllTripleGroups(poles)) ...g.rays,
  ];
}

/// 四型对线：取 [poles] 前四中两顶、两底。
List<FxExtendRay> calcQuadPairRays(List<FxPole> poles) {
  if (poles.length < 4) return const [];
  final win = poles.sublist(0, 4);
  final tops = win.where((e) => e.fx == 'TOP').toList()
    ..sort((a, b) => a.x.compareTo(b.x));
  final bottoms = win.where((e) => e.fx == 'BOTTOM').toList()
    ..sort((a, b) => a.x.compareTo(b.x));
  if (tops.length < 2 || bottoms.length < 2) return const [];

  FxExtendRay? pair(List<FxPole> two, String kind) {
    final a = two[0];
    final b = two[1];
    final dx = (b.x - a.x).toDouble();
    if (dx.abs() < 1) return null;
    final slope = (b.price - a.price) / dx;
    return FxExtendRay(
      x0: b.x.toDouble(),
      y0: b.price,
      slope: slope,
      kind: kind,
      x1: a.x.toDouble(),
      y1: a.price,
    );
  }

  final out = <FxExtendRay>[];
  final t = pair(tops.take(2).toList(), 'topPair');
  final b = pair(bottoms.take(2).toList(), 'bottomPair');
  if (t != null) out.add(t);
  if (b != null) out.add(b);
  return out;
}

/// 四型：滑动窗长 4 → 窗组列表。
List<FxExtendGroup> calcAllQuadGroups(List<FxPole> poles) {
  if (poles.length < 4) return const [];
  final out = <FxExtendGroup>[];
  for (var i = 0; i + 4 <= poles.length; i++) {
    final win = poles.sublist(i, i + 4);
    final rays = calcQuadPairRays(win);
    if (rays.isEmpty) continue;
    var lo = win.first.x;
    var hi = win.first.x;
    var cMax = win.first.confirmX;
    for (final p in win) {
      lo = math.min(lo, p.x);
      hi = math.max(hi, p.x);
      cMax = math.max(cMax, p.confirmX);
    }
    out.add(FxExtendGroup(
      poleMinX: lo,
      poleMaxX: hi,
      confirmMax: cMax,
      rays: rays,
    ));
  }
  return out;
}

List<FxExtendRay> calcAllQuadPairRays(List<FxPole> poles) {
  return [
    for (final g in calcAllQuadGroups(poles)) ...g.rays,
  ];
}

/// 无焦点→最新一组；有焦点→落在窗内优先（多则取最新），否则取距焦点最近一组。
List<FxExtendGroup> selectFxExtendGroups(
  List<FxExtendGroup> groups, {
  int? focusX,
}) {
  if (groups.isEmpty) return const [];
  if (focusX == null) return [groups.last];

  FxExtendGroup? bestIn;
  for (final g in groups) {
    if (g.distTo(focusX) == 0) bestIn = g; // 同含则取更后（更新）
  }
  if (bestIn != null) return [bestIn];

  var best = groups.first;
  var bestD = best.distTo(focusX);
  for (var i = 1; i < groups.length; i++) {
    final g = groups[i];
    final d = g.distTo(focusX);
    if (d < bestD || (d == bestD && g.confirmMax >= best.confirmMax)) {
      best = g;
      bestD = d;
    }
  }
  return [best];
}

List<FxExtendRay> selectFxExtendRays(
  List<FxExtendGroup> groups, {
  int? focusX,
}) {
  return [
    for (final g in selectFxExtendGroups(groups, focusX: focusX)) ...g.rays,
  ];
}

/// 便捷：三型窗组。
List<FxExtendGroup> calcTripleGroupsForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  return calcAllTripleGroups(
    collectLevelFxPoles(
      displayKn: displayKn,
      bars: bars,
      k0Confirms: k0Confirms,
      levels: levels,
      asOf: asOf,
    ),
  );
}

/// 便捷：四型窗组。
List<FxExtendGroup> calcQuadGroupsForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  return calcAllQuadGroups(
    collectLevelFxPoles(
      displayKn: displayKn,
      bars: bars,
      k0Confirms: k0Confirms,
      levels: levels,
      asOf: asOf,
    ),
  );
}

/// 射线在 K0 柱 [atX] 上的外推价：y0 + slope*(atX-x0)。
double rayPriceAt(FxExtendRay ray, int atX) {
  return ray.y0 + ray.slope * (atX - ray.x0);
}

/// tip：三型延长线在 [atX] 的价格（近邻窗）；无则 null。
double? triplePriceReadout(
  List<FxExtendGroup> groups, {
  required int atX,
  int? focusX,
}) {
  final sel = selectFxExtendGroups(groups, focusX: focusX ?? atX);
  if (sel.isEmpty || sel.first.rays.isEmpty) return null;
  return rayPriceAt(sel.first.rays.first, atX);
}

/// tip：四型顶/底延长线在 [atX] 的价格。
({double? top, double? bottom}) quadPriceReadout(
  List<FxExtendGroup> groups, {
  required int atX,
  int? focusX,
}) {
  final sel = selectFxExtendGroups(groups, focusX: focusX ?? atX);
  if (sel.isEmpty) return (top: null, bottom: null);
  double? top;
  double? bottom;
  for (final r in sel.first.rays) {
    if (r.kind == 'topPair') top = rayPriceAt(r, atX);
    if (r.kind == 'bottomPair') bottom = rayPriceAt(r, atX);
  }
  return (top: top, bottom: bottom);
}

/// 兼容旧 ForLevel 名：返回筛选前全量射线（测试用）。
List<FxExtendRay> calcTripleParallelForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  return calcAllTripleParallelRays(
    collectLevelFxPoles(
      displayKn: displayKn,
      bars: bars,
      k0Confirms: k0Confirms,
      levels: levels,
      asOf: asOf,
    ),
  );
}

List<FxExtendRay> calcQuadPairForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  return calcAllQuadPairRays(
    collectLevelFxPoles(
      displayKn: displayKn,
      bars: bars,
      k0Confirms: k0Confirms,
      levels: levels,
      asOf: asOf,
    ),
  );
}
