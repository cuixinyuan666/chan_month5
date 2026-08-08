import '../models/bar_crosshair_feature.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'adjacent_ratio_compute.dart';

/// Kn连线斜率：末根子线 (endVal-beginVal)/(endX-beginX)。
///
/// **方案B全层同构**：displayKn → LevelBundle.level==displayKn（与比例/节奏/主图 Kn连线同号）。
/// 子线复用 [buildRatioChildren]（冻段+展示轨，虚实不论）；K0 颗粒度每步覆盖写入。

/// 单步产出（K0 颗粒度；同 x 覆盖更新）。
class LineSlopePoint {
  final int x;
  final int displayKn;
  final double slope;
  final String dir; // up / down
  final int childIdx;

  const LineSlopePoint({
    required this.x,
    required this.displayKn,
    required this.slope,
    required this.dir,
    required this.childIdx,
  });
}

/// 本步连线斜率：取出现链末根；|dx|<1 或不存在 → null。
LineSlopePoint? calcLineSlopeForStep({
  required List<LevelBundle> levels,
  required int displayKn,
  required int displayX,
  List<KlineBar> bars = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  bool truncationCheck = true,
}) {
  final children = buildRatioChildren(
    levels: levels,
    displayKn: displayKn,
    bars: bars,
    barFeatures: barFeatures,
    truncationCheck: truncationCheck,
    displayX: displayX,
  );
  if (children.isEmpty) return null;

  final cur = children.last;
  if (cur.dir != 1 && cur.dir != -1) return null;
  final dx = cur.endConfirmX - cur.beginX;
  if (dx.abs() < 1) return null;

  return LineSlopePoint(
    x: displayX,
    displayKn: displayKn,
    slope: (cur.endVal - cur.beginVal) / dx,
    dir: cur.dir > 0 ? 'up' : 'down',
    childIdx: cur.idx,
  );
}

void mergeLineSlopePoint(
  List<LineSlopePoint> log,
  LineSlopePoint? point,
) {
  if (point == null) return;
  final i = log.indexWhere((e) => e.x == point.x);
  if (i >= 0) {
    log[i] = point;
  } else {
    log.add(point);
  }
}

void mergeLineSlopeForStep({
  required Map<int, List<LineSlopePoint>> historyByKn,
  required List<LevelBundle> levels,
  required int displayX,
  required int maxDisplayKn,
  List<KlineBar> bars = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  bool truncationCheck = true,
}) {
  for (var kn = 0; kn <= maxDisplayKn; kn++) {
    final log = historyByKn.putIfAbsent(kn, () => <LineSlopePoint>[]);
    mergeLineSlopePoint(
      log,
      calcLineSlopeForStep(
        levels: levels,
        displayKn: kn,
        displayX: displayX,
        bars: bars,
        barFeatures: barFeatures,
        truncationCheck: truncationCheck,
      ),
    );
  }
}

List<double?> expandLineSlopeToSeries(
  List<LineSlopePoint> history,
  int barCount, {
  int? maxX,
}) {
  final out = List<double?>.filled(barCount < 0 ? 0 : barCount, null);
  for (final p in history) {
    if (p.x < 0 || p.x >= out.length) continue;
    if (maxX != null && p.x > maxX) continue;
    out[p.x] = p.slope;
  }
  return out;
}
