import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compute/bi_combine_compute.dart';
import '../compute/bi_virtual_bar_view_compute.dart';
import '../compute/chart_view_compute.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/bi_virtual_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_frame.dart';
import '../models/bar_feature_lookup.dart';
import '../models/level_models.dart';
import '../models/seg_analysis.dart';
import 'chart_level_line_style.dart';
import 'kline_axis_format.dart';
import 'kline_viewport.dart';
import 'main_indicator_picker.dart';
import 'sub_indicator_picker.dart';

/// 主图同级别连线配色（笔 + 各 N 段见 [ChartLevelLineStyle]）。
abstract final class ChartLineColors {
  /// 全部笔统一色
  static const bi = Color(0xCC94A3B8);
  /// 2 段（线段）默认色（与 ChartLevelLineStyle level=2 一致）
  static const seg = Color(0xCCF59E0B);
}

/// K 线图：主图 + 副图（可多指标叠加），支持高度分割拖动。
class KlineChart extends StatefulWidget {
  const KlineChart({
    super.key,
    required this.bars,
    required this.combineFrames,
    required this.biConfirmSignals,
    required this.barFeatures,
    required this.biSegments,
    required this.biVirtualBarViews,
    required this.biCombineFrames,
    required this.segAnalysis,
    required this.mainIndicators,
    required this.subIndicators,
    this.levels = const [],
    this.defaultBiPolicy = 'pending',
    this.onMainIndicatorsChanged,
    this.onSubIndicatorsChanged,
    this.autoFollowLatest = false,
  });

  final List<KlineBar> bars;
  final List<KlineCombineFrame> combineFrames;
  final List<BiConfirmSignal> biConfirmSignals;
  final List<BarCrosshairFeature> barFeatures;
  final List<BiSegment> biSegments;
  final List<BiVirtualBarView> biVirtualBarViews;
  final List<KlineCombineFrame> biCombineFrames;
  final SegAnalysisBundle segAnalysis;

  /// N 段流水线全量输出（十字线 as-of 重绘与 tooltip N 段块查表用）
  final List<LevelBundle> levels;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final String defaultBiPolicy;
  final ValueChanged<Set<MainChartIndicator>>? onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>>? onSubIndicatorsChanged;
  final bool autoFollowLatest;

  @override
  State<KlineChart> createState() => _KlineChartState();
}

class _KlineChartState extends State<KlineChart> {
  final _viewport = KlineViewport();
  bool _crosshairEnabled = false;
  double? _crosshairX;
  double? _crosshairY;
  int? _crosshairBarIdx;
  bool _panning = false;
  Offset? _panStart;
  double _panStartYShift = 0;
  double _panStartViewMin = 0;
  double _panStartViewMax = 0;
  Size _chartSize = Size.zero;

  /// 主图占「主+副」区域比例，可拖动分割线调整。
  double _mainFraction = 0.79;
  static const _minMainFraction = 0.22;
  static const _maxMainFraction = 0.92;
  bool _splitDragging = false;
  double _splitDragStartY = 0;
  double _splitDragStartFraction = 0.79;
  double _chartBodyH = 1;

  Set<SubChartIndicator> get _activeSubs {
    if (widget.subIndicators.isEmpty) {
      return {SubChartIndicator.biConfirm};
    }
    return widget.subIndicators;
  }

  Set<MainChartIndicator> get _activeMains {
    if (widget.mainIndicators.isEmpty) {
      return {
        MainChartIndicator.kline,
        MainChartIndicator.biLine,
        MainChartIndicator.segLine,
      };
    }
    return widget.mainIndicators;
  }

  String get _subLabel =>
      _activeSubs.map((e) => e.label).join(' + ');

  String get _mainLabel =>
      _activeMains.map((e) => e.label).join(' + ');

  @override
  void initState() {
    super.initState();
    _resetViewport();
  }

  @override
  void didUpdateWidget(covariant KlineChart oldWidget) {
    super.didUpdateWidget(oldWidget);
    final lenChanged = oldWidget.bars.length != widget.bars.length;
    final seriesChanged = widget.bars.isEmpty ||
        oldWidget.bars.isEmpty ||
        oldWidget.bars.first.timeMs != widget.bars.first.timeMs;

    if (widget.bars.isEmpty) {
      _resetViewport();
    } else if (seriesChanged) {
      _resetViewport();
    } else if (lenChanged) {
      _viewport.allXMax = math.max(0, widget.bars.length - 1).toDouble();
      if (widget.autoFollowLatest) {
        _viewport.syncWindowOnStep(widget.bars.length - 1);
      }
    }

    if (lenChanged || seriesChanged) {
      _crosshairX = null;
      _crosshairY = null;
      _crosshairBarIdx = null;
    }
  }

  /// 十字线跟随鼠标：竖线吸附 K 线中心，横线跟价格。
  void _updateCrosshairAt(Offset pos, double plotTop, double contentBottom) {
    if (!_crosshairEnabled || widget.bars.isEmpty || _chartSize.width <= 0) return;

    final barIdx = _viewport.barIndexAtCanvasX(
      pos.dx,
      _chartSize.width,
      widget.bars.length,
    );
    _crosshairBarIdx = barIdx;
    _crosshairX = _viewport.barCenterX(barIdx, _chartSize.width);
    _crosshairY = pos.dy.clamp(plotTop, contentBottom);
    _scheduleRedraw();
  }

  /// 十字线开启时按当步 K 重建笔 K view，与 bar_features 逐步冻结口径对齐。
  List<BiVirtualBarView> get _effectiveBiVirtualBarViews {
    if (!_crosshairEnabled || _crosshairBarIdx == null) {
      return widget.biVirtualBarViews;
    }
    final asOfBars = _asOfBiVirtualBars();
    return buildBiVirtualBarViews(asOfBars);
  }

  /// 十字线开启时按当步笔 K 重建笔K线合并框（与 bi_combine 逐步口径对齐）。
  List<KlineCombineFrame> get _effectiveBiCombineFrames {
    if (!_crosshairEnabled || _crosshairBarIdx == null) {
      return widget.biCombineFrames;
    }
    final asOf = _crosshairAsOfIdx();
    final barsSlice = widget.bars.where((b) => b.idx <= asOf).toList();
    if (barsSlice.isEmpty) return const [];
    return computeBiCombineFrames(barsSlice, _asOfBiVirtualBars());
  }

  int _crosshairAsOfIdx() =>
      widget.bars[_crosshairBarIdx!.clamp(0, widget.bars.length - 1)].idx;

  /// K2+ 分层统计（状态栏；旧称「n段K线」）
  String get _levelSegHint {
    if (widget.levels.length < 2) {
      return 'K2 ${widget.segAnalysis.segLines.length}';
    }
    final parts = <String>[];
    for (final b in widget.levels) {
      if (b.level < 2) continue;
      if (b.segments.isEmpty && b.confirms.isEmpty) continue;
      parts.add(
        'K${b.level} ${b.segments.length}',
      );
    }
    if (parts.isEmpty) return 'K2 0';
    return parts.join('  ');
  }

  /// as-of 笔 K 重建：Rust 冻结段 + 当步快照查表组装，Dart 端零缠论计算。
  List<BiVirtualBar> _asOfBiVirtualBars() {
    return asOfBiVirtualBars(
      bars: widget.bars,
      levels: widget.levels,
      barFeatures: widget.barFeatures,
      defaultBiPolicy: widget.defaultBiPolicy,
      asOf: _crosshairAsOfIdx(),
    );
  }

  void _resetViewport() {
    _viewport.resetForBarCount(widget.bars.length);
  }

  void _scheduleRedraw() {
    if (mounted) setState(() {});
  }

  void _onWheel(PointerScrollEvent e, double mainPlotH) {
    if (widget.bars.isEmpty || !_viewport.ready || _chartSize.width <= 0) return;

    final ctrl = HardwareKeyboard.instance.isControlPressed ||
        HardwareKeyboard.instance.isMetaPressed;
    if (ctrl) {
      _viewport.markUserAdjusted();
      _viewport.zoomY(e.scrollDelta.dy < 0);
    } else {
      _viewport.markUserAdjusted();
      final factor = e.scrollDelta.dy > 0 ? 1 / KlineViewport.zoomFactor : KlineViewport.zoomFactor;
      _viewport.zoomXAt(factor, e.localPosition.dx, _chartSize.width);
    }
    _scheduleRedraw();
  }

  void _onPointerDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton || widget.bars.isEmpty) return;
    if (_splitDragging) return;
    _panning = true;
    _panStart = e.localPosition;
    _panStartViewMin = _viewport.viewXMin;
    _panStartViewMax = _viewport.viewXMax;
    _panStartYShift = _viewport.yShiftRatio;
  }

  void _onPointerMove(PointerMoveEvent e, double mainPlotH, double contentBottom) {
    if (_splitDragging) {
      _onSplitMove(e);
      return;
    }
    if (_panning && _panStart != null) {
      final dx = e.localPosition.dx - _panStart!.dx;
      final dy = e.localPosition.dy - _panStart!.dy;
      _viewport.viewXMin = _panStartViewMin;
      _viewport.viewXMax = _panStartViewMax;
      _viewport.yShiftRatio = _panStartYShift;
      _viewport.markUserAdjusted();
      _viewport.panByPixels(dx, dy, _chartSize.width, mainPlotH);
      _scheduleRedraw();
      return;
    }

    if (_crosshairEnabled) {
      _updateCrosshairAt(
        e.localPosition,
        KlineViewport.padT,
        contentBottom,
      );
    }
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_splitDragging) {
      _onSplitUp(e);
      return;
    }
    _panning = false;
    _panStart = null;
  }

  void _onPointerLeave() {
    _panning = false;
    _panStart = null;
    if (!_crosshairEnabled) {
      _crosshairX = null;
      _crosshairY = null;
      _crosshairBarIdx = null;
      _scheduleRedraw();
    }
  }

  void _onDoubleTap(TapDownDetails d, double plotTop, double contentBottom) {
    if (widget.bars.isEmpty) return;
    setState(() {
      _crosshairEnabled = !_crosshairEnabled;
      if (_crosshairEnabled) {
        _updateCrosshairAt(d.localPosition, plotTop, contentBottom);
      } else {
        _crosshairX = null;
        _crosshairY = null;
        _crosshairBarIdx = null;
      }
    });
  }

  void _onSplitDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryMouseButton) return;
    _splitDragging = true;
    _splitDragStartY = e.localPosition.dy;
    _splitDragStartFraction = _mainFraction;
    _panning = false;
    _panStart = null;
  }

  void _onSplitMove(PointerMoveEvent e) {
    if (!_splitDragging || _chartBodyH <= 0) return;
    final delta = e.localPosition.dy - _splitDragStartY;
    final next = (_splitDragStartFraction * _chartBodyH + delta) / _chartBodyH;
    setState(() {
      _mainFraction = next.clamp(_minMainFraction, _maxMainFraction);
    });
  }

  void _onSplitUp(PointerUpEvent e) {
    _splitDragging = false;
  }

  Future<void> _pickMainIndicators(BuildContext context) async {
    final picked = await showMainIndicatorPicker(
      context: context,
      selected: _activeMains,
    );
    if (picked != null && picked.isNotEmpty) {
      widget.onMainIndicatorsChanged?.call(picked);
    }
  }

  Future<void> _pickSubIndicators(BuildContext context) async {
    final picked = await showSubIndicatorPicker(
      context: context,
      selected: _activeSubs,
    );
    if (picked != null && picked.isNotEmpty) {
      widget.onSubIndicatorsChanged?.call(picked);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.bars.isEmpty) {
      return const Center(child: Text('暂无 K 线（请加载后逐K播放）'));
    }

    return LayoutBuilder(
      builder: (context, constraints) {
        final w = constraints.maxWidth;
        final h = constraints.maxHeight;
        final hintH = math.max(22.0, h * 0.06);
        _chartBodyH = math.max(1.0, h - hintH);
        final mainH = _chartBodyH * _mainFraction;
        final volH = _chartBodyH - mainH;
        final xAxisTop = mainH + volH - KlineViewport.xAxisH;
        final contentBottom = xAxisTop;
        _chartSize = Size(w, mainH + volH);

        final visible = _viewport.visibleBars(widget.bars);
        final priceRange = _viewport.priceRangeFor(visible);

        final cursor = _crosshairEnabled
            ? SystemMouseCursors.precise
            : (_panning ? SystemMouseCursors.grabbing : SystemMouseCursors.grab);
        final plotTop = KlineViewport.padT;

        return Column(
          children: [
            Expanded(
              child: Stack(
                clipBehavior: Clip.none,
                children: [
                  CustomPaint(
                    size: Size(w, mainH + volH),
                    painter: _KlineCompositePainter(
                      bars: widget.bars,
                      combineFrames: widget.combineFrames,
                      biConfirmSignals: widget.biConfirmSignals,
                      barFeatures: widget.barFeatures,
                      biSegments: widget.biSegments,
                      biVirtualBarViews: _effectiveBiVirtualBarViews,
                      biCombineFrames: _effectiveBiCombineFrames,
                      segAnalysis: widget.segAnalysis,
                      levels: widget.levels,
                      mainIndicators: _activeMains,
                      subIndicators: _activeSubs,
                      viewport: _viewport,
                      priceRange: priceRange,
                      visible: visible,
                      mainH: mainH,
                      volH: volH,
                      crosshairEnabled: _crosshairEnabled,
                      crosshairX: _crosshairX,
                      crosshairY: _crosshairY,
                      crosshairBarIdx: _crosshairBarIdx,
                      segAsOf: _crosshairEnabled && _crosshairBarIdx != null
                          ? _crosshairAsOfIdx()
                          : null,
                    ),
                  ),
                  Positioned(
                    left: KlineViewport.padL,
                    right: KlineViewport.padR,
                    top: mainH - 4,
                    height: 8,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: Listener(
                        behavior: HitTestBehavior.translucent,
                        onPointerDown: _onSplitDown,
                        onPointerMove: _onSplitMove,
                        onPointerUp: _onSplitUp,
                        child: Center(
                          child: Container(
                            height: _splitDragging ? 3 : 2,
                            decoration: BoxDecoration(
                              color: _splitDragging
                                  ? const Color(0xAA42A5F5)
                                  : const Color(0x55FFFFFF),
                              borderRadius: BorderRadius.circular(2),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned.fill(
                    child: MouseRegion(
                      cursor: cursor,
                      onExit: (_) => _onPointerLeave(),
                      onHover: (e) {
                        if (!_panning) {
                          _updateCrosshairAt(e.localPosition, plotTop, contentBottom);
                        }
                      },
                      child: Listener(
                        behavior: HitTestBehavior.opaque,
                        onPointerSignal: (e) {
                          if (e is PointerScrollEvent) {
                            _onWheel(
                              e,
                              mainH - KlineViewport.padT - KlineViewport.padB,
                            );
                          }
                        },
                        onPointerDown: _onPointerDown,
                        onPointerMove: (e) => _onPointerMove(
                          e,
                          mainH - KlineViewport.padT - KlineViewport.padB,
                          contentBottom,
                        ),
                        onPointerUp: _onPointerUp,
                        child: GestureDetector(
                          behavior: HitTestBehavior.opaque,
                          onDoubleTapDown: (d) => _onDoubleTap(d, plotTop, contentBottom),
                          child: const SizedBox.expand(),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: KlineViewport.padL,
                    top: 2,
                    child: Material(
                      color: const Color(0xCC1A1A1A),
                      borderRadius: BorderRadius.circular(4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => _pickMainIndicators(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Text(
                            '主图指标选择',
                            style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                  ),
                  Positioned(
                    left: KlineViewport.padL,
                    top: mainH + 2,
                    child: Material(
                      color: const Color(0xCC1A1A1A),
                      borderRadius: BorderRadius.circular(4),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(4),
                        onTap: () => _pickSubIndicators(context),
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                          child: Text(
                            '副图指标选择',
                            style: const TextStyle(color: Color(0xFFE2E8F0), fontSize: 11),
                          ),
                        ),
                      ),
                    ),
                  ),
                ],
              ),
            ),
            SizedBox(
              height: hintH,
              child: Center(
                child: Text(
                  '主图: $_mainLabel  |  副图: $_subLabel  |  K1 ${widget.biVirtualBarViews.length}  K1合并 ${widget.biCombineFrames.length}  $_levelSegHint  |  双击十字线  |  ${widget.bars.length}根',
                  style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
                  textAlign: TextAlign.center,
                ),
              ),
            ),
          ],
        );
      },
    );
  }
}

class _KlineCompositePainter extends CustomPainter {
  _KlineCompositePainter({
    required this.bars,
    required this.combineFrames,
    required this.biConfirmSignals,
    required this.barFeatures,
    required this.biSegments,
    required this.biVirtualBarViews,
    required this.biCombineFrames,
    required this.segAnalysis,
    required this.levels,
    required this.mainIndicators,
    required this.subIndicators,
    required this.viewport,
    required this.priceRange,
    required this.visible,
    required this.mainH,
    required this.volH,
    required this.crosshairEnabled,
    required this.crosshairX,
    required this.crosshairY,
    required this.crosshairBarIdx,
    this.segAsOf,
  }) : featureLookup = BarFeatureLookup.build(
          bars: bars,
          combineFrames: combineFrames,
          biConfirms: biConfirmSignals,
          barFeatures: barFeatures,
          biSegments: biSegments,
          segAnalysis: segAnalysis,
          levels: levels,
          subIndicators: subIndicators,
        );

  final List<KlineBar> bars;
  final List<KlineCombineFrame> combineFrames;
  final List<BiConfirmSignal> biConfirmSignals;
  final List<BarCrosshairFeature> barFeatures;
  final List<BiSegment> biSegments;
  final List<BiVirtualBarView> biVirtualBarViews;
  final List<KlineCombineFrame> biCombineFrames;
  final SegAnalysisBundle segAnalysis;
  final List<LevelBundle> levels;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final BarFeatureLookup featureLookup;
  final KlineViewport viewport;
  final PriceRange priceRange;
  final List<KlineBar> visible;
  final double mainH;
  final double volH;
  final bool crosshairEnabled;
  final double? crosshairX;
  final double? crosshairY;
  final int? crosshairBarIdx;
  /// 十字线 as-of 2 段连线截止 K（null=末态全量）
  final int? segAsOf;

  @override
  void paint(Canvas canvas, Size size) {
    final plotTop = KlineViewport.padT;
    final plotBottom = mainH - KlineViewport.padB;
    final plotH = math.max(1.0, plotBottom - plotTop);
    final plotW = math.max(1.0, size.width - KlineViewport.padL - KlineViewport.padR);
    final span = math.max(viewport.xSpan, 1e-6);
    final slotW = plotW / span;
    final barW = _candleBodyW(slotW);
    final xAxisTop = contentBottom;

    _drawGrid(canvas, size.width, plotTop, plotBottom);
    if (mainIndicators.contains(MainChartIndicator.kline)) {
      _drawCandles(canvas, size.width, plotTop, plotH, barW, slotW);
    }
    if (mainIndicators.contains(MainChartIndicator.klineCombine)) {
      _drawCombineFramesOnMainChart(
        canvas,
        size.width,
        plotTop,
        plotH,
        barW,
        slotW,
        combineFrames,
        const Color(0xFF6366F1),
        const Color(0x226366F1),
      );
    }
    if (mainIndicators.contains(MainChartIndicator.biKlineCombine)) {
      _drawBiCombineOnMainChart(canvas, size.width, plotTop, plotH, barW, slotW);
    }
    if (mainIndicators.contains(MainChartIndicator.biLine)) {
      _drawBiSegments(canvas, size.width, plotTop, plotH, slotW);
    }
    if (mainIndicators.contains(MainChartIndicator.segLine)) {
      _drawSegLines(canvas, size.width, plotTop, plotH, slotW);
    }
    _drawSubCharts(canvas, size.width, mainH, barW, slotW);

    _drawYLabels(canvas, size.width, plotTop, plotH, priceRange);
    _drawXAxis(canvas, size.width, xAxisTop);

    if (crosshairEnabled && crosshairX != null && crosshairY != null) {
      _drawCrosshair(canvas, size, contentBottom, plotTop, priceRange);
    }
  }

  double get contentBottom => mainH + volH - KlineViewport.xAxisH;

  /// 主图蜡烛实体宽（与 _drawCandles 一致）。
  double _candleBodyW(double slotW) => math.max(1.0, slotW * 0.65);

  /// 合并线框横向：以 x1/x2 对应 K 线中轴为起止基准（非实体左右边）。
  (double left, double right) _combineFrameHSpan(
    int x1,
    int x2,
    double w,
    double slotW,
    double barW,
  ) {
    final cx1 = _barCenterX(x1, w, slotW);
    final cx2 = _barCenterX(x2, w, slotW);
    var left = math.min(cx1, cx2);
    var right = math.max(cx1, cx2);
    if (right - left < barW) {
      final mid = (left + right) / 2;
      left = mid - barW / 2;
      right = mid + barW / 2;
    }
    return (left, right);
  }

  /// 线框横向：合并 K 中轴口径 + 笔合并框半侧锚定（与笔 K [_biVirtualBarHSpan] 同逻辑）。
  (double left, double right) _combineFrameSpan(
    KlineCombineFrame f,
    double w,
    double slotW,
    double barW,
  ) {
    var (left, right) = _combineFrameHSpan(f.x1, f.x2, w, slotW, barW);
    if (f.endAtLeftHalf) {
      final junctionRight = _barCenterX(f.x2, w, slotW);
      right = math.min(right, junctionRight);
    }
    if (f.startAtRightHalf) {
      final junctionLeft = _barCenterX(f.x1, w, slotW);
      left = math.max(left, junctionLeft);
    }
    if (f.endAtLeftHalf || f.startAtRightHalf) {
      if (right - left < 2.0) {
        final mid = (left + right) / 2;
        left = mid - 1.0;
        right = mid + 1.0;
      }
    }
    return (left, right);
  }

  /// 笔 K 横向：衔接 K 左/右半侧锚定，避免相邻笔在中轴处留空。
  (double left, double right) _biVirtualBarHSpan(
    BiVirtualBarView v,
    double w,
    double slotW,
    double barW,
  ) {
    var (left, right) = _combineFrameHSpan(v.viewX1, v.viewX2, w, slotW, barW);
    if (v.endAtLeftHalf) {
      final junctionRight = _barCenterX(v.viewX2, w, slotW);
      right = math.min(right, junctionRight);
    }
    if (v.startAtRightHalf) {
      final junctionLeft = _barCenterX(v.viewX1, w, slotW);
      left = math.max(left, junctionLeft);
    }
    if (right - left < 2.0) {
      final mid = (left + right) / 2;
      left = mid - 1.0;
      right = mid + 1.0;
    }
    return (left, right);
  }

  /// 按 frame.x1 + count 精确取合并框内含的笔 K view（避免衔接 K 误入下一框）。
  List<BiVirtualBarView> _biViewsForCombineFrame(KlineCombineFrame f) {
    final startIdx = biVirtualBarViews.indexWhere((v) => v.viewX1 == f.x1);
    if (startIdx >= 0 && f.count > 0) {
      final endIdx = math.min(startIdx + f.count, biVirtualBarViews.length);
      if (endIdx > startIdx) {
        return biVirtualBarViews.sublist(startIdx, endIdx);
      }
    }
    return biVirtualBarViews
        .where((v) => v.viewX1 >= f.x1 && v.viewX2 <= f.x2)
        .toList();
  }

  /// 合并笔外线框横向：与 [_combineFrameSpan] 同构——单元换笔 K view，首尾 view 中轴起止。
  /// count>1：纯中轴（同合并 K 对 1 分钟 K）；count==1：半侧与 [_biVirtualBarHSpan] 一致。
  (double left, double right) _biCombineFrameSpan(
    KlineCombineFrame f,
    double w,
    double slotW,
    double barW,
  ) {
    final related = _biViewsForCombineFrame(f);
    if (related.isEmpty) {
      return _combineFrameSpan(f, w, slotW, barW);
    }
    final first = related.first;
    final last = related.last;
    var (left, right) = _combineFrameHSpan(
      first.viewX1,
      last.viewX2,
      w,
      slotW,
      barW,
    );
    if (f.count <= 1) {
      final v = first;
      if (v.endAtLeftHalf) {
        right = math.min(right, _barCenterX(v.viewX2, w, slotW));
      }
      if (v.startAtRightHalf) {
        left = math.max(left, _barCenterX(v.viewX1, w, slotW));
      }
      if (v.endAtLeftHalf || v.startAtRightHalf) {
        if (right - left < 2.0) {
          final mid = (left + right) / 2;
          left = mid - 1.0;
          right = mid + 1.0;
        }
      }
    }
    return (left, right);
  }

  double _barCenterX(int barIdx, double w, double slotW) =>
      viewport.indexToX(barIdx.toDouble(), w) + slotW / 2;

  void _drawGrid(Canvas canvas, double w, double top, double bottom) {
    final grid = Paint()
      ..color = const Color(0x22FFFFFF)
      ..strokeWidth = 1;
    for (var i = 0; i <= 4; i++) {
      final y = top + (bottom - top) * i / 4;
      canvas.drawLine(Offset(KlineViewport.padL, y), Offset(w - KlineViewport.padR, y), grid);
    }
    final border = Paint()
      ..color = const Color(0x44FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(Offset(KlineViewport.padL, top), Offset(KlineViewport.padL, bottom), border);
    canvas.drawLine(Offset(w - KlineViewport.padR, top), Offset(w - KlineViewport.padR, contentBottom), border);
  }

  /// 笔 K 线（展示层 view 区间）：横向 [_biVirtualBarHSpan]，与合并笔框 [_biCombineFrameSpan] 同口径。
  void _drawBiVirtualCandles(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW, {
    bool faint = false,
  }) {
    if (biVirtualBarViews.isEmpty) return;

    // faint：主图笔K线合并底层，低不透明度以免压住 1 分钟 K
    final upBody = faint ? const Color(0x38E53935) : const Color(0x88E53935);
    final dnBody = faint ? const Color(0x3826A69A) : const Color(0x8826A69A);
    final upStroke = faint ? const Color(0x55E53935) : const Color(0xFFE53935);
    final dnStroke = faint ? const Color(0x5526A69A) : const Color(0xFF26A69A);

    for (final v in biVirtualBarViews) {
      if (v.viewX2 < viewport.viewXMin - 1 || v.viewX1 > viewport.viewXMax + 1) {
        continue;
      }

      final (left, right) = _biVirtualBarHSpan(v, w, slotW, barW);
      final cx = (left + right) / 2;
      final spanW = math.max(2.0, right - left);
      final isUp = v.isUp;
      final stroke = Paint()
        ..color = isUp ? upStroke : dnStroke
        ..strokeWidth = 1.6;
      final fill = Paint()..color = isUp ? upBody : dnBody;

      final yH = priceRange.yOf(v.high, plotTop, plotH);
      final yL = priceRange.yOf(v.low, plotTop, plotH);
      final yO = priceRange.yOf(v.open, plotTop, plotH);
      final yC = priceRange.yOf(v.close, plotTop, plotH);

      canvas.drawLine(Offset(cx, yH), Offset(cx, yL), stroke);

      final top = math.min(yO, yC);
      final bottom = math.max(yO, yC);
      final rect = Rect.fromLTWH(left, top, spanW, math.max(1.0, bottom - top));
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, stroke);
    }
  }

  void _drawBiSegments(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
  ) {
    if (biSegments.isEmpty && biConfirmSignals.isEmpty) return;

    final paint = Paint()
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    for (final seg in biSegments) {
      final xMin = [
        seg.beginFractalX1,
        seg.beginFractalX2,
        seg.endFractalX1,
        seg.endFractalX2,
      ].reduce(math.min);
      final xMax = [
        seg.beginFractalX1,
        seg.beginFractalX2,
        seg.endFractalX1,
        seg.endFractalX2,
      ].reduce(math.max);
      if (xMax < viewport.viewXMin - 1 || xMin > viewport.viewXMax + 1) {
        continue;
      }
      final (beginX, beginPrice) =
          _biSegmentEndpoint(seg, isBegin: true, w: w, slotW: slotW);
      final (endX, endPrice) =
          _biSegmentEndpoint(seg, isBegin: false, w: w, slotW: slotW);
      final y1 = priceRange.yOf(beginPrice, plotTop, plotH);
      final y2 = priceRange.yOf(endPrice, plotTop, plotH);
      paint.color = seg.isBootstrap
          ? ChartLineColors.bi.withValues(alpha: 0.55)
          : ChartLineColors.bi;
      canvas.drawLine(Offset(beginX, y1), Offset(endX, y2), paint);
    }

    _drawBuildingBiLine(canvas, w, plotTop, plotH, slotW);
  }

  /// 笔段端点：引导笔起点走分型框极值；其余严格匹配笔确认信号。
  (double, double) _biSegmentEndpoint(
    BiSegment seg, {
    required bool isBegin,
    required double w,
    required double slotW,
  }) {
    final fx1 = isBegin ? seg.beginFractalX1 : seg.endFractalX1;
    final fx2 = isBegin ? seg.beginFractalX2 : seg.endFractalX2;
    final wantHigh = isBegin ? seg.dir < 0 : seg.dir > 0;

    if (isBegin && seg.isBootstrap) {
      return _fractalBoxExtremeAnchor(fx1, fx2, wantHigh, w, slotW);
    }

    final confirmX = isBegin ? seg.beginConfirmX : seg.endConfirmX;
    final conf = _biConfirmAt(confirmX, fx1, fx2);
    if (conf != null) {
      return _biExtremeAnchorPoint(
        conf,
        fx1,
        fx2,
        w,
        slotW,
        fallbackWantHigh: wantHigh,
      );
    }
    return _fractalBoxExtremeAnchor(fx1, fx2, wantHigh, w, slotW);
  }

  /// 分型框内极点 K 锚点（无笔确认信号时用，如引导笔虚拟起点）。
  (double, double) _fractalBoxExtremeAnchor(
    int fractalX1,
    int fractalX2,
    bool wantHigh,
    double w,
    double slotW,
  ) {
    final lo = fractalX1 < fractalX2 ? fractalX1 : fractalX2;
    final hi = fractalX1 > fractalX2 ? fractalX1 : fractalX2;
    if (lo < 0 || hi >= bars.length || lo > hi) {
      return (
        _fractalCenterX(fractalX1, fractalX2, w, slotW),
        _combineFramePriceAt(fractalX1, wantHigh),
      );
    }
    var extremeIdx = lo;
    if (wantHigh) {
      var peak = double.negativeInfinity;
      for (var j = lo; j <= hi; j++) {
        if (bars[j].high > peak) {
          peak = bars[j].high;
          extremeIdx = j;
        }
      }
      return (_barCenterX(extremeIdx, w, slotW), bars[extremeIdx].high);
    }
    var trough = double.infinity;
    for (var j = lo; j <= hi; j++) {
      if (bars[j].low < trough) {
        trough = bars[j].low;
        extremeIdx = j;
      }
    }
    return (_barCenterX(extremeIdx, w, slotW), bars[extremeIdx].low);
  }

  /// 按确认步 + 分型框严格匹配笔确认信号（禁止仅按 x 退化匹配，避免引导笔起终点重合）。
  BiConfirmSignal? _biConfirmAt(int confirmX, int fractalX1, int fractalX2) {
    for (final c in biConfirmSignals) {
      if (c.x == confirmX &&
          c.fractalX1 == fractalX1 &&
          c.fractalX2 == fractalX2) {
        return c;
      }
    }
    return null;
  }

  /// 笔连线端点：极点 K 中轴 + 极点价（与 K线分型极点距同口径，仅展示用）。
  (double, double) _biExtremeAnchorPoint(
    BiConfirmSignal? conf,
    int fractalX1,
    int fractalX2,
    double w,
    double slotW, {
    required bool fallbackWantHigh,
  }) {
    if (conf != null) {
      final extremeIdx = fractalExtremeBarIdx(bars, conf);
      if (extremeIdx != null &&
          extremeIdx >= 0 &&
          extremeIdx < bars.length) {
        final bar = bars[extremeIdx];
        final price = conf.fx == 'TOP' ? bar.high : bar.low;
        return (_barCenterX(extremeIdx, w, slotW), price);
      }
    }
    final cx = _fractalCenterX(fractalX1, fractalX2, w, slotW);
    final price = _combineFramePriceAt(fractalX1, fallbackWantHigh);
    return (cx, price);
  }

  double _combineFramePriceAt(int x, bool wantHigh) {
    for (final f in combineFrames) {
      if (x >= f.x1 && x <= f.x2) {
        return wantHigh ? f.high : f.low;
      }
    }
    if (x >= 0 && x < bars.length) {
      return wantHigh ? bars[x].high : bars[x].low;
    }
    return 0;
  }

  /// N≥2 段主图连线：各层独立色/线型/粗细；已冻结 + 构建中虚线。
  void _drawSegLines(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
  ) {
    final tailIdx = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);

    if (levels.length >= 2) {
      // 低层先画、高层后画，避免粗线被遮挡
      final bundles = levels.where((b) => b.level >= 2).toList()
        ..sort((a, b) => a.level.compareTo(b.level));
      for (final bundle in bundles) {
        _drawOneLevelLines(
          canvas,
          w,
          plotTop,
          plotH,
          slotW,
          bundle: bundle,
          tailIdx: tailIdx,
        );
      }
    } else {
      final style = ChartLevelLineStyle.forLevel(2);
      final paint = Paint()
        ..color = style.color
        ..strokeWidth = style.strokeWidth
        ..style = PaintingStyle.stroke;
      for (final seg in segAnalysis.segLines) {
        final beginIdx = seg.beginX;
        final endIdx = seg.endX;
        if (endIdx < viewport.viewXMin - 1 || beginIdx > viewport.viewXMax + 1) {
          continue;
        }
        final beginFx = seg.dir < 0 ? 'TOP' : 'BOTTOM';
        final endFx = seg.dir > 0 ? 'TOP' : 'BOTTOM';
        final beginPrice = poleBarPrice(bars, beginIdx, beginFx);
        final endPrice = poleBarPrice(bars, endIdx, endFx);
        if (beginPrice == null || endPrice == null) continue;
        final a = Offset(_barCenterX(beginIdx, w, slotW), priceRange.yOf(beginPrice, plotTop, plotH));
        final b = Offset(_barCenterX(endIdx, w, slotW), priceRange.yOf(endPrice, plotTop, plotH));
        _drawStyledSegmentLine(canvas, a, b, paint, style, building: false);
      }
      if (tailIdx >= 0) {
        _drawBuildingLevelLine(
          canvas,
          w,
          plotTop,
          plotH,
          slotW,
          level: 2,
          style: style,
          tailIdx: tailIdx,
          confirms: const [],
          useLegacySegAnalysis: true,
        );
      }
    }
  }

  /// 单层 N 段（level≥2）已冻结段 + 构建中段。
  void _drawOneLevelLines(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required LevelBundle bundle,
    required int tailIdx,
  }) {
    final level = bundle.level;
    if (level < 2) return;
    final style = ChartLevelLineStyle.forLevel(level);
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final segments = segAsOf != null
        ? asOfLevelSegments(levels: levels, level: level, asOf: segAsOf!)
        : bundle.segments;

    for (final seg in segments) {
      final begin = levelSegmentEndpoint(
        bars: bars,
        seg: seg,
        confirms: bundle.confirms,
        isBegin: true,
      );
      final end = levelSegmentEndpoint(
        bars: bars,
        seg: seg,
        confirms: bundle.confirms,
        isBegin: false,
      );
      if (begin == null || end == null) continue;
      final xMin = math.min(begin.barIdx, end.barIdx);
      final xMax = math.max(begin.barIdx, end.barIdx);
      if (xMax < viewport.viewXMin - 1 || xMin > viewport.viewXMax + 1) {
        continue;
      }
      final a = Offset(
        _barCenterX(begin.barIdx, w, slotW),
        priceRange.yOf(begin.price, plotTop, plotH),
      );
      final b = Offset(
        _barCenterX(end.barIdx, w, slotW),
        priceRange.yOf(end.price, plotTop, plotH),
      );
      _drawStyledSegmentLine(canvas, a, b, paint, style, building: false);
    }

    if (tailIdx >= 0) {
      _drawBuildingLevelLine(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        level: level,
        style: style,
        tailIdx: tailIdx,
        confirms: bundle.confirms,
        useLegacySegAnalysis: false,
      );
    }
  }

  /// 按层级样式画线段（实线或 pattern 虚线）。
  void _drawStyledSegmentLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint,
    ChartLevelLineStyle style, {
    required bool building,
  }) {
    if (building) {
      final p = Paint()
        ..color = style.color.withValues(alpha: style.buildingAlpha)
        ..strokeWidth = style.buildingStrokeWidth
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      _drawPatternLine(canvas, a, b, p, style.buildingDashPattern);
      return;
    }
    if (style.frozenDashPattern == null) {
      canvas.drawLine(a, b, paint);
    } else {
      _drawPatternLine(canvas, a, b, paint, style.frozenDashPattern!);
    }
  }

  /// 构建中 N 段：末次确认极点 → as-of/末 K 方向极值。
  void _drawBuildingLevelLine(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required int level,
    required ChartLevelLineStyle style,
    required int tailIdx,
    required List<LevelConfirm> confirms,
    required bool useLegacySegAnalysis,
  }) {
    if (bars.isEmpty || tailIdx < 0 || tailIdx >= bars.length) return;

    final buildingDir = useLegacySegAnalysis
        ? segAnalysis.buildingSegDir
        : buildingLevelDirAt(
            levels: levels,
            barFeatures: barFeatures,
            level: level,
            asOf: tailIdx,
          );
    if (buildingDir == 0) return;

    LevelConfirm? lastConfirm;
    if (useLegacySegAnalysis) {
      final sc = segAnalysis.segConfirms
          .where((c) => c.x <= tailIdx && (c.fx == 'TOP' || c.fx == 'BOTTOM'))
          .toList();
      if (sc.isNotEmpty) {
        final c = sc.last;
        lastConfirm = LevelConfirm(
          x: c.x,
          fx: c.fx,
          value: c.value,
          fractalX1: c.fractalX1,
          fractalX2: c.fractalX2,
          fractalHigh: c.fractalHigh,
          fractalLow: c.fractalLow,
        );
      }
    } else {
      lastConfirm = lastLevelConfirmAt(confirms, tailIdx);
    }
    if (lastConfirm == null || lastConfirm.x > tailIdx) return;

    final begin = levelConfirmEndpoint(bars, lastConfirm);
    if (begin == null) return;

    final tail = bars[tailIdx];
    var endPrice = buildingDir > 0 ? tail.high : tail.low;
    for (final b in bars) {
      if (b.idx < lastConfirm.x || b.idx > tailIdx) continue;
      if (buildingDir > 0) {
        endPrice = math.max(endPrice, b.high);
      } else {
        endPrice = math.min(endPrice, b.low);
      }
    }

    final geomMin = math.min(begin.barIdx, tail.idx);
    final geomMax = math.max(begin.barIdx, tail.idx);
    if (geomMax < viewport.viewXMin - 1 || geomMin > viewport.viewXMax + 1) {
      return;
    }

    final a = Offset(
      _barCenterX(begin.barIdx, w, slotW),
      priceRange.yOf(begin.price, plotTop, plotH),
    );
    final b = Offset(
      _barCenterX(tail.idx, w, slotW),
      priceRange.yOf(endPrice, plotTop, plotH),
    );
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.buildingStrokeWidth
      ..style = PaintingStyle.stroke;
    _drawStyledSegmentLine(canvas, a, b, paint, style, building: true);
  }

  /// 构建中笔：末次笔确认分型极点 → 当前末根 K 方向极值（虚线，展示专用）。
  void _drawBuildingBiLine(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
  ) {
    if (bars.isEmpty || biConfirmSignals.isEmpty) return;

    BiConfirmSignal? last;
    for (final c in biConfirmSignals) {
      if (c.fx == 'TOP' || c.fx == 'BOTTOM') last = c;
    }
    if (last == null) return;

    final tail = bars.last;
    if (last.x > tail.idx) return;

    final buildingDir = last.fx == 'BOTTOM' ? 1 : -1;
    final extremeIdx = fractalExtremeBarIdx(bars, last);
    if (extremeIdx == null ||
        extremeIdx < 0 ||
        extremeIdx >= bars.length) {
      return;
    }

    final beginX = _barCenterX(extremeIdx, w, slotW);
    final beginBar = bars[extremeIdx];
    final beginPrice = last.fx == 'TOP' ? beginBar.high : beginBar.low;

    final endX = _barCenterX(tail.idx, w, slotW);
    var endPrice = buildingDir > 0 ? tail.high : tail.low;
    for (final b in bars) {
      if (b.idx <= last.x || b.idx > tail.idx) continue;
      if (buildingDir > 0) {
        endPrice = math.max(endPrice, b.high);
      } else {
        endPrice = math.min(endPrice, b.low);
      }
    }

    final geomMin = math.min(extremeIdx, tail.idx);
    final geomMax = math.max(extremeIdx, tail.idx);
    if (geomMax < viewport.viewXMin - 1 ||
        geomMin > viewport.viewXMax + 1) {
      return;
    }

    final y1 = priceRange.yOf(beginPrice, plotTop, plotH);
    final y2 = priceRange.yOf(endPrice, plotTop, plotH);
    final paint = Paint()
      ..color = ChartLineColors.bi.withValues(alpha: 0.45)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;

    _drawDashedLine(canvas, Offset(beginX, y1), Offset(endX, y2), paint);
  }

  double _fractalCenterX(int x1, int x2, double w, double slotW) {
    final cx1 = viewport.indexToX(x1.toDouble(), w) + slotW / 2;
    final cx2 = viewport.indexToX(x2.toDouble(), w) + slotW / 2;
    return (cx1 + cx2) / 2;
  }

  void _drawCandles(Canvas canvas, double w, double plotTop, double plotH, double barW, double slotW) {
    final up = const Color(0xFFE53935);
    final down = const Color(0xFF26A69A);
    final wick = Paint()..strokeWidth = 1.2;

    for (var i = 0; i < bars.length; i++) {
      final idx = bars[i].idx;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) continue;
      final b = bars[i];
      final cx = _barCenterX(idx, w, slotW);
      final x = cx - barW / 2;
      final color = b.isUp ? up : down;
      wick.color = color;

      final yH = priceRange.yOf(b.high, plotTop, plotH);
      final yL = priceRange.yOf(b.low, plotTop, plotH);
      final yO = priceRange.yOf(b.open, plotTop, plotH);
      final yC = priceRange.yOf(b.close, plotTop, plotH);
      canvas.drawLine(Offset(cx, yH), Offset(cx, yL), wick);

      final top = math.min(yO, yC);
      final bottom = math.max(yO, yC);
      canvas.drawRect(
        Rect.fromLTWH(x, top, barW, math.max(1.0, bottom - top)),
        Paint()..color = color,
      );
    }
  }

  /// 主图 K线合并 / 笔K线合并线框：按真实价格坐标叠加。
  void _drawCombineFramesOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
    List<KlineCombineFrame> frames,
    Color strokeColor,
    Color fillColor, {
    bool alignBiCombineWithViews = false,
  }) {
    if (frames.isEmpty) return;

    const minFramePx = 6.0;
    final framePaint = Paint()
      ..color = strokeColor
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;

    for (final f in frames) {
      if (f.x2 < viewport.viewXMin - 1 || f.x1 > viewport.viewXMax + 1) continue;

      final (xLeft, xRight) = alignBiCombineWithViews
          ? _biCombineFrameSpan(f, w, slotW, barW)
          : _combineFrameSpan(f, w, slotW, barW);
      var yTop = priceRange.yOf(f.high, plotTop, plotH);
      var yBottom = priceRange.yOf(f.low, plotTop, plotH);
      var height = (yBottom - yTop).abs();
      if (height < minFramePx) {
        final mid = (yTop + yBottom) / 2;
        yTop = mid - minFramePx / 2;
        yBottom = mid + minFramePx / 2;
        height = minFramePx;
      }
      final rect = Rect.fromLTRB(
        math.min(xLeft, xRight),
        math.min(yTop, yBottom),
        math.max(xLeft, xRight),
        math.max(yTop, yBottom),
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, framePaint);

      if (f.fx == 'TOP' || f.fx == 'BOTTOM') {
        final tp = TextPainter(
          text: TextSpan(
            text: f.fx == 'TOP' ? '顶' : '底',
            style: TextStyle(color: strokeColor, fontSize: 9),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(rect.left + 2, rect.top + 1));
      }
    }
  }

  /// 主图笔K线合并：先铺淡笔 K 底层，再描笔K线合并框。
  void _drawBiCombineOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
  ) {
    if (biCombineFrames.isEmpty && biVirtualBarViews.isEmpty) return;

    _drawBiVirtualCandles(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      faint: true,
    );

    if (biCombineFrames.isNotEmpty) {
      _drawCombineFramesOnMainChart(
        canvas,
        w,
        plotTop,
        plotH,
        barW,
        slotW,
        biCombineFrames,
        const Color(0xAAF59E0B),
        const Color(0x0CF59E0B),
        alignBiCombineWithViews: true,
      );
    }
  }

  void _drawSubCharts(
    Canvas canvas,
    double w,
    double volTop,
    double barW,
    double slotW,
  ) {
    _drawSubSeparator(canvas, w, volTop);

    final innerTop = volTop + 6;
    final innerBottom = contentBottom - 4;
    final innerH = math.max(12.0, innerBottom - innerTop);
    if (innerH <= 0) return;

    if (subIndicators.contains(SubChartIndicator.volume)) {
      _drawVolume(canvas, w, innerTop, innerBottom, innerH, barW, slotW);
    }
    if (subIndicators.contains(SubChartIndicator.klineCombine)) {
      _drawCombineFrameSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        combineFrames,
        const Color(0xFF6366F1),
        const Color(0x226366F1),
      );
    }
    if (subIndicators.contains(SubChartIndicator.biKlineCombine)) {
      _drawBiKlineCombineSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
      );
    }
    if (subIndicators.contains(SubChartIndicator.biConfirm)) {
      _drawBiConfirmSubChart(canvas, w, innerTop, innerH, barW, slotW);
    }
    if (subIndicators.contains(SubChartIndicator.segConfirm)) {
      _drawSegConfirmSubChart(canvas, w, innerTop, innerH, barW, slotW);
    }
    if (subIndicators.contains(SubChartIndicator.firstSegDir)) {
      _drawDirStepSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        (i) => segAnalysis.snapshotAt(bars[i].idx)?.firstSegDir ?? 0,
        const Color(0xFF8B5CF6),
      );
    }
    if (subIndicators.contains(SubChartIndicator.fractalPeakDist)) {
      _drawFractalPeakDistSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
      );
    }
  }

  void _drawVolume(
    Canvas canvas,
    double w,
    double innerTop,
    double innerBottom,
    double innerH,
    double barW,
    double slotW,
  ) {
    if (bars.isEmpty) return;
    var maxV = 1.0;
    for (final b in bars) {
      if (b.volume > maxV) maxV = b.volume;
    }
    for (var i = 0; i < bars.length; i++) {
      final idx = bars[i].idx;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) continue;
      final b = bars[i];
      final cx = _barCenterX(idx, w, slotW);
      final x = cx - barW / 2;
      final bh = b.volume / maxV * innerH;
      final color = b.isUp
          ? const Color(0x66E53935)
          : const Color(0x6626A69A);
      canvas.drawRect(Rect.fromLTWH(x, innerBottom - bh, barW, bh), Paint()..color = color);
    }
  }

  /// 笔K线合并副图：底层铺淡「笔 K 线」，再描笔K线合并框（与 K线合并副图同构：单元→合并框）。
  void _drawBiKlineCombineSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
  ) {
    if (biCombineFrames.isEmpty) return;

    final visibleFrames = biCombineFrames
        .where(
          (f) => f.x2 >= viewport.viewXMin - 1 && f.x1 <= viewport.viewXMax + 1,
        )
        .toList();
    if (visibleFrames.isEmpty) return;

    // 底层单元改为「笔 K 线」：与 K线合并副图「1 分钟 K → 合并框」严格同构
    final visibleBiBars = biVirtualBarViews
        .where(
          (v) =>
              v.viewX2 >= viewport.viewXMin - 1 &&
              v.viewX1 <= viewport.viewXMax + 1,
        )
        .toList();

    var minP = visibleFrames.first.low;
    var maxP = visibleFrames.first.high;
    for (final f in visibleFrames) {
      minP = math.min(minP, f.low);
      maxP = math.max(maxP, f.high);
    }
    // 刻度同时纳入笔 K 线，保证底层笔 K 落在副图纵轴内
    for (final v in visibleBiBars) {
      minP = math.min(minP, v.low);
      maxP = math.max(maxP, v.high);
    }
    var span = math.max(1e-9, maxP - minP);
    final pad = span * 0.18;
    minP -= pad;
    maxP += pad;
    span = math.max(1e-9, maxP - minP);

    double subY(double price) => innerTop + (maxP - price) / span * innerH;

    // 底层：笔 K 线（中轴口径，与合并框对齐）
    final wick = Paint()..strokeWidth = 1.0;
    for (final v in visibleBiBars) {
      final (left, right) = _biVirtualBarHSpan(v, w, slotW, barW);
      final cx = (left + right) / 2;
      final spanW = math.max(1.5, right - left);
      final color = v.isUp
          ? const Color(0x55E53935)
          : const Color(0x5526A69A);
      wick.color = color;
      final yH = subY(v.high);
      final yL = subY(v.low);
      final yO = subY(v.open);
      final yC = subY(v.close);
      canvas.drawLine(Offset(cx, yH), Offset(cx, yL), wick);
      final top = math.min(yO, yC);
      final bottom = math.max(yO, yC);
      canvas.drawRect(
        Rect.fromLTWH(left, top, spanW, math.max(1.0, bottom - top)),
        Paint()..color = color.withValues(alpha: 0.22),
      );
    }

    // 上层：笔K线合并框——仅描边为主，填充极淡（相邻框 x 区间交叠时不会叠成实心）
    const strokeColor = Color(0xAAF59E0B);
    const fillColor = Color(0x0CF59E0B);
    const minFramePx = 8.0;
    final framePaint = Paint()
      ..color = strokeColor
      ..strokeWidth = 1.3
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;

    for (final f in visibleFrames) {
      final (xLeft, xRight) = _biCombineFrameSpan(f, w, slotW, barW);
      var yTop = subY(f.high);
      var yBottom = subY(f.low);
      var height = (yBottom - yTop).abs();
      if (height < minFramePx) {
        final mid = (yTop + yBottom) / 2;
        yTop = mid - minFramePx / 2;
        yBottom = mid + minFramePx / 2;
        height = minFramePx;
      }
      final rect = Rect.fromLTRB(
        math.min(xLeft, xRight),
        math.min(yTop, yBottom),
        math.max(xLeft, xRight),
        math.max(yTop, yBottom),
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, framePaint);

      if (f.fx == 'TOP' || f.fx == 'BOTTOM') {
        final tp = TextPainter(
          text: TextSpan(
            text: f.fx == 'TOP' ? '顶' : '底',
            style: const TextStyle(color: strokeColor, fontSize: 9),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(rect.left + 2, rect.top + 1));
      }
    }
  }

  /// 合并线框副图（1 分钟 K 合并；笔 K 合并见 [_drawBiKlineCombineSubChart]）。
  void _drawCombineFrameSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    List<KlineCombineFrame> frames,
    Color strokeColor,
    Color fillColor,
  ) {
    if (frames.isEmpty) return;

    final visibleFrames = frames
        .where(
          (f) => f.x2 >= viewport.viewXMin - 1 && f.x1 <= viewport.viewXMax + 1,
        )
        .toList();
    if (visibleFrames.isEmpty) return;

    var minP = visibleFrames.first.low;
    var maxP = visibleFrames.first.high;
    for (final f in visibleFrames) {
      minP = math.min(minP, f.low);
      maxP = math.max(maxP, f.high);
    }
    var span = math.max(1e-9, maxP - minP);
    final pad = span * 0.18;
    minP -= pad;
    maxP += pad;
    span = math.max(1e-9, maxP - minP);

    const minFramePx = 8.0;
    final framePaint = Paint()
      ..color = strokeColor
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final fillPaint = Paint()
      ..color = fillColor
      ..style = PaintingStyle.fill;

    for (final f in visibleFrames) {
      final (xLeft, xRight) = _combineFrameSpan(f, w, slotW, barW);
      var yTop = innerTop + (maxP - f.high) / span * innerH;
      var yBottom = innerTop + (maxP - f.low) / span * innerH;
      var height = (yBottom - yTop).abs();
      if (height < minFramePx) {
        final mid = (yTop + yBottom) / 2;
        yTop = mid - minFramePx / 2;
        yBottom = mid + minFramePx / 2;
        height = minFramePx;
      }
      final rect = Rect.fromLTRB(
        math.min(xLeft, xRight),
        math.min(yTop, yBottom),
        math.max(xLeft, xRight),
        math.max(yTop, yBottom),
      );
      canvas.drawRect(rect, fillPaint);
      canvas.drawRect(rect, framePaint);

      if (f.fx == 'TOP' || f.fx == 'BOTTOM') {
        final tp = TextPainter(
          text: TextSpan(
            text: f.fx == 'TOP' ? '顶' : '底',
            style: TextStyle(color: strokeColor, fontSize: 9),
          ),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(rect.left + 2, rect.top + 1));
      }
    }
  }

  /// 副图 ±1 方向柱（K线合并分型确认 / 段确认共用）：0 轴 + 确认当步 K 索引处画柱。
  void _drawSignedConfirmBars(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW, {
    required Iterable<(int x, int value)> points,
  }) {
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;

    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final y0 = subY(0);

    final zeroLine = Paint()
      ..color = const Color(0x88FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(KlineViewport.padL, y0),
      Offset(w - KlineViewport.padR, y0),
      zeroLine,
    );

    final barWClamped = math.max(2.0, math.min(barW, 8.0));
    for (final (x, value) in points) {
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) continue;
      if (value == 0) continue;
      final cx = _barCenterX(x, w, slotW);
      final yp = subY(value.toDouble());
      final color = value > 0
          ? const Color(0xFFE53935)
          : const Color(0xFF26A69A);
      final top = math.min(yp, y0);
      final height = math.max(1.0, (yp - y0).abs());
      canvas.drawRect(
        Rect.fromLTWH(cx - barWClamped / 2, top, barWClamped, height),
        Paint()..color = color,
      );
    }
  }

  void _drawBiConfirmSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
  ) {
    _drawSignedConfirmBars(
      canvas,
      w,
      innerTop,
      innerH,
      barW,
      slotW,
      points: biConfirmSignals.map((s) => (s.x, s.value)),
    );
  }

  void _drawSegConfirmSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
  ) {
    if (segAnalysis.segConfirms.isEmpty) return;

    // 与 K线合并分型确认一致：展示全部已冻结段确认，仅按视窗裁剪（不用十字线二次截断）
    _drawSignedConfirmBars(
      canvas,
      w,
      innerTop,
      innerH,
      barW,
      slotW,
      points: segAnalysis.segConfirms
          .where(
            (s) =>
                (s.fx == 'TOP' || s.fx == 'BOTTOM') && s.value != 0,
          )
          .map((s) => (s.x, s.value)),
    );
  }

  /// 副图 K线分型极点距：折线 + 柱，0=首笔确认前。
  void _drawFractalPeakDistSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
  ) {
    if (bars.isEmpty || barFeatures.isEmpty) return;

    var maxV = 1.0;
    for (final f in barFeatures) {
      if (f.fractalPeakDist > maxV) maxV = f.fractalPeakDist.toDouble();
    }
    final span = math.max(1.0, maxV);
    double subY(double v) => innerTop + (span - v) / span * innerH;

    final zeroLine = Paint()
      ..color = const Color(0x55FFFFFF)
      ..strokeWidth = 1;
    final y0 = subY(0);
    canvas.drawLine(
      Offset(KlineViewport.padL, y0),
      Offset(w - KlineViewport.padR, y0),
      zeroLine,
    );

    const lineColor = Color(0xFF38BDF8);
    final linePaint = Paint()
      ..color = lineColor
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final barPaint = Paint()..color = lineColor.withValues(alpha: 0.45);
    final barWClamped = math.max(1.5, math.min(barW, 6.0));

    Offset? prev;
    for (var i = 0; i < bars.length; i++) {
      final idx = bars[i].idx;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) continue;
      final feat = _featureAt(idx);
      final dist = feat?.fractalPeakDist ?? 0;
      if (dist <= 0) {
        prev = null;
        continue;
      }
      final cx = _barCenterX(idx, w, slotW);
      final y = subY(dist.toDouble());
      final top = math.min(y, y0);
      final height = math.max(1.0, (y - y0).abs());
      canvas.drawRect(
        Rect.fromLTWH(cx - barWClamped / 2, top, barWClamped, height),
        barPaint,
      );
      final pt = Offset(cx, y);
      if (prev != null) {
        canvas.drawLine(prev, pt, linePaint);
      }
      prev = pt;
    }
  }

  void _drawDirStepSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int Function(int barIdx) dirAt,
    Color color,
  ) {
    if (bars.isEmpty) return;
    final yMid = innerTop + innerH / 2;
    final yUp = innerTop + innerH * 0.22;
    final yDn = innerTop + innerH * 0.78;
    final barWClamped = math.max(1.0, barW);
    final paint = Paint()..color = color.withValues(alpha: 0.85);

    for (var i = 0; i < bars.length; i++) {
      final idx = bars[i].idx;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) continue;
      final d = dirAt(i);
      if (d == 0) continue;
      final cx = _barCenterX(idx, w, slotW);
      if (d > 0) {
        canvas.drawRect(
          Rect.fromLTWH(cx - barWClamped / 2, yUp, barWClamped, math.max(2.0, yMid - yUp)),
          paint,
        );
      } else {
        canvas.drawRect(
          Rect.fromLTWH(cx - barWClamped / 2, yMid, barWClamped, math.max(2.0, yDn - yMid)),
          paint,
        );
      }
    }
  }

  void _drawSubSeparator(Canvas canvas, double w, double volTop) {
    final sep = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(KlineViewport.padL, volTop),
      Offset(w - KlineViewport.padR, volTop),
      sep,
    );
  }

  void _drawYLabels(Canvas canvas, double w, double plotTop, double plotH, PriceRange pr) {
    const style = TextStyle(color: Color(0x99FFFFFF), fontSize: 9);
    for (var i = 0; i <= 4; i++) {
      final p = pr.max - pr.span * i / 4;
      final y = plotTop + plotH * i / 4;
      final tp = TextPainter(
        text: TextSpan(text: p.toStringAsFixed(2), style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(w - tp.width - 3, y - tp.height / 2));
    }
  }

  void _drawXAxis(Canvas canvas, double w, double axisTop) {
    if (bars.isEmpty) return;

    final plotW = math.max(1.0, w - KlineViewport.padL - KlineViewport.padR);
    final span = math.max(viewport.xSpan, 1e-6);
    final minuteLike = KlineAxisFormat.isMinuteLike(visible.isNotEmpty ? visible : bars);
    final i0 = viewport.viewXMin.floor().clamp(0, bars.length - 1);
    final sample = KlineAxisFormat.xLabel(bars[i0].timeText, minuteLike: minuteLike);
    final interval = KlineAxisFormat.xTickInterval(plotW, span, sample);

    final axisLine = Paint()
      ..color = const Color(0x44FFFFFF)
      ..strokeWidth = 1;
    canvas.drawLine(
      Offset(KlineViewport.padL, axisTop),
      Offset(w - KlineViewport.padR, axisTop),
      axisLine,
    );

    final startX = ((viewport.viewXMin / interval).ceil() * interval).toInt();
    final endX = viewport.viewXMax.ceil().clamp(0, bars.length - 1);
    final tickPaint = Paint()
      ..color = const Color(0x33FFFFFF)
      ..strokeWidth = 1;
    const labelStyle = TextStyle(color: Color(0x99FFFFFF), fontSize: 9);

    for (var xi = startX; xi <= endX; xi += interval) {
      if (xi < 0 || xi >= bars.length) continue;
      final cx = viewport.barCenterX(xi, w);
      canvas.drawLine(Offset(cx, axisTop), Offset(cx, axisTop + 4), tickPaint);

      final label = KlineAxisFormat.xLabel(bars[xi].timeText, minuteLike: minuteLike);
      final tp = TextPainter(
        text: TextSpan(text: label, style: labelStyle),
        textDirection: TextDirection.ltr,
      )..layout();

      final perBarPx = plotW / span;
      final dense = perBarPx * interval < tp.width + 6;
      if (dense) {
        canvas.save();
        canvas.translate(cx, axisTop + KlineViewport.xAxisH - 2);
        canvas.rotate(-0.65);
        tp.paint(canvas, Offset(-tp.width / 2, -tp.height));
        canvas.restore();
      } else {
        var lx = cx - tp.width / 2;
        lx = lx.clamp(KlineViewport.padL, w - KlineViewport.padR - tp.width).toDouble();
        tp.paint(canvas, Offset(lx, axisTop + 5));
      }
    }
  }

  void _drawCrosshair(Canvas canvas, Size size, double contentBottom, double plotTop, PriceRange pr) {
    // 绘图区高度不足时避免 clamp 下界>上界
    final safeRight = math.max(KlineViewport.padL, size.width - KlineViewport.padR);
    final safeBottom = math.max(plotTop, contentBottom);
    final x = crosshairX!.clamp(KlineViewport.padL, safeRight).toDouble();
    final y = crosshairY!.clamp(plotTop, safeBottom).toDouble();
    final plotH = math.max(1.0, mainH - KlineViewport.padT - KlineViewport.padB);

    final paint = Paint()
      ..color = const Color(0xFFE2E8F0)
      ..strokeWidth = 1.2;

    _drawDashedLine(canvas, Offset(x, plotTop), Offset(x, contentBottom), paint);
    _drawDashedLine(
      canvas,
      Offset(KlineViewport.padL, y),
      Offset(size.width - KlineViewport.padR, y),
      paint,
    );

    final price = pr.priceFromY(y, plotTop, plotH);
    final barIdx = crosshairBarIdx ?? viewport.nearestBarIndex(bars, viewport.xToIndex(x, size.width));
    final bar = bars[barIdx.clamp(0, bars.length - 1)];

    final labelBg = Paint()..color = const Color(0xF0FFFFFF);
    final labelBorder = Paint()
      ..color = Colors.black
      ..style = PaintingStyle.stroke;
    final tp = TextPainter(
      text: TextSpan(
        text: price.toStringAsFixed(2),
        style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final lw = tp.width + 12;
    final lh = tp.height + 8;
    final ly = y - lh / 2;
    final lx = size.width - lw - 3;
    canvas.drawRect(Rect.fromLTWH(lx, ly, lw, lh), labelBg);
    canvas.drawRect(Rect.fromLTWH(lx, ly, lw, lh), labelBorder);
    tp.paint(canvas, Offset(lx + 6, ly + 4));

    final minuteLike = KlineAxisFormat.isMinuteLike(bars);
    final timePart = KlineAxisFormat.xLabel(bar.timeText, minuteLike: minuteLike);
    final info = [
      ...featureLookup.crosshairTooltipLines(bar.idx, timePart: timePart),
      ...featureLookup.crosshairSubLines(bar.idx, subIndicators),
    ];
    var maxW = 0.0;
    final rows = <TextPainter>[];
    for (final line in info) {
      final row = TextPainter(
        text: TextSpan(
          text: line,
          style: const TextStyle(color: Colors.black, fontSize: 11, fontWeight: FontWeight.bold),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      rows.add(row);
      if (row.width > maxW) maxW = row.width;
    }
    final boxW = maxW + 16;
    final boxH = rows.length * 16.0 + 12;
    var boxX = x + 12;
    if (boxX + boxW > size.width - KlineViewport.padR - 4) boxX = x - boxW - 12;
    // N段 tooltip 过宽/过高时上下界可能颠倒，clamp 前先保证 min<=max
    final minBoxX = KlineViewport.padL + 4;
    final maxBoxX = size.width - KlineViewport.padR - boxW - 4;
    boxX = boxX.clamp(minBoxX, math.max(minBoxX, maxBoxX));
    var boxY = y - boxH - 10;
    final minBoxY = plotTop + 4;
    final maxBoxY = contentBottom - boxH - 4;
    boxY = boxY.clamp(minBoxY, math.max(minBoxY, maxBoxY));
    canvas.drawRect(Rect.fromLTWH(boxX, boxY, boxW, boxH), labelBg);
    canvas.drawRect(Rect.fromLTWH(boxX, boxY, boxW, boxH), labelBorder);
    var ry = boxY + 6;
    for (final row in rows) {
      row.paint(canvas, Offset(boxX + 8, ry));
      ry += 16;
    }
  }

  BarCrosshairFeature? _featureAt(int idx) {
    for (final f in barFeatures) {
      if (f.idx == idx) return f;
    }
    return null;
  }

  /// 通用 pattern 虚线（pattern=[画,空,画,空,…] 像素）。
  void _drawPatternLine(
    Canvas canvas,
    Offset a,
    Offset b,
    Paint paint,
    List<double> pattern,
  ) {
    if (pattern.isEmpty) {
      canvas.drawLine(a, b, paint);
      return;
    }
    final total = (b - a).distance;
    if (total <= 0) return;
    final dir = (b - a) / total;
    var dist = 0.0;
    var patIdx = 0;
    while (dist < total) {
      final segLen = pattern[patIdx % pattern.length];
      final next = math.min(dist + segLen, total);
      if (patIdx % 2 == 0) {
        canvas.drawLine(a + dir * dist, a + dir * next, paint);
      }
      dist = next;
      patIdx++;
    }
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    _drawPatternLine(canvas, a, b, paint, const [4, 4]);
  }

  @override
  bool shouldRepaint(covariant _KlineCompositePainter oldDelegate) {
    return oldDelegate.bars != bars ||
        oldDelegate.combineFrames != combineFrames ||
        oldDelegate.biConfirmSignals != biConfirmSignals ||
        oldDelegate.barFeatures != barFeatures ||
        oldDelegate.biSegments != biSegments ||
        oldDelegate.biVirtualBarViews != biVirtualBarViews ||
        oldDelegate.biCombineFrames != biCombineFrames ||
        oldDelegate.segAnalysis != segAnalysis ||
        oldDelegate.levels != levels ||
        oldDelegate.segAsOf != segAsOf ||
        oldDelegate.mainIndicators != mainIndicators ||
        oldDelegate.subIndicators != subIndicators ||
        oldDelegate.mainH != mainH ||
        oldDelegate.volH != volH ||
        oldDelegate.viewport.viewXMin != viewport.viewXMin ||
        oldDelegate.viewport.viewXMax != viewport.viewXMax ||
        oldDelegate.viewport.yZoomRatio != viewport.yZoomRatio ||
        oldDelegate.viewport.yShiftRatio != viewport.yShiftRatio ||
        oldDelegate.crosshairEnabled != crosshairEnabled ||
        oldDelegate.crosshairX != crosshairX ||
        oldDelegate.crosshairY != crosshairY ||
        oldDelegate.crosshairBarIdx != crosshairBarIdx;
  }
}
