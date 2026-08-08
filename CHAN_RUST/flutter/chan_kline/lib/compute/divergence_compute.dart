import 'dart:math' as math;

import '../models/divergence_algo.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../models/math_indicator_config.dart';
import '../models/zs_frame.dart';
import 'adjacent_ratio_compute.dart';
import 'math_classic_compute.dart';
import 'math_series_freeze_store.dart';
import 'zs_compute.dart';
import 'zs_signal_compute.dart';

export '../models/divergence_algo.dart';

/// 单条背驰样本（K0 步进 x）。
class DivergenceSample {
  final int x;
  final double? inMetric;
  final double? outMetric;
  final double? ratio;
  /// 背离=1，未背离=-1，无值=0
  final int diver;

  const DivergenceSample({
    required this.x,
    this.inMetric,
    this.outMetric,
    this.ratio,
    required this.diver,
  });
}

/// 单算法 K0 展开序列。
class DivergenceAlgoK0Series {
  final List<double?> inAt;
  final List<double?> outAt;
  final List<double?> ratioAt;
  final List<int> diverAt;

  const DivergenceAlgoK0Series({
    required this.inAt,
    required this.outAt,
    required this.ratioAt,
    required this.diverAt,
  });
}

/// 当步背驰比较两段的 K0 区间（学习观察：MACD 高亮用）。
class DivergenceCompareSpan {
  final int inSegIdx;
  final int outSegIdx;
  final int inLoX;
  final int inHiX;
  final int outLoX;
  final int outHiX;
  final int inBeginX;
  final int inEndX;
  final int outBeginX;
  final int outEndX;
  final int inDir;
  final int outDir;
  /// contained | broke
  final String mode;

  const DivergenceCompareSpan({
    required this.inSegIdx,
    required this.outSegIdx,
    required this.inLoX,
    required this.inHiX,
    required this.outLoX,
    required this.outHiX,
    required this.inBeginX,
    required this.inEndX,
    required this.outBeginX,
    required this.outEndX,
    required this.inDir,
    required this.outDir,
    required this.mode,
  });
}

/// MACD 类背驰高亮：按算法差异列出实际贡献柱（及 peak 极值点）。
class DivergenceMacdHighlight {
  final DivergenceAlgo algo;
  final List<int> inXs;
  final List<int> outXs;
  /// peak 算法：in/out 段内同向柱峰值所在 x
  final int? inPeakX;
  final int? outPeakX;
  final String mode;

  const DivergenceMacdHighlight({
    required this.algo,
    required this.inXs,
    required this.outXs,
    this.inPeakX,
    this.outPeakX,
    required this.mode,
  });
}

/// 本枢会话：中枢判断启动后的 activeOwn（合并后可重映射）。
class DivergenceOwnSession {
  int? activeOwnX1;
  int? activeOwnRangeX1;
  int? activeOwnRangeX2;

  DivergenceOwnSession({
    this.activeOwnX1,
    this.activeOwnRangeX1,
    this.activeOwnRangeX2,
  });

  DivergenceOwnSession copy() => DivergenceOwnSession(
        activeOwnX1: activeOwnX1,
        activeOwnRangeX1: activeOwnRangeX1,
        activeOwnRangeX2: activeOwnRangeX2,
      );
}

/// 进出段视图（K0=单根分钟K；Kn=连线段/active）。
class _SegView {
  final int idx;
  final int dir;
  final int beginX;
  final int endX;
  final double high;
  final double low;

  const _SegView({
    required this.idx,
    required this.dir,
    required this.beginX,
    required this.endX,
    required this.high,
    required this.low,
  });

  bool get isUp => dir > 0;
  bool get isDown => dir < 0;

  int get loX => beginX < endX ? beginX : endX;
  int get hiX => beginX > endX ? beginX : endX;
}

/// 按中枢判断同构规则更新本枢会话，并在 x1 消失时按区间重叠重映射。
DivergenceOwnSession updateDivergenceOwnSession({
  required DivergenceOwnSession prev,
  required List<ZSFrame> zsList,
  Set<int> confirmedX1ThisStep = const {},
}) {
  final next = prev.copy();

  // 与 mergeZsJudgmentEventLog 同序：离开窗 → 确认同拍
  final unsure = [for (final f in zsList) if (!f.isSure) f];
  if (unsure.length >= 2) {
    final anchor = unsure[unsure.length - 2];
    next.activeOwnX1 = anchor.x1;
    next.activeOwnRangeX1 = anchor.x1;
    next.activeOwnRangeX2 = anchor.x2;
  }
  for (final x1 in confirmedX1ThisStep) {
    ZSFrame? anchor;
    for (final f in zsList) {
      if (f.isSure && f.x1 == x1) {
        anchor = f;
        break;
      }
    }
    if (anchor == null) continue;
    next.activeOwnX1 = anchor.x1;
    next.activeOwnRangeX1 = anchor.x1;
    next.activeOwnRangeX2 = anchor.x2;
  }

  final own = resolveDivergenceOwnFrame(zsList, next);
  if (own != null) {
    next.activeOwnX1 = own.x1;
    next.activeOwnRangeX1 = own.x1;
    next.activeOwnRangeX2 = own.x2;
  }
  return next;
}

/// 解析本枢：先按 x1；消失则用缓存 [x1,x2] 区间重叠重映射（合并塌缩）。
ZSFrame? resolveDivergenceOwnFrame(
  List<ZSFrame> zsList,
  DivergenceOwnSession session,
) {
  final x1 = session.activeOwnX1;
  if (x1 != null) {
    for (final f in zsList) {
      if (f.x1 == x1) return f;
    }
  }
  final rx1 = session.activeOwnRangeX1;
  final rx2 = session.activeOwnRangeX2;
  if (rx1 == null || rx2 == null || zsList.isEmpty) return null;
  ZSFrame? best;
  var bestOv = 0;
  for (final f in zsList) {
    final lo = math.max(f.x1, rx1);
    final hi = math.min(f.x2, rx2);
    final ov = hi - lo;
    if (ov > bestOv) {
      bestOv = ov;
      best = f;
    }
  }
  return bestOv > 0 ? best : null;
}

/// 本枢在列表中的前一框（按 x1 定位，兼容动态 x2 延伸）。
ZSFrame? divergencePrevFrame(List<ZSFrame> zsList, ZSFrame own) {
  for (var i = 0; i < zsList.length; i++) {
    if (zsList[i].x1 == own.x1) {
      return i > 0 ? zsList[i - 1] : null;
    }
  }
  // 回退：精确匹配（同 zsFrameBefore）
  return zsFrameBefore(zsList, own);
}

/// 最新动态中枢：未确认列表末框；若无未确认则取列表末框。
ZSFrame? divergenceDynZs(List<ZSFrame> zsList) {
  if (zsList.isEmpty) return null;
  for (var i = zsList.length - 1; i >= 0; i--) {
    if (!zsList[i].isSure) return zsList[i];
  }
  return zsList.last;
}

/// 动态 Kn 是否仍包在动态中枢 [ZD,ZG] 内（high/low 全层同构）。
bool divergenceKnContainedInZs({
  required double knHigh,
  required double knLow,
  required ZSFrame zs,
}) {
  return knHigh <= zs.high && knLow >= zs.low;
}

/// 解析动态 Kn 的高低：Kn≥1 优先 activeUnit；否则解析 dynZs.endIdx 段（K0 同构）。
({double high, double low, int? idx})? resolveDynKnHL({
  required int displayKn,
  required ZSFrame dynZs,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  // 方案B：Kn≥1 → structure level==displayKn-1
  if (displayKn > 0) {
    for (final lv in levels) {
      if (lv.level != displayKn - 1) continue;
      final a = lv.activeUnit;
      if (a != null) {
        return (high: a.high, low: a.low, idx: a.idx);
      }
      break;
    }
  }
  final endIdx = dynZs.endIdx;
  if (endIdx == null) return null;
  final idx = asOf != null ? math.min(endIdx, asOf) : endIdx;
  final seg = _resolveSeg(
    displayKn: displayKn,
    idx: idx,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  if (seg == null) return null;
  return (high: seg.high, low: seg.low, idx: seg.idx);
}

/// 选背驰比较对：包中→上枢末 vs 上上枢末；突破→本（动态中枢）末 vs 上枢末。
/// [dynKnEndIdx] 突破时本末可覆盖（active.idx）；缺省用 dynZs.endIdx。
({int inEnd, int outEnd, String mode})? selectDivergenceEndPair({
  required List<ZSFrame> zsList,
  required ZSFrame dynZs,
  required double knHigh,
  required double knLow,
  int? dynKnEndIdx,
}) {
  final dynIdx = zsList.indexWhere((f) => f.x1 == dynZs.x1);
  if (dynIdx < 0) return null;
  final contained =
      divergenceKnContainedInZs(knHigh: knHigh, knLow: knLow, zs: dynZs);
  if (contained) {
    // 不使用当前动态中枢末 Kn；用上个 vs 上上个
    if (dynIdx < 2) return null;
    final prev = zsList[dynIdx - 1];
    final prevPrev = zsList[dynIdx - 2];
    final a = prevPrev.endIdx;
    final b = prev.endIdx;
    if (a == null || b == null) return null;
    return (inEnd: a, outEnd: b, mode: 'contained');
  }
  // 突破：本动态中枢末 vs 上个末
  if (dynIdx < 1) return null;
  final prev = zsList[dynIdx - 1];
  final a = prev.endIdx;
  final b = dynKnEndIdx ?? dynZs.endIdx;
  if (a == null || b == null) return null;
  return (inEnd: a, outEnd: b, mode: 'broke');
}

/// 解析当步比较两段的几何区间（与 compute 同源选段）。
DivergenceCompareSpan? resolveDivergenceCompareSpan({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  List<ZSFrame> zsK0Frames = const [],
  int? asOf,
  DivergenceOwnSession? ownSession,
  Set<int> confirmedX1ThisStep = const {},
}) {
  if (bars.isEmpty) return null;
  final zsList = rustZsFramesForKn(
    kn: displayKn,
    zsK0Frames: zsK0Frames,
    levels: levels,
  );
  if (zsList.isEmpty) return null;
  final session = updateDivergenceOwnSession(
    prev: ownSession ?? DivergenceOwnSession(),
    zsList: zsList,
    confirmedX1ThisStep: confirmedX1ThisStep,
  );
  if (session.activeOwnX1 == null) return null;
  if (resolveDivergenceOwnFrame(zsList, session) == null) return null;
  final dynZs = divergenceDynZs(zsList);
  if (dynZs == null) return null;
  final knHL = resolveDynKnHL(
    displayKn: displayKn,
    dynZs: dynZs,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  if (knHL == null) return null;
  final pair = selectDivergenceEndPair(
    zsList: zsList,
    dynZs: dynZs,
    knHigh: knHL.high,
    knLow: knHL.low,
    dynKnEndIdx: knHL.idx,
  );
  if (pair == null) return null;
  final inSeg = _resolveSeg(
    displayKn: displayKn,
    idx: pair.inEnd,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final outSeg = _resolveSeg(
    displayKn: displayKn,
    idx: pair.outEnd,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  if (inSeg == null || outSeg == null) return null;
  return DivergenceCompareSpan(
    inSegIdx: inSeg.idx,
    outSegIdx: outSeg.idx,
    inLoX: inSeg.loX,
    inHiX: inSeg.hiX,
    outLoX: outSeg.loX,
    outHiX: outSeg.hiX,
    inBeginX: inSeg.beginX,
    inEndX: inSeg.endX,
    outBeginX: outSeg.beginX,
    outEndX: outSeg.endX,
    inDir: inSeg.dir,
    outDir: outSeg.dir,
    mode: pair.mode,
  );
}

/// 按算法差异，从比较段 + MACD 柱提取高亮 x（与 _metric* 同源）。
/// - area：从端点起同号连续柱（异号截断，可短于整段）
/// - peak：整段内同向柱；另标峰值 x
/// - full_area：整段内同向柱（异号跳过形成空隙）
/// - diff：整段内所有非空柱（max−min）
DivergenceMacdHighlight? buildDivergenceMacdHighlight({
  required DivergenceAlgo algo,
  required DivergenceCompareSpan span,
  required List<double?> macdHist,
}) {
  if (!isMacdDivergenceAlgo(algo)) return null;
  final inPart = _macdHighlightForSide(
    algo: algo,
    beginX: span.inBeginX,
    endX: span.inEndX,
    loX: span.inLoX,
    hiX: span.inHiX,
    dir: span.inDir,
    isReverse: false,
    macd: macdHist,
  );
  final outPart = _macdHighlightForSide(
    algo: algo,
    beginX: span.outBeginX,
    endX: span.outEndX,
    loX: span.outLoX,
    hiX: span.outHiX,
    dir: span.outDir,
    isReverse: true,
    macd: macdHist,
  );
  return DivergenceMacdHighlight(
    algo: algo,
    inXs: inPart.xs,
    outXs: outPart.xs,
    inPeakX: inPart.peakX,
    outPeakX: outPart.peakX,
    mode: span.mode,
  );
}

({List<int> xs, int? peakX}) _macdHighlightForSide({
  required DivergenceAlgo algo,
  required int beginX,
  required int endX,
  required int loX,
  required int hiX,
  required int dir,
  required bool isReverse,
  required List<double?> macd,
}) {
  switch (algo) {
    case DivergenceAlgo.area:
      return (xs: _macdAreaXs(beginX, endX, loX, hiX, isReverse, macd), peakX: null);
    case DivergenceAlgo.peak:
      return _macdPeakXs(loX, hiX, dir, macd);
    case DivergenceAlgo.fullArea:
      return (xs: _macdSameDirXs(loX, hiX, dir, macd), peakX: null);
    case DivergenceAlgo.diff:
      return (xs: _macdAllXs(loX, hiX, macd), peakX: null);
    case DivergenceAlgo.slope:
    case DivergenceAlgo.lineSlope:
    case DivergenceAlgo.amp:
    case DivergenceAlgo.amount:
    case DivergenceAlgo.volumn:
    case DivergenceAlgo.amountAvg:
    case DivergenceAlgo.volumnAvg:
    case DivergenceAlgo.rsi:
      return (xs: const [], peakX: null);
  }
}

List<int> _macdAreaXs(
  int beginX,
  int endX,
  int loX,
  int hiX,
  bool isReverse,
  List<double?> macd,
) {
  final xs = <int>[];
  if (!isReverse) {
    if (beginX < 0 || beginX >= macd.length) return xs;
    final peak = macd[beginX];
    if (peak == null) return xs;
    for (var i = beginX; i < macd.length && i <= hiX; i++) {
      final m = macd[i];
      if (m == null) break;
      if (m * peak > 0) {
        xs.add(i);
      } else {
        break;
      }
    }
    return xs;
  }
  if (endX < 0 || endX >= macd.length) return xs;
  final peak = macd[endX];
  if (peak == null) return xs;
  for (var i = endX; i >= 0 && i >= loX; i--) {
    final m = macd[i];
    if (m == null) break;
    if (m * peak > 0) {
      xs.add(i);
    } else {
      break;
    }
  }
  return xs;
}

({List<int> xs, int? peakX}) _macdPeakXs(
  int loX,
  int hiX,
  int dir,
  List<double?> macd,
) {
  final xs = <int>[];
  var peak = 1e-7;
  int? peakX;
  final isUp = dir > 0;
  final isDown = dir < 0;
  for (var i = loX; i <= hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    final ok = (isDown && m < 0) || (isUp && m > 0);
    if (!ok) continue;
    xs.add(i);
    if (m.abs() > peak) {
      peak = m.abs();
      peakX = i;
    }
  }
  return (xs: xs, peakX: peakX);
}

List<int> _macdSameDirXs(int loX, int hiX, int dir, List<double?> macd) {
  final xs = <int>[];
  final isUp = dir > 0;
  final isDown = dir < 0;
  for (var i = loX; i <= hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    if ((isDown && m < 0) || (isUp && m > 0)) xs.add(i);
  }
  return xs;
}

List<int> _macdAllXs(int loX, int hiX, List<double?> macd) {
  final xs = <int>[];
  for (var i = loX; i <= hiX && i < macd.length; i++) {
    if (i < 0) continue;
    if (macd[i] == null) continue;
    xs.add(i);
  }
  return xs;
}

/// 计算某 displayKn、全部 12 算法的背驰特征（只写当前 eventX 格）。
/// 力度与 Math 同号：本层 MACD/RSI（优先读冻结仓，禁 live EMA 回写晃动）。
/// 启动：中枢判断激活本枢会话；选段：相对最新动态中枢包中/突破。
Map<DivergenceAlgo, DivergenceAlgoK0Series> computeDivergenceForLevel({
  required int displayKn,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  List<ZSFrame> zsK0Frames = const [],
  MathIndicatorConfig config = const MathIndicatorConfig(),
  int? asOf,
  MathSeriesFreezeStore? mathFreezeStore,
  DivergenceOwnSession? ownSession,
  Set<int> confirmedX1ThisStep = const {},
}) {
  final n = bars.length;
  final empty = {
    for (final a in DivergenceAlgoMeta.all)
      a: DivergenceAlgoK0Series(
        inAt: List<double?>.filled(n, null),
        outAt: List<double?>.filled(n, null),
        ratioAt: List<double?>.filled(n, null),
        diverAt: List<int>.filled(n, 0),
      ),
  };
  if (n <= 0) return empty;

  final eventX = asOf ?? (n - 1);
  if (eventX < 0 || eventX >= n) return empty;

  final span = resolveDivergenceCompareSpan(
    displayKn: displayKn,
    bars: bars,
    levels: levels,
    zsK0Frames: zsK0Frames,
    asOf: asOf,
    ownSession: ownSession,
    confirmedX1ThisStep: confirmedX1ThisStep,
  );
  if (span == null) return empty;

  // 本层力度：优先读 Math 冻结仓；无仓再现场算本层采样
  final frozenMacd = mathFreezeStore?.macd(displayKn);
  final frozenRsi = mathFreezeStore?.rsi(displayKn);
  final macdHist = frozenMacd?.macd ??
      computeMacdForLevel(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        fast: config.macdFast,
        slow: config.macdSlow,
        signal: config.macdSignal,
        asOf: asOf,
      ).macd;
  final rsiArr = frozenRsi ??
      computeRsiForLevel(
        displayKn: displayKn,
        bars: bars,
        levels: levels,
        period: config.rsiPeriod,
        asOf: asOf,
      );

  final inSeg = _resolveSeg(
    displayKn: displayKn,
    idx: span.inSegIdx,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  final outSeg = _resolveSeg(
    displayKn: displayKn,
    idx: span.outSegIdx,
    bars: bars,
    levels: levels,
    asOf: asOf,
  );
  if (inSeg == null || outSeg == null) return empty;

  final out = <DivergenceAlgo, DivergenceAlgoK0Series>{};
  for (final algo in DivergenceAlgoMeta.all) {
    final inAt = List<double?>.filled(n, null);
    final outAt = List<double?>.filled(n, null);
    final ratioAt = List<double?>.filled(n, null);
    final diverAt = List<int>.filled(n, 0);

    final inM = _calMetric(
      algo: algo,
      seg: inSeg,
      isReverse: false,
      bars: bars,
      macdHist: macdHist,
      rsi: rsiArr,
      displayKn: displayKn,
      levels: levels,
      asOf: asOf,
    );
    final outM = _calMetric(
      algo: algo,
      seg: outSeg,
      isReverse: true,
      bars: bars,
      macdHist: macdHist,
      rsi: rsiArr,
      displayKn: displayKn,
      levels: levels,
      asOf: asOf,
    );
    if (inM == null ||
        outM == null ||
        !inM.isFinite ||
        !outM.isFinite ||
        inM == 0.0) {
      out[algo] = DivergenceAlgoK0Series(
        inAt: inAt,
        outAt: outAt,
        ratioAt: ratioAt,
        diverAt: diverAt,
      );
      continue;
    }
    final ratio = outM / inM;
    if (!ratio.isFinite) {
      out[algo] = DivergenceAlgoK0Series(
        inAt: inAt,
        outAt: outAt,
        ratioAt: ratioAt,
        diverAt: diverAt,
      );
      continue;
    }
    final rate = config.divergenceRate;
    final isDiver = rate > 100 || outM <= rate * inM;
    inAt[eventX] = inM;
    outAt[eventX] = outM;
    ratioAt[eventX] = ratio;
    diverAt[eventX] = isDiver ? 1 : -1;
    out[algo] = DivergenceAlgoK0Series(
      inAt: inAt,
      outAt: outAt,
      ratioAt: ratioAt,
      diverAt: diverAt,
    );
  }
  return out;
}

_SegView? _resolveSeg({
  required int displayKn,
  required int idx,
  required List<KlineBar> bars,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  if (displayKn <= 0) {
    if (idx < 0 || idx >= bars.length) return null;
    if (asOf != null && idx > asOf) return null;
    final b = bars[idx];
    final dir = _k0BarDir(bars, idx);
    return _SegView(
      idx: idx,
      dir: dir,
      beginX: idx,
      endX: idx,
      high: b.high,
      low: b.low,
    );
  }
  // 方案B：段解析 Kn≥1 → structure level==displayKn-1
  LevelBundle? lv;
  for (final b in levels) {
    if (b.level == displayKn - 1) {
      lv = b;
      break;
    }
  }
  if (lv == null) return null;
  for (final s in lv.segments) {
    if (s.idx == idx) {
      if (asOf != null && s.endConfirmX > asOf && s.endPoleX > asOf) {
        return null;
      }
      return _SegView(
        idx: s.idx,
        dir: s.dir,
        beginX: s.beginPoleX,
        endX: s.endPoleX,
        high: s.high,
        low: s.low,
      );
    }
  }
  final a = lv.activeUnit;
  if (a != null && a.idx == idx) {
    final x2 = asOf != null ? math.min(a.x2, asOf) : a.x2;
    return _SegView(
      idx: a.idx,
      dir: a.dir,
      beginX: a.x1,
      endX: x2,
      high: a.high,
      low: a.low,
    );
  }
  return null;
}

/// 对齐 Rust `kline_bars_to_segments` 方向。
int _k0BarDir(List<KlineBar> bars, int i) {
  if (i <= 0 || i >= bars.length) return 1;
  final b = bars[i];
  final p = bars[i - 1];
  final mid = (b.high + b.low) / 2.0;
  final pMid = (p.high + p.low) / 2.0;
  return mid >= pMid ? 1 : -1;
}

double? _calMetric({
  required DivergenceAlgo algo,
  required _SegView seg,
  required bool isReverse,
  required List<KlineBar> bars,
  required List<double?> macdHist,
  required List<double?> rsi,
  required int displayKn,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  switch (algo) {
    case DivergenceAlgo.area:
      return _metricArea(seg, isReverse, macdHist);
    case DivergenceAlgo.peak:
      return _metricPeak(seg, macdHist);
    case DivergenceAlgo.fullArea:
      return _metricFullArea(seg, macdHist);
    case DivergenceAlgo.diff:
      return _metricDiff(seg, macdHist);
    case DivergenceAlgo.slope:
      return _metricSlope(seg, bars);
    case DivergenceAlgo.amp:
      return _metricAmp(seg, bars);
    case DivergenceAlgo.amount:
      return _metricTrade(seg, bars, _TradeField.amount, avg: false);
    case DivergenceAlgo.volumn:
      return _metricTrade(seg, bars, _TradeField.volume, avg: false);
    case DivergenceAlgo.amountAvg:
      return _metricTrade(seg, bars, _TradeField.amount, avg: true);
    case DivergenceAlgo.volumnAvg:
      return _metricTrade(seg, bars, _TradeField.volume, avg: true);
    case DivergenceAlgo.rsi:
      return _metricRsi(seg, rsi);
    case DivergenceAlgo.lineSlope:
      return _metricLineSlopeAbs(
        displayKn: displayKn,
        segIdx: seg.idx,
        levels: levels,
        asOf: asOf,
      );
  }
}

/// 与 Kn连线斜率同源；力度取绝对值（保持 out<=rate*in 语义）。K0 无连线段 → null。
double? _metricLineSlopeAbs({
  required int displayKn,
  required int segIdx,
  required List<LevelBundle> levels,
  int? asOf,
}) {
  // 方案B：背驰 displayKn≥1 → structure level==displayKn-1
  if (displayKn <= 0) return null;
  final s = calcUnitLineSlope(
    levels: levels,
    level: displayKn - 1,
    unitIdx: segIdx,
    asOf: asOf,
  );
  if (s == null || !s.isFinite) return null;
  final a = s.abs();
  return a < 1e-12 ? 1e-7 : a;
}

double _metricArea(_SegView seg, bool isReverse, List<double?> macd) {
  var s = 1e-7;
  if (!isReverse) {
    final begin = seg.beginX;
    if (begin < 0 || begin >= macd.length) return s;
    final peak = macd[begin];
    if (peak == null) return s;
    for (var i = begin; i < macd.length && i <= seg.hiX; i++) {
      final m = macd[i];
      if (m == null) break;
      if (m * peak > 0) {
        s += m.abs();
      } else {
        break;
      }
    }
    return s;
  }
  // 从终点往回：异号停止
  final begin = seg.endX;
  if (begin < 0 || begin >= macd.length) return s;
  final peak = macd[begin];
  if (peak == null) return s;
  for (var i = begin; i >= 0 && i >= seg.loX; i--) {
    final m = macd[i];
    if (m == null) break;
    if (m * peak > 0) {
      s += m.abs();
    } else {
      break;
    }
  }
  return s;
}

double _metricPeak(_SegView seg, List<double?> macd) {
  var peak = 1e-7;
  for (var i = seg.loX; i <= seg.hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    if (m.abs() > peak) {
      if (seg.isDown && m < 0) {
        peak = m.abs();
      } else if (seg.isUp && m > 0) {
        peak = m.abs();
      }
    }
  }
  return peak;
}

double _metricFullArea(_SegView seg, List<double?> macd) {
  var s = 1e-7;
  for (var i = seg.loX; i <= seg.hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    if ((seg.isDown && m < 0) || (seg.isUp && m > 0)) {
      s += m.abs();
    }
  }
  return s;
}

double? _metricDiff(_SegView seg, List<double?> macd) {
  var maxV = double.negativeInfinity;
  var minV = double.infinity;
  var any = false;
  for (var i = seg.loX; i <= seg.hiX && i < macd.length; i++) {
    if (i < 0) continue;
    final m = macd[i];
    if (m == null) continue;
    any = true;
    if (m > maxV) maxV = m;
    if (m < minV) minV = m;
  }
  if (!any) return null;
  return maxV - minV;
}

double? _metricSlope(_SegView seg, List<KlineBar> bars) {
  final b0 = seg.beginX;
  final b1 = seg.endX;
  if (b0 < 0 || b1 < 0 || b0 >= bars.length || b1 >= bars.length) return null;
  final begin = bars[b0];
  final end = bars[b1];
  final cnt = (b1 - b0).abs() + 1;
  if (seg.isUp) {
    if (end.high == 0) return null;
    return (end.high - begin.low) / end.high / cnt;
  }
  if (begin.high == 0) return null;
  return (begin.high - end.low) / begin.high / cnt;
}

double? _metricAmp(_SegView seg, List<KlineBar> bars) {
  final b0 = seg.beginX;
  final b1 = seg.endX;
  if (b0 < 0 || b1 < 0 || b0 >= bars.length || b1 >= bars.length) return null;
  final begin = bars[b0];
  final end = bars[b1];
  if (seg.isDown) {
    if (begin.high == 0) return null;
    return (begin.high - end.low) / begin.high;
  }
  if (begin.low == 0) return null;
  return (end.high - begin.low) / begin.low;
}

enum _TradeField { amount, volume }

double? _metricTrade(
  _SegView seg,
  List<KlineBar> bars,
  _TradeField field, {
  required bool avg,
}) {
  var sum = 0.0;
  var cnt = 0;
  for (var i = seg.loX; i <= seg.hiX && i < bars.length; i++) {
    if (i < 0) continue;
    final b = bars[i];
    double? v;
    switch (field) {
      case _TradeField.amount:
        v = b.amount;
        break;
      case _TradeField.volume:
        v = b.volume;
        break;
    }
    sum += v;
    cnt++;
  }
  if (cnt <= 0) return null;
  return avg ? sum / cnt : sum;
}

double? _metricRsi(_SegView seg, List<double?> rsi) {
  final vals = <double>[];
  for (var i = seg.loX; i <= seg.hiX && i < rsi.length; i++) {
    if (i < 0) continue;
    final v = rsi[i];
    if (v != null) vals.add(v);
  }
  if (vals.isEmpty) return null;
  if (seg.isDown) {
    final m = vals.reduce(math.min);
    return 10000.0 / (m + 1e-7);
  }
  return vals.reduce(math.max);
}
