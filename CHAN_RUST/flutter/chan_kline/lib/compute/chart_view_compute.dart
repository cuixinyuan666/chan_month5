import '../models/bar_crosshair_feature.dart';
import '../models/fractal_judgment_event.dart';
import '../models/k0_confirm_signal.dart';
import '../models/k1_bar.dart';
import '../models/kline_bar.dart';
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

  final l1 = levels.isNotEmpty ? levels.first : null;
  final frozen = <K1Bar>[];
  if (l1 != null) {
    for (final s in l1.segments) {
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

  // 当步快照（逐K当下冻结）：进行中 K0连线或刚冻结首根
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

/// as-of 展示轨虚拟单元（全层同构）：冻结段 + 可选当步进行中（LevelSnap）。
List<K1Bar> asOfLevelVirtualK1Bars({
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required int level,
  required int asOf,
  bool includeBuilding = true,
}) {
  if (level < 1 || levels.length < level) return const [];
  final bundle = levels[level - 1];
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


/// 种子框内「出发极值」端点：升=框内首次最低 low；降=框内首次最高 high。
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
  /// 调试用：关联虚拟单元 idx（无则 -1）
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
List<_DashPole> _collectConfirmPoles({
  required List<KlineBar> bars,
  required int asOf,
  required List<LevelConfirm> levelConfirms,
  required List<K0ConfirmSignal> k0Confirms,
}) {
  final raw = <_DashPole>[];
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
  return out;
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

/// 极点链 → 闭段 + 开口尖端（确认↔确认/判断↔判断实；确认↔判断虚；开口虚）。
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

    final bothJudgment = a.src == 'judgment' && b.src == 'judgment';
    final asSolid = bothConfirm || bothJudgment;
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

  // 开口尖端
  final last = poles.last;
  final bool allowOpen;
  if (last.src == 'confirm') {
    allowOpen = poles.length == 1 || js.isEmpty;
  } else {
    // 末判断仅在「本步刚成立」时画开口（triggerX==asOf）；否则钉死不拉长
    allowOpen = last.triggerX == asOf;
  }
  if (allowOpen) {
    final openDir = last.fx == 'BOTTOM' ? 1 : -1;
    LevelLineEndpoint? tip;
    final beginEp = last.endpoint;

    if (last.src == 'judgment' && last.rightX1 >= 0) {
      // 判断开口：右组 [rightX1,rightX2] 内方向首极值
      final rightEnd =
          last.rightX2 >= last.rightX1 ? last.rightX2 : last.rightX1;
      final asOfCap = asOf < rightEnd ? asOf : rightEnd;
      tip = buildingTailEndpoint(
        bars: bars,
        afterConfirmX: last.rightX1 - 1,
        asOfX: asOfCap,
        buildingDir: openDir,
      );
    } else {
      // 确认开口（含刚成立当步）：一律从极点扫到 asOf，取方向极值首次出现根
      // （取消确认刚成立右组=[x,x] 特例，避免终点跳到确认本根）
      tip = buildingTailEndpoint(
        bars: bars,
        afterConfirmX: last.poleX,
        asOfX: asOf,
        buildingDir: openDir,
      );
    }

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
  }

  return out;
}

/// 动态KN + 当下分型判断拆段的构建中连线（全层同构）。
///
/// [liveJudgments]：as-of 当下重算的有效判断（禁止用会话历史，否则失效判断自动回退）。
/// 口径（全层同构）：
/// - 判断极点钉在 (上一极点, judgment.x] 扫价（buildingTailEndpoint），不随 asOf 拉长；
/// - 尚无确认时：首判断用中组极点起链，画判断↔判断实 / 判断开口虚（与有确认同构）；
/// - 右组=分型第三元素的 K0 跨度 [rightX1,rightX2]
///   （K0 例确认@8 → [8,8]；K1 例判断@58 → [55,58]）；
/// - 判断刚成立开口：起点=判断极点；终点=右组内方向首极值
///   （扫 (rightX1-1, min(asOf,rightX2)]；禁止扫进中组如 44→47）；
/// - 确认开口（含刚成立当步）：一律从确认极点扫到 asOf，取方向极值首次出现根
///   （取消右组=[confirm.x,confirm.x] 特例，避免确认当步终点跳到本根）；
/// - 确认↔确认(未冻覆盖)实线；判断↔判断实线定格；确认↔判断虚线。
List<DisplayBuildingLine> computeDisplayBuildingLines({
  required List<KlineBar> bars,
  required int asOf,
  required List<K1Bar> virtualUnits,
  required Set<int> frozenIdx,
  List<LevelConfirm> levelConfirms = const [],
  List<K0ConfirmSignal> k0Confirms = const [],
  List<FractalJudgmentEvent> liveJudgments = const [],
}) {
  if (bars.isEmpty || asOf < 0 || asOf >= bars.length) return const [];

  final confirmPoles = _collectConfirmPoles(
    bars: bars,
    asOf: asOf,
    levelConfirms: levelConfirms,
    k0Confirms: k0Confirms,
  );

  final List<FractalJudgmentEvent> js;
  final List<_DashPole> poles;

  if (confirmPoles.isEmpty) {
    // 尚无确认：仍消费 live 判断（全层同构）；无判断才退化到未冻虚拟单元
    js = [
      for (final j in liveJudgments)
        if (j.x <= asOf && (j.fx == 'TOP' || j.fx == 'BOTTOM')) j,
    ]..sort((a, b) => a.x.compareTo(b.x));
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
        out.add(DisplayBuildingLine(
          begin: LevelLineEndpoint(barIdx: u.x1, price: u.open),
          end: LevelLineEndpoint(barIdx: u.x2, price: u.close),
          dir: u.dir,
          unitIdx: u.idx,
          anchorX: u.x1,
          beginSrc: 'dynamic',
          endSrc: 'dynamic',
          asSolid: false,
          isOpenTip: true,
        ));
      }
      return out;
    }
  } else {
    poles = <_DashPole>[...confirmPoles];
    final lastConfirmTrig = confirmPoles.last.triggerX;
    js = [
      for (final j in liveJudgments)
        if (j.x <= asOf &&
            j.x > lastConfirmTrig &&
            (j.fx == 'TOP' || j.fx == 'BOTTOM'))
          j,
    ]..sort((a, b) => a.x.compareTo(b.x));
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
