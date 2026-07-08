import '../models/bi_confirm_signal.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/kline_bar.dart';
import 'bar_feature_compute.dart';

int dirFromConfirmFx(String fx) => fx == 'TOP' ? 1 : -1;

/// 笔确认前展示用默认笔：首根 K → 当步末 K。
BiVirtualBar? buildPreConfirmDefaultBi(List<KlineBar> bars, int endBarX) {
  if (bars.isEmpty || endBarX < 0 || endBarX >= bars.length) return null;
  final dir = bars[endBarX].close >= bars[0].open ? 1 : -1;
  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (var i = 0; i <= endBarX; i++) {
    hi = hi > bars[i].high ? hi : bars[i].high;
    lo = lo < bars[i].low ? lo : bars[i].low;
  }
  return BiVirtualBar(
    idx: 0,
    dir: dir,
    x1: 0,
    x2: endBarX,
    open: bars[0].open,
    high: hi,
    low: lo,
    close: bars[endBarX].close,
    confirmX: endBarX,
  );
}

/// 分型框内极点 K（dir>0 取首个 high 极大，dir<0 取首个 low 极小）。
int? fractalPoleBarIdx(List<KlineBar> bars, int fx1, int fx2, int dir) {
  final x1 = fx1 < 0 ? 0 : fx1;
  final x2 = fx2 < 0 ? 0 : fx2;
  if (bars.isEmpty || x1 > x2 || x2 >= bars.length) return null;
  if (dir > 0) {
    var peak = double.negativeInfinity;
    for (var j = x1; j <= x2; j++) {
      if (bars[j].high > peak) peak = bars[j].high;
    }
    for (var j = x1; j <= x2; j++) {
      if ((bars[j].high - peak).abs() < 1e-12) return j;
    }
  } else {
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

/// 首确认当步冻结默认笔：virtual_k → 分型极点 K（审判用，终点非 confirm_x）。
BiVirtualBar? buildFrozenDefaultBiAtFirstConfirm(
  List<KlineBar> bars,
  BiConfirmSignal first,
  int virtualK,
) {
  final pole = fractalExtremeBarIdx(bars, first);
  if (pole == null) return null;
  final x1 = virtualK < 0 ? 0 : virtualK;
  final x2 = pole;
  if (x1 >= bars.length || x2 >= bars.length || x1 > x2) return null;
  final dir = bars[x2].close >= bars[x1].open ? 1 : -1;
  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (var i = x1; i <= x2; i++) {
    if (bars[i].high > hi) hi = bars[i].high;
    if (bars[i].low < lo) lo = bars[i].low;
  }
  return BiVirtualBar(
    idx: 0,
    dir: dir,
    x1: x1,
    x2: x2,
    open: bars[x1].open,
    high: hi,
    low: lo,
    close: bars[x2].close,
    confirmX: first.x,
  );
}

BiVirtualBar? _bootstrapVbAtFirstConfirm(
  List<KlineBar> bars,
  BiConfirmSignal first,
  int virtualK,
) {
  final pole = fractalExtremeBarIdx(bars, first);
  if (pole == null) return null;
  final x1 = virtualK < 0 ? 0 : virtualK;
  final x2 = pole;
  if (x1 >= bars.length || x2 >= bars.length || x1 > x2) return null;
  final dir = dirFromConfirmFx(first.fx);
  var hi = double.negativeInfinity;
  var lo = double.infinity;
  for (var i = x1; i <= x2; i++) {
    if (bars[i].high > hi) hi = bars[i].high;
    if (bars[i].low < lo) lo = bars[i].low;
  }
  return BiVirtualBar(
    idx: 0,
    dir: dir,
    x1: x1,
    x2: x2,
    open: bars[x1].open,
    high: hi,
    low: lo,
    close: bars[x2].close,
    confirmX: first.x,
  );
}

bool _endIsDirectionalPeak(
  List<KlineBar> bars,
  BiVirtualBar vb,
  BiConfirmSignal first,
) {
  final pole = fractalExtremeBarIdx(bars, first);
  if (pole == null) return false;
  final x1 = vb.x1 < 0 ? 0 : vb.x1;
  final x2 = vb.x2.clamp(0, bars.length - 1);
  if (pole < x1 || pole > x2) return false;
  if (vb.dir > 0) {
    var peak = double.negativeInfinity;
    for (var i = x1; i <= x2; i++) {
      if (bars[i].high > peak) peak = bars[i].high;
    }
    return (bars[pole].high - peak).abs() < 1e-9;
  }
  var trough = double.infinity;
  for (var i = x1; i <= x2; i++) {
    if (bars[i].low < trough) trough = bars[i].low;
  }
  return (bars[pole].low - trough).abs() < 1e-9;
}

bool _geomEquivVb(BiVirtualBar a, BiVirtualBar b) {
  return a.x1 == b.x1 &&
      a.x2 == b.x2 &&
      a.dir == b.dir &&
      (a.high - b.high).abs() < 1e-9 &&
      (a.low - b.low).abs() < 1e-9;
}

BiSegment? buildBootstrapSegment(List<KlineBar> bars, BiConfirmSignal first) {
  final virtualK = bootstrapReverseExtremeBarIdx(bars, first);
  if (virtualK == null) return null;
  return BiSegment(
    idx: 0,
    dir: dirFromConfirmFx(first.fx),
    beginConfirmX: first.x,
    endConfirmX: first.x,
    beginFractalX1: virtualK,
    beginFractalX2: virtualK,
    endFractalX1: first.fractalX1,
    endFractalX2: first.fractalX2,
    isBootstrap: true,
  );
}

BiSegment buildPromotedSegment(BiConfirmSignal first, int virtualK) {
  return BiSegment(
    idx: 0,
    dir: dirFromConfirmFx(first.fx),
    beginConfirmX: first.x,
    endConfirmX: first.x,
    beginFractalX1: virtualK,
    beginFractalX2: virtualK,
    endFractalX1: first.fractalX1,
    endFractalX2: first.fractalX2,
    isPromotedDefault: true,
  );
}

/// 首笔确认当步审判默认笔（F1∧F2∧F3∧F8；终点=分型极点 K）。
bool trialDefaultBi(List<KlineBar> bars, BiConfirmSignal first) {
  final confirmX = first.x;
  if (confirmX < 0 || confirmX >= bars.length) return false;
  final virtualK = bootstrapReverseExtremeBarIdx(bars, first);
  if (virtualK == null) return false;
  final frozen = buildFrozenDefaultBiAtFirstConfirm(bars, first, virtualK);
  if (frozen == null) return false;
  if (frozen.dir != dirFromConfirmFx(first.fx)) return false;
  if (frozen.x1 != virtualK) return false;
  if (!_endIsDirectionalPeak(bars, frozen, first)) return false;
  final bootstrapVb = _bootstrapVbAtFirstConfirm(bars, first, virtualK);
  if (bootstrapVb == null) return false;
  return _geomEquivVb(frozen, bootstrapVb);
}

/// 默认笔策略：pending / retained / purged。
String resolveDefaultBiPolicy(List<KlineBar> bars, List<BiConfirmSignal> confirms) {
  final valid = confirms.where((c) => c.fx == 'TOP' || c.fx == 'BOTTOM').toList();
  if (valid.isEmpty) return 'pending';
  final first = valid.first;
  if (first.x >= bars.length) return 'pending';
  return trialDefaultBi(bars, first) ? 'retained' : 'purged';
}

/// 会话级 purge：步退到首确认前也剔除默认笔展示/特征。
({List<BiVirtualBar> bars, List<BarCrosshairFeature> features}) stripPreConfirmDefault(
  List<BiVirtualBar> virtualBars,
  List<BarCrosshairFeature> features,
  List<BiSegment> segments,
) {
  if (segments.isNotEmpty) {
    return (bars: virtualBars, features: features);
  }
  final cleared = features
      .map(
        (f) => BarCrosshairFeature(
          idx: f.idx,
          weekday: f.weekday,
          mergeInnerSeq: f.mergeInnerSeq,
          mergeCount: f.mergeCount,
          combineFx: f.combineFx,
          combineHigh: f.combineHigh,
          combineLow: f.combineLow,
          fractalPeakDist: f.fractalPeakDist,
        ),
      )
      .toList();
  return (bars: <BiVirtualBar>[], features: cleared);
}
