import '../models/bar_crosshair_feature.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// 纯视图组装（十字线 as-of 重绘）：全部数据来自 Rust 冻结产物 + 逐K快照，
/// Dart 端不做缠论计算（无回退实现）。

/// 段/笔连线端点（极点 K 索引 + 极点价；展示专用，与 Rust `pole_x` 同口径）。
/// 主图「K0连线」即旧「笔连线」（曾称 K1连线）。
class LevelLineEndpoint {
  final int barIdx;
  final double price;
  const LevelLineEndpoint({required this.barIdx, required this.price});
}

/// 分型合并框内极点 K（raw；TOP 取首个 high 极大，BOTTOM 取首个 low 极小，与 Rust `fx_pole_x` 同口径）。
int? fractalExtremeBarIdxRaw(
  List<KlineBar> bars, {
  required String fx,
  required int fractalX1,
  required int fractalX2,
}) {
  final x1 = fractalX1 < 0 ? 0 : fractalX1;
  final x2 = fractalX2 < 0 ? 0 : fractalX2;
  if (bars.isEmpty || x1 > x2 || x2 >= bars.length) return null;
  if (fx == 'TOP') {
    var peak = double.negativeInfinity;
    for (var j = x1; j <= x2; j++) {
      if (bars[j].high > peak) peak = bars[j].high;
    }
    for (var j = x1; j <= x2; j++) {
      if ((bars[j].high - peak).abs() < 1e-12) return j;
    }
  } else if (fx == 'BOTTOM') {
    var trough = double.infinity;
    for (var j = x1; j <= x2; j++) {
      if (bars[j].low < trough) trough = bars[j].low;
    }
    for (var j = x1; j <= x2; j++) {
      if ((bars[j].low - trough).abs() < 1e-12) return j;
    }
  }
  return null;
}

/// 1 段笔确认包装（兼容旧调用方）。
int? fractalExtremeBarIdx(List<KlineBar> bars, BiConfirmSignal conf) {
  return fractalExtremeBarIdxRaw(
    bars,
    fx: conf.fx,
    fractalX1: conf.fractalX1,
    fractalX2: conf.fractalX2,
  );
}

/// 极点 K：优先 Rust 冻结 `poleX`，无效则 raw 扫描分型框。
int? resolvePoleBarIdx({
  required List<KlineBar> bars,
  int poleX = -1,
  required String fx,
  required int fractalX1,
  required int fractalX2,
}) {
  if (poleX >= 0 && poleX < bars.length) return poleX;
  return fractalExtremeBarIdxRaw(
    bars,
    fx: fx,
    fractalX1: fractalX1,
    fractalX2: fractalX2,
  );
}

double? poleBarPrice(List<KlineBar> bars, int barIdx, String fx) {
  if (barIdx < 0 || barIdx >= bars.length) return null;
  final b = bars[barIdx];
  if (fx == 'TOP') return b.high;
  if (fx == 'BOTTOM') return b.low;
  return null;
}

/// 按确认步 + 分型框匹配 N 段确认（禁止仅按 x 退化匹配）。
LevelConfirm? levelConfirmAt(
  List<LevelConfirm> confirms,
  int confirmX,
  int fractalX1,
  int fractalX2,
) {
  for (final c in confirms) {
    if (c.x == confirmX &&
        c.fractalX1 == fractalX1 &&
        c.fractalX2 == fractalX2) {
      return c;
    }
  }
  return null;
}

/// Kn 连线端点：极点 K + 极点价（与 K1 连线同逻辑；方案 A 优先查表 `poleX`）。
LevelLineEndpoint? levelSegmentEndpoint({
  required List<KlineBar> bars,
  required LevelSegmentN seg,
  required List<LevelConfirm> confirms,
  required bool isBegin,
}) {
  final poleField = isBegin ? seg.beginPoleX : seg.endPoleX;
  final fx1 = isBegin ? seg.beginFractalX1 : seg.endFractalX1;
  final fx2 = isBegin ? seg.beginFractalX2 : seg.endFractalX2;
  final confirmX = isBegin ? seg.beginConfirmX : seg.endConfirmX;
  final wantHigh = isBegin ? seg.dir < 0 : seg.dir > 0;

  if (isBegin && seg.isBootstrap) {
    final idx = poleField >= 0
        ? poleField
        : fractalExtremeBarIdxRaw(
            bars,
            fx: wantHigh ? 'TOP' : 'BOTTOM',
            fractalX1: fx1,
            fractalX2: fx2,
          );
    if (idx == null) return null;
    final price = wantHigh ? bars[idx].high : bars[idx].low;
    return LevelLineEndpoint(barIdx: idx, price: price);
  }

  final conf = levelConfirmAt(confirms, confirmX, fx1, fx2);
  final fx = conf?.fx ?? (wantHigh ? 'TOP' : 'BOTTOM');
  final poleIdx = resolvePoleBarIdx(
    bars: bars,
    poleX: conf?.poleX ?? poleField,
    fx: fx,
    fractalX1: fx1,
    fractalX2: fx2,
  );
  if (poleIdx == null) return null;
  final price = poleBarPrice(bars, poleIdx, fx);
  if (price == null) return null;
  return LevelLineEndpoint(barIdx: poleIdx, price: price);
}

/// N 段确认分型极点端点（构建中虚线起点；与 1 段 `_drawBuildingBiLine` 同口径）。
LevelLineEndpoint? levelConfirmEndpoint(
  List<KlineBar> bars,
  LevelConfirm conf,
) {
  final poleIdx = resolvePoleBarIdx(
    bars: bars,
    poleX: conf.poleX,
    fx: conf.fx,
    fractalX1: conf.fractalX1,
    fractalX2: conf.fractalX2,
  );
  if (poleIdx == null) return null;
  final price = poleBarPrice(bars, poleIdx, conf.fx);
  if (price == null) return null;
  return LevelLineEndpoint(barIdx: poleIdx, price: price);
}

/// as-of 已冻结 N 段（`endConfirmX <= asOf`）。
List<LevelSegmentN> asOfLevelSegments({
  required List<LevelBundle> levels,
  required int level,
  required int asOf,
}) {
  if (level < 1 || levels.length < level) return const [];
  final bundle = levels[level - 1];
  return bundle.segments.where((s) => s.endConfirmX <= asOf).toList();
}

/// as-of 前末次 N 段分型确认（TOP/BOTTOM）。
LevelConfirm? lastLevelConfirmAt(List<LevelConfirm> confirms, int asOf) {
  LevelConfirm? last;
  for (final c in confirms) {
    if (c.x > asOf) break;
    if (c.fx == 'TOP' || c.fx == 'BOTTOM') last = c;
  }
  return last;
}

/// as-of 构建中 N 段方向：当步快照进行中单元优先，否则取末次确认反向。
int buildingLevelDirAt({
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required int level,
  required int asOf,
}) {
  if (level < 1 || levels.length < level) return 0;
  final bundle = levels[level - 1];

  LevelSnap? snap;
  if (asOf < barFeatures.length && barFeatures[asOf].idx == asOf) {
    for (final ls in barFeatures[asOf].levels) {
      if (ls.level == level) {
        snap = ls;
        break;
      }
    }
  }
  if (snap != null && snap.unitIdx != null && snap.unitDir != 0) {
    final frozen = asOfLevelSegments(levels: levels, level: level, asOf: asOf);
    final contained = frozen.any(
      (s) => s.idx == snap!.unitIdx && s.endConfirmX <= asOf,
    );
    if (!contained) return snap.unitDir;
  }

  final last = lastLevelConfirmAt(bundle.confirms, asOf);
  if (last == null) return 0;
  return last.fx == 'BOTTOM' ? 1 : -1;
}

/// 笔确认前展示用默认笔：首根 K → asOf 末 K（仅 pending 策略；纯展示）。
BiVirtualBar? preConfirmDefaultBi(List<KlineBar> bars, int endBarX) {
  if (bars.isEmpty || endBarX < 0 || endBarX >= bars.length) return null;
  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (var i = 0; i <= endBarX; i++) {
    if (bars[i].high > hi) hi = bars[i].high;
    if (bars[i].low < lo) lo = bars[i].low;
  }
  return BiVirtualBar(
    idx: 0,
    dir: bars[endBarX].close >= bars[0].open ? 1 : -1,
    x1: 0,
    x2: endBarX,
    open: bars[0].open,
    high: hi,
    low: lo,
    close: bars[endBarX].close,
    confirmX: endBarX,
  );
}

/// 十字线 as-of 笔 K 列表：已冻结段（Rust 冻结时算好 OHLC，查表）+ 可选当步进行中笔。
/// [includeBuilding]：主图笔K展示可含进行中；K1合并/截断必须为 false（只认已确认笔）。
List<BiVirtualBar> asOfBiVirtualBars({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required String defaultBiPolicy,
  required int asOf,
  bool includeBuilding = true,
}) {
  if (bars.isEmpty) return const [];
  final bx = asOf.clamp(0, bars.length - 1);

  final l1 = levels.isNotEmpty ? levels.first : null;
  final frozen = <BiVirtualBar>[];
  if (l1 != null) {
    for (final s in l1.segments) {
      if (s.endConfirmX > bx) continue;
      final x1 = s.beginPoleX < s.endPoleX ? s.beginPoleX : s.endPoleX;
      final x2 = s.beginPoleX > s.endPoleX ? s.beginPoleX : s.endPoleX;
      frozen.add(BiVirtualBar(
        idx: s.idx,
        dir: s.dir,
        x1: x1,
        x2: x2,
        open: s.open,
        high: s.high,
        low: s.low,
        close: s.close,
        confirmX: s.endConfirmX,
      ));
    }
  }

  // 当步快照（逐K当下冻结）：进行中笔或刚冻结首笔
  LevelSnap? snap;
  if (bx < barFeatures.length && barFeatures[bx].idx == bx) {
    final ls = barFeatures[bx].levels;
    if (ls.isNotEmpty) snap = ls.first;
  } else {
    for (final f in barFeatures) {
      if (f.idx == bx && f.levels.isNotEmpty) {
        snap = f.levels.first;
        break;
      }
    }
  }

  final unitIdx = snap?.unitIdx;
  if (unitIdx == null) {
    // 首笔确认前：pending 策略给默认笔展示
    if (defaultBiPolicy == 'pending' && frozen.isEmpty) {
      final d = preConfirmDefaultBi(bars, bx);
      if (d != null) frozen.add(d);
    }
    return frozen;
  }

  if (!includeBuilding) return frozen;

  // 快照单元未包含在冻结列表 → 追加进行中笔（unit_x 区间与 OHLC 均来自快照）
  final s = snap!;
  final contained = frozen.any((v) => v.idx == unitIdx && v.x2 >= s.unitX2);
  if (!contained && s.unitX1 >= 0 && s.unitX2 >= s.unitX1) {
    frozen.add(BiVirtualBar(
      idx: unitIdx,
      dir: s.unitDir,
      x1: s.unitX1,
      x2: s.unitX2,
      open: s.unitOpen,
      high: s.unitHigh,
      low: s.unitLow,
      close: s.unitClose,
      confirmX: bx,
    ));
  }
  return frozen;
}
