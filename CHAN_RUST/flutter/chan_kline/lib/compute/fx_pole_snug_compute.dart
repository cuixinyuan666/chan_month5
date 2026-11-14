import '../models/k0_confirm_signal.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'fx_extend_line_compute.dart';
import 'parent_span_collect.dart';
import 'trend_line_compute.dart';

/// K{n}底极贴合线 / K{n}顶极贴合线：父段内同型分型极点距离最小拟合（纯 Flutter）。
///
/// 方案B：displayKn 分型源 + displayKn+1 父段切分；≥2 同型极点。
/// 呈现：自段内**首个**同型极点沿拟合斜率画到 asOf（步进末根/十字），非延伸到视口右缘。

/// 父段内筛同型极点（极点 x 落在父段区间内，含端点）。
List<FxPole> collectPolesInParentSpan({
  required List<FxPole> poles,
  required ParentSpan parent,
  required String fx,
}) {
  final out = <FxPole>[];
  for (final p in poles) {
    if (p.fx != fx) continue;
    if (p.x < parent.beginX || p.x > parent.endX) continue;
    out.add(p);
  }
  out.sort((a, b) {
    final c = a.x.compareTo(b.x);
    return c != 0 ? c : a.confirmX.compareTo(b.confirmX);
  });
  return out;
}

FitLine? _fitSnugLine(List<FxPole> poles, int dir, TrendLineSide side) {
  if (poles.length < 2) return null;
  final pts = [
    for (final p in poles) FitPoint(p.x, p.price),
  ];
  return calcMinDistFitLine(pts, dir: dir, side: side);
}

FxExtendRay? _lineToSnugRay(
  FitLine line,
  List<FxPole> poles,
  String kind,
) {
  if (line.slope.isNaN || line.slope.isInfinite) return null;
  if (poles.isEmpty) return null;
  final first = poles.first;
  double yAt(int x) => line.yAt(x.toDouble());
  // x0,y0 = 拟合锚点（段内首个同型极点）；绘制时沿 slope 延伸到 asOf
  return FxExtendRay(
    x0: first.x.toDouble(),
    y0: yAt(first.x),
    slope: line.slope,
    kind: kind,
  );
}

List<FxExtendGroup> _calcSnugGroupsForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  required String fx,
  required String rayKind,
  required TrendLineSide side,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  final parentLv = bundleAtLevel(levels, displayKn + 1);
  if (parentLv == null || bars.isEmpty) return const [];

  final allPoles = collectLevelFxPoles(
    displayKn: displayKn,
    bars: bars,
    k0Confirms: k0Confirms,
    levels: levels,
    asOf: asOf,
  );

  final out = <FxExtendGroup>[];
  for (final parent in collectParentSpans(parentLv, asOf)) {
    if (side == TrendLineSide.inside && parent.dir <= 0) continue;
    if (side == TrendLineSide.outside && parent.dir >= 0) continue;

    final poles = collectPolesInParentSpan(
      poles: allPoles,
      parent: parent,
      fx: fx,
    );
    if (poles.length < 2) continue;

    final line = _fitSnugLine(poles, parent.dir, side);
    if (line == null) continue;
    final ray = _lineToSnugRay(line, poles, rayKind);
    if (ray == null) continue;

    out.add(FxExtendGroup(
      poleMinX: parent.beginX,
      poleMaxX: parent.endX,
      confirmMax: parent.confirmMax,
      rays: [ray],
    ));
  }
  return out;
}

/// 全量父段组：底极贴合（上升父段内底极点）。
List<FxExtendGroup> calcBottomSnugGroupsForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  return _calcSnugGroupsForLevel(
    displayKn: displayKn,
    bars: bars,
    fx: 'BOTTOM',
    rayKind: 'bottomSnug',
    side: TrendLineSide.inside,
    k0Confirms: k0Confirms,
    levels: levels,
    asOf: asOf,
  );
}

/// 全量父段组：顶极贴合（下降父段内顶极点）。
List<FxExtendGroup> calcTopSnugGroupsForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<K0ConfirmSignal> k0Confirms = const [],
  List<LevelBundle> levels = const [],
  int? asOf,
}) {
  return _calcSnugGroupsForLevel(
    displayKn: displayKn,
    bars: bars,
    fx: 'TOP',
    rayKind: 'topSnug',
    side: TrendLineSide.outside,
    k0Confirms: k0Confirms,
    levels: levels,
    asOf: asOf,
  );
}

double? bottomSnugPriceReadout(
  List<FxExtendGroup> groups, {
  required int atX,
  int? focusX,
}) {
  final sel = selectFxExtendGroups(groups, focusX: focusX ?? atX);
  if (sel.isEmpty || sel.first.rays.isEmpty) return null;
  final r = sel.first.rays.first;
  if (r.kind != 'bottomSnug') return null;
  return rayPriceAt(r, atX);
}

double? topSnugPriceReadout(
  List<FxExtendGroup> groups, {
  required int atX,
  int? focusX,
}) {
  final sel = selectFxExtendGroups(groups, focusX: focusX ?? atX);
  if (sel.isEmpty || sel.first.rays.isEmpty) return null;
  final r = sel.first.rays.first;
  if (r.kind != 'topSnug') return null;
  return rayPriceAt(r, atX);
}
