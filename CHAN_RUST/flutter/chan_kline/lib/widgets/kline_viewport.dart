import 'dart:math' as math;

import '../models/kline_bar.dart';

/// K 线视口状态（对齐 a_replay_trainer：viewXMin/Max、Y 缩放/平移）。
class KlineViewport {
  /// 左侧留白（K 线最大化：仅留极小边距）
  static const double padL = 4;
  /// 右侧几乎不留白：主/副图画到价格数字处，价格标签叠在图上
  static const double padR = 2;
  /// 桌面主图顶留白
  static const double padT = 28;
  /// 手机主图「主图」收纳钮行高
  static const double mainIndicatorToggleBand = 30;
  /// 主图指标 chip 区最大占位（防多行撑入副图）
  static const double mainIndicatorChipMaxBand = 56;
  /// 副图指标 chip 区最大占位（为标记区保底高度）
  static const double subIndicatorChipMaxBand = 40;
  /// 副图标记/曲线最小绘制高度（chip 再长也不挤没标记）
  static const double minSubMarkerPlotH = 52;
  /// 副图顶留白：避开左上角指标名按钮，标记不被盖
  static const double subIndicatorChipBand = 26;
  /// 副图全关时仍保留的收纳钮占位（主图底 / X 轴上方）
  static const double subIndicatorEntryBand = 28;
  /// 主图底边距（与副图分隔）
  static const double padB = 4;
  /// 底部 X 轴时间刻度带高度
  static const double xAxisH = 24;
  static const double zoomFactor = 1.15;
  /// 放大时最少可见约几根（仍可按 barCount 再放宽）
  static const double minSpan = 5;
  /// 缩小时最多可扩到「全量跨度」的倍数（越大蜡烛越小、空白越多）
  static const double maxZoomOutFactor = 8.0;
  static const double maxYShift = 3.0;

  double allXMin = 0;
  double allXMax = 0;
  double viewXMin = 0;
  double viewXMax = 0;
  double yZoomRatio = 1.0;
  double yShiftRatio = 0.0;
  bool ready = false;
  /// 用户手动缩放/平移后为 true，步进时按 ensureLatest 滚动而非整屏复位。
  bool userAdjustedView = false;

  /// 当前视窗跨度（bar 索引，可为小数）。
  /// 下限 1.0：单根 K 时 viewXMin==viewXMax，若用 1e-6 会让 slotW 变成天文数字，
  /// 虚线描边（构建中合并框等）循环上亿次 → 白屏卡死。
  double get xSpan => math.max(1.0, viewXMax - viewXMin);

  /// 允许缩到多窄：全量 bar 少时放宽，避免 minSpan=5 卡死缩放。
  double minSpanFor(int barCount) {
    if (barCount <= 1) return 1;
    return math.min(minSpan, math.max(2.0, barCount * 0.15));
  }

  void markUserAdjusted() {
    userAdjustedView = true;
  }

  void resetForBarCount(int count) {
    allXMin = 0;
    allXMax = math.max(0, count - 1).toDouble();
    if (count <= 1) {
      // 单根：视窗跨度至少 1 个 slot，避免 xSpan 塌成 0
      viewXMin = 0;
      viewXMax = 1;
    } else {
      viewXMin = allXMin;
      viewXMax = allXMax;
    }
    yZoomRatio = 1.0;
    yShiftRatio = 0.0;
    userAdjustedView = false;
    ready = count > 0;
  }

  /// 步进/播放时最新 K 在视窗内的相对位置。0.5 = 视窗正中。
  ///
  /// 上一版用 0.75（距右边界约 1/4），用户看了仍觉得贴着右缘；
  /// 再改到 0.6 也一样：数据不够长时左边界会把视窗顶回去，最新 K 又贴到最右。
  /// 2026-11-06 改为 0.5，并允许视窗左端低于数据起点（左侧留白），
  /// 这样从第一根起最新 K 就在正中，不会被左边界顶偏。
  /// 各子窗口各自一份视口，但跟随口径同此。
  static const double stepFollowPos = 0.5;

  /// 子窗口盯住某根 K 时，最新 K 比正中再靠右一截。
  static const double stepFollowPosRight = 0.65;

  /// 步进/播放时把最新 K 固定到视窗水平正中。
  ///
  /// 不再等最新 K 滑出右边界才拽回：每一步都重新落位。
  /// 数据刚开始、目标位置落在数据起点之前时，左侧留白，不把视窗顶回去。
  void ensureLatestVisible(int lastIdx, {double followPos = stepFollowPos}) {
    if (!ready) return;

    final span = xSpan;
    if (span <= 1) {
      viewXMin = allXMin;
      viewXMax = allXMax;
      return;
    }

    var newMin = lastIdx - span * followPos;
    var newMax = newMin + span;
    // 右侧最多留两个视窗宽的空白；超出就整体左移。
    // 左侧不再卡在数据起点：卡住会把最新 K 顶到最右，居中就做不到。
    final rightMax = allXMax + span * 2;
    if (newMax > rightMax) {
      newMax = rightMax;
      newMin = newMax - span;
    }
    viewXMin = newMin;
    viewXMax = newMax;
  }

  /// 步进/播放时把最新 K 的价格拉回垂直居中。
  ///
  /// 纵向平移不会随步进自动清掉：价格走高或走低后，
  /// 最新 K 会慢慢漂到窗口上沿或下沿。这里按「当前可见 K 的高低区间」
  /// 反推平移量，使最新 K 的中间价落在区间中部；用户设过的纵向缩放保留。
  /// [bars] 必须是本窗实际画的那些 K：子窗口画的是该层自己的 K，
  /// 不能用底层 K0 的价格代替，否则层级价格跑出 K0 区间后会贴到窗口上下沿。
  void centerLatestVertically(List<KlineBar> bars, int lastIdx) {
    if (!ready || bars.isEmpty) return;
    if (lastIdx < 0) return;
    // 取序列最后一根，不按下标取：子窗口只把本层最新一根传进来时，
    // 它的下标是 0，而 lastIdx 是底层 K 的序号，按下标取会直接越界返回。
    final bar = bars.last;
    final mid = (bar.high + bar.low) / 2;

    var yMin = bars.first.low;
    var yMax = bars.first.high;
    for (final b in bars) {
      yMin = math.min(yMin, b.low);
      yMax = math.max(yMax, b.high);
    }
    final baseSpan = math.max(1e-6, yMax - yMin);
    final rangeMid = (yMax + yMin) / 2;
    yShiftRatio = ((mid - rangeMid) / baseSpan).clamp(-maxYShift, maxYShift);
  }

  /// 把指定 K0 滚进视窗中间附近（报告点交易时跳图）。
  void ensureBarVisible(int idx) {
    if (!ready) return;
    final i = idx.toDouble();
    if (i >= viewXMin && i <= viewXMax) return;
    final span = xSpan;
    var newMin = i - span * 0.4;
    var newMax = newMin + span;
    if (newMin < allXMin) {
      newMin = allXMin;
      newMax = newMin + span;
    }
    if (newMax > allXMax + span * 0.5) {
      newMax = allXMax + span * 0.5;
      newMin = newMax - span;
    }
    viewXMin = newMin;
    viewXMax = newMax;
    markUserAdjusted();
  }

  /// 逐K步进后同步视窗。
  ///
  /// [centerLatest] 为真（子窗口）时：每一步都把最新 K 放到视窗正中，
  /// 不管用户有没有手动缩放过。没调过的窗口用「至少 40 根」的视窗宽居中，
  /// 数据还少于 40 根时左侧留白；用户调过的缩放宽度原样保留。
  /// [centerLatest] 为假（单图）时保持原口径：没手动调过就展示全量，
  /// 调过才跟随最新 K。
  void syncWindowOnStep(
    int lastIdx, {
    bool centerLatest = false,
    double followPos = stepFollowPos,
  }) {
    if (!ready) return;
    allXMax = math.max(allXMax, lastIdx.toDouble());
    if (centerLatest) {
      if (!userAdjustedView) {
        const minSpan = 40.0;
        viewXMin = lastIdx - minSpan * followPos;
        viewXMax = viewXMin + minSpan;
      }
      ensureLatestVisible(lastIdx, followPos: followPos);
      return;
    }
    if (!userAdjustedView) {
      viewXMin = allXMin;
      viewXMax = allXMax;
    } else {
      ensureLatestVisible(lastIdx);
    }
  }

  /// 逐 K 步进时**保持最新 K 的当前屏幕位置**。
  ///
  /// 仅用户手动缩放/平移过（[userAdjustedView]）后使用：视窗按数据增量
  /// 整体平移（进度退一步就反向平移），跨度（缩放）与纵轴缩放/位移一概不动，
  /// 因此最新 K 停在原屏幕位置，不会再被拉回正中/全量。
  /// 调用方负责在未手动调整时走旧口径（[syncWindowOnStep]/[showAllBars]）。
  void holdLatestThroughStep({
    required int lastIdx,
    required int prevLastIdx,
  }) {
    if (!ready) return;
    allXMax = math.max(allXMax, lastIdx.toDouble());
    final delta = lastIdx - prevLastIdx;
    if (delta == 0) return;
    viewXMin += delta;
    viewXMax += delta;
  }

  /// 没盯住某一根 K 时：按当前 K 线根数把整段放进视窗。
  /// 右侧留一截空白，步进/播放时最新 K 不贴右边界。
  void showAllBars({
    double leftBlankRatio = 0.08,
    double rightBlankRatio = 0.22,
  }) {
    if (!ready) return;
    final dataSpan = math.max(1.0, allXMax - allXMin);
    viewXMin = allXMin - dataSpan * leftBlankRatio;
    viewXMax = allXMax + dataSpan * rightBlankRatio;
    yZoomRatio = 1.0;
    yShiftRatio = 0.0;
    userAdjustedView = false;
  }

  /// 滚轮横向缩放，锚点为画布内 X（像素）。
  /// [allowLeftBlank] 为真时左端也可以扩出去，左右一起变，不再只朝右边挤。
  void zoomXAt(
    double factor,
    double anchorCanvasX,
    double canvasWidth, {
    bool allowLeftBlank = false,
  }) {
    if (!ready || allXMax < allXMin) return;
    final barCount = (allXMax - allXMin + 1).round();
    if (barCount <= 1) return;

    var span = xSpan;
    if (span < 1e-6) {
      span = allXMax - allXMin;
    }

    var newSpan = span / factor;
    final dataSpan = math.max(1.0, allXMax - allXMin + 1);
    // 缩小：允许视窗大于全量，蜡烛继续变细
    final maxSpan = dataSpan * maxZoomOutFactor;
    newSpan = newSpan.clamp(minSpanFor(barCount), maxSpan);

    final usableW = math.max(1, canvasWidth - padL - padR);
    final rel = ((anchorCanvasX - padL) / usableW).clamp(0.0, 1.0);
    final xAtMouse = viewXMin + rel * span;
    var newMin = xAtMouse - rel * newSpan;
    var newMax = newMin + newSpan;

    if (!allowLeftBlank && newMin < allXMin) {
      newMin = allXMin;
      newMax = newMin + newSpan;
    }
    // 右侧留白：超出时整体左移视窗，避免 span 变小后 rightMax 收紧把视窗硬拽回、缩放失效
    final rightLimit = allXMax + newSpan * 2;
    if (newMax > rightLimit) {
      final shift = newMax - rightLimit;
      newMin -= shift;
      newMax -= shift;
      if (newMin < allXMin) {
        newMin = allXMin;
        newMax = newMin + newSpan;
      }
    }

    viewXMin = newMin;
    viewXMax = newMax;
    if (!allowLeftBlank && viewXMin < allXMin) viewXMin = allXMin;
    if (viewXMax <= viewXMin) {
      viewXMax = math.min(allXMax, viewXMin + minSpanFor(barCount));
    }
  }

  /// 纵向缩放后，把 [price] 钉在绘图区从上往下 [relFromTop] 的位置（0 顶，1 底）。
  /// 滚轮以鼠标为焦点时，鼠标下的价格不乱跑。
  void pinPriceAtPlotFraction({
    required List<KlineBar> bars,
    required double price,
    required double relFromTop,
  }) {
    if (!ready || bars.isEmpty) return;
    var yMin = bars.first.low;
    var yMax = bars.first.high;
    for (final b in bars) {
      yMin = math.min(yMin, b.low);
      yMax = math.max(yMax, b.high);
    }
    if ((yMax - yMin).abs() < 1e-9) {
      yMin -= 0.5;
      yMax += 0.5;
    }
    final baseSpan = math.max(1e-6, yMax - yMin);
    final mid = (yMax + yMin) / 2;
    final rel = relFromTop.clamp(0.0, 1.0);
    final shift = (price - mid) / baseSpan + (rel - 0.5) / yZoomRatio;
    yShiftRatio = shift.clamp(-maxYShift, maxYShift);
  }

  /// 双指/滚轮纵向缩放：factor>1 放大，<1 缩小。
  void zoomYBy(double factor) {
    if (!ready || factor <= 0) return;
    yZoomRatio = (yZoomRatio * factor).clamp(0.2, 20.0);
  }

  /// 滚轮 + Ctrl：纵向缩放。
  void zoomY(bool zoomIn) {
    zoomYBy(zoomIn ? zoomFactor : 1 / zoomFactor);
  }

  /// 左键拖拽平移：dx/dy 为像素位移。
  void panByPixels(double dx, double dy, double canvasWidth, double plotH) {
    if (!ready) return;
    final span = xSpan;
    final usableW = math.max(1, canvasWidth - padL - padR);
    final dxBars = (-dx / usableW) * span;
    var newMin = viewXMin + dxBars;
    var newMax = viewXMax + dxBars;
    if (newMin < allXMin) {
      newMin = allXMin;
      newMax = newMin + span;
    }
    viewXMin = newMin;
    viewXMax = newMax;
    yShiftRatio += dy / math.max(1, plotH);
    yShiftRatio = yShiftRatio.clamp(-maxYShift, maxYShift);
  }

  PriceRange priceRangeFor(List<KlineBar> bars) {
    if (bars.isEmpty) {
      return const PriceRange(0, 1);
    }
    var yMin = bars.first.low;
    var yMax = bars.first.high;
    for (final b in bars) {
      yMin = math.min(yMin, b.low);
      yMax = math.max(yMax, b.high);
    }
    if ((yMax - yMin).abs() < 1e-9) {
      yMin -= 0.5;
      yMax += 0.5;
    }
    final baseSpan = math.max(1e-6, yMax - yMin);
    final mid = (yMax + yMin) / 2;
    final zoomedSpan = baseSpan / yZoomRatio;
    yMin = mid - zoomedSpan / 2;
    yMax = mid + zoomedSpan / 2;
    if (yShiftRatio != 0) {
      final offset = baseSpan * yShiftRatio;
      yMin += offset;
      yMax += offset;
    }
    return PriceRange(yMin, yMax);
  }

  List<KlineBar> visibleBars(List<KlineBar> all) {
    if (all.isEmpty) return const [];
    final i0 = viewXMin.floor().clamp(0, all.length - 1);
    final i1 = viewXMax.ceil().clamp(0, all.length - 1);
    return all.sublist(i0, i1 + 1);
  }

  double indexToX(double index, double canvasWidth) {
    final plotW = math.max(1, canvasWidth - padL - padR);
    final span = math.max(xSpan, 1e-6);
    return padL + ((index - viewXMin) / span) * plotW;
  }

  double xToIndex(double canvasX, double canvasWidth) {
    final plotW = math.max(1, canvasWidth - padL - padR);
    final clamped = canvasX.clamp(padL, canvasWidth - padR);
    final span = math.max(xSpan, 1e-6);
    return viewXMin + ((clamped - padL) / plotW) * span;
  }

  /// 当前视窗下单根 K 线槽宽（像素）。
  double barSlotWidth(double canvasWidth) {
    final plotW = math.max(1, canvasWidth - padL - padR);
    return plotW / math.max(xSpan, 1e-6);
  }

  /// K 线中心 X（与蜡烛绘制 cx 对齐）。
  double barCenterX(int barIdx, double canvasWidth) {
    return indexToX(barIdx.toDouble(), canvasWidth) + barSlotWidth(canvasWidth) / 2;
  }

  /// 鼠标 X → 最近 K 线索引（整数精度，对齐主图 x）。
  int barIndexAtCanvasX(double canvasX, double canvasWidth, int barCount) {
    if (barCount <= 0) return 0;
    final idx = xToIndex(canvasX, canvasWidth).round();
    return idx.clamp(0, barCount - 1);
  }

  int nearestBarIndex(List<KlineBar> bars, double targetIndex) {
    if (bars.isEmpty) return 0;
    var best = 0;
    var bestDist = double.infinity;
    for (var i = 0; i < bars.length; i++) {
      final d = (i - targetIndex).abs();
      if (d < bestDist) {
        bestDist = d;
        best = i;
      }
    }
    return best;
  }
}

class PriceRange {
  final double min;
  final double max;
  const PriceRange(this.min, this.max);
  double get span => math.max(1e-6, max - min);
  double yOf(double price, double plotTop, double plotH) =>
      plotTop + ((max - price) / span) * plotH;
  double priceFromY(double py, double plotTop, double plotH) =>
      max - ((py - plotTop) / math.max(1, plotH)) * span;
}
