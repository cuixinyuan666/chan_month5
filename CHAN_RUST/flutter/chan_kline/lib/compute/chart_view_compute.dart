import '../models/bar_crosshair_feature.dart';
import '../models/fractal_judgment_event.dart';
import '../models/k0_confirm_signal.dart';
import '../models/k1_bar.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';

/// 纯视图组装（十字线 as-of 重绘）：全部数据来自 Rust 冻结产物 + 逐K快照，
/// Dart 端不做缠论计算（无回退实现）。

/// 段/K0连线端点（极点 K 索引 + 极点价；展示专用，与 Rust `pole_x` 同口径）。
/// 主图「K0连线」即旧「笔连线」（曾称 K1连线）。
class LevelLineEndpoint {
  final int barIdx;
  final double price;
  const LevelLineEndpoint({required this.barIdx, required this.price});
}

/// 构建中虚线尾端「价」(X,Y)：扫价区间 `(afterConfirmX, asOfX]` 内方向极值
/// **首次**出现的那根 K0（升=首个 max(high)，降=首个 min(low)）。
/// 区间仅 1 根时自然落在该根；空区间退化为 asOf 本根方向价。全层同构展示口径。
LevelLineEndpoint? buildingTailEndpoint({
  required List<KlineBar> bars,
  required int afterConfirmX,
  required int asOfX,
  required int buildingDir,
}) {
  if (bars.isEmpty || buildingDir == 0) return null;
  if (asOfX < 0 || asOfX >= bars.length) return null;

  int? extremeIdx;
  double? extremePrice;
  if (buildingDir > 0) {
    var peak = double.negativeInfinity;
    for (final b in bars) {
      if (b.idx <= afterConfirmX || b.idx > asOfX) continue;
      if (b.high > peak) {
        peak = b.high;
        extremeIdx = b.idx;
        extremePrice = b.high;
      }
    }
  } else {
    var trough = double.infinity;
    for (final b in bars) {
      if (b.idx <= afterConfirmX || b.idx > asOfX) continue;
      if (b.low < trough) {
        trough = b.low;
        extremeIdx = b.idx;
        extremePrice = b.low;
      }
    }
  }

  if (extremeIdx != null && extremePrice != null) {
    return LevelLineEndpoint(barIdx: extremeIdx, price: extremePrice);
  }
  // 确认当步==asOf 或区间无 K：尾端退化为 asOf 本根
  final tail = bars[asOfX];
  return LevelLineEndpoint(
    barIdx: tail.idx,
    price: buildingDir > 0 ? tail.high : tail.low,
  );
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

/// K0连线确认包装（兼容旧调用方）。
int? fractalExtremeBarIdx(List<KlineBar> bars, K0ConfirmSignal conf) {
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

/// N 段确认分型极点端点（构建中虚线起点；与 1 段 `_drawBuildingK0Line` 同口径）。
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

/// 方案B：按 lv.level==level 查找，允许 level==0。
LevelBundle? bundleAtStructureLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

LevelBundle? _bundleAtStructureLevel(List<LevelBundle> levels, int level) =>
    bundleAtStructureLevel(levels, level);

/// 取 as-of 当步层级快照（与 [asOfLevelVirtualK1Bars] 同源）。
LevelSnap? levelSnapAt(
  List<BarCrosshairFeature> barFeatures, {
  required int level,
  required int asOf,
}) {
  if (barFeatures.isEmpty || asOf < 0) return null;
  BarCrosshairFeature? feat;
  if (asOf < barFeatures.length && barFeatures[asOf].idx == asOf) {
    feat = barFeatures[asOf];
  } else {
    for (final f in barFeatures) {
      if (f.idx == asOf) {
        feat = f;
        break;
      }
    }
  }
  if (feat == null) return null;
  for (final ls in feat.levels) {
    if (ls.level == level) return ls;
  }
  return null;
}

/// Kn连线（structure level≥1）是否允许绘制；全层同构。
/// 规则：父层（level-1）首根虚拟单元未形成前禁止，避免下层判断链整批画成 Kn连线。
/// 例：K1连线看 level0；K2连线看 level1；K3连线看 level2 …
bool levelLineDrawAllowed({
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required int level,
  required int asOf,
}) {
  if (level < 1) return true;
  if (bundleAtStructureLevel(levels, level) == null) return false;

  final parentLevel = level - 1;
  final parentFrozen =
      asOfLevelSegments(levels: levels, level: parentLevel, asOf: asOf);
  final parentSnap = levelSnapAt(barFeatures, level: parentLevel, asOf: asOf);
  return parentFrozen.isNotEmpty || parentSnap?.unitIdx != null;
}

/// as-of 已冻结 N 段（`endConfirmX <= asOf`）。
List<LevelSegmentN> asOfLevelSegments({
  required List<LevelBundle> levels,
  required int level,
  required int asOf,
}) {
  if (level < 0) return const [];
  final bundle = _bundleAtStructureLevel(levels, level);
  if (bundle == null) return const [];
  return bundle.segments.where((s) => s.endConfirmX <= asOf).toList();
}

/// K{level}连线在 as-of 视图下的「最后一段」两端 K0 格点（含构建中虚线端点）。
///
/// 冻段取 beginPoleX/endPoleX；构建中虚线取 [computeDisplayBuildingLines] 的首尾端点
/// （虚线是 pole→pole→开口尾端 一串，取末段即「倒数第二极点 → 末极点」）。
/// 供 K{n}回归通道当基准区间（父层 = level = displayKn+1；全层同构）。
/// 返回 null = 该层此刻还没有能当基准的连线。
({int x1, int x2})? lastLevelLineSpanAtAsOf({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required int level,
  required int asOf,
  List<FractalJudgmentEvent> liveJudgments = const [],
}) {
  if (level < 1 || bars.isEmpty) return null;
  if (asOf < 0 || asOf >= bars.length) return null;
  final bundle = bundleAtStructureLevel(levels, level);
  if (bundle == null) return null;

  int? lo;
  int? hi;
  void take(int a, int b) {
    final l = a <= b ? a : b;
    final h = a <= b ? b : a;
    if (hi == null || h >= hi!) {
      lo = l;
      hi = h;
    }
  }

  final frozen = asOfLevelSegments(levels: levels, level: level, asOf: asOf);
  for (final s in frozen) {
    if (s.beginPoleX < 0 || s.endPoleX < 0) continue;
    take(s.beginPoleX, s.endPoleX);
  }

  final virtualUnits = asOfLevelVirtualK1Bars(
    levels: levels,
    barFeatures: barFeatures,
    level: level,
    asOf: asOf,
    includeBuilding: true,
    // 预锚单元不是连线；该层无确认段时基准应保持为空（经典口径）。
    includePreAnchor: false,
  );
  final frozenIdx = <int>{for (final s in frozen) s.idx};
  for (final l in computeDisplayBuildingLines(
    bars: bars,
    asOf: asOf,
    virtualUnits: virtualUnits,
    frozenIdx: frozenIdx,
    levelConfirms: bundle.confirms,
    liveJudgments: liveJudgments,
  )) {
    take(l.begin.barIdx, l.end.barIdx);
  }

  if (lo == null || hi == null) return null;
  final end = hi! > asOf ? asOf : hi!;
  if (end <= lo!) return null;
  return (x1: lo!, x2: end);
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
  if (level < 0) return 0;
  final bundle = _bundleAtStructureLevel(levels, level);
  if (bundle == null) return 0;

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

/// K0连线确认前展示用默认 K1 bar：首根 K → asOf 末 K（仅 pending 策略；纯展示）。
K1Bar? preConfirmDefaultK1Bar(List<KlineBar> bars, int endBarX) {
  if (bars.isEmpty || endBarX < 0 || endBarX >= bars.length) return null;
  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (var i = 0; i <= endBarX; i++) {
    if (bars[i].high > hi) hi = bars[i].high;
    if (bars[i].low < lo) lo = bars[i].low;
  }
  return K1Bar(
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

/// 十字线 as-of K1 bar 列表：已冻结段（Rust 冻结时算好 OHLC，查表）+ 可选当步进行中 K0连线。
/// [includeBuilding]：展示轨（主图 K1 bar / K1合并）可含进行中；永久结构仍只认冻结。
List<K1Bar> asOfK1Bars({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required String defaultK0Policy,
  required int asOf,
  bool includeBuilding = true,
}) {
  if (bars.isEmpty) return const [];
  final bx = asOf.clamp(0, bars.length - 1);

  // 方案B：K0连线 = structure level==0
  final l0 = _bundleAtStructureLevel(levels, 0);
  final frozen = <K1Bar>[];
  if (l0 != null) {
    for (final s in l0.segments) {
      if (s.endConfirmX > bx) continue;
      final x1 = s.beginPoleX < s.endPoleX ? s.beginPoleX : s.endPoleX;
      final x2 = s.beginPoleX > s.endPoleX ? s.beginPoleX : s.endPoleX;
      frozen.add(K1Bar(
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

  // 当步快照（逐K当下冻结）：进行中 K0连线或刚冻结首根（level==0）
  LevelSnap? snap;
  if (bx < barFeatures.length && barFeatures[bx].idx == bx) {
    for (final ls in barFeatures[bx].levels) {
      if (ls.level == 0) {
        snap = ls;
        break;
      }
    }
  } else {
    for (final f in barFeatures) {
      if (f.idx != bx) continue;
      for (final ls in f.levels) {
        if (ls.level == 0) {
          snap = ls;
          break;
        }
      }
      if (snap != null) break;
    }
  }

  final unitIdx = snap?.unitIdx;
  if (unitIdx == null) {
    // 首K0连线确认前：pending 策略给默认 K1 bar 展示
    if (defaultK0Policy == 'pending' && frozen.isEmpty) {
      final d = preConfirmDefaultK1Bar(bars, bx);
      if (d != null) frozen.add(d);
    }
    return frozen;
  }

  if (!includeBuilding) return frozen;

  // 快照单元未包含在冻结列表 → 追加进行中 K0连线（unit_x 区间与 OHLC 均来自快照）
  final s = snap!;
  final contained = frozen.any((v) => v.idx == unitIdx && v.x2 >= s.unitX2);
  if (!contained && s.unitX1 >= 0 && s.unitX2 >= s.unitX1) {
    frozen.add(K1Bar(
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

/// LevelUnitBar → 展示用虚拟 K1 bar（与 Rust `unit_to_virtual_bar` 同口径）。
K1Bar levelUnitToK1Bar(LevelUnitBar u) {
  final x1 = u.x1 < u.x2 ? u.x1 : u.x2;
  final x2 = u.x1 > u.x2 ? u.x1 : u.x2;
  return K1Bar(
    idx: u.idx,
    dir: u.dir,
    x1: x1,
    x2: x2,
    open: u.open,
    high: u.high,
    low: u.low,
    close: u.close,
    confirmX: u.confirmX,
  );
}

/// LevelSegmentN → 展示用虚拟 K1 bar（与 Rust `segment_to_virtual_bar` 同口径）。
K1Bar levelSegmentToK1Bar(LevelSegmentN s) {
  final x1 = s.beginPoleX < s.endPoleX ? s.beginPoleX : s.endPoleX;
  final x2 = s.beginPoleX > s.endPoleX ? s.beginPoleX : s.endPoleX;
  return K1Bar(
    idx: s.idx,
    dir: s.dir,
    x1: x1,
    x2: x2,
    open: s.open,
    high: s.high,
    low: s.low,
    close: s.close,
    confirmX: s.endConfirmX,
  );
}

/// 单层展示轨虚拟单元：unitBars + active（或 pending），与 Rust `build_level_virtual_units` 同构。
List<K1Bar> levelBundleVirtualK1Bars(LevelBundle bundle) {
  final v = bundle.unitBars.map(levelUnitToK1Bar).toList();
  final active = bundle.activeUnit;
  if (active != null) {
    final last = v.isEmpty ? null : v.last;
    if (last == null ||
        active.idx != last.idx ||
        active.x2 != last.x2 ||
        active.high != last.high ||
        active.low != last.low) {
      if (last != null && active.idx == last.idx) {
        v[v.length - 1] = levelUnitToK1Bar(active);
      } else {
        v.add(levelUnitToK1Bar(active));
      }
    }
  } else if (bundle.segmentPolicy == 'pending' && bundle.pendingUnit != null) {
    v.add(levelUnitToK1Bar(bundle.pendingUnit!));
  }
  return v;
}

/// Kn 窗口「K 蜡烛展示轨」的首分型框口径（**仅蜡烛**，不动合并框、不动连线）。
///
/// 首分型确认后，引擎会把首分型前的种子组冻结成一颗**单根等值单元**
/// （`x1 == x2`、OHLC 全等），画出来只是一根 1px 针，看起来「K1 蜡烛消失了」。
/// 而该层真正有形的第一段其实是**首分型框** `[fx1..fx2]`。
///
/// 这里把开头那颗退化单元换成首分型框整体（高/低取区间极值），紧随其后的单元
/// 左端夹到 `fx2`、高/低按夹后区间重算——结果就是：
/// 首根 = 首分型框，第二根 = 框右端起到当步，随 asOf 右移。
///
/// 合并框与连线仍用**未变换**的单元列表（保持已确认的下沿口径不变）。
///
/// 全层同构：K1 / K2 / … / Kn 的窗口蜡烛都走这一条，禁止层级特例。
List<K1Bar> boxedFirstFractalCandleBars({
  required List<K1Bar> units,
  required List<KlineBar> bars,
  required int firstFractalX1,
  required int firstFractalX2,
  required int asOf,
}) {
  if (units.isEmpty || bars.isEmpty) return units;
  if (firstFractalX2 < firstFractalX1 || firstFractalX1 < 0) return units;
  final head = units.first;
  // 只处理「退化种子单元」：单根、跨度 0，且落在首分型框内。
  if (head.x1 != head.x2) return units;
  if (head.x2 < firstFractalX1 || head.x2 > firstFractalX2) return units;

  final out = <K1Bar>[];
  final box = _rangeK1Bar(
    bars,
    x1: firstFractalX1,
    x2: firstFractalX2,
    idx: head.idx,
    dir: head.dir,
  );
  if (box == null) return units;
  out.add(box);
  for (final u in units.skip(1)) {
    final trimmed = u.x1 < firstFractalX2;
    final nx1 = trimmed ? firstFractalX2 : u.x1;
    final nx2 = u.x2 < nx1 ? nx1 : u.x2;
    final reb = _rangeK1Bar(
      bars,
      x1: nx1,
      x2: nx2,
      idx: u.idx,
      dir: u.dir,
    );
    if (reb == null) continue;
    if (!trimmed || u.x1 == nx1) {
      out.add(reb);
      continue;
    }
    // 被首分型框裁掉左段的单元：只裁 x 跨度，开价必须保留原单元的开价
    // （= 上一层首分型的极值：下降段取顶分型最高、上升段取底分型最低）。
    // 否则 x3..4 重算会把开价顶成 10.19，第二根动态 K 就丢了 10.22 的顶。
    // 上下沿同时把开价包进来，保证 OHLC 自洽；全层同构，Kn 同走这一条。
    final hi = reb.high > u.open ? reb.high : u.open;
    final lo = reb.low < u.open ? reb.low : u.open;
    out.add(K1Bar(
      idx: reb.idx,
      dir: reb.dir,
      x1: reb.x1,
      x2: reb.x2,
      open: u.open,
      high: hi,
      low: lo,
      close: reb.close,
      confirmX: reb.confirmX,
    ));
  }

  // 当步仍在首分型框右侧延伸时补一根进行中动态单元（「K1 idx=1 动态 K」）。
  // 场景：首分型刚确认那一步，引擎快照的当步单元还是「刚冻结的退化 0..0」，
  // `asOfLevelVirtualK1Bars` 会认为已包含而不再追加进行中单元 → 若不补，
  // 该步只有首分型框一根 K，右侧这一段就凭空消失了。
  final lastX2 = out.last.x2;
  if (asOf > lastX2) {
    final tailX1 = lastX2 < firstFractalX2 ? firstFractalX2 : lastX2;
    final tail = _rangeK1Bar(
      bars,
      x1: tailX1,
      x2: asOf,
      idx: out.last.idx + 1,
      dir: out.last.dir,
    );
    if (tail != null) {
      if (tailX1 == firstFractalX2) {
        // 紧接首分型框之后的第一根动态 K：开价取框的极值（下降框取最高、上升框取最低），
        // 不能取 tailX1 那根 K 的开价 —— 否则 10.22 的顶被 10.19 顶掉。
        final startPrice = box.close >= box.open ? box.low : box.high;
        final hi = tail.high > startPrice ? tail.high : startPrice;
        final lo = tail.low < startPrice ? tail.low : startPrice;
        out.add(K1Bar(
          idx: tail.idx,
          dir: tail.dir,
          x1: tail.x1,
          x2: tail.x2,
          open: startPrice,
          high: hi,
          low: lo,
          close: tail.close,
          confirmX: tail.confirmX,
        ));
      } else {
        out.add(tail);
      }
    }
  }
  return out;
}

/// 区间 [x1..x2] 的展示用 K1 bar：高/低取区间极值，开=首根开、收=末根收。
/// 不套合并框的「高高/低低」。
K1Bar? _rangeK1Bar(
  List<KlineBar> bars, {
  required int x1,
  required int x2,
  required int idx,
  required int dir,
}) {
  KlineBar? first;
  KlineBar? last;
  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (final b in bars) {
    if (b.idx < x1 || b.idx > x2) continue;
    first ??= b;
    last = b;
    if (b.high > hi) hi = b.high;
    if (b.low < lo) lo = b.low;
  }
  if (first == null || last == null) return null;
  return K1Bar(
    idx: idx,
    dir: dir,
    x1: x1,
    x2: x2,
    open: first.open,
    high: hi,
    low: lo,
    close: last.close,
    confirmX: x2,
  );
}

/// as-of 展示轨虚拟单元（全层同构）：冻结段 + 可选当步进行中（LevelSnap）。
///
/// [includePreAnchor]：是否把「预锚动态单元」计入。预锚单元主要服务下一窗口的
/// K 蜡烛/合并框（以及虚拟K、采样钟、中枢/买卖点）；本层「构建中连线」在
/// 层级早生成开启时也按它补首分型前虚线（2026-11-06 口径：升段取区间内
/// 首次最低 low → 首次最高 high），相邻比例与回归基准仍必须传 false，
/// 否则该层还没有任何确认段时会多出一条基准/子线。
List<K1Bar> asOfLevelVirtualK1Bars({
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required int level,
  required int asOf,
  bool includeBuilding = true,
  bool includePreAnchor = true,
}) {
  // 方案B：按 lv.level==level 查找，允许 level==0
  if (level < 0) return const [];
  final bundle = _bundleAtStructureLevel(levels, level);
  if (bundle == null) return const [];
  final frozen = asOfLevelSegments(levels: levels, level: level, asOf: asOf)
      .map(levelSegmentToK1Bar)
      .toList();

  LevelSnap? snap;
  if (asOf < barFeatures.length && barFeatures[asOf].idx == asOf) {
    for (final ls in barFeatures[asOf].levels) {
      if (ls.level == level) {
        snap = ls;
        break;
      }
    }
  } else {
    for (final f in barFeatures) {
      if (f.idx != asOf) continue;
      for (final ls in f.levels) {
        if (ls.level == level) {
          snap = ls;
          break;
        }
      }
      if (snap != null) break;
    }
  }

  final unitIdx = snap?.unitIdx;
  if (unitIdx == null) {
    if (bundle.segmentPolicy == 'pending' &&
        frozen.isEmpty &&
        bundle.pendingUnit != null &&
        includeBuilding) {
      return [levelUnitToK1Bar(bundle.pendingUnit!)];
    }
    return frozen;
  }
  if (!includeBuilding) return frozen;

  final s = snap!;
  // 预锚动态单元 = 该层此刻还没有任何确认段时的“演化中首段”。
  // 它只给下一窗口当 K 蜡烛（快照 unit_*），不能当成本层构建中段喂给连线。
  if (!includePreAnchor && frozen.isEmpty) return frozen;
  final contained = frozen.any((v) => v.idx == unitIdx && v.x2 >= s.unitX2);
  if (!contained && s.unitX1 >= 0 && s.unitX2 >= s.unitX1) {
    frozen.add(K1Bar(
      idx: unitIdx,
      dir: s.unitDir,
      x1: s.unitX1,
      x2: s.unitX2,
      open: s.unitOpen,
      high: s.unitHigh,
      low: s.unitLow,
      close: s.unitClose,
      confirmX: asOf,
    ));
  }
  return frozen;
}

/// 首分型前：由父层（Kn-1）首框生成子层（Kn）动态 K（全层同构，2026-11-19）。
///
/// 规则：
/// - 父层首框存在 → 子层首根动态 K = 首框固定映射：
///   `open=框内首根 open`、`close=框内末根 close`、`high/low=框沿`；
/// - 父层首框 `fx` 为 `TOP` / `BOTTOM`（两元素章）→ 子层再生成第二根：
///   顶「首框最高 → 当前最低」/ 底「首框最低 → 当前最高」；
/// - 第二根只给当前区间，极值端点每步按 `asOf` 更新（不回写历史）。
///
/// 动态 K 不下传：本函数只算「父→子」一层，调用方不得拿它的结果再当父层。
List<K1Bar> buildPreFirstDynamicK1Bars({
  required List<KlineBar> bars,
  required List<KlineCombineFrame> parentFrames,
  required int asOf,
}) {
  if (parentFrames.isEmpty || bars.isEmpty) return const [];
  final first = parentFrames.first;
  final x1 = first.x1 < 0 ? 0 : first.x1;
  final x2 = first.x2 < 0
      ? 0
      : (first.x2 >= bars.length ? bars.length - 1 : first.x2);
  if (x1 > x2 || x1 >= bars.length) return const [];

  // 首合并框仅单个（AGENTS「首分型前动态 K」第 2 条 · 全层同构）：
  // 首框里只有 1 根 K（真单根，或并框时标记 firstBoxWasSingle）且已出二元素章时，
  // 只生成 idx=0 且保持动态，不生成 idx=1；价格取第一条构建虚线的两个端点：
  // 顶 = 首根最高 → 其后到 asOf 的最低；底 = 首根最低 → 其后到 asOf 的最高。
  // 开=起点价、高/低=两端价的高与低；收=上一层最新一根 K 的收盘（2026-11-27 用户确认，
  // 夹在高低内）。虚线还没出现时先不生成。
  final singleFx = first.fx == 'TOP' || first.fx == 'BOTTOM';
  if (singleFx && (x1 == x2 || first.firstBoxWasSingle)) {
    final top = first.fx == 'TOP';
    final from = x2 > x1 ? x2 : x1 + 1;
    int? endIdx;
    var endPrice = top ? double.infinity : double.negativeInfinity;
    for (var i = from; i <= asOf && i < bars.length; i++) {
      final v = top ? bars[i].low : bars[i].high;
      if (top ? v < endPrice : v > endPrice) {
        endPrice = v;
        endIdx = i;
      }
    }
    if (endIdx == null) return const [];
    final beginPrice = top ? bars[x1].high : bars[x1].low;
    final hi = beginPrice > endPrice ? beginPrice : endPrice;
    final lo = beginPrice < endPrice ? beginPrice : endPrice;
    final tail = bars[asOf < bars.length ? asOf : bars.length - 1].close;
    return [
      K1Bar(
        idx: 0,
        dir: top ? -1 : 1,
        x1: x1,
        x2: endIdx,
        open: beginPrice,
        high: hi,
        low: lo,
        close: tail.clamp(lo, hi).toDouble(),
        confirmX: asOf + 1,
      ),
    ];
  }

  // 首根开收仍取框内首/末根，但必须夹进框沿：低低档首框 high 可能低于首根开盘，
  // 不夹会让蜡烛实体冒出框外（方案 A 展示口径，2026-11-19 用户确认）。
  final headOpen = bars[x1].open;
  final headClose = bars[x2].close;
  final head = K1Bar(
    idx: 0,
    dir: 1,
    x1: x1,
    x2: x2,
    open: headOpen.clamp(first.low, first.high).toDouble(),
    high: first.high,
    low: first.low,
    close: headClose.clamp(first.low, first.high).toDouble(),
    confirmX: asOf,
  );

  final fx = first.fx;
  if (fx != 'TOP' && fx != 'BOTTOM') return [head];

  // 第二根：顶分型向下找当前最低；底分型向上找当前最高。
  int? extremeIdx;
  double? extremePrice;
  if (fx == 'TOP') {
    var low = double.infinity;
    for (var i = x2; i <= asOf && i < bars.length; i++) {
      if (bars[i].low < low) {
        low = bars[i].low;
        extremeIdx = i;
      }
    }
    if (low.isFinite) extremePrice = low;
  } else {
    var high = double.negativeInfinity;
    for (var i = x2; i <= asOf && i < bars.length; i++) {
      if (bars[i].high > high) {
        high = bars[i].high;
        extremeIdx = i;
      }
    }
    if (high.isFinite) extremePrice = high;
  }
  if (extremeIdx == null || extremePrice == null) return [head];

  return [
    head,
    K1Bar(
      idx: 1,
      dir: fx == 'TOP' ? -1 : 1,
      x1: x2,
      x2: extremeIdx,
      open: fx == 'TOP' ? first.high : first.low,
      high: fx == 'TOP' ? first.high : extremePrice,
      low: fx == 'TOP' ? extremePrice : first.low,
      close: extremePrice,
      confirmX: asOf,
    ),
  ];
}

/// 区间 [x1, x2] 内原始 K 的真实极值：[high] 为真取最高价，否则取最低价；同价取首次出现那根。
({int idx, double price})? preFirstTrueExtreme(
  List<KlineBar> bars,
  int x1,
  int x2, {
  required bool high,
}) {
  if (bars.isEmpty) return null;
  final a = x1 < 0 ? 0 : x1;
  final b = x2 >= bars.length ? bars.length - 1 : x2;
  if (a > b || a >= bars.length) return null;
  var idx = a;
  var price = high ? bars[a].high : bars[a].low;
  for (var i = a + 1; i <= b; i++) {
    final p = high ? bars[i].high : bars[i].low;
    if (high ? p > price : p < price) {
      price = p;
      idx = i;
    }
  }
  return (idx: idx, price: price);
}

bool _preFirstFxStamped(String fx) => fx == 'TOP' || fx == 'BOTTOM';

/// 上一层首框是否「只有 1 根」：按首框里的**单元数**算（K1 看 K0 原始 K 根数，
/// K2 看 K1 根数……），不按 K0 跨度；并框时被并进来的首框只有 1 根也算。
bool preFirstHeadIsSingle(KlineCombineFrame head) =>
    head.count <= 1 || head.firstBoxWasSingle;

/// 上一层首框内 K 合成一根（全层同构 · 2026-11-26 用户确认）。
///
/// 高/低 = 框内原始 K 的**真实**最高/最低（不取高高/低低框沿）；
/// 开/收 = [open]/[close]（上一层框内第一根 K 的开、最后一根 K 的收），不传则取框内首根开、末根收。
/// [confirmed] 为假 → 动态（confirmX=asOf+1，外框虚线）；为真 → 确认（实线）。
/// 首框跨度只有 1 根 K0 时返回 null。
K1Bar? buildPreFirstHeadComposite({
  required List<KlineBar> bars,
  required KlineCombineFrame parentHead,
  required int asOf,
  required bool confirmed,
  double? open,
  double? close,
}) {
  if (bars.isEmpty) return null;
  final x1 = parentHead.x1 < 0 ? 0 : parentHead.x1;
  final x2 =
      parentHead.x2 >= bars.length ? bars.length - 1 : parentHead.x2;
  if (x2 <= x1) return null;
  var high = bars[x1].high;
  var low = bars[x1].low;
  for (var i = x1 + 1; i <= x2; i++) {
    if (bars[i].high > high) high = bars[i].high;
    if (bars[i].low < low) low = bars[i].low;
  }
  return K1Bar(
    idx: 0,
    dir: 1,
    x1: x1,
    x2: x2,
    open: (open ?? bars[x1].open).clamp(low, high).toDouble(),
    high: high,
    low: low,
    close: (close ?? bars[x2].close).clamp(low, high).toDouble(),
    confirmX: confirmed ? asOf : asOf + 1,
  );
}

/// 首框只有 1 根且已盖二元素章：idx=0 = 第一条构建中虚线（首连线）的两端——
/// 首框内分型极点 → 其后到 asOf 的反向极值（首次）。虚线还没出现返回 null。
/// 开 = 起点价，高/低 = 两端价的高与低；收 = 上一层最新一根 K 的收盘 [close]
/// （2026-11-27 用户确认 · 全层同构；不传则取 K0 第 asOf 根收盘，夹在高低内）。
K1Bar? buildPreFirstSingleHeadBar({
  required List<KlineBar> bars,
  required KlineCombineFrame head,
  required int asOf,
  double? close,
}) {
  if (!_preFirstFxStamped(head.fx)) return null;
  final top = head.fx == 'TOP';
  final begin = preFirstTrueExtreme(bars, head.x1, head.x2, high: top);
  final end = preFirstTrueExtreme(bars, head.x2 + 1, asOf, high: !top);
  if (begin == null || end == null) return null;
  final hi = begin.price > end.price ? begin.price : end.price;
  final lo = begin.price < end.price ? begin.price : end.price;
  final tail = close ?? bars[asOf < bars.length ? asOf : bars.length - 1].close;
  return K1Bar(
    idx: 0,
    dir: top ? -1 : 1,
    x1: begin.idx,
    x2: end.idx,
    open: begin.price,
    high: hi,
    low: lo,
    close: tail.clamp(lo, hi).toDouble(),
    confirmX: asOf + 1,
  );
}

/// idx=1（全层同构 · 2026-11-26 用户确认）：上一层首框多于 1 根且已盖二元素章时生成。
/// - 价位：首框内真实极值 → 右组内真实反向极值；
/// - 时间：从**首框右端**起（首根不压缩），到右组极值所在 K；
/// - 右组盖上顶/底章前动态（confirmX=asOf+1），盖章后终点定住（confirmX=终点）。
K1Bar? buildPreFirstSecondBar({
  required List<KlineBar> bars,
  required List<KlineCombineFrame> parentFrames,
  required int asOf,
}) {
  if (bars.isEmpty || parentFrames.length < 2) return null;
  final first = parentFrames.first;
  final right = parentFrames[1];
  if (preFirstHeadIsSingle(first) || !_preFirstFxStamped(first.fx)) {
    return null;
  }
  final top = first.fx == 'TOP';
  final pole = preFirstTrueExtreme(bars, first.x1, first.x2, high: top);
  // 右组与首框可能共用交界那根 K：交界 K 归首框，右组从下一根扫起。
  final rStart = right.x1 > first.x2
      ? right.x1
      : (first.x2 + 1 <= right.x2 ? first.x2 + 1 : right.x1);
  final end = preFirstTrueExtreme(bars, rStart, right.x2, high: !top);
  if (pole == null || end == null) return null;
  final x1 = first.x2 >= bars.length ? bars.length - 1 : first.x2;
  final x2 = end.idx < x1 ? x1 : end.idx;
  final rightFixed = _preFirstFxStamped(right.fx);
  return K1Bar(
    idx: 1,
    dir: top ? -1 : 1,
    x1: x1,
    x2: x2,
    open: pole.price,
    high: pole.price > end.price ? pole.price : end.price,
    low: pole.price < end.price ? pole.price : end.price,
    close: end.price,
    confirmX: rightFixed ? end.idx : asOf + 1,
  );
}

/// 首分型前各层统一取轨（全层同构 · 2026-11-26 用户确认）。
///
/// 窗口 Kn 只看上一层**画面上的合并框** [parentFrames]；K1/K2/…/Kn、单图/子窗口、
/// K 线与合并框都从这里取，不再分层各写一套。
/// - 上一层没有框，或首框只有 1 根且未盖章 → `[]`（本层不出生）；
/// - 首框只有 1 根且已盖章 → 只有 idx=0（首连线两端，动态；收 = 上一层最新一根 K 的收盘 [tailClose]）；
/// - 首框多于 1 根、未盖章 → idx=0 = 首框合成（真实高低），动态；
/// - 首框多于 1 根、已盖章 → idx=0 转确认 + idx=1 + [legs]（续接腿 idx≥2）。
List<K1Bar> buildPreFirstUnifiedUnits({
  required List<KlineBar> bars,
  required List<KlineCombineFrame> parentFrames,
  required int asOf,
  double? headOpen,
  double? headClose,
  double? tailClose,
  List<K1Bar> legs = const [],
}) {
  if (parentFrames.isEmpty || bars.isEmpty || asOf < 0) return const [];
  final head = parentFrames.first;
  if (preFirstHeadIsSingle(head)) {
    final b = buildPreFirstSingleHeadBar(
      bars: bars,
      head: head,
      asOf: asOf,
      close: tailClose,
    );
    return b == null ? const [] : <K1Bar>[b];
  }
  final second = buildPreFirstSecondBar(
    bars: bars,
    parentFrames: parentFrames,
    asOf: asOf,
  );
  final h0 = buildPreFirstHeadComposite(
    bars: bars,
    parentHead: head,
    asOf: asOf,
    confirmed: second != null,
    open: headOpen,
    close: headClose,
  );
  if (h0 == null) return const [];
  if (second == null) return <K1Bar>[h0];
  return <K1Bar>[h0, second, ...legs];
}

/// 首分型前二元素章的预告线（构建中虚线通道，2026-11-19 全层同构）。
///
/// - 顶分型：首框最高价 ↔ 当前最低；
/// - 底分型：首框最低价 ↔ 当前最高；
/// - 端点每步按 `asOf` 跟当前极值更新；返回 null 表示无预告线
///   （无两元素章 / 首框越界 / 两端点重合）。
///
/// 正式连线仍守「单框不画 / 两端同框不画 / 首框同根极值不画内线」三条禁令；
/// 本函数只负责「预告线」这一独立通道。
DisplayBuildingLine? computePreFirstFractalTipLine({
  required List<KlineBar> bars,
  required KlineCombineFrame first,
  required int asOf,
}) {
  if (bars.isEmpty) return null;
  final fx = first.fx;
  if (fx != 'TOP' && fx != 'BOTTOM') return null;
  final x1 = first.x1 < 0 ? 0 : first.x1;
  final x2 = first.x2 < 0
      ? 0
      : (first.x2 >= bars.length ? bars.length - 1 : first.x2);
  if (x1 > x2 || x1 >= bars.length) return null;
  final asOfX = asOf < 0 ? 0 : (asOf >= bars.length ? bars.length - 1 : asOf);

  // 起点：框内极值所在根（同价取首根）。
  var beginIdx = x1;
  if (fx == 'TOP') {
    for (var i = x1; i <= x2; i++) {
      if ((bars[i].high - first.high).abs() < 1e-12) {
        beginIdx = i;
        break;
      }
    }
  } else {
    for (var i = x1; i <= x2; i++) {
      if ((bars[i].low - first.low).abs() < 1e-12) {
        beginIdx = i;
        break;
      }
    }
  }
  final beginPrice = fx == 'TOP' ? first.high : first.low;

  // 终点：首框末根之后到 asOf 的同向极值（首次）。
  int? endIdx;
  double? endPrice;
  if (fx == 'TOP') {
    var low = double.infinity;
    for (var i = x2; i <= asOfX; i++) {
      if (bars[i].low < low) {
        low = bars[i].low;
        endIdx = i;
      }
    }
    if (low.isFinite) endPrice = low;
  } else {
    var high = double.negativeInfinity;
    for (var i = x2; i <= asOfX; i++) {
      if (bars[i].high > high) {
        high = bars[i].high;
        endIdx = i;
      }
    }
    if (high.isFinite) endPrice = high;
  }
  if (endIdx == null || endPrice == null) return null;
  if (beginIdx == endIdx && (beginPrice - endPrice).abs() < 1e-12) {
    return null;
  }

  return DisplayBuildingLine(
    begin: LevelLineEndpoint(barIdx: beginIdx, price: beginPrice),
    end: LevelLineEndpoint(barIdx: endIdx, price: endPrice),
    dir: fx == 'TOP' ? -1 : 1,
    unitIdx: -1,
    anchorX: beginIdx,
    beginSrc: 'judgment',
    endSrc: 'open',
    asSolid: false,
    isOpenTip: true,
  );
}


LevelLineEndpoint? seedBoxDepartEndpoint({
  required List<KlineBar> bars,
  required int seedBoxX1,
  required int seedBoxX2,
  required double seedBoxHigh,
  required double seedBoxLow,
  required int leaveDir,
}) {
  if (bars.isEmpty || leaveDir == 0) return null;
  final x1 = seedBoxX1 < 0 ? 0 : seedBoxX1;
  final x2 = seedBoxX2 < 0 ? 0 : seedBoxX2;
  if (x1 > x2 || x2 >= bars.length) return null;
  if (leaveDir > 0) {
    // 升段起点=框低（与 kn_segment_open 同口径）
    for (var j = x1; j <= x2; j++) {
      if ((bars[j].low - seedBoxLow).abs() < 1e-12) {
        return LevelLineEndpoint(barIdx: j, price: seedBoxLow);
      }
    }
  } else {
    for (var j = x1; j <= x2; j++) {
      if ((bars[j].high - seedBoxHigh).abs() < 1e-12) {
        return LevelLineEndpoint(barIdx: j, price: seedBoxHigh);
      }
    }
  }
  return null;
}

/// 主图是否绘制种子框/种子相虚线。
/// 「层级早生成动态单元」开启时，首段由预锚动态单元接管，种子框、种子开口与 ABC 全部不画；
/// 关闭时保持经典种子绘制。只影响主图绘制，不影响种子数据与相邻比例指标。
bool seedPhaseVisible({required bool earlyDynamicUnit}) => !earlyDynamicUnit;

/// 合并帧剔除「本层种子框」首组（全层同构，K0/K1/K2…/Kn 同一口径）。
///
/// 层级早生成开启时，首段由预锚动态单元接管，种子框不再绘制；而该层合并帧的
/// 第一组与种子框同矩形（同 x 区间、同 high/low），必须一并跳过，否则同一只框
/// 仍会以「合并框」名义留在图上。开关关闭时原样返回，保持经典种子绘制。
List<KlineCombineFrame> combineFramesWithoutSeed({
  required List<KlineCombineFrame> frames,
  required LevelSnap? snap,
  required bool earlyDynamicUnit,
}) {
  if (!earlyDynamicUnit || frames.isEmpty || snap == null) return frames;
  if (snap.seedBoxSeq < 0) return frames;
  final first = frames.first;
  final sameAsSeed = first.x1 == snap.seedBoxX1 &&
      first.x2 == snap.seedBoxX2 &&
      (first.high - snap.seedBoxHigh).abs() < 1e-9 &&
      (first.low - snap.seedBoxLow).abs() < 1e-9;
  return sameAsSeed ? frames.sublist(1) : frames;
}

/// 种子 UNKNOWN 开口虚线（方案2·D2·S-b，**全层同构**：K1/K2/…/Kn 同一函数、同口径）：
/// - 仅 `firstFxState==UNKNOWN` 且 `seedLeaveDir!=0`（已有 group1，「离开种子」方向）；
/// - 仅 group0 时 leaveDir=0 → 不画连线，只留虚线种子框；
/// - begin=框内出发极值（升=框低，降=框高）；
/// - 尾端从 `seed_box_x2` **外**扫 `(seed_x2, asOf]` 首次同向极值（buildingTailEndpoint）；
/// - 进入 JUDGE/CONFIRM 后本函数返回 null，让位种子 ABC。
DisplayBuildingLine? computeSeedUnknownOpenTip({
  required List<KlineBar> bars,
  required int asOf,
  required int seedBoxX1,
  required int seedBoxX2,
  required double seedBoxHigh,
  required double seedBoxLow,
  required int seedLeaveDir,
  required String firstFxState,
  required bool seedConfirmed,
}) {
  if (seedConfirmed || firstFxState != 'UNKNOWN') return null;
  if (seedLeaveDir == 0) return null;
  if (seedBoxX1 < 0 || seedBoxX2 < 0) return null;
  if (!seedBoxHigh.isFinite || !seedBoxLow.isFinite) return null;
  if (bars.isEmpty || asOf < 0 || asOf >= bars.length) return null;
  // S-b：必须扫到框右沿之外；asOf 仍在框内则无开口
  if (asOf <= seedBoxX2) return null;

  final begin = seedBoxDepartEndpoint(
    bars: bars,
    seedBoxX1: seedBoxX1,
    seedBoxX2: seedBoxX2,
    seedBoxHigh: seedBoxHigh,
    seedBoxLow: seedBoxLow,
    leaveDir: seedLeaveDir,
  );
  if (begin == null) return null;

  final end = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: seedBoxX2,
    asOfX: asOf,
    buildingDir: seedLeaveDir,
  );
  if (end == null) return null;
  if (begin.barIdx == end.barIdx && (begin.price - end.price).abs() < 1e-12) {
    return null;
  }

  return DisplayBuildingLine(
    begin: begin,
    end: end,
    dir: seedLeaveDir,
    unitIdx: -1,
    anchorX: begin.barIdx,
    beginSrc: 'seed',
    endSrc: 'open',
    asSolid: false,
    isOpenTip: true,
  );
}

/// 展示轨构建中连线：动态KN几何 + 当下分型判断拆段；
/// 确认优先改实线/纠端点；判断失效（live 不再出现）则自动合并回退；不回写结构。
class DisplayBuildingLine {
  final LevelLineEndpoint begin;
  final LevelLineEndpoint end;
  /// 升=+1，降=-1
  final int dir;
  /// 关联的虚拟单元序号；没有对应单元时为 -1。
  final int unitIdx;
  /// 起点锚点 x
  final int anchorX;
  /// 端点是否被确认纠正
  final bool corrected;
  /// begin/end 来源：confirm | judgment | open | dynamic
  final String beginSrc;
  final String endSrc;
  /// true=本段画实线（确认段或判断↔判断定格）；false=虚线
  final bool asSolid;
  /// 开口到 asOf 的尖端段
  final bool isOpenTip;

  const DisplayBuildingLine({
    required this.begin,
    required this.end,
    required this.dir,
    required this.unitIdx,
    required this.anchorX,
    this.corrected = false,
    this.beginSrc = 'dynamic',
    this.endSrc = 'dynamic',
    this.asSolid = false,
    this.isOpenTip = false,
  });
}

class _DashPole {
  final int poleX;
  final String fx;
  final LevelLineEndpoint endpoint;
  /// confirm | judgment
  final String src;
  /// 判断触发步（confirm 时=确认 x）
  final int triggerX;
  /// 判断中组右沿（confirm=-1）
  final int fractalX2;
  /// 右组左沿（confirm=-1；刚确认时可用 triggerX 充当）
  final int rightX1;
  /// 右组右沿
  final int rightX2;

  const _DashPole({
    required this.poleX,
    required this.fx,
    required this.endpoint,
    required this.src,
    required this.triggerX,
    this.fractalX2 = -1,
    this.rightX1 = -1,
    this.rightX2 = -1,
  });
}

LevelLineEndpoint? _k0ConfirmEndpoint(
  List<KlineBar> bars,
  K0ConfirmSignal conf,
) {
  final poleIdx = fractalExtremeBarIdx(bars, conf);
  if (poleIdx == null) return null;
  final price = poleBarPrice(bars, poleIdx, conf.fx);
  if (price == null) return null;
  return LevelLineEndpoint(barIdx: poleIdx, price: price);
}

/// as-of 内全部确认极点（按确认步排序；同 fx 后者覆盖）。
({List<_DashPole> poles, Set<String> spans}) _collectConfirmPoles({
  required List<KlineBar> bars,
  required int asOf,
  required List<LevelConfirm> levelConfirms,
  required List<K0ConfirmSignal> k0Confirms,
}) {
  final raw = <_DashPole>[];
  final spans = <String>{};
  for (final c in levelConfirms) {
    if (c.x > asOf) continue;
    if (c.fx != 'TOP' && c.fx != 'BOTTOM') continue;
    final ep = levelConfirmEndpoint(bars, c);
    if (ep == null) continue;
    raw.add(_DashPole(
      poleX: ep.barIdx,
      fx: c.fx,
      endpoint: ep,
      src: 'confirm',
      triggerX: c.x,
    ));
    spans.add('${c.fx}|${c.fractalX1}|${c.fractalX2}');
  }
  if (raw.isEmpty) {
    for (final c in k0Confirms) {
      if (c.x > asOf) continue;
      if (c.fx != 'TOP' && c.fx != 'BOTTOM') continue;
      final ep = _k0ConfirmEndpoint(bars, c);
      if (ep == null) continue;
      raw.add(_DashPole(
        poleX: ep.barIdx,
        fx: c.fx,
        endpoint: ep,
        src: 'confirm',
        triggerX: c.x,
      ));
      spans.add('${c.fx}|${c.fractalX1}|${c.fractalX2}');
    }
  }
  raw.sort((a, b) => a.triggerX.compareTo(b.triggerX));
  // 交替：同向连续只留后者
  final out = <_DashPole>[];
  for (final p in raw) {
    if (out.isNotEmpty && out.last.fx == p.fx) {
      out[out.length - 1] = p;
    } else {
      out.add(p);
    }
  }
  return (poles: out, spans: spans);
}

/// 判断极点：扫 (prevPole, judgment.x] 内方向首极值（钉在判断触发步，不随 asOf 拉长）。
/// 对齐提交 10ead1f 画线口径·改版v2（出现分型判断时的虚线拆段）。
_DashPole? _judgmentPole({
  required List<KlineBar> bars,
  required _DashPole prev,
  required FractalJudgmentEvent j,
}) {
  if (j.fx != 'TOP' && j.fx != 'BOTTOM') return null;
  if (j.x <= prev.poleX) return null;
  final dir = j.fx == 'TOP' ? 1 : -1;
  final ep = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: prev.poleX,
    asOfX: j.x,
    buildingDir: dir,
  );
  if (ep == null) return null;
  return _DashPole(
    poleX: ep.barIdx,
    fx: j.fx,
    endpoint: ep,
    src: 'judgment',
    triggerX: j.x,
    fractalX2: j.fractalX2,
    rightX1: j.rightX1,
    rightX2: j.rightX2,
  );
}

bool _frozenCoversPoles({
  required List<K1Bar> virtualUnits,
  required Set<int> frozenIdx,
  required int a,
  required int b,
}) {
  final lo = a < b ? a : b;
  final hi = a > b ? a : b;
  for (final u in virtualUnits) {
    if (!frozenIdx.contains(u.idx)) continue;
    if (u.x1 == lo && u.x2 == hi) return true;
    if (u.x1 == hi && u.x2 == lo) return true;
  }
  return false;
}



/// 首个判断极点（尚无确认时）：钉在中组 [fractalX1,fractalX2] 内方向极值；
/// 无中组则扫 (0, j.x]。与有确认时 `_judgmentPole` 同钉死语义。
_DashPole? _firstJudgmentPole({
  required List<KlineBar> bars,
  required FractalJudgmentEvent j,
}) {
  if (j.fx != 'TOP' && j.fx != 'BOTTOM') return null;
  final dir = j.fx == 'TOP' ? 1 : -1;
  final int after;
  final int asOfScan;
  if (j.fractalX1 >= 0 && j.fractalX2 >= j.fractalX1) {
    after = j.fractalX1 - 1;
    asOfScan = j.fractalX2;
  } else {
    after = -1;
    asOfScan = j.x;
  }
  if (asOfScan < 0) return null;
  final ep = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: after,
    asOfX: asOfScan,
    buildingDir: dir,
  );
  if (ep == null) return null;
  return _DashPole(
    poleX: ep.barIdx,
    fx: j.fx,
    endpoint: ep,
    src: 'judgment',
    triggerX: j.x,
    fractalX2: j.fractalX2,
    rightX1: j.rightX1,
    rightX2: j.rightX2,
  );
}

/// 把判断列表并入极点链（同 fx 后者覆盖）；[seedFirst]=尚无确认时用中组首极点。
void _appendJudgmentPoles({
  required List<KlineBar> bars,
  required List<_DashPole> poles,
  required List<FractalJudgmentEvent> js,
  required bool seedFirst,
}) {
  for (final j in js) {
    if (poles.isEmpty) {
      if (!seedFirst) continue;
      final p = _firstJudgmentPole(bars: bars, j: j);
      if (p != null) poles.add(p);
      continue;
    }
    final prev = poles.last;
    if (j.fx == prev.fx) {
      if (prev.src == 'judgment') poles.removeLast();
      if (poles.isEmpty) {
        if (!seedFirst) continue;
        final p = _firstJudgmentPole(bars: bars, j: j);
        if (p != null) poles.add(p);
        continue;
      }
      final refreshedPrev = poles.last;
      final p = _judgmentPole(bars: bars, prev: refreshedPrev, j: j);
      if (p != null) poles.add(p);
      continue;
    }
    final p = _judgmentPole(bars: bars, prev: prev, j: j);
    if (p != null) poles.add(p);
  }
}

/// 极点链 → 闭段 + 开口尖端（收束的分型连线实；开口虚）。
List<DisplayBuildingLine> _linesFromPoles({
  required List<KlineBar> bars,
  required int asOf,
  required List<_DashPole> poles,
  required List<K1Bar> virtualUnits,
  required Set<int> frozenIdx,
  required List<FractalJudgmentEvent> js,
}) {
  if (poles.isEmpty) return const [];

  final out = <DisplayBuildingLine>[];
  for (var i = 0; i + 1 < poles.length; i++) {
    final a = poles[i];
    final b = poles[i + 1];
    if (a.poleX == b.poleX) continue;

    final bothConfirm = a.src == 'confirm' && b.src == 'confirm';
    if (bothConfirm &&
        _frozenCoversPoles(
          virtualUnits: virtualUnits,
          frozenIdx: frozenIdx,
          a: a.poleX,
          b: b.poleX,
        )) {
      continue; // 冻结实线已画
    }

    // 收束段：两端都是分型（确认或已钉死的判断）→ 实线。
    // 开口尖端另画，继续虚线。
    final bothFractal = (a.src == 'confirm' || a.src == 'judgment') &&
        (b.src == 'confirm' || b.src == 'judgment');
    final asSolid = bothFractal;
    final dir = b.fx == 'TOP' ? 1 : -1;
    out.add(DisplayBuildingLine(
      begin: a.endpoint,
      end: b.endpoint,
      dir: dir,
      unitIdx: -1,
      anchorX: a.poleX,
      corrected: a.src == 'confirm' || b.src == 'confirm',
      beginSrc: a.src,
      endSrc: b.src,
      asSolid: asSolid,
      isOpenTip: false,
    ));
  }

  // 开口尖端：最后分型极点的方向腿仍开口——一律画，扫到 asOf 取方向极值首次出现根。
  // （顶点只增不减后，判定极点不是「当步刚成立」才有效，旧极点的开口段继续跟最新 K。）
  // 扫价起点：判断极点从右组左沿前一根起扫（不扫进中组）；确认极点从极点起扫。
  final last = poles.last;
  final openDir = last.fx == 'BOTTOM' ? 1 : -1;
  final beginEp = last.endpoint;
  final scanAfter = last.src == 'judgment' && last.rightX1 >= 0
      ? last.rightX1 - 1
      : last.poleX;
  final tip = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: scanAfter,
    asOfX: asOf,
    buildingDir: openDir,
  );

  if (tip != null && tip.barIdx != beginEp.barIdx) {
    out.add(DisplayBuildingLine(
      begin: beginEp,
      end: tip,
      dir: openDir,
      unitIdx: -1,
      anchorX: beginEp.barIdx,
      corrected: last.src == 'confirm',
      beginSrc: last.src,
      endSrc: 'open',
      asSolid: false,
      isOpenTip: true,
    ));
  }

  return out;
}

/// 首分型确认前的构建中虚线：区间内按方向扫「首次极值」。
///
/// 升段起点=区间内首次最低 low、终点=首次最高 high；降段对调。
/// 与首个分型之后的开口虚线同一套扫价（[buildingTailEndpoint]），
/// 端点钉在极值第一次出现的那根，不跟当根收盘价、也不跟当根最低价。
/// 两端落在同一根（还没走出第二根极值）时返回 null，不画点。
DisplayBuildingLine? _preConfirmExtremeLine(
  List<KlineBar> bars,
  K1Bar unit,
  int asOf,
) {
  if (unit.dir == 0 || bars.isEmpty) return null;
  final lo = unit.x1.clamp(0, bars.length - 1);
  final hi = (unit.x2 < asOf ? unit.x2 : asOf).clamp(0, bars.length - 1);
  if (lo > hi) return null;
  final up = unit.dir > 0;
  final begin = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: lo - 1,
    asOfX: hi,
    buildingDir: up ? -1 : 1,
  );
  final end = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: lo - 1,
    asOfX: hi,
    buildingDir: up ? 1 : -1,
  );
  if (begin == null || end == null) return null;
  if (begin.barIdx == end.barIdx && (begin.price - end.price).abs() < 1e-9) {
    return null;
  }
  return DisplayBuildingLine(
    begin: begin,
    end: end,
    dir: unit.dir,
    unitIdx: unit.idx,
    anchorX: begin.barIdx,
    beginSrc: 'dynamic',
    endSrc: 'dynamic',
    asSolid: false,
    isOpenTip: true,
  );
}

/// 首个分型判断出现后，判断极点之前那段收成实线。
///
/// 出发端仍按本层方向取区间内首次极值（升=首次最低 low，降=首次最高 high），
/// 到达端钉在首个判断极点。与开口虚线不重叠；两端同点不画。
DisplayBuildingLine? _seedLineBeforeFirstPole({
  required List<KlineBar> bars,
  required int asOf,
  required List<K1Bar> virtualUnits,
  required Set<int> frozenIdx,
  required _DashPole firstPole,
  bool asSolid = true,
}) {
  K1Bar? unit;
  for (final u in virtualUnits) {
    if (frozenIdx.contains(u.idx) || u.dir == 0 || u.x1 > asOf) continue;
    if (u.x1 <= firstPole.poleX) {
      unit = u;
      break;
    }
  }
  if (unit == null) return null;
  final lo = unit.x1.clamp(0, bars.length - 1);
  final hi = firstPole.poleX.clamp(0, bars.length - 1);
  if (lo > hi) return null;
  final up = unit.dir > 0;
  final begin = buildingTailEndpoint(
    bars: bars,
    afterConfirmX: lo - 1,
    asOfX: hi,
    buildingDir: up ? -1 : 1,
  );
  if (begin == null) return null;
  if (begin.barIdx == firstPole.poleX &&
      (begin.price - firstPole.endpoint.price).abs() < 1e-9) {
    return null;
  }
  return DisplayBuildingLine(
    begin: begin,
    end: firstPole.endpoint,
    dir: unit.dir,
    unitIdx: unit.idx,
    anchorX: begin.barIdx,
    beginSrc: 'dynamic',
    endSrc: 'judgment',
    asSolid: asSolid,
    isOpenTip: false,
  );
}

/// 判定事件去重：同一分型在活动单元生长期可能以不同 rightX 跨度重复进历史，
/// 按 (fx, fractalX1, fractalX2) 合并、保留 rightX2 最大者（最完整的右组）。
List<FractalJudgmentEvent> _dedupeJudgmentEvents(
  List<FractalJudgmentEvent> js,
) {
  if (js.length <= 1) return js;
  final best = <String, FractalJudgmentEvent>{};
  for (final j in js) {
    final k = '${j.fx}|${j.fractalX1}|${j.fractalX2}';
    final cur = best[k];
    if (cur == null || j.rightX2 > cur.rightX2) best[k] = j;
  }
  final out = best.values.toList()
    ..sort((a, b) => a.x.compareTo(b.x));
  return out;
}

/// 动态KN + 当下分型判断拆段的构建中连线（全层同构）。
///
/// [liveJudgments]：分型极点来源。绘制路径喂累积判定历史（judgmentHistoryByKn，
/// 只增不删，顶点不回撤）；无会话历史的入口退回 as-of 重放（健壮兜底）。
/// 口径（全层同构 · 2026-11-24 顶点只增不减）：
/// - 判断极点钉在 (上一极点, judgment.x] 扫价（buildingTailEndpoint），不随 asOf 拉长；
/// - 尚无确认时：首判断用中组极点起链，画判断↔判断实 / 判断开口虚（与有确认同构）；
/// - 右组=分型第三元素的 K0 跨度 [rightX1,rightX2]
///   （K0 例确认@8 → [8,8]；K1 例判断@58 → [55,58]）；
/// - 开口尖端一律从最后分型极点扫到 asOf、取方向极值首次出现根
///   （顶点只增不减后，开口段持续跟到最新 K，不再按 rightX 封顶）；
/// - 收束段（确认或判定极点，两端都是分型）画实线；开口尖端虚线。
List<DisplayBuildingLine> computeDisplayBuildingLines({
  required List<KlineBar> bars,
  required int asOf,
  required List<K1Bar> virtualUnits,
  required Set<int> frozenIdx,
  List<LevelConfirm> levelConfirms = const [],
  List<K0ConfirmSignal> k0Confirms = const [],
  List<FractalJudgmentEvent> liveJudgments = const [],
  bool seedBeforeFirstPoleSolid = true,
}) {
  if (bars.isEmpty || asOf < 0 || asOf >= bars.length) return const [];

  final confirmResult = _collectConfirmPoles(
    bars: bars,
    asOf: asOf,
    levelConfirms: levelConfirms,
    k0Confirms: k0Confirms,
  );
  final confirmPoles = confirmResult.poles;
  // 已被确认覆盖的分型跨度：同 fx+同跨度的判定事件是同一枚分型的
  // 确认前重发，不得再生成判定极点（否则确认极点后会叠出幻影同向极点，
  // 例：K0 idx=34 BOTTOM@34 确认后 BOTTOM@30..33(T) 仍放行 → 假实线段）。
  final confirmedSpans = confirmResult.spans;

  final List<FractalJudgmentEvent> js;
  final List<_DashPole> poles;

  if (confirmPoles.isEmpty) {
    // 尚无确认：仍消费判断极点（全层同构）；无判断才退化到未冻虚拟单元
    js = _dedupeJudgmentEvents([
      for (final j in liveJudgments)
        if (j.x <= asOf && (j.fx == 'TOP' || j.fx == 'BOTTOM')) j,
    ]);
    poles = <_DashPole>[];
    _appendJudgmentPoles(
      bars: bars,
      poles: poles,
      js: js,
      seedFirst: true,
    );

    if (poles.isEmpty) {
      final out = <DisplayBuildingLine>[];
      for (final u in virtualUnits) {
        if (frozenIdx.contains(u.idx) || u.x1 > asOf || u.dir == 0) continue;
        // 首分型前没有极点可钉：按本层单元方向扫区间首次极值。
        // 升段 low→high，降段 high→low；与首个分型之后的开口虚线同一套扫价。
        // 两端同点（还没走出第二根极值）不画线。
        // 首框多于 1 个单元时，内核单元 idx=1 的时间从首框右端起（2026-11-28），
        // 但连线端点仍钉在首框内真实极值首次出现那根：扫价起点回退到首框左端（全层同构）。
        var scan = u;
        if (u.idx == 1) {
          for (final v in virtualUnits) {
            // 首框合成段：连线 idx=0 终点（首框内真实极值根）早于单元 idx=1 起点（首框右端）。
            if (v.idx == 0 && frozenIdx.contains(0) && v.x2 < u.x1) {
              scan = K1Bar(
                idx: u.idx,
                dir: u.dir,
                x1: v.x2,
                x2: u.x2,
                open: u.open,
                high: u.high,
                low: u.low,
                close: u.close,
                confirmX: u.confirmX,
              );
              break;
            }
          }
        }
        final line = _preConfirmExtremeLine(bars, scan, asOf);
        if (line != null) out.add(line);
      }
      return out;
    }

    // 首个分型判断出现时，判断极点之前那段不再整段丢掉。
    // K1 这一段保持虚线：顶分型前最低点 → 顶分型最高点。
    final seeded = _seedLineBeforeFirstPole(
      bars: bars,
      asOf: asOf,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      firstPole: poles.first,
      asSolid: seedBeforeFirstPoleSolid,
    );
    return [
      ?seeded,
      ..._linesFromPoles(
        bars: bars,
        asOf: asOf,
        poles: poles,
        virtualUnits: virtualUnits,
        frozenIdx: frozenIdx,
        js: js,
      ),
    ];
  } else {
    poles = <_DashPole>[...confirmPoles];
    final lastConfirmTrig = confirmPoles.last.triggerX;
    // 截断章与三元素章/确认同级永久：盖章步早于末确认触发步、但结构位置在其后
    // 的截断事件不得被 triggerX 过滤（例：K0 idx=31 顶确认触发后，idx=30 截断
    // 底章会被误滤导致实线段+上行虚线整条塌缩）。仍要求盖章步在末确认极点之后，
    // 由 _judgmentPole 的 j.x>prev.poleX 与同 fx 替换兜底结构顺序。
    final lastConfirmPoleX = confirmPoles.last.poleX;
    js = _dedupeJudgmentEvents([
      for (final j in liveJudgments)
        if (j.x <= asOf &&
            (j.x > lastConfirmTrig ||
                (j.truncated && j.x > lastConfirmPoleX)) &&
            (j.fx == 'TOP' || j.fx == 'BOTTOM') &&
            !(j.fractalX1 >= 0 &&
                j.fractalX2 >= j.fractalX1 &&
                confirmedSpans.contains('${j.fx}|${j.fractalX1}|${j.fractalX2}')))
          j,
    ]);
    _appendJudgmentPoles(
      bars: bars,
      poles: poles,
      js: js,
      seedFirst: false,
    );
  }

  return _linesFromPoles(
    bars: bars,
    asOf: asOf,
    poles: poles,
    virtualUnits: virtualUnits,
    frozenIdx: frozenIdx,
    js: js,
  );
}
