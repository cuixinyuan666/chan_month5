import '../models/bar_crosshair_feature.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'chart_view_compute.dart';
import 'fractal_judgment_compute.dart';

/// 相邻连线比例：当前线幅度 / 上一线幅度（不拆回调/趋势）。
///
/// **指标设计遵循动态计算**（除非明确指示其它逻辑）：
/// - 全层同构：displayKn → LevelBundle.level==displayKn+1（与 Kn连线同号）
/// - 子线序列 = 主图已实现的连线出现链（冻段实线 + 展示轨虚线/种子），**虚实一视同仁**
/// - 排序按起点极点出现时机（beginX），取末两根做比值
/// - 颗粒度 = K0：每步 displayX=stepIdx 写入/覆盖当步读数
///
/// 踩坑（2026-07-31）：
/// - 只读 segments 会在「主图已有虚线、层尚无冻段」时读成 0 → 必须接展示轨/种子
/// - 按 endConfirmX 排序会把后确认长段错当当前线 → 必须按 beginX 出现链
/// - 禁止用 isSure 过滤 prev/cur

/// 单步产出（K0 颗粒度；同 x 覆盖更新）。
class AdjacentRatioPoint {
  final int x;
  final int displayKn;
  final double ratio;
  final String childDir; // up / down
  final int prevIdx;
  final int curIdx;

  const AdjacentRatioPoint({
    required this.x,
    required this.displayKn,
    required this.ratio,
    required this.childDir,
    required this.prevIdx,
    required this.curIdx,
  });
}

/// 子线：幅度 = |endVal-beginVal|；虚实由 [isSure] 仅作标记，不参与过滤。
class RatioChild {
  final int idx;
  final int dir;
  /// true=冻段实线；false=展示轨虚线（指标比值不区分）
  final bool isSure;
  /// 起点极点 K0（出现时机排序用）
  final int beginX;
  /// 终点极点/开口 K0
  final int endConfirmX;
  final double beginVal;
  final double endVal;

  const RatioChild({
    required this.idx,
    required this.dir,
    required this.isSure,
    required this.beginX,
    required this.endConfirmX,
    required this.beginVal,
    required this.endVal,
  });

  double get amp => (endVal - beginVal).abs();
}

LevelBundle? _bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

LevelSnap? _snapAt({
  required List<BarCrosshairFeature> barFeatures,
  required int level,
  required int asOf,
}) {
  if (barFeatures.isEmpty) return null;
  if (asOf < barFeatures.length && barFeatures[asOf].idx == asOf) {
    for (final ls in barFeatures[asOf].levels) {
      if (ls.level == level) return ls;
    }
  }
  for (final f in barFeatures) {
    if (f.idx != asOf) continue;
    for (final ls in f.levels) {
      if (ls.level == level) return ls;
    }
  }
  return null;
}

double? _polePrice(List<KlineBar> bars, int x, {required bool useHigh}) {
  if (x < 0 || x >= bars.length) return null;
  return useHigh ? bars[x].high : bars[x].low;
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

RatioChild _fromSeg(LevelSegmentN s) {
  return RatioChild(
    idx: s.idx,
    dir: s.dir,
    isSure: true,
    beginX: s.beginPoleX,
    endConfirmX: s.endConfirmX,
    beginVal: _segBeginVal(s),
    endVal: _segEndVal(s),
  );
}

RatioChild? _fromDisplayLine(DisplayBuildingLine line, int syntheticIdx) {
  if (line.dir != 1 && line.dir != -1) return null;
  if ((line.end.price - line.begin.price).abs() <= 1e-12) return null;
  return RatioChild(
    idx: line.unitIdx >= 0 ? line.unitIdx : syntheticIdx,
    dir: line.dir,
    isSure: line.asSolid,
    beginX: line.begin.barIdx,
    endConfirmX: line.end.barIdx,
    beginVal: line.begin.price,
    endVal: line.end.price,
  );
}

List<RatioChild> _seedAbcChildren({
  required List<KlineBar> bars,
  required LevelSnap snap,
  required int baseIdx,
}) {
  final state = snap.firstFxState;
  if (state != 'JUDGE' && state != 'CONFIRM') return const [];
  if (snap.drawAX < 0 || snap.drawBX < 0) return const [];
  if (snap.seedFx != 'TOP' && snap.seedFx != 'BOTTOM') return const [];
  final seedTop = snap.seedFx == 'TOP';
  final a = _polePrice(bars, snap.drawAX, useHigh: seedTop);
  final b = _polePrice(bars, snap.drawBX, useHigh: !seedTop);
  if (a == null || b == null) return const [];
  final out = <RatioChild>[];
  var syn = baseIdx;
  if (state == 'JUDGE') {
    final dirAb = b >= a ? 1 : -1;
    out.add(RatioChild(
      idx: syn--,
      dir: dirAb,
      isSure: false,
      beginX: snap.drawAX,
      endConfirmX: snap.drawBX,
      beginVal: a,
      endVal: b,
    ));
  }
  if (snap.drawCX >= 0) {
    final c = _polePrice(bars, snap.drawCX, useHigh: seedTop);
    if (c != null) {
      final dirBc = c >= b ? 1 : -1;
      out.add(RatioChild(
        idx: syn--,
        dir: dirBc,
        isSure: false,
        beginX: snap.drawBX,
        endConfirmX: snap.drawCX,
        beginVal: b,
        endVal: c,
      ));
    }
  }
  return out;
}

/// 几何近似重复：同向且端点价/起点接近 → 保留后写（冻段优先已先写入）。
bool _nearDup(RatioChild a, RatioChild b) {
  if (a.dir != b.dir) return false;
  return (a.beginX - b.beginX).abs() <= 1 &&
      (a.beginVal - b.beginVal).abs() < 1e-6 &&
      (a.endVal - b.endVal).abs() < 1e-6;
}

/// 按主图连线出现链收集子线（虚实一视同仁；按 beginX 出现时机排序）。
List<RatioChild> buildRatioChildren({
  required List<LevelBundle> levels,
  required int displayKn,
  List<KlineBar> bars = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  bool truncationCheck = true,
  int? displayX,
}) {
  final level = displayKn + 1;
  final lv = _bundleAtLevel(levels, level);
  if (lv == null) return const [];

  final asOf = displayX ?? (bars.isEmpty ? -1 : bars.last.idx);
  final out = <RatioChild>[];

  // ① 冻段实线（主图已画实线的部分）——按起点极点序
  final segs = [
    for (final s in lv.segments)
      if ((s.dir == 1 || s.dir == -1) &&
          (asOf < 0 || s.endConfirmX <= asOf))
        _fromSeg(s),
  ]..sort((a, b) {
      final c = a.beginX.compareTo(b.beginX);
      return c != 0 ? c : a.idx.compareTo(b.idx);
    });
  out.addAll(segs);
  final frozenIdx = {for (final c in segs) c.idx};

  // 无 bars：仅冻段 + active（单测兼容）
  if (bars.isEmpty || asOf < 0) {
    final act = lv.activeUnit;
    if (act != null && (act.dir == 1 || act.dir == -1)) {
      final begin = act.dir > 0 ? act.low : act.high;
      final end = act.dir > 0 ? act.high : act.low;
      final live = RatioChild(
        idx: act.idx,
        dir: act.dir,
        isSure: false,
        beginX: act.x1,
        endConfirmX: act.x2,
        beginVal: begin,
        endVal: end,
      );
      final i = out.indexWhere((e) => e.idx == act.idx);
      if (i >= 0) {
        out[i] = live;
      } else {
        out.add(live);
      }
    }
    return out;
  }

  // ② 展示轨虚线（与主图 _drawBuildingLevelLine 同源；已跳过冻段覆盖）
  final virtualUnits = asOfLevelVirtualK1Bars(
    levels: levels,
    barFeatures: barFeatures,
    level: level,
    asOf: asOf,
    includeBuilding: true,
  );
  final liveJudgments = collectFractalJudgmentEvents(
    kn: level,
    bars: bars,
    levels: levels,
    barFeatures: barFeatures,
    asOf: asOf,
    truncationCheck: truncationCheck,
  );
  final building = computeDisplayBuildingLines(
    bars: bars,
    asOf: asOf,
    virtualUnits: virtualUnits,
    frozenIdx: frozenIdx,
    levelConfirms: lv.confirms,
    liveJudgments: liveJudgments,
  );
  var syn = -1000 - displayKn * 100;
  for (final line in building) {
    final child = _fromDisplayLine(line, syn--);
    if (child == null) continue;
    if (out.any((e) => _nearDup(e, child))) continue;
    out.add(child);
  }

  // ③ 种子相虚线（尚无冻段或种子仍开口时；与主图种子相同源）
  final snap = _snapAt(barFeatures: barFeatures, level: level, asOf: asOf);
  if (snap != null) {
    final tip = computeSeedUnknownOpenTip(
      bars: bars,
      asOf: asOf,
      seedBoxX1: snap.seedBoxX1,
      seedBoxX2: snap.seedBoxX2,
      seedBoxHigh: snap.seedBoxHigh,
      seedBoxLow: snap.seedBoxLow,
      seedLeaveDir: snap.seedLeaveDir,
      firstFxState: snap.firstFxState,
      seedConfirmed: snap.seedConfirmed,
    );
    if (tip != null) {
      final child = _fromDisplayLine(tip, syn--);
      if (child != null && !out.any((e) => _nearDup(e, child))) {
        out.add(child);
      }
    }
    for (final child in _seedAbcChildren(bars: bars, snap: snap, baseIdx: syn)) {
      if (!out.any((e) => _nearDup(e, child))) out.add(child);
    }
  }

  // 按起点极点出现时机排序（连线出现链），虚实不分
  out.sort((a, b) {
    final c = a.beginX.compareTo(b.beginX);
    if (c != 0) return c;
    final d = a.endConfirmX.compareTo(b.endConfirmX);
    return d != 0 ? d : a.idx.compareTo(b.idx);
  });
  return out;
}

/// 本步相邻比例：取出现链末两根（虚实不论）；K0 颗粒度。
AdjacentRatioPoint? calcAdjacentRatioForStep({
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
  if (children.length < 2) return null;

  final prev = children[children.length - 2];
  final cur = children[children.length - 1];
  if ((cur.dir != 1 && cur.dir != -1) ||
      (prev.dir != 1 && prev.dir != -1)) {
    return null;
  }
  final denom = prev.amp;
  final numer = cur.amp;
  if (denom <= 1e-12) return null;
  return AdjacentRatioPoint(
    x: displayX,
    displayKn: displayKn,
    ratio: numer / denom,
    childDir: cur.dir > 0 ? 'up' : 'down',
    prevIdx: prev.idx,
    curIdx: cur.idx,
  );
}

void mergeAdjacentRatioPoint(
  List<AdjacentRatioPoint> log,
  AdjacentRatioPoint? point,
) {
  if (point == null) return;
  final i = log.indexWhere((e) => e.x == point.x);
  if (i >= 0) {
    log[i] = point;
  } else {
    log.add(point);
  }
}

void mergeAdjacentRatioForStep({
  required Map<int, List<AdjacentRatioPoint>> historyByKn,
  required List<LevelBundle> levels,
  required int displayX,
  required int maxDisplayKn,
  List<KlineBar> bars = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  bool truncationCheck = true,
}) {
  for (var kn = 0; kn <= maxDisplayKn; kn++) {
    final log =
        historyByKn.putIfAbsent(kn, () => <AdjacentRatioPoint>[]);
    mergeAdjacentRatioPoint(
      log,
      calcAdjacentRatioForStep(
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

List<double?> expandAdjacentRatioToSeries(
  List<AdjacentRatioPoint> history,
  int barCount, {
  int? maxX,
}) {
  final out = List<double?>.filled(barCount < 0 ? 0 : barCount, null);
  for (final p in history) {
    if (p.x < 0 || p.x >= out.length) continue;
    if (maxX != null && p.x > maxX) continue;
    out[p.x] = p.ratio;
  }
  return out;
}

/// 与「Kn连线斜率」同一公式：`(endVal-beginVal)/(endX-beginX)`（有符号）。
/// [level] = LevelBundle.level（背驰 displayKn；连线斜率侧为 displayKn+1）。
/// 冻段 endX=endConfirmX；动态 active endX=min(x2,asOf)。|dx|<1 → null。
double? calcUnitLineSlope({
  required List<LevelBundle> levels,
  required int level,
  required int unitIdx,
  int? asOf,
}) {
  final lv = _bundleAtLevel(levels, level);
  if (lv == null) return null;
  for (final s in lv.segments) {
    if (s.idx != unitIdx) continue;
    if (s.dir != 1 && s.dir != -1) return null;
    final dx = s.endConfirmX - s.beginPoleX;
    if (dx.abs() < 1) return null;
    return (_segEndVal(s) - _segBeginVal(s)) / dx;
  }
  final a = lv.activeUnit;
  if (a == null || a.idx != unitIdx) return null;
  if (a.dir != 1 && a.dir != -1) return null;
  final x2 = asOf != null ? (a.x2 < asOf ? a.x2 : asOf) : a.x2;
  final dx = x2 - a.x1;
  if (dx.abs() < 1) return null;
  final begin = a.dir > 0 ? a.low : a.high;
  final end = a.dir > 0 ? a.high : a.low;
  return (end - begin) / dx;
}
