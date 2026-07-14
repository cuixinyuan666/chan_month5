import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compute/bi_combine_compute.dart';
import '../compute/bi_virtual_bar_view_compute.dart';
import '../compute/chart_view_compute.dart';
import '../compute/level_unit_bar_view_compute.dart';
import '../models/bi_confirm_signal.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/bi_segment.dart';
import '../models/bi_virtual_bar.dart';
import '../models/bi_virtual_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/chart_indicator.dart';
import '../models/kline_combine_frame.dart';
import '../models/bar_feature_lookup.dart';
import '../models/level_models.dart';
import '../models/seg_analysis.dart';
import 'chart_level_line_style.dart';
import 'crosshair_tooltip_panel.dart';
import 'fractal_confirm_paint.dart';
import 'indicator_picker_chip.dart';
import 'kline_axis_format.dart';
import 'kline_viewport.dart';
import 'main_indicator_picker.dart';
import 'sub_indicator_picker.dart';

/// 十字线三态：双击循环 off → 全开(含tooltip) → 仅线(关tooltip) → off。
enum CrosshairMode {
  /// 关闭：恢复抓取光标与普通拖拽观感
  off,
  /// 十字线 + 价格标签 + K0/Kn 信息框
  withTooltip,
  /// 十字线 + 价格标签，隐藏信息框
  linesOnly,
}

/// 主图同级别连线配色（K0连线/笔 + 更高层见 [ChartLevelLineStyle]）。
abstract final class ChartLineColors {
  /// K0连线（笔）统一色
  static const bi = Color(0xCC94A3B8);
  /// K1连线（线段，内部 level=2）默认色（与 ChartLevelLineStyle 一致）
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
    this.truncationCheck = true,
    this.onMainIndicatorsChanged,
    this.onSubIndicatorsChanged,
    this.indicatorsEnabled = true,
    this.autoFollowLatest = false,
    this.onTapStepBack,
    this.onTapPlay,
    this.onTapStepForward,
    this.onLongPressReset,
    this.onLongPressReload,
    this.onLongPressRunToEnd,
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
  /// 截断监察：十字线 as-of 本地重算笔K合并时与 Rust 同开关
  final bool truncationCheck;
  final ValueChanged<Set<MainChartIndicator>>? onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>>? onSubIndicatorsChanged;
  /// 无数据时禁止点主/副图指标入口
  final bool indicatorsEnabled;
  final bool autoFollowLatest;

  /// 点击左/中/右：后退 / 播放暂停 / 前进
  final VoidCallback? onTapStepBack;
  final VoidCallback? onTapPlay;
  final VoidCallback? onTapStepForward;

  /// 长按左/中/右：首K / 重新加载 / 一次性走完
  final VoidCallback? onLongPressReset;
  final VoidCallback? onLongPressReload;
  final VoidCallback? onLongPressRunToEnd;

  @override
  State<KlineChart> createState() => _KlineChartState();
}

class _KlineChartState extends State<KlineChart> {
  final _viewport = KlineViewport();
  /// 双击三态：开十字线 → 关 tooltip → 全关
  CrosshairMode _crosshairMode = CrosshairMode.off;
  double? _crosshairX;
  double? _crosshairY;
  int? _crosshairBarIdx;

  bool get _crosshairEnabled => _crosshairMode != CrosshairMode.off;
  bool get _crosshairShowTooltip => _crosshairMode == CrosshairMode.withTooltip;
  /// tooltip 滚轮下翻（显示 tooltip 时接管滚轮，不缩放）
  final _tooltipScroll = ScrollController();
  int? _tooltipScrollBarIdx;
  bool _panning = false;
  Offset? _panStart;
  double _panStartYShift = 0;
  double _panStartViewMin = 0;
  double _panStartViewMax = 0;
  Size _chartSize = Size.zero;

  /// 中间区自管双击：避免左/右连点被系统双击手势吞掉
  static const _doubleTapMs = 280;
  Timer? _middleTapTimer;
  DateTime? _lastMiddleTapAt;
  Offset? _lastMiddleTapPos;

  /// 主图占「主+副」区域比例，可拖动分割线调整。
  double _mainFraction = 0.79;
  static const _minMainFraction = 0.22;
  static const _maxMainFraction = 0.92;
  bool _splitDragging = false;
  double _splitDragStartY = 0;
  double _splitDragStartFraction = 0.79;
  double _chartBodyH = 1;

  Set<SubChartIndicator> get _activeSubs => widget.subIndicators;

  Set<MainChartIndicator> get _activeMains => widget.mainIndicators;

  /// 当前数据最高 Kn → 动态生成可选指标
  int get _maxKn => chartMaxKn(
        levels: widget.levels,
        biSegments: widget.biSegments,
      );

  List<MainChartIndicator> get _mainCatalog =>
      buildMainIndicatorCatalog(_maxKn);

  List<SubChartIndicator> get _subCatalog =>
      buildSubIndicatorCatalog(_maxKn, truncationCheck: widget.truncationCheck);

  /// 副图是否展开（无勾选副图指标则收起整块副图区）
  bool get _showSubPane => _activeSubs.isNotEmpty;

  @override
  void initState() {
    super.initState();
    _resetViewport();
  }

  @override
  void dispose() {
    _middleTapTimer?.cancel();
    _tooltipScroll.dispose();
    super.dispose();
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
    if (_crosshairShowTooltip) {
      _resetTooltipScrollIfNeeded(barIdx);
    }
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
    return computeBiCombineFrames(
      barsSlice,
      // 截断/合并只认已确认笔（与 Rust L2 feed、all_confirm 同构）
      _asOfBiVirtualBars(includeBuilding: false),
      truncationCheck: widget.truncationCheck,
    );
  }

  int _crosshairAsOfIdx() =>
      widget.bars[_crosshairBarIdx!.clamp(0, widget.bars.length - 1)].idx;

  /// as-of 笔 K 重建：Rust 冻结段 + 可选当步进行中笔。
  List<BiVirtualBar> _asOfBiVirtualBars({bool includeBuilding = true}) {
    return asOfBiVirtualBars(
      bars: widget.bars,
      levels: widget.levels,
      barFeatures: widget.barFeatures,
      defaultBiPolicy: widget.defaultBiPolicy,
      asOf: _crosshairAsOfIdx(),
      includeBuilding: includeBuilding,
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

    // 显示 tooltip：滚轮只翻信息框，不缩放 K 线；仅线(关tooltip)时仍可缩放
    if (_crosshairShowTooltip) {
      _scrollTooltipBy(e.scrollDelta.dy);
      return;
    }

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

  void _scrollTooltipBy(double dy) {
    if (!_tooltipScroll.hasClients) return;
    final pos = _tooltipScroll.position;
    final next = (pos.pixels + dy).clamp(0.0, pos.maxScrollExtent);
    if (next != pos.pixels) {
      _tooltipScroll.jumpTo(next);
    }
  }

  void _resetTooltipScrollIfNeeded(int? barIdx) {
    if (barIdx != _tooltipScrollBarIdx) {
      _tooltipScrollBarIdx = barIdx;
      if (_tooltipScroll.hasClients) {
        _tooltipScroll.jumpTo(0);
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_tooltipScroll.hasClients) _tooltipScroll.jumpTo(0);
        });
      }
    }
  }

  /// 组装当前十字线 tooltip 行（含副图）
  List<CrosshairTooltipRow> _tooltipRowsForBar(int barIdx) {
    final bar = widget.bars[barIdx.clamp(0, widget.bars.length - 1)];
    final minuteLike = KlineAxisFormat.isMinuteLike(widget.bars);
    final timePart = KlineAxisFormat.xLabel(bar.timeText, minuteLike: minuteLike);
    final lookup = BarFeatureLookup.build(
      bars: widget.bars,
      combineFrames: widget.combineFrames,
      biConfirms: widget.biConfirmSignals,
      barFeatures: widget.barFeatures,
      biSegments: widget.biSegments,
      segAnalysis: widget.segAnalysis,
      levels: widget.levels,
      subIndicators: _activeSubs,
    );
    return lookup.crosshairTooltipRows(
      bar.idx,
      timePart: timePart,
      subIndicators: _activeSubs,
    );
  }

  /// tooltip 锚点：十字线旁，尽量不挡价签
  Offset _tooltipAnchor({
    required double chartW,
    required double contentBottom,
    required double plotTop,
    required double maxW,
    required double maxH,
  }) {
    final x = (_crosshairX ?? chartW / 2)
        .clamp(KlineViewport.padL, math.max(KlineViewport.padL, chartW - KlineViewport.padR))
        .toDouble();
    final y = (_crosshairY ?? plotTop + 40)
        .clamp(plotTop, math.max(plotTop, contentBottom))
        .toDouble();
    var boxX = x + 12;
    if (boxX + maxW > chartW - KlineViewport.padR - 4) {
      boxX = x - maxW - 12;
    }
    final minBoxX = KlineViewport.padL + 4.0;
    final maxBoxX = chartW - KlineViewport.padR - maxW - 4;
    boxX = boxX.clamp(minBoxX, math.max(minBoxX, maxBoxX));
    var boxY = y - math.min(maxH, 220) - 10;
    final minBoxY = plotTop + 4.0;
    final maxBoxY = contentBottom - 40;
    boxY = boxY.clamp(minBoxY, math.max(minBoxY, maxBoxY));
    return Offset(boxX, boxY);
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

  void _cycleCrosshair(Offset pos, double plotTop, double contentBottom) {
    setState(() {
      // 第一次开十字线+tooltip；第二次只关 tooltip；第三次全关恢复鼠标
      switch (_crosshairMode) {
        case CrosshairMode.off:
          _crosshairMode = CrosshairMode.withTooltip;
          _tooltipScrollBarIdx = null;
          _updateCrosshairAt(pos, plotTop, contentBottom);
        case CrosshairMode.withTooltip:
          _crosshairMode = CrosshairMode.linesOnly;
        case CrosshairMode.linesOnly:
          _crosshairMode = CrosshairMode.off;
          _crosshairX = null;
          _crosshairY = null;
          _crosshairBarIdx = null;
          _tooltipScrollBarIdx = null;
      }
    });
  }

  /// 左/中/右三等分热区
  int _hotZone(Offset local) {
    final w = math.max(1.0, _chartSize.width);
    final t = local.dx / w;
    if (t < 1 / 3) return 0;
    if (t < 2 / 3) return 1;
    return 2;
  }

  void _onZoneTap(TapUpDetails d, double plotTop, double contentBottom) {
    if (widget.bars.isEmpty) return;
    final zone = _hotZone(d.localPosition);

    // 十字线激活：屏蔽步退/步进/播放，只保留中间双击切三态 + 点击跟线
    if (_crosshairEnabled) {
      if (zone != 1) {
        _middleTapTimer?.cancel();
        _lastMiddleTapAt = null;
        _lastMiddleTapPos = null;
        _updateCrosshairAt(d.localPosition, plotTop, contentBottom);
        return;
      }
      final now = DateTime.now();
      final last = _lastMiddleTapAt;
      final lastPos = _lastMiddleTapPos;
      if (last != null &&
          lastPos != null &&
          now.difference(last).inMilliseconds <= _doubleTapMs &&
          (d.localPosition - lastPos).distance < 48) {
        _middleTapTimer?.cancel();
        _lastMiddleTapAt = null;
        _lastMiddleTapPos = null;
        _cycleCrosshair(d.localPosition, plotTop, contentBottom);
        return;
      }
      _lastMiddleTapAt = now;
      _lastMiddleTapPos = d.localPosition;
      _middleTapTimer?.cancel();
      // 单击只跟线，不触发播放
      _updateCrosshairAt(d.localPosition, plotTop, contentBottom);
      _middleTapTimer = Timer(const Duration(milliseconds: _doubleTapMs), () {
        _lastMiddleTapAt = null;
        _lastMiddleTapPos = null;
      });
      return;
    }

    // 左/右：每次点击立刻步退/步进，连点即加速（不走系统双击）
    if (zone == 0) {
      _middleTapTimer?.cancel();
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      widget.onTapStepBack?.call();
      return;
    }
    if (zone == 2) {
      _middleTapTimer?.cancel();
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      widget.onTapStepForward?.call();
      return;
    }
    // 中间：自管双击=十字线三态；单击延迟后播放
    final now = DateTime.now();
    final last = _lastMiddleTapAt;
    final lastPos = _lastMiddleTapPos;
    if (last != null &&
        lastPos != null &&
        now.difference(last).inMilliseconds <= _doubleTapMs &&
        (d.localPosition - lastPos).distance < 48) {
      _middleTapTimer?.cancel();
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      _cycleCrosshair(d.localPosition, plotTop, contentBottom);
      return;
    }
    _lastMiddleTapAt = now;
    _lastMiddleTapPos = d.localPosition;
    _middleTapTimer?.cancel();
    _middleTapTimer = Timer(const Duration(milliseconds: _doubleTapMs), () {
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      widget.onTapPlay?.call();
    });
  }

  void _onZoneLongPress(LongPressStartDetails d) {
    // 十字线激活时屏蔽长按：复位/重载/跑到末尾
    if (_crosshairEnabled) return;
    if (widget.bars.isEmpty && _hotZone(d.localPosition) != 1) return;
    switch (_hotZone(d.localPosition)) {
      case 0:
        widget.onLongPressReset?.call();
      case 1:
        widget.onLongPressReload?.call();
      default:
        widget.onLongPressRunToEnd?.call();
    }
  }

  void _onPanStart(DragStartDetails d, double mainPlotH) {
    if (widget.bars.isEmpty || _splitDragging) return;
    _panning = true;
    _panStart = d.localPosition;
    _panStartViewMin = _viewport.viewXMin;
    _panStartViewMax = _viewport.viewXMax;
    _panStartYShift = _viewport.yShiftRatio;
  }

  void _onPanUpdate(DragUpdateDetails d, double mainPlotH) {
    if (!_panning || _panStart == null || _splitDragging) return;
    final dx = d.localPosition.dx - _panStart!.dx;
    final dy = d.localPosition.dy - _panStart!.dy;
    _viewport.viewXMin = _panStartViewMin;
    _viewport.viewXMax = _panStartViewMax;
    _viewport.yShiftRatio = _panStartYShift;
    _viewport.markUserAdjusted();
    _viewport.panByPixels(dx, dy, _chartSize.width, mainPlotH);
    _scheduleRedraw();
  }

  void _onPanEnd(DragEndDetails d) {
    _panning = false;
    _panStart = null;
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
    if (!widget.indicatorsEnabled) return;
    final picked = await showMainIndicatorPicker(
      context: context,
      selected: _activeMains,
      available: _mainCatalog,
    );
    // null 已在 picker 内转成草稿；此处仍可能为 Set（含空）
    if (picked != null) {
      widget.onMainIndicatorsChanged?.call(picked);
    }
  }

  Future<void> _pickSubIndicators(BuildContext context) async {
    if (!widget.indicatorsEnabled) return;
    final picked = await showSubIndicatorPicker(
      context: context,
      selected: _activeSubs,
      available: _subCatalog,
    );
    if (picked != null) {
      widget.onSubIndicatorsChanged?.call(picked);
    }
  }

  /// 双击关闭某一主图指标（可关到空=只留 K0 线）。
  void _closeMainIndicator(MainChartIndicator item) {
    final next = Set<MainChartIndicator>.from(_activeMains)..remove(item);
    widget.onMainIndicatorsChanged?.call(next);
  }

  /// 双击关闭某一副图指标（可关到空=收起副图）。
  void _closeSubIndicator(SubChartIndicator item) {
    final next = Set<SubChartIndicator>.from(_activeSubs)..remove(item);
    widget.onSubIndicatorsChanged?.call(next);
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
        _chartBodyH = math.max(1.0, h);
        // 无副图指标：收起副图，主图吃满（底部只留 X 轴）
        final double mainH;
        final double volH;
        if (_showSubPane) {
          mainH = _chartBodyH * _mainFraction;
          volH = _chartBodyH - mainH;
        } else {
          volH = KlineViewport.xAxisH;
          mainH = math.max(1.0, _chartBodyH - volH);
        }
        final xAxisTop = mainH + volH - KlineViewport.xAxisH;
        final contentBottom = xAxisTop;
        _chartSize = Size(w, mainH + volH);

        final visible = _viewport.visibleBars(widget.bars);
        final priceRange = _viewport.priceRangeFor(visible);

        final cursor = _crosshairEnabled
            ? SystemMouseCursors.precise
            : (_panning ? SystemMouseCursors.grabbing : SystemMouseCursors.grab);
        final plotTop = KlineViewport.padT;

        return Stack(
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
                crosshairShowTooltip: _crosshairShowTooltip,
                crosshairX: _crosshairX,
                crosshairY: _crosshairY,
                crosshairBarIdx: _crosshairBarIdx,
                truncationCheck: widget.truncationCheck,
                segAsOf: _crosshairEnabled && _crosshairBarIdx != null
                    ? _crosshairAsOfIdx()
                    : null,
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
                  onPointerMove: (e) => _onPointerMove(
                    e,
                    mainH - KlineViewport.padT - KlineViewport.padB,
                    contentBottom,
                  ),
                  onPointerUp: _onPointerUp,
                  child: GestureDetector(
                    behavior: HitTestBehavior.opaque,
                    onTapUp: (d) => _onZoneTap(d, plotTop, contentBottom),
                    onLongPressStart: _onZoneLongPress,
                    onPanStart: (d) => _onPanStart(
                      d,
                      mainH - KlineViewport.padT - KlineViewport.padB,
                    ),
                    onPanUpdate: (d) => _onPanUpdate(
                      d,
                      mainH - KlineViewport.padT - KlineViewport.padB,
                    ),
                    onPanEnd: _onPanEnd,
                    child: const SizedBox.expand(),
                  ),
                ),
              ),
            ),
            // 十字线 tooltip 盖在手势层之上（IgnorePointer 保证点击/滚轮仍由下层接管）
            if (_crosshairShowTooltip &&
                _crosshairX != null &&
                _crosshairY != null &&
                _crosshairBarIdx != null)
              Builder(builder: (context) {
                final barIdx = _crosshairBarIdx!;
                final rows = _tooltipRowsForBar(barIdx);
                final maxW = math.min(420.0, w * 0.55);
                final maxH = math.min(contentBottom - plotTop - 16, h * 0.55);
                final anchor = _tooltipAnchor(
                  chartW: w,
                  contentBottom: contentBottom,
                  plotTop: plotTop,
                  maxW: maxW,
                  maxH: maxH,
                );
                return Positioned(
                  left: anchor.dx,
                  top: anchor.dy,
                  child: IgnorePointer(
                    child: CrosshairTooltipPanel(
                      rows: rows,
                      scrollController: _tooltipScroll,
                      maxWidth: maxW,
                      maxHeight: maxH,
                    ),
                  ),
                );
              }),
            // 主副图分割条（副图收起时不显示）
            if (_showSubPane)
              Positioned(
                left: KlineViewport.padL,
                right: KlineViewport.padR,
                top: mainH - 4,
                height: 8,
                child: MouseRegion(
                  cursor: SystemMouseCursors.resizeUpDown,
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
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
            // 主图：↓ + 已选指标名（无数据不可点）
            Positioned(
              left: 0,
              top: 0,
              child: IgnorePointer(
                ignoring: !widget.indicatorsEnabled,
                child: Opacity(
                  opacity: widget.indicatorsEnabled ? 1 : 0.35,
                  child: IndicatorPickerChip(
                    entries: _mainCatalog
                        .where(_activeMains.contains)
                        .map(
                          (e) => IndicatorChipEntry(
                            label: e.label,
                            onDoubleTapClose: () => _closeMainIndicator(e),
                          ),
                        )
                        .toList(),
                    onTapDropdown: () => _pickMainIndicators(context),
                    maxWidth: math.min(280, w * 0.55),
                    emptyHint: 'K0',
                  ),
                ),
              ),
            ),
            // 副图入口
            Positioned(
              left: KlineViewport.padL,
              top: _showSubPane ? mainH + 2 : math.max(0.0, mainH - 26),
              child: IgnorePointer(
                ignoring: !widget.indicatorsEnabled,
                child: Opacity(
                  opacity: widget.indicatorsEnabled ? 1 : 0.35,
                  child: IndicatorPickerChip(
                    entries: _subCatalog
                        .where(_activeSubs.contains)
                        .map(
                          (e) => IndicatorChipEntry(
                            label: e.label,
                            onDoubleTapClose: () => _closeSubIndicator(e),
                          ),
                        )
                        .toList(),
                    onTapDropdown: () => _pickSubIndicators(context),
                    maxWidth: math.min(280, w * 0.55),
                    emptyHint: '未选',
                  ),
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
    required this.crosshairShowTooltip,
    required this.crosshairX,
    required this.crosshairY,
    required this.crosshairBarIdx,
    this.truncationCheck = true,
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
  /// false=仅画十字线与价格标签，不画 K0/Kn 信息框
  final bool crosshairShowTooltip;
  final double? crosshairX;
  final double? crosshairY;
  final int? crosshairBarIdx;
  /// 截断机制开关：关则不画 Kn截断副图
  final bool truncationCheck;
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

    if (mainIndicators.isEmpty) {
      // 关闭全部主图指标：只画 K0 线
      _drawCandles(canvas, size.width, plotTop, plotH, barW, slotW);
    } else {
      final hasK0Combine =
          mainIndicators.contains(const MainChartIndicator.combine(0));
      // 未勾 K0合并时仍铺底层 K0 蜡烛，避免只选连线时空白
      if (!hasK0Combine) {
        _drawCandles(canvas, size.width, plotTop, plotH, barW, slotW);
      }
      // 按勾选项逐层画：勾哪层画哪层（不再一项自动叠全部）
      for (final ind in mainIndicators) {
        if (ind.kind == MainIndicatorKind.combine) {
          if (ind.kn == 0) {
            _drawKlineCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW);
          } else if (ind.kn == 1) {
            _drawBiCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW);
          } else {
            _drawLevelCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
          }
        } else if (ind.kind == MainIndicatorKind.line) {
          // 内部 kn：1=笔→展示 K0连线；≥2→展示 K(kn-1)连线
          if (ind.kn == 1) {
            _drawBiSegments(canvas, size.width, plotTop, plotH, slotW);
          } else {
            _drawSegLinesForLevel(
                canvas, size.width, plotTop, plotH, slotW, ind.kn);
          }
        }
      }
    }
    if (subIndicators.isNotEmpty) {
      _drawSubCharts(canvas, size.width, mainH, barW, slotW);
    }

    _drawYLabels(canvas, size.width, plotTop, plotH, priceRange);
    _drawXAxis(canvas, size.width, xAxisTop);

    if (crosshairEnabled && crosshairX != null && crosshairY != null) {
      _drawCrosshair(canvas, size, contentBottom, plotTop, priceRange);
      // 极点距数值：不画在折线上，十字线激活时在副图右上角固定读数
      _drawPeakDistCrosshairReadout(canvas, size.width);
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

  // 主/副图不再绘制网格横线与右侧封口竖线（价格标签仍保留）

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

  /// K0连线（笔）端点：极点 K 中轴 + 极点价（与 K线分型极点距同口径，仅展示用）。
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

  /// 指定层连线（内部 kn≥2 → 展示名 K(kn-1)连线）；勾哪层画哪层。
  void _drawSegLinesForLevel(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (kn < 2) return;
    final tailIdx = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);

    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == kn) {
        bundle = b;
        break;
      }
    }
    if (bundle != null) {
      _drawOneLevelLines(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        bundle: bundle,
        tailIdx: tailIdx,
      );
      return;
    }
    // 回退：仅 K2 且无 levels 时用旧 segAnalysis
    if (kn != 2) return;
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

  /// 主图 Kn 合并（kn≥2）：先铺淡 KN 单元线，再描该层合并框（对齐 K1合并）。
  void _drawLevelCombineOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
    int kn,
  ) {
    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == kn) {
        bundle = b;
        break;
      }
    }
    if (bundle == null) return;
    if (bundle.combineFrames.isEmpty &&
        bundle.unitBars.isEmpty &&
        bundle.activeUnit == null) {
      return;
    }

    final views = buildLevelUnitBarViews(
      bundle.unitBars,
      activeUnit: bundle.activeUnit,
    );
    if (views.isNotEmpty) {
      _drawLevelUnitCandles(
        canvas,
        w,
        plotTop,
        plotH,
        barW,
        slotW,
        views,
        faint: true,
      );
    }

    if (bundle.combineFrames.isNotEmpty) {
      final style = ChartLevelLineStyle.forLevel(kn);
      _drawCombineFramesOnMainChart(
        canvas,
        w,
        plotTop,
        plotH,
        barW,
        slotW,
        bundle.combineFrames,
        style.color.withValues(alpha: 0.85),
        style.color.withValues(alpha: 0.08),
        // 有单元 view 时按半侧衔接框对齐（同 K1合并）
        levelUnitViews: views,
      );
    }
  }

  /// Kn 单元线（淡色底层，仿笔 K [_drawBiVirtualCandles]）。
  void _drawLevelUnitCandles(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
    List<LevelUnitBarView> views, {
    bool faint = false,
  }) {
    if (views.isEmpty) return;
    final upBody = faint ? const Color(0x38E53935) : const Color(0x88E53935);
    final dnBody = faint ? const Color(0x3826A69A) : const Color(0x8826A69A);
    final upStroke = faint ? const Color(0x55E53935) : const Color(0xFFE53935);
    final dnStroke = faint ? const Color(0x5526A69A) : const Color(0xFF26A69A);

    for (final v in views) {
      if (v.viewX2 < viewport.viewXMin - 1 || v.viewX1 > viewport.viewXMax + 1) {
        continue;
      }
      final (left, right) = _levelUnitBarHSpan(v, w, slotW, barW);
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

  /// Kn 单元线横向半侧锚定（同 [_biVirtualBarHSpan]）。
  (double left, double right) _levelUnitBarHSpan(
    LevelUnitBarView v,
    double w,
    double slotW,
    double barW,
  ) {
    var (left, right) = _combineFrameHSpan(v.viewX1, v.viewX2, w, slotW, barW);
    if (v.endAtLeftHalf) {
      right = math.min(right, _barCenterX(v.viewX2, w, slotW));
    }
    if (v.startAtRightHalf) {
      left = math.max(left, _barCenterX(v.viewX1, w, slotW));
    }
    if (right - left < 2.0) {
      final mid = (left + right) / 2;
      left = mid - 1.0;
      right = mid + 1.0;
    }
    return (left, right);
  }

  /// 按 frame.x1 + count 取层内单元 view（仿 [_biViewsForCombineFrame]）。
  List<LevelUnitBarView> _levelViewsForCombineFrame(
    KlineCombineFrame f,
    List<LevelUnitBarView> views,
  ) {
    final startIdx = views.indexWhere((v) => v.viewX1 == f.x1);
    if (startIdx < 0) return const [];
    final end = math.min(startIdx + f.count, views.length);
    if (end <= startIdx) return const [];
    return views.sublist(startIdx, end);
  }

  /// Kn 合并框横向：有单元 view 时对齐半侧衔接（同 [_biCombineFrameSpan]）。
  (double left, double right) _levelCombineFrameSpan(
    KlineCombineFrame f,
    double w,
    double slotW,
    double barW,
    List<LevelUnitBarView> views,
  ) {
    final related = _levelViewsForCombineFrame(f, views);
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

  void _drawCandles(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
  ) {
    // 沿用原主图「K0」蜡烛样式（红涨绿跌实体+影线）
    const up = Color(0xFFE53935);
    const down = Color(0xFF26A69A);
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

  /// 主图 K0合并：底层用原「K0」蜡烛样式，再描 K0合并框。
  void _drawKlineCombineOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
  ) {
    _drawCandles(canvas, w, plotTop, plotH, barW, slotW);
    if (combineFrames.isEmpty) return;
    _drawCombineFramesOnMainChart(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      combineFrames,
      const Color(0xFF6366F1),
      const Color(0x226366F1),
    );
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
    List<LevelUnitBarView>? levelUnitViews,
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
          : (levelUnitViews != null && levelUnitViews.isNotEmpty)
              ? _levelCombineFrameSpan(f, w, slotW, barW, levelUnitViews)
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
    final innerTop = volTop + 6;
    final innerBottom = contentBottom - 4;
    final innerH = math.max(12.0, innerBottom - innerTop);
    if (innerH <= 0) return;

    if (subIndicators.any((e) => e.kind == SubIndicatorKind.volume)) {
      _drawVolume(canvas, w, innerTop, innerBottom, innerH, barW, slotW);
    }
    // 勾哪层画哪层；叠加时横向错位+描边，避免同 x 盖住
    final confirmKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.fractalConfirm)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (var i = 0; i < confirmKns.length; i++) {
      _drawKnFractalConfirmSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        confirmKns[i],
        stackRank: i,
        stackCount: confirmKns.length,
      );
    }
    final peakKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.fractalPeakDist)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (final kn in peakKns) {
      _drawKnFractalPeakDistSubChart(
          canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    // Kn截断：只画 truncated=true；且仅截断机制开启时绘制
    final truncKns = truncationCheck
        ? (subIndicators
            .where((e) => e.kind == SubIndicatorKind.truncation)
            .map((e) => e.kn)
            .toList()
          ..sort())
        : <int>[];
    for (var i = 0; i < truncKns.length; i++) {
      _drawKnTruncationSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        truncKns[i],
        stackRank: i,
        stackCount: truncKns.length,
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

  /// 单层 Kn 分型确认：红涨绿跌；形状按 Kn；叠画时横向扇形错位 + 描边。
  void _drawKnFractalConfirmSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int labelKn, {
    int stackRank = 0,
    int stackCount = 1,
  }) {
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final y0 = subY(0);
    final shape = confirmMarkerShapeForKn(labelKn);
    final level = labelKn + 1;
    final dx = confirmStackOffsetX(
      rank: stackRank,
      count: stackCount,
      barW: barW,
    );

    void paintPoint(int x, int value) {
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) return;
      if (value == 0) return;
      final cx = _barCenterX(x, w, slotW) + dx;
      final yp = subY(value.toDouble());
      paintFractalConfirmMarker(
        canvas,
        cx: cx,
        y0: y0,
        yp: yp,
        value: value,
        shape: shape,
        barW: barW,
        withOutline: stackCount > 1,
      );
    }

    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == level) {
        bundle = b;
        break;
      }
    }
    if (bundle != null) {
      for (final c in bundle.confirms) {
        if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.value != 0) {
          paintPoint(c.x, c.value);
        }
      }
      return;
    }
    // 回退：K0 层用旧 bi_confirms
    if (labelKn == 0) {
      for (final s in biConfirmSignals) {
        paintPoint(s.x, s.value);
      }
    }
  }

  /// 由确认列表生成逐 K 极点距（确认当步起算；不含极点 K；对齐 Rust enrich）。
  List<int> _peakDistSeries(int barCount, List<LevelConfirm> confirms) {
    final out = List<int>.filled(barCount, 0);
    if (barCount <= 0) return out;
    var ptr = 0;
    int? extreme;
    for (var i = 0; i < barCount; i++) {
      while (ptr < confirms.length && confirms[ptr].x <= i) {
        final c = confirms[ptr];
        if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.poleX >= 0) {
          extreme = c.poleX;
        }
        ptr++;
      }
      out[i] = extreme == null ? 0 : i - extreme;
    }
    return out;
  }

  /// 单层 Kn 分型极点距：不同 Kn 换线型/粗细，叠画可辨。
  void _drawKnFractalPeakDistSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int labelKn,
  ) {
    if (bars.isEmpty) return;
    final n = bars.length;
    final level = labelKn + 1;

    List<int> series;
    Color color;
    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == level) {
        bundle = b;
        break;
      }
    }
    if (bundle != null) {
      series = _peakDistSeries(n, bundle.confirms);
      color = labelKn <= 0
          ? const Color(0xFF38BDF8)
          : ChartLevelLineStyle.forLevel(level).color;
    } else if (labelKn == 0 && barFeatures.isNotEmpty) {
      series = List<int>.generate(
        n,
        (i) => i < barFeatures.length ? barFeatures[i].fractalPeakDist : 0,
      );
      color = const Color(0xFF38BDF8);
    } else {
      return;
    }

    var maxV = 1.0;
    for (final v in series) {
      if (v > maxV) maxV = v.toDouble();
    }
    final span = math.max(1.0, maxV);
    double subY(double v) => innerTop + (span - v) / span * innerH;

    final style = peakDistLineStyleForKn(labelKn);
    final linePaint = Paint()
      ..color = color
      ..strokeWidth = style.stroke
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    Offset? prev;
    for (var i = 0; i < series.length; i++) {
      final idx = bars[i].idx;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) {
        prev = null;
        continue;
      }
      final p = Offset(_barCenterX(idx, w, slotW), subY(series[i].toDouble()));
      if (prev != null) {
        if (style.dash.isEmpty) {
          canvas.drawLine(prev, p, linePaint);
        } else {
          _drawPatternLine(canvas, prev, p, linePaint, style.dash);
        }
      }
      prev = p;
    }
  }

  /// 单层 Kn 截断：只画 truncated 确认点（x=触发截断当步 K）。
  void _drawKnTruncationSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int labelKn, {
    int stackRank = 0,
    int stackCount = 1,
  }) {
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final y0 = subY(0);
    final shape = confirmMarkerShapeForKn(labelKn);
    final level = labelKn + 1;
    final dx = confirmStackOffsetX(
      rank: stackRank,
      count: stackCount,
      barW: barW,
    );

    void paintPoint(int x, int value) {
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) return;
      if (value == 0) return;
      final cx = _barCenterX(x, w, slotW) + dx;
      final yp = subY(value.toDouble());
      paintTruncationMarker(
        canvas,
        cx: cx,
        y0: y0,
        yp: yp,
        value: value,
        shape: shape,
        barW: barW,
      );
    }

    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == level) {
        bundle = b;
        break;
      }
    }
    if (bundle != null) {
      for (final c in bundle.confirms) {
        if (!c.truncated) continue;
        if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.value != 0) {
          paintPoint(c.x, c.value);
        }
      }
      return;
    }
    // 回退：K0 层用旧 bi_confirms
    if (labelKn == 0) {
      for (final s in biConfirmSignals) {
        if (!s.truncated) continue;
        paintPoint(s.x, s.value);
      }
    }
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

    // tooltip 改由 Flutter 覆盖层绘制（表格对齐 + 可滚动半透明）
  }

  /// 十字线激活时：副图右上角固定显示已勾选层的极点距当前值。
  void _drawPeakDistCrosshairReadout(Canvas canvas, double w) {
    if (crosshairBarIdx == null || bars.isEmpty || subIndicators.isEmpty) {
      return;
    }
    final peakKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.fractalPeakDist)
        .map((e) => e.kn)
        .toList()
      ..sort();
    if (peakKns.isEmpty) return;

    final barX = bars[crosshairBarIdx!.clamp(0, bars.length - 1)].idx;
    final parts = <String>[];
    for (final kn in peakKns) {
      final v = _peakDistValueAt(barX, kn);
      if (v == null) continue;
      parts.add('K$kn极点距:$v');
    }
    if (parts.isEmpty) return;

    final tp = TextPainter(
      text: TextSpan(
        text: parts.join('  '),
        style: const TextStyle(
          color: Color(0xFF38BDF8),
          fontSize: 11,
          fontWeight: FontWeight.w600,
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    final pad = 6.0;
    final boxW = tp.width + pad * 2;
    final boxH = tp.height + pad;
    // 固定：副图区右上角（主图下方）
    final lx = (w - KlineViewport.padR - boxW)
        .clamp(KlineViewport.padL, w - boxW)
        .toDouble();
    final ly = mainH + 4;
    final bg = Paint()..color = const Color(0xCC121212);
    final border = Paint()
      ..color = const Color(0x6638BDF8)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1;
    final rect = Rect.fromLTWH(lx, ly, boxW, boxH);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      bg,
    );
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      border,
    );
    tp.paint(canvas, Offset(lx + pad, ly + pad / 2));
  }

  /// 十字线当步某层极点距（与副图折线同口径）。
  int? _peakDistValueAt(int barX, int labelKn) {
    if (bars.isEmpty) return null;
    final n = bars.length;
    final level = labelKn + 1;
    List<int> series;
    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == level) {
        bundle = b;
        break;
      }
    }
    if (bundle != null) {
      series = _peakDistSeries(n, bundle.confirms);
    } else if (labelKn == 0 && barFeatures.isNotEmpty) {
      series = List<int>.generate(
        n,
        (i) => i < barFeatures.length ? barFeatures[i].fractalPeakDist : 0,
      );
    } else {
      return null;
    }
    final i = barX.clamp(0, series.length - 1);
    return series[i];
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
        oldDelegate.crosshairShowTooltip != crosshairShowTooltip ||
        oldDelegate.crosshairX != crosshairX ||
        oldDelegate.crosshairY != crosshairY ||
        oldDelegate.crosshairBarIdx != crosshairBarIdx ||
        oldDelegate.truncationCheck != truncationCheck;
  }
}
