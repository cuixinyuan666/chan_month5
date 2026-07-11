import 'dart:math' as math;

import '../models/kline_bar.dart';

/// K 线视口状态（对齐 a_replay_trainer：viewXMin/Max、Y 缩放/平移）。
class KlineViewport {
  /// 左侧留白（K 线最大化：仅留极小边距）
  static const double padL = 4;
  /// 右侧几乎不留白：主/副图画到价格数字处，价格标签叠在图上
  static const double padR = 2;
  static const double padT = 6;
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
  double get xSpan => math.max(1e-6, viewXMax - viewXMin);

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
    viewXMin = allXMin;
    viewXMax = allXMax;
    yZoomRatio = 1.0;
    yShiftRatio = 0.0;
    userAdjustedView = false;
    ready = count > 0;
  }

  /// 对齐 a_replay ensureLatestKVisible：最新 K 滑出视窗时右对齐跟随。
  void ensureLatestVisible(int lastIdx) {
    if (!ready) return;
    if (lastIdx >= viewXMin && lastIdx <= viewXMax) return;

    final span = xSpan;
    if (span <= 1) {
      viewXMin = allXMin;
      viewXMax = allXMax;
      return;
    }

    const pos = 0.85;
    var newMin = lastIdx - span * pos;
    var newMax = newMin + span;
    if (newMin < allXMin) {
      newMin = allXMin;
      newMax = newMin + span;
    }
    final rightMax = allXMax + span * 2;
    if (newMax > rightMax) {
      newMax = rightMax;
      newMin = newMax - span;
    }
    viewXMin = newMin;
    viewXMax = newMax;
  }

  /// 逐K步进后同步视窗（未手动调视图则展示全量，已调视图则跟随最新 K）。
  void syncWindowOnStep(int lastIdx) {
    if (!ready) return;
    allXMax = math.max(allXMax, lastIdx.toDouble());
    if (!userAdjustedView) {
      viewXMin = allXMin;
      viewXMax = allXMax;
    } else {
      ensureLatestVisible(lastIdx);
    }
  }

  /// 滚轮横向缩放，锚点为画布内 X（像素）。
  void zoomXAt(double factor, double anchorCanvasX, double canvasWidth) {
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

    if (newMin < allXMin) {
      newMin = allXMin;
      newMax = newMin + newSpan;
    }
    final rightMax = allXMax + newSpan * 2;
    if (newMax > rightMax) {
      newMax = rightMax;
      newMin = newMax - newSpan;
    }

    viewXMin = newMin;
    viewXMax = newMax;
    if (viewXMin < allXMin) viewXMin = allXMin;
    if (viewXMax <= viewXMin) {
      viewXMax = math.min(allXMax, viewXMin + minSpanFor(barCount));
    }
  }

  /// 滚轮 + Ctrl：纵向缩放。
  void zoomY(bool zoomIn) {
    if (!ready) return;
    if (zoomIn) {
      yZoomRatio *= zoomFactor;
    } else {
      yZoomRatio /= zoomFactor;
    }
    yZoomRatio = yZoomRatio.clamp(0.2, 20.0);
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
