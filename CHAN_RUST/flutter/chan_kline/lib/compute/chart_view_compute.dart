import '../models/bar_crosshair_feature.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';

/// 纯视图组装（十字线 as-of 重绘）：全部数据来自 Rust 冻结产物 + 逐K快照，
/// Dart 端不做缠论计算（无回退实现）。

/// 分型合并框内极点 K（绘制笔连线端点用；TOP 取首个 high 极大，BOTTOM 取首个 low 极小）。
int? fractalExtremeBarIdx(List<KlineBar> bars, BiConfirmSignal conf) {
  final x1 = conf.fractalX1 < 0 ? 0 : conf.fractalX1;
  final x2 = conf.fractalX2 < 0 ? 0 : conf.fractalX2;
  if (bars.isEmpty || x1 > x2 || x2 >= bars.length) return null;
  if (conf.fx == 'TOP') {
    var peak = double.negativeInfinity;
    for (var j = x1; j <= x2; j++) {
      if (bars[j].high > peak) peak = bars[j].high;
    }
    for (var j = x1; j <= x2; j++) {
      if ((bars[j].high - peak).abs() < 1e-12) return j;
    }
  } else if (conf.fx == 'BOTTOM') {
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

/// 十字线 as-of 笔 K 列表：已冻结段（Rust 冻结时算好 OHLC，查表）+ 当步快照进行中笔。
List<BiVirtualBar> asOfBiVirtualBars({
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  required List<BarCrosshairFeature> barFeatures,
  required String defaultBiPolicy,
  required int asOf,
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
