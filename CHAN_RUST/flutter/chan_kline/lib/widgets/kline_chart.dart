import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compute/k0_combine_compute.dart';
import '../compute/k1_combine_compute.dart';
import '../compute/k1_bar_view_compute.dart';
import '../compute/chart_view_compute.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/kuaduan_compute.dart';
import '../compute/level_unit_bar_view_compute.dart';
import '../history/msg_history.dart';
import '../models/kuaduan_frame.dart';
import '../models/k0_confirm_signal.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/k0_line.dart';
import '../models/k1_bar.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/chart_indicator.dart';
import '../models/kline_combine_frame.dart';
import '../models/bar_feature_lookup.dart';
import '../models/level_models.dart';
import '../models/k1_analysis.dart';
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

/// 主图同级别连线配色（K0连线 + 更高层见 [ChartLevelLineStyle]）。
abstract final class ChartLineColors {
  /// K0连线统一色
  static const bi = Color(0xCC94A3B8);
  /// K1连线（内部 level=2）默认色（与 ChartLevelLineStyle 一致）
  static const seg = Color(0xCCF59E0B);
}

/// K 线图：主图 + 副图（可多指标叠加），支持高度分割拖动。
class KlineChart extends StatefulWidget {
  const KlineChart({
    super.key,
    required this.bars,
    required this.combineFrames,
    required this.k0ConfirmSignals,
    required this.barFeatures,
    required this.k0Lines,
    required this.k1BarViews,
    required this.k1CombineFrames,
    required this.k1Analysis,
    required this.mainIndicators,
    required this.subIndicators,
    this.levels = const [],
    this.defaultK0Policy = 'pending',
    this.truncationCheck = true,
    this.showBuildingDash = true,
    this.judgmentHistoryByKn = const {},
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
  final List<K0ConfirmSignal> k0ConfirmSignals;
  final List<BarCrosshairFeature> barFeatures;
  final List<K0Line> k0Lines;
  final List<K1BarView> k1BarViews;
  final List<KlineCombineFrame> k1CombineFrames;
  final K1AnalysisBundle k1Analysis;

  /// N 段流水线全量输出（十字线 as-of 重绘与 tooltip N 段块查表用）
  final List<LevelBundle> levels;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final String defaultK0Policy;
  /// 截断监察：十字线 as-of 本地重算K1合并时与 Rust 同开关
  final bool truncationCheck;
  /// 构建中/未确认元素虚线开关：开=末组合并框虚线 + K0/K1/KN 构建中连线虚线；关=全部实线（不区分构建中）
  final bool showBuildingDash;
  /// 分型判断会话事件日志（main 步进累积；换股才清空）
  final Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn;
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
  /// 十字线“贴最右端步进”标记：十字线态按→到最右端转步进后，bars 变长，
  /// didUpdateWidget 会重置十字线，故用此标记在重建后把十字线重新吸附到新最右端，
  /// 实现“按住→连续步进”。左移/手动移线即解除（见 _moveCrosshairBy/_updateCrosshairAt）。
  bool _crosshairPinRightmost = false;

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
        k0Lines: widget.k0Lines,
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
    // 全局键盘监听：方向键←/→（十字线态=十字线左右移；非十字线态=步退/步进）
    HardwareKeyboard.instance.addHandler(_handleHardwareKey);
  }

  @override
  void dispose() {
    _middleTapTimer?.cancel();
    _arrowStartTimer?.cancel();
    _arrowRepeatTimer?.cancel();
    _tooltipScroll.dispose();
    HardwareKeyboard.instance.removeHandler(_handleHardwareKey);
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
      // 贴右步进：bars 变长后把十字线吸附到“新最右端”，保持按住→连续步进
      if (_crosshairPinRightmost && _crosshairEnabled && widget.bars.isNotEmpty) {
        _crosshairBarIdx = widget.bars.length - 1;
        _crosshairX = _viewport.barCenterX(_crosshairBarIdx!, _chartSize.width);
        _crosshairY ??= KlineViewport.padT + 40;
      } else {
        _crosshairX = null;
        _crosshairY = null;
        _crosshairBarIdx = null;
      }
    }
  }

  /// 十字线跟随鼠标：竖线吸附 K 线中心，横线跟价格。鼠标移线解除贴右步进标记。
  void _updateCrosshairAt(Offset pos, double plotTop, double contentBottom) {
    _crosshairPinRightmost = false;
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

  /// 键盘方向键“按住连发加速”：单次 keydown 触发一次，按住超过阈值后按加速节奏连发；
  /// 同时吞掉系统自带重复（event.repeat），避免与自管连发叠加成双倍速度。
  static const _arrowStartMs = 300; // 按住多久后开始连发
  static const _arrowSlowMs = 110; // 连发起始间隔
  static const _arrowMidMs = 70; // 加速中段间隔
  static const _arrowFastMs = 40; // 最快间隔（越小越快）
  Timer? _arrowStartTimer; // 等待进入连发的计时
  Timer? _arrowRepeatTimer; // 连发计时
  int _arrowDir = 0; // 当前按住方向：-1 左 / +1 右
  int _arrowRepeatCount = 0; // 连发次数（用于节奏加速）

  /// 键盘方向键交互（HardwareKeyboard 全局监听）：
  /// 十字线激活时 → 左/右方向键移动十字线（竖线吸附相邻 K 线中心）；
  /// 未激活时 → 左=步退、右=步进（与点击左/右热区同义）。
  /// 返回 true 表示已处理（拦截该方向键，避免页面默认滚动等）。
  bool _handleHardwareKey(KeyEvent event) {
    final key = event.logicalKey;
    final isLeft = key == LogicalKeyboardKey.arrowLeft;
    final isRight = key == LogicalKeyboardKey.arrowRight;
    if (!isLeft && !isRight) return false;

    if (event is KeyDownEvent) {
      if (event is KeyRepeatEvent) return true; // 系统自带重复：吞掉，改由自管连发避免双倍
      _startArrowRepeat(isRight ? 1 : -1);
      return true;
    }
    if (event is KeyUpEvent) {
      _stopArrowRepeat();
      return true;
    }
    return false;
  }

  /// 方向键按下：立即触发一次，随后自管加速连发。
  void _startArrowRepeat(int dir) {
    _arrowDir = dir;
    _arrowRepeatCount = 0;
    _fireArrowAction();
    _arrowStartTimer?.cancel();
    _arrowStartTimer = Timer(Duration(milliseconds: _arrowStartMs), _arrowTick);
  }

  void _arrowTick() {
    _arrowRepeatCount++;
    _fireArrowAction();
    final delay = _arrowRepeatCount < 8
        ? _arrowSlowMs
        : (_arrowRepeatCount < 20 ? _arrowMidMs : _arrowFastMs);
    _arrowRepeatTimer = Timer(Duration(milliseconds: delay), _arrowTick);
  }

  /// 十字线是否已吸附到最右端那根 K（再往右无 K 可移）。
  bool _isCrosshairAtRightmost() {
    if (!_crosshairEnabled || _crosshairBarIdx == null || widget.bars.isEmpty) {
      return false;
    }
    return _crosshairBarIdx! >= widget.bars.length - 1;
  }

  /// 执行一次方向键动作：
  /// 十字线态 → 右移到最右端后继续按→转为“步进”（喂入下一根 K，绝步退）；
  ///           左/右非最右端 → 竖线吸附相邻 K；左到最左端已 clamp，永不步退。
  /// 非十字线态 → 左=步退、右=步进（与点击左/右热区同义）。
  /// 重要：十字线态下方向键永不触发步退，仅最右端→可步进。
  void _fireArrowAction() {
    if (!_crosshairEnabled) {
      if (_arrowDir > 0) {
        widget.onTapStepForward?.call();
      } else {
        widget.onTapStepBack?.call();
      }
      return;
    }
    // 十字线态：向右且已到最右端 → 贴右步进（长按连发同理，节奏同见 _arrowTick）
    if (_arrowDir > 0 && _isCrosshairAtRightmost()) {
      _crosshairPinRightmost = true; // 重建后由 didUpdateWidget 吸附新最右端
      widget.onTapStepForward?.call();
      return;
    }
    // 其余情况：左右移线（左移会解除贴右标记）；永不步退
    _moveCrosshairBy(_arrowDir);
  }

  /// 方向键抬起/失焦：停止连发。
  void _stopArrowRepeat() {
    _arrowStartTimer?.cancel();
    _arrowRepeatTimer?.cancel();
    _arrowRepeatTimer = null;
  }

  /// 十字线按方向键左移/右移一格（dir=-1 左 / +1 右），竖线吸附相邻 K 线中心。
  /// 任何手动移线都解除“贴右步进”标记（左移到非最右端即恢复普通移线）。
  void _moveCrosshairBy(int dir) {
    _crosshairPinRightmost = false;
    if (widget.bars.isEmpty || _chartSize.width <= 0) return;
    int barIdx = _crosshairBarIdx ??
        _viewport.barIndexAtCanvasX(
          _crosshairX ?? _chartSize.width / 2,
          _chartSize.width,
          widget.bars.length,
        );
    barIdx = (barIdx + dir).clamp(0, widget.bars.length - 1);
    _crosshairBarIdx = barIdx;
    _crosshairX = _viewport.barCenterX(barIdx, _chartSize.width);
    _crosshairY ??= KlineViewport.padT + 40;
    if (_crosshairShowTooltip) {
      _resetTooltipScrollIfNeeded(barIdx);
    }
    _scheduleRedraw();
  }

  /// 十字线开启时按当步 K 重建K1 bar view，与 bar_features 逐步冻结口径对齐。
  List<K1BarView> get _effectiveK1BarViews {
    if (!_crosshairEnabled || _crosshairBarIdx == null) {
      return widget.k1BarViews;
    }
    final asOfBars = _asOfK1Bars();
    return buildK1BarViews(asOfBars);
  }

  /// 十字线开启时按当步分钟 K 重建K0合并框（与 k0_combine 逐步口径对齐）。
  List<KlineCombineFrame> get _effectiveK0CombineFrames {
    if (!_crosshairEnabled || _crosshairBarIdx == null) {
      return widget.combineFrames;
    }
    final asOf = _crosshairAsOfIdx();
    final barsSlice = widget.bars.where((b) => b.idx <= asOf).toList();
    if (barsSlice.isEmpty) return const [];
    return computeK0CombineFrames(
      barsSlice,
      truncationCheck: widget.truncationCheck,
    );
  }

  /// 十字线开启时按当步K1 bar 重建K1合并框（展示轨：含进行中，与 Rust k1_combine_frames 同构）。
  List<KlineCombineFrame> get _effectiveK1CombineFrames {
    if (!_crosshairEnabled || _crosshairBarIdx == null) {
      return widget.k1CombineFrames;
    }
    final asOf = _crosshairAsOfIdx();
    final barsSlice = widget.bars.where((b) => b.idx <= asOf).toList();
    if (barsSlice.isEmpty) return const [];
    return computeK1CombineFrames(
      barsSlice,
      // 展示轨：冻+进行中；永久结构仍只认冻结
      _asOfK1Bars(includeBuilding: true),
      truncationCheck: widget.truncationCheck,
    );
  }

  int _crosshairAsOfIdx() =>
      widget.bars[_crosshairBarIdx!.clamp(0, widget.bars.length - 1)].idx;

  /// as-of K1 bar 重建：Rust 冻结段 + 可选当步进行中 K0连线。
  List<K1Bar> _asOfK1Bars({bool includeBuilding = true}) {
    return asOfK1Bars(
      bars: widget.bars,
      levels: widget.levels,
      barFeatures: widget.barFeatures,
      defaultK0Policy: widget.defaultK0Policy,
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
      k0Confirms: widget.k0ConfirmSignals,
      barFeatures: widget.barFeatures,
      k0Lines: widget.k0Lines,
      k1Analysis: widget.k1Analysis,
      levels: widget.levels,
      subIndicators: _activeSubs,
      truncationCheck: widget.truncationCheck,
      judgmentHistoryByKn: widget.judgmentHistoryByKn,
      // 与传给 _KlineCompositePainter 的 segAsOf 完全一致：十字线激活时按当步 idx 截断，
      // 使 tooltip 分型判断与副图同源同截断（KlineChart 无 segAsOf 字段，须在此现算）。
      asOf: _crosshairEnabled && _crosshairBarIdx != null
          ? _crosshairAsOfIdx()
          : null,
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
          _crosshairPinRightmost = false;
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
                combineFrames: _effectiveK0CombineFrames,
                k0ConfirmSignals: widget.k0ConfirmSignals,
                barFeatures: widget.barFeatures,
                k0Lines: widget.k0Lines,
                k1BarViews: _effectiveK1BarViews,
                k1CombineFrames: _effectiveK1CombineFrames,
                k1Analysis: widget.k1Analysis,
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
                showBuildingDash: widget.showBuildingDash,
                defaultK0Policy: widget.defaultK0Policy,
                segAsOf: _crosshairEnabled && _crosshairBarIdx != null
                    ? _crosshairAsOfIdx()
                    : null,
                judgmentHistoryByKn: widget.judgmentHistoryByKn,
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
    required this.k0ConfirmSignals,
    required this.barFeatures,
    required this.k0Lines,
    required this.k1BarViews,
    required this.k1CombineFrames,
    required this.k1Analysis,
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
    this.showBuildingDash = true,
    this.defaultK0Policy = 'pending',
    this.segAsOf,
    this.judgmentHistoryByKn = const {},
  }) : featureLookup = BarFeatureLookup.build(
          bars: bars,
          combineFrames: combineFrames,
          k0Confirms: k0ConfirmSignals,
          barFeatures: barFeatures,
          k0Lines: k0Lines,
          k1Analysis: k1Analysis,
          levels: levels,
          subIndicators: subIndicators,
          truncationCheck: truncationCheck,
          judgmentHistoryByKn: judgmentHistoryByKn,
        );

  final List<KlineBar> bars;
  final List<KlineCombineFrame> combineFrames;
  final List<K0ConfirmSignal> k0ConfirmSignals;
  final List<BarCrosshairFeature> barFeatures;
  final List<K0Line> k0Lines;
  final List<K1BarView> k1BarViews;
  final List<KlineCombineFrame> k1CombineFrames;
  final K1AnalysisBundle k1Analysis;
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
  /// 构建中/未确认元素虚线开关：开=末组合并框虚线 + K0/K1/KN 构建中连线虚线；关=全部实线（不区分构建中）
  final bool showBuildingDash;
  /// 与 asOfK1Bars 同构的默认 K0 策略（pending/purged）
  final String defaultK0Policy;
  /// 十字线 as-of 2 段连线截止 K（null=末态全量）
  final int? segAsOf;

  /// 分型判断会话事件日志（步进追加；绘制扫全部历史点）
  final Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn;

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

    // K0 原始蜡烛改为由 KN 的「K0」项独立控制（可关闭/显示），不再是恒显底图；
    // 合并框/连线/各层淡实体均叠加其上。
    final showK0 = mainIndicators.contains(const MainChartIndicator.kn(1));
    if (showK0) {
      _drawCandles(canvas, size.width, plotTop, plotH, barW, slotW);
    }
    if (mainIndicators.isNotEmpty) {
      // 按勾选项逐层画：勾哪层画哪层（不再一项自动叠全部）
      for (final ind in mainIndicators) {
        if (ind.kind == MainIndicatorKind.combine) {
          // 合并与连线统一层号：combine(1)=K0合并，combine(2)=K1合并，combine(>=3)=K(n-1)合并
          // 合并指标只画合并框；淡实体线已拆出到 KN 指标
          if (ind.kn == 1) {
            _drawKlineCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW);
          } else if (ind.kn == 2) {
            _drawK1CombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW);
          } else {
            _drawLevelCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
          }
        } else if (ind.kind == MainIndicatorKind.kn) {
          // KN 线（由 KN合并 拆出）按层独立：kn(1)=K0 实体由顶层 showK0 绘制；
          // kn(2)=K1 淡蜡烛；kn(>=3)=K(n-1) 单元淡蜡烛。各层独立开关、与对应合并框对齐。
          if (ind.kn == 2) {
            _drawK1Candles(
                canvas, size.width, plotTop, plotH, barW, slotW, faint: true);
          } else if (ind.kn >= 3) {
            _drawLevelUnitCandlesOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
          }
          // ind.kn == 1 的 K0 实体由顶层 showK0 统一绘制，避免重复
        } else if (ind.kind == MainIndicatorKind.line) {
          // 内部 kn：1=K0连线→展示 K0连线；≥2→展示 K(kn-1)连线
          if (ind.kn == 1) {
            _drawK0Lines(canvas, size.width, plotTop, plotH, slotW);
          } else {
            _drawK1LinesForLevel(
                canvas, size.width, plotTop, plotH, slotW, ind.kn);
          }
        } else if (ind.kind == MainIndicatorKind.kuaduan) {
          // 跨段中枢框：与合并/连线同号，kuaduan(n)=K(n-1)跨段中枢（K0跨段中枢）
          _drawKuaduanOnMainChart(
              canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
        } else if (ind.kind == MainIndicatorKind.zs) {
          // 原生中枢框：与合并/连线/跨段中枢同号，zs(n)=K(n-1)原生中枢（K0原生中枢）
          _drawZSOnMainChart(
              canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
        } else if (ind.kind == MainIndicatorKind.bsp) {
          // 三类买卖点：与合并/连线/跨段中枢/原生中枢同号，bsp(n)=K(n-1)买卖点（K0买卖点）
          _drawBSPOnMainChart(
              canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
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
      // 副图指标当前值：不画在折线/打点上，十字线激活时在副图右上角固定读数；
      // 含分型确认/判断/极点距/截断（与副图折线、主 tooltip 同源同口径）
      _drawSubCrosshairReadout(canvas, size.width);
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

  /// 线框横向：合并 K 中轴口径 + K1合并框半侧锚定（与K1 bar [_k1BarHSpan] 同逻辑）。
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

  /// K1 bar 横向：衔接 K 左/右半侧锚定，避免相邻K0连线在中轴处留空。
  (double left, double right) _k1BarHSpan(
    K1BarView v,
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

  /// 按 frame.x1 + count 精确取合并框内含的K1 bar view（避免衔接 K 误入下一框）。
  List<K1BarView> _k1ViewsForCombineFrame(KlineCombineFrame f) {
    final startIdx = k1BarViews.indexWhere((v) => v.viewX1 == f.x1);
    if (startIdx >= 0 && f.count > 0) {
      final endIdx = math.min(startIdx + f.count, k1BarViews.length);
      if (endIdx > startIdx) {
        return k1BarViews.sublist(startIdx, endIdx);
      }
    }
    return k1BarViews
        .where((v) => v.viewX1 >= f.x1 && v.viewX2 <= f.x2)
        .toList();
  }

  /// 合并框外线框横向：与 [_combineFrameSpan] 同构——单元换K1 bar view，首尾 view 中轴起止。
  /// count>1：纯中轴（同合并 K 对 1 分钟 K）；count==1：半侧与 [_k1BarHSpan] 一致。
  (double left, double right) _k1CombineFrameSpan(
    KlineCombineFrame f,
    double w,
    double slotW,
    double barW,
  ) {
    final related = _k1ViewsForCombineFrame(f);
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

  /// K1 bar（展示层 view 区间）：横向 [_k1BarHSpan]，与K1合并框 [_k1CombineFrameSpan] 同口径。
  void _drawK1Candles(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW, {
    bool faint = false,
  }) {
    if (k1BarViews.isEmpty) return;

    // faint：主图K1合并底层，低不透明度以免压住 1 分钟 K
    final upBody = faint ? const Color(0x38E53935) : const Color(0x88E53935);
    final dnBody = faint ? const Color(0x3826A69A) : const Color(0x8826A69A);
    final upStroke = faint ? const Color(0x55E53935) : const Color(0xFFE53935);
    final dnStroke = faint ? const Color(0x5526A69A) : const Color(0xFF26A69A);

    for (final v in k1BarViews) {
      if (v.viewX2 < viewport.viewXMin - 1 || v.viewX1 > viewport.viewXMax + 1) {
        continue;
      }

      final (left, right) = _k1BarHSpan(v, w, slotW, barW);
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

  void _drawK0Lines(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
  ) {
    if (k0Lines.isEmpty && k0ConfirmSignals.isEmpty) return;

    // 十字线 as-of：只展示已确认且 <= asOf 的 K0连线，与 K1 逐K当下冻结口径对齐
    final asOf = segAsOf;
    final segs = (asOf == null)
        ? k0Lines
        : k0Lines.where((s) => s.endConfirmX <= asOf).toList();

    final paint = Paint()
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;

    for (final seg in segs) {
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
          _k0LineEndpoint(seg, isBegin: true, w: w, slotW: slotW);
      final (endX, endPrice) =
          _k0LineEndpoint(seg, isBegin: false, w: w, slotW: slotW);
      final y1 = priceRange.yOf(beginPrice, plotTop, plotH);
      final y2 = priceRange.yOf(endPrice, plotTop, plotH);
      paint.color = seg.isBootstrap
          ? ChartLineColors.bi.withValues(alpha: 0.55)
          : ChartLineColors.bi;
      canvas.drawLine(Offset(beginX, y1), Offset(endX, y2), paint);
    }

    _drawBuildingK0Line(canvas, w, plotTop, plotH, slotW);
  }

  /// K0 构建中虚线：动态 K1 bar（asOfK1Bars）当确认段画虚线；确认纠正/改实线。
  void _drawBuildingK0Line(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final tailIdx = asOf ?? bars.last.idx;
    if (tailIdx < 0 || tailIdx >= bars.length) return;

    // 与动态合并同输入：冻+进行中虚拟单元
    final virtualUnits = asOfK1Bars(
      bars: bars,
      levels: levels,
      barFeatures: barFeatures,
      defaultK0Policy: defaultK0Policy,
      asOf: tailIdx,
      includeBuilding: true,
    );
    final frozenIdx = <int>{
      for (final s in asOfLevelSegments(
        levels: levels,
        level: 1,
        asOf: tailIdx,
      ))
        s.idx,
    };
    final liveJudgments = collectFractalJudgmentEvents(
      kn: 1,
      bars: bars,
      levels: levels,
      barFeatures: barFeatures,
      asOf: tailIdx,
      truncationCheck: truncationCheck,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: tailIdx,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      k0Confirms: k0ConfirmSignals,
      liveJudgments: liveJudgments,
    );
    // 历史记录调试摘要（内容变才追加，便于复制排查）
    MsgHistory.instance.appendDisplayBuildingLinesRuntime(
      kn: 1,
      asOf: tailIdx,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      lines: lines,
      liveJudgments: liveJudgments,
    );
    _paintDisplayBuildingLines(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      lines: lines,
      style: null,
    );
  }

  /// K0连线端点：引导K0连线起点走分型框极值；其余严格匹配K0连线确认信号。
  (double, double) _k0LineEndpoint(
    K0Line seg, {
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
    final conf = _k0ConfirmAt(confirmX, fx1, fx2);
    if (conf != null) {
      return _k0ExtremeAnchorPoint(
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

  /// 分型框内极点 K 锚点（无K0连线确认信号时用，如引导K0连线虚拟起点）。
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

  /// 按确认步 + 分型框严格匹配K0连线确认信号（禁止仅按 x 退化匹配，避免引导K0连线起终点重合）。
  K0ConfirmSignal? _k0ConfirmAt(int confirmX, int fractalX1, int fractalX2) {
    for (final c in k0ConfirmSignals) {
      if (c.x == confirmX &&
          c.fractalX1 == fractalX1 &&
          c.fractalX2 == fractalX2) {
        return c;
      }
    }
    return null;
  }

  /// K0连线端点：极点 K 中轴 + 极点价（与 K线分型极点距同口径，仅展示用）。
  (double, double) _k0ExtremeAnchorPoint(
    K0ConfirmSignal? conf,
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
  void _drawK1LinesForLevel(
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
    // 回退：仅 K2 且无 levels 时用旧 k1Analysis
    if (kn != 2) return;
    final style = ChartLevelLineStyle.forLevel(2);
    final paint = Paint()
      ..color = style.color
      ..strokeWidth = style.strokeWidth
      ..style = PaintingStyle.stroke;
    for (final seg in k1Analysis.k1Lines) {
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
        useLegacyK1Analysis: true,
      );
    }
  }

  /// 主图 Kn 合并（kn≥2）：只描该层**展示轨**合并框（冻+进行中）；淡实体线已拆出到 KN 指标。
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

    final asOf = segAsOf;
    final barsForCombine =
        asOf != null ? bars.where((b) => b.idx <= asOf).toList() : bars;
    final virtualUnits = asOf != null
        ? asOfLevelVirtualK1Bars(
            levels: levels,
            barFeatures: barFeatures,
            level: kn,
            asOf: asOf,
            includeBuilding: true,
          )
        : levelBundleVirtualK1Bars(bundle);

    if (virtualUnits.isEmpty &&
        bundle.unitBars.isEmpty &&
        bundle.activeUnit == null &&
        bundle.pendingUnit == null) {
      return;
    }

    // 单元 view 仅用于合并框横向对齐（不再在此画淡实体；淡实体由 KN 指标统一控制）
    final views = _levelUnitViewsForLevel(kn);

    // 展示轨合并框：不画永久 combineFrames，改由虚拟单元重算
    if (virtualUnits.isEmpty || barsForCombine.isEmpty) return;
    final displayFrames = computeK1CombineFrames(
      barsForCombine,
      virtualUnits,
      truncationCheck: truncationCheck,
    );
    if (displayFrames.isEmpty) return;

    final style = ChartLevelLineStyle.forLevel(kn);
    _drawCombineFramesOnMainChart(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      displayFrames,
      style.color.withValues(alpha: 0.85),
      style.color.withValues(alpha: 0.08),
      levelUnitViews: views.isNotEmpty ? views : null,
      lastAsBuilding: showBuildingDash,
      buildingDashPattern: style.buildingDashPattern,
    );
  }

  /// 取某层（kn≥2）的单元 view（用于合并框横向对齐 / KN 指标画淡实体），含十字线 as-of 重算。
  List<LevelUnitBarView> _levelUnitViewsForLevel(int kn) {
    LevelBundle? bundle;
    for (final b in levels) {
      if (b.level == kn) {
        bundle = b;
        break;
      }
    }
    if (bundle == null) return const [];
    final asOf = segAsOf;
    final virtualUnits = asOf != null
        ? asOfLevelVirtualK1Bars(
            levels: levels,
            barFeatures: barFeatures,
            level: kn,
            asOf: asOf,
            includeBuilding: true,
          )
        : levelBundleVirtualK1Bars(bundle);
    if (virtualUnits.isEmpty &&
        bundle.unitBars.isEmpty &&
        bundle.activeUnit == null &&
        bundle.pendingUnit == null) {
      return const [];
    }
    if (asOf != null) {
      return _levelUnitViewsFromVirtualK1Bars(
        virtualUnits,
        frozenIdx: {
          for (final s in asOfLevelSegments(
            levels: levels,
            level: kn,
            asOf: asOf,
          ))
            s.idx,
        },
      );
    } else {
      return buildLevelUnitBarViews(
        bundle.unitBars,
        activeUnit: bundle.activeUnit ??
            (bundle.segmentPolicy == 'pending' ? bundle.pendingUnit : null),
      );
    }
  }

  /// KN 指标用的单层淡实体蜡烛（原内嵌于 KN合并；拆出后由 KN 指标统一控制）。
  void _drawLevelUnitCandlesOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
    int kn,
  ) {
    final views = _levelUnitViewsForLevel(kn);
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
  }

  /// 虚拟 K1 bar → LevelUnitBarView（冻在 unitBars，未冻当 active）。
  List<LevelUnitBarView> _levelUnitViewsFromVirtualK1Bars(
    List<K1Bar> units, {
    required Set<int> frozenIdx,
  }) {
    if (units.isEmpty) return const [];
    final frozenBars = <LevelUnitBar>[];
    LevelUnitBar? active;
    for (final u in units) {
      final bar = LevelUnitBar(
        idx: u.idx,
        dir: u.dir,
        x1: u.x1,
        x2: u.x2,
        open: u.open,
        high: u.high,
        low: u.low,
        close: u.close,
        confirmX: u.confirmX,
      );
      if (frozenIdx.contains(u.idx)) {
        frozenBars.add(bar);
      } else {
        active = bar;
      }
    }
    return buildLevelUnitBarViews(frozenBars, activeUnit: active);
  }

  /// 主图跨段中枢框：复用合并框横向 [_combineFrameHSpan]，按层号取该层段序列产出的 KuaDuanFrame，
  /// 画 ZD/ZG 半透明框 + 「K(n-1)跨段中枢{序号}·段数」标签。与合并框同层号、同色系。
  /// 十字线 as-of：只认已冻结段本地重算；关十字线用 Rust 末态框。
  void _drawKuaduanOnMainChart(
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
    final List<KuaDuanFrame> frames;
    if (segAsOf != null) {
      // as-of：只喂 endConfirmX<=asOf 的已冻结段，重跑松重叠吸收器
      final segs = asOfLevelSegments(
        levels: levels,
        level: kn,
        asOf: segAsOf!,
      );
      frames = computeKuaduanFrames(segs, kn);
    } else {
      frames = bundle.kuaduanFrames;
    }
    if (frames.isEmpty) return;

    final style = ChartLevelLineStyle.forLevel(kn);
    final stroke = Paint()
      ..color = style.color.withValues(alpha: 0.9)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = style.color.withValues(alpha: 0.12);
    final labelStyle = TextStyle(
      color: style.color.withValues(alpha: 0.95),
      fontSize: 9,
    );

    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f.x2 < viewport.viewXMin - 1 || f.x1 > viewport.viewXMax + 1) {
        continue;
      }
      final (xLeft, xRight) = _combineFrameHSpan(f.x1, f.x2, w, slotW, barW);
      final yHigh = priceRange.yOf(f.high, plotTop, plotH); // ZD 上沿
      final yLow = priceRange.yOf(f.low, plotTop, plotH); // ZG 下沿
      final top = math.min(yHigh, yLow);
      final bottom = math.max(yHigh, yLow);
      final rect = Rect.fromLTRB(
        math.min(xLeft, xRight),
        top,
        math.max(xLeft, xRight),
        bottom,
      );
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, stroke);

      // 序号优先用 Rust seq（1-based）；缺省时用列表下标兜底
      final seq = f.seq > 0 ? f.seq : (i + 1);
      final tp = TextPainter(
        text: TextSpan(
          text: 'K${kn - 1}跨段中枢$seq·${f.count}',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left + 2, rect.top + 1));
    }
  }

  /// 主图原生中枢框：复用合并框横向 [_combineFrameHSpan]，直接用 Rust 逐K末态产出的 ZSFrame
  /// （pipeline export 每步都基于冻结段重算 zs_frames，已是「as-of 冻结」版本，无需 Dart 本地重算），
  /// 画 ZD/ZG 半透明框 + 「K(n-1)原生中枢{序号}·段数」标签，九段升级追加标记。与跨段中枢同层号、独立色系。
  void _drawZSOnMainChart(
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
    // 原生中枢直接消费 Rust 末态框（逐K已重算），不做本地重算
    final frames = bundle.zsFrames;
    if (frames.isEmpty) return;

    final style = ChartLevelLineStyle.forZS(kn);
    final stroke = Paint()
      ..color = style.color.withValues(alpha: 0.9)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final fill = Paint()..color = style.color.withValues(alpha: 0.12);
    final labelStyle = TextStyle(
      color: style.color.withValues(alpha: 0.95),
      fontSize: 9,
    );

    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f.x2 < viewport.viewXMin - 1 || f.x1 > viewport.viewXMax + 1) {
        continue;
      }
      final (xLeft, xRight) = _combineFrameHSpan(f.x1, f.x2, w, slotW, barW);
      final yHigh = priceRange.yOf(f.high, plotTop, plotH); // ZD 上沿
      final yLow = priceRange.yOf(f.low, plotTop, plotH); // ZG 下沿
      final top = math.min(yHigh, yLow);
      final bottom = math.max(yHigh, yLow);

      final rect = Rect.fromLTRB(
        math.min(xLeft, xRight),
        top,
        math.max(xLeft, xRight),
        bottom,
      );
      canvas.drawRect(rect, fill);
      canvas.drawRect(rect, stroke);

      // 序号优先用 Rust seq（1-based）；缺省时用列表下标兜底
      final seq = f.seq > 0 ? f.seq : (i + 1);
      final dirMark = f.dir > 0 ? '↑' : (f.dir < 0 ? '↓' : '');
      final upgradeMark = f.isNineSegUpgrade ? '·9段升级' : '';
      final tp = TextPainter(
        text: TextSpan(
          text: 'K${kn - 1}原生中枢$seq·${f.count}$dirMark$upgradeMark',
          style: labelStyle,
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(rect.left + 2, rect.top + 1));
    }
  }

  /// 主图三类买卖点：直接在 Rust 末态 `bsp_frames` 上画点标记（不做 Dart 本地重算）。
  /// 买=红、卖=绿（涨红跌绿）；类用不同形状：一类圆、二类三角、三类菱形，并在旁标注「买N/卖N」与价位。
  /// 与合并/连线/跨段中枢/原生中枢同层号。
  void _drawBSPOnMainChart(
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
    final frames = bundle.bspFrames;
    if (frames.isEmpty) return;

    const markerR = 4.5;
    const labelStyle = TextStyle(fontSize: 9, fontWeight: FontWeight.w600);
    for (final f in frames) {
      if (f.x < viewport.viewXMin - 1 || f.x > viewport.viewXMax + 1) {
        continue;
      }
      final cx = _barCenterX(f.x, w, slotW);
      final cy = priceRange.yOf(f.price, plotTop, plotH);
      final color = ChartLevelLineStyle.forBSP(f.cls, f.isBuy);
      // 标签：买N/卖N + 价位，放点位右上方避免压住 K 线
      final tag = '${f.isBuy ? "买" : "卖"}${f.cls}';
      final tp = TextPainter(
        text: TextSpan(
          text: '$tag ${f.price.toStringAsFixed(2)}',
          style: labelStyle.copyWith(color: color),
        ),
        textDirection: TextDirection.ltr,
      )..layout();

      final fill = Paint()..color = color;
      final stroke = Paint()
        ..color = Colors.black.withValues(alpha: 0.55)
        ..strokeWidth = 1.0;
      final c = Offset(cx, cy);
      switch (f.cls) {
        case 1:
          // 一类：实心圆
          canvas.drawCircle(c, markerR, fill);
          canvas.drawCircle(c, markerR, stroke);
          break;
        case 2:
          // 二类：实心三角（买卖决定朝向）
          _drawTriangle(canvas, c, markerR + 0.5, f.isBuy, fill, stroke);
          break;
        default:
          // 三类：实心菱形
          _drawDiamond(canvas, c, markerR + 0.5, fill, stroke);
          break;
      }

      tp.paint(canvas, Offset(cx + markerR + 2, cy - tp.height - 1));
    }
  }

  /// 画向上/向下实心三角（买卖点二类标记）。
  void _drawTriangle(
    Canvas canvas,
    Offset c,
    double r,
    bool isUp,
    Paint fill,
    Paint stroke,
  ) {
    final dy = isUp ? -r : r;
    final path = Path()
      ..moveTo(c.dx, c.dy + dy)
      ..lineTo(c.dx - r, c.dy - dy)
      ..lineTo(c.dx + r, c.dy - dy)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  /// 画实心菱形（买卖点三类标记）。
  void _drawDiamond(Canvas canvas, Offset c, double r, Paint fill, Paint stroke) {
    final path = Path()
      ..moveTo(c.dx, c.dy - r)
      ..lineTo(c.dx + r, c.dy)
      ..lineTo(c.dx, c.dy + r)
      ..lineTo(c.dx - r, c.dy)
      ..close();
    canvas.drawPath(path, fill);
    canvas.drawPath(path, stroke);
  }

  /// Kn 单元线（淡色底层，仿K1 bar [_drawK1Candles]）。
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

  /// Kn 单元线横向半侧锚定（同 [_k1BarHSpan]）。
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

  /// 按 frame.x1 + count 取层内单元 view（仿 [_k1ViewsForCombineFrame]）。
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

  /// Kn 合并框横向：有单元 view 时对齐半侧衔接（同 [_k1CombineFrameSpan]）。
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
        useLegacyK1Analysis: false,
      );
    }
  }

  /// 按层级样式画K1连线（实线或 pattern 虚线）。
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

  /// 构建中 N 段虚线：动态 KN 虚拟单元当确认段画虚线（确认纠正/改实线；全层同构）。
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
    required bool useLegacyK1Analysis,
  }) {
    if (bars.isEmpty || tailIdx < 0 || tailIdx >= bars.length) return;

    List<LevelConfirm> levelConfirms = confirms;
    if (useLegacyK1Analysis && confirms.isEmpty) {
      levelConfirms = [
        for (final c in k1Analysis.k1Confirms)
          if (c.x <= tailIdx && (c.fx == 'TOP' || c.fx == 'BOTTOM'))
            LevelConfirm(
              x: c.x,
              fx: c.fx,
              value: c.value,
              fractalX1: c.fractalX1,
              fractalX2: c.fractalX2,
              fractalHigh: c.fractalHigh,
              fractalLow: c.fractalLow,
            ),
      ];
    }

    // 与动态 KN 合并框同输入
    final List<K1Bar> virtualUnits;
    final Set<int> frozenIdx;
    if (useLegacyK1Analysis) {
      // 旧 K1Analysis 回退：无 levels 时用已确认 k1Lines 当冻 + 无进行中则无虚线单元
      virtualUnits = [
        for (final seg in k1Analysis.k1Lines)
          if (seg.endX <= tailIdx)
            K1Bar(
              idx: seg.idx,
              dir: seg.dir,
              x1: seg.beginX < seg.endX ? seg.beginX : seg.endX,
              x2: seg.beginX > seg.endX ? seg.beginX : seg.endX,
              open: seg.beginPrice,
              high: math.max(seg.beginPrice, seg.endPrice),
              low: math.min(seg.beginPrice, seg.endPrice),
              close: seg.endPrice,
              confirmX: seg.endX,
            ),
      ];
      // 旧路径无进行中动态单元：全部当冻结，虚线跳过（实线已画）
      frozenIdx = {for (final u in virtualUnits) u.idx};
    } else {
      virtualUnits = asOfLevelVirtualK1Bars(
        levels: levels,
        barFeatures: barFeatures,
        level: level,
        asOf: tailIdx,
        includeBuilding: true,
      );
      frozenIdx = {
        for (final s in asOfLevelSegments(
          levels: levels,
          level: level,
          asOf: tailIdx,
        ))
          s.idx,
      };
    }

    final liveJudgments = collectFractalJudgmentEvents(
      kn: level,
      bars: bars,
      levels: levels,
      barFeatures: barFeatures,
      asOf: tailIdx,
      truncationCheck: truncationCheck,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: tailIdx,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      levelConfirms: levelConfirms,
      liveJudgments: liveJudgments,
    );
    MsgHistory.instance.appendDisplayBuildingLinesRuntime(
      kn: level,
      asOf: tailIdx,
      virtualUnits: virtualUnits,
      frozenIdx: frozenIdx,
      lines: lines,
      liveJudgments: liveJudgments,
    );
    _paintDisplayBuildingLines(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      lines: lines,
      style: style,
    );
  }

  /// 绘制展示轨构建中虚线列表（style=null 时用 K0 连线色）。
  void _paintDisplayBuildingLines(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required List<DisplayBuildingLine> lines,
    required ChartLevelLineStyle? style,
  }) {
    for (final line in lines) {
      final geomMin = math.min(line.begin.barIdx, line.end.barIdx);
      final geomMax = math.max(line.begin.barIdx, line.end.barIdx);
      if (geomMax < viewport.viewXMin - 1 || geomMin > viewport.viewXMax + 1) {
        continue;
      }
      final a = Offset(
        _barCenterX(line.begin.barIdx, w, slotW),
        priceRange.yOf(line.begin.price, plotTop, plotH),
      );
      final b = Offset(
        _barCenterX(line.end.barIdx, w, slotW),
        priceRange.yOf(line.end.price, plotTop, plotH),
      );
      if (style != null) {
        final paint = Paint()
          ..color = style.color
          ..strokeWidth = style.buildingStrokeWidth
          ..style = PaintingStyle.stroke;
        // asSolid：判断↔判断定格/确认段 → 实线；其余受虚线开关控制
        final useDash = showBuildingDash && !line.asSolid;
        _drawStyledSegmentLine(
          canvas,
          a,
          b,
          paint,
          style,
          building: useDash,
        );
      } else {
        final paint = Paint()
          ..color = ChartLineColors.bi.withValues(alpha: 0.45)
          ..strokeWidth = 1.4
          ..style = PaintingStyle.stroke;
        final useDash = showBuildingDash && !line.asSolid;
        if (useDash) {
          _drawDashedLine(canvas, a, b, paint);
        } else {
          canvas.drawLine(a, b, paint);
        }
      }
    }
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
      // 十字线激活时，按当步截断：右侧(idx>segAsOf)的 K0 蜡烛不绘制，与 K1/K2/.../Kn 各层一致
      final asOf = segAsOf;
      if (asOf != null && idx > asOf) continue;
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

  /// 主图 K0合并：只描 K0合并框（K0 原始蜡烛已由底图始终绘制，不再在此附带）。
  void _drawKlineCombineOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
  ) {
    if (combineFrames.isEmpty) return;
    // 末组=构建中合并（虚线）；前组=已冻结合并（实线）。
    // 信号取 CombineEngine.groups 末项（已在 combineFrames 末尾），不是 activeUnit（那是进行中段）。
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
      lastAsBuilding: showBuildingDash,
      buildingDashPattern:
          ChartLevelLineStyle.forLevel(1).buildingDashPattern,
    );
  }

  /// 主图 K线合并 / K1合并线框：按真实价格坐标叠加。
  /// [lastAsBuilding]=true 时：末框虚线（构建中合并），前框实线（已冻结）；虚线框不画顶/底标签。
  /// 口径：CombineEngine 末组仍可继续 absorb，即「构建中合并框」；与构建中连线同「虚线=未确认」。
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
    bool alignK1CombineWithViews = false,
    List<LevelUnitBarView>? levelUnitViews,
    bool lastAsBuilding = false,
    List<double> buildingDashPattern = const <double>[5, 4],
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

    final last = frames.length - 1;
    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f.x2 < viewport.viewXMin - 1 || f.x1 > viewport.viewXMax + 1) {
        continue;
      }

      final (xLeft, xRight) = alignK1CombineWithViews
          ? _k1CombineFrameSpan(f, w, slotW, barW)
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
      // 末组虚线=构建中；其余实线=已冻结（可标顶/底）
      final building = lastAsBuilding && i == last;
      if (building) {
        _strokeDashedRect(canvas, rect, framePaint, buildingDashPattern);
      } else {
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
  }

  /// 主图K1合并：只描K1合并框（淡K1 bar 实体已拆出到 KN 指标统一控制）。
  void _drawK1CombineOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
  ) {
    if (k1CombineFrames.isEmpty && k1BarViews.isEmpty) return;

    if (k1CombineFrames.isNotEmpty) {
      _drawCombineFramesOnMainChart(
        canvas,
        w,
        plotTop,
        plotH,
        barW,
        slotW,
        k1CombineFrames,
        const Color(0xAAF59E0B),
        const Color(0x0CF59E0B),
        alignK1CombineWithViews: true,
        // 末组=构建中合并（虚线）；前组=已冻结合并（实线）；showBuildingDash 关则全实线
        lastAsBuilding: showBuildingDash,
        buildingDashPattern:
            ChartLevelLineStyle.forLevel(2).buildingDashPattern,
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
    // 分型判断：确认式打点（成立当步）；半透明空心，可与确认叠画
    final judgmentKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.fractalJudgment)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (var i = 0; i < judgmentKns.length; i++) {
      _drawKnFractalJudgmentSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        judgmentKns[i],
        stackRank: i,
        stackCount: judgmentKns.length,
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
    final asOf = segAsOf;
    for (var i = 0; i < bars.length; i++) {
      final idx = bars[i].idx;
      // 十字线激活时，按当步截断：右侧(idx>asOf)的成交量不绘制，与 K0 蜡烛/K1../Kn 各层一致
      if (asOf != null && idx > asOf) continue;
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
    final level = labelKn;
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
    // 回退：K0 层（kn=1，无 LevelBundle）用旧 k0_confirms
    if (labelKn == 1) {
      for (final s in k0ConfirmSignals) {
        paintPoint(s.x, s.value);
      }
    }
  }

  /// 副图 Kn 分型判断：展示轨确认式打点（成立当步；半透明空心；扫会话历史事件）。
  void _drawKnFractalJudgmentSubChart(
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
    if (bars.isEmpty || labelKn < 1) return;
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final y0 = subY(0);
    final shape = confirmMarkerShapeForKn(labelKn);
    final dx = confirmStackOffsetX(
      rank: stackRank,
      count: stackCount,
      barW: barW,
    );

    final history = judgmentHistoryByKn[labelKn] ?? const <FractalJudgmentEvent>[];
    final maxX = segAsOf ?? bars.last.idx;
    // 直接扫事件列表：每个曾经出现过的点都画，不经 Map-by-x 折叠成「只剩末点」
    for (final e in history) {
      if (e.x < 0 || e.x > maxX) continue;
      final value = fxToSigned(e.fx);
      if (value == 0) continue;
      if (e.x < viewport.viewXMin - 1 || e.x > viewport.viewXMax + 1) continue;
      final cx = _barCenterX(e.x, w, slotW) + dx;
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
        fillAlpha: 0.45,
        hollow: true,
      );
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
    final level = labelKn;

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
      color = ChartLevelLineStyle.forLevel(level).color;
    } else if (labelKn == 1 && barFeatures.isNotEmpty) {
      // 回退：K0 层（kn=1，无 LevelBundle）用旧 bi 极点距
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
    final level = labelKn;
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
    // 回退：K0 层（kn=1，无 LevelBundle）用旧 k0_confirms
    if (labelKn == 1) {
      for (final s in k0ConfirmSignals) {
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

    canvas.drawLine(Offset(x, plotTop), Offset(x, contentBottom), paint);
    canvas.drawLine(
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

  /// 十字线激活时：副图右上角固定显示已勾选副图指标的当前值。
  /// 原仅显示极点距，现扩展到分型确认/判断/截断（与副图折线打点、主 tooltip 同源同口径）。
  /// 展示名用 SubIndicatorKind.label（比层号小 1，与全 UI 同口径）。
  void _drawSubCrosshairReadout(Canvas canvas, double w) {
    if (crosshairBarIdx == null || bars.isEmpty || subIndicators.isEmpty) {
      return;
    }
    final barX = bars[crosshairBarIdx!.clamp(0, bars.length - 1)].idx;
    final parts = <String>[];
    for (final ind in subIndicators) {
      // 成交量数值大且已有独立副图坐标轴，不进紧凑读数框
      if (ind.kind == SubIndicatorKind.volume) continue;
      // 与主 tooltip 对齐：每个已勾选指标都显示，其值为 tooltip 当步值；
      // tooltip 未取到的（无值/空闲）按 "0" 显示，避免读数框随 K 跳进跳出。
      final rows = featureLookup.crosshairSubRows(barX, {ind});
      final value = rows.isNotEmpty ? rows.first.value : '0';
      parts.add('${ind.label}:$value');
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
    canvas.drawRRect(RRect.fromRectAndRadius(rect, const Radius.circular(3)), bg);
    canvas.drawRRect(
      RRect.fromRectAndRadius(rect, const Radius.circular(3)),
      border,
    );
    tp.paint(canvas, Offset(lx + pad, ly + pad / 2));
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
    if (total <= 0 || !total.isFinite) return;
    final dir = (b - a) / total;
    var dist = 0.0;
    var patIdx = 0;
    // 硬上限：防止异常坐标导致虚线循环卡死 UI
    final maxIter = (total / 0.5).ceil().clamp(1, 100000) + pattern.length;
    var iter = 0;
    while (dist < total && iter < maxIter) {
      iter++;
      final segLen = pattern[patIdx % pattern.length];
      // segLen<=0 会死循环卡死 UI（白屏），强制前进
      final step = segLen > 0 ? segLen : 1.0;
      final next = math.min(dist + step, total);
      if (patIdx % 2 == 0 && segLen > 0) {
        canvas.drawLine(a + dir * dist, a + dir * next, paint);
      }
      dist = next;
      patIdx++;
    }
  }

  void _drawDashedLine(Canvas canvas, Offset a, Offset b, Paint paint) {
    _drawPatternLine(canvas, a, b, paint, const [4, 4]);
  }

  /// 虚线矩形描边（构建中合并框用）：四边各画一段 pattern 虚线。
  void _strokeDashedRect(
    Canvas canvas,
    Rect rect,
    Paint paint,
    List<double> pattern,
  ) {
    _drawPatternLine(
        canvas, Offset(rect.left, rect.top), Offset(rect.right, rect.top), paint, pattern);
    _drawPatternLine(
        canvas, Offset(rect.right, rect.top), Offset(rect.right, rect.bottom), paint, pattern);
    _drawPatternLine(canvas, Offset(rect.right, rect.bottom),
        Offset(rect.left, rect.bottom), paint, pattern);
    _drawPatternLine(canvas, Offset(rect.left, rect.bottom),
        Offset(rect.left, rect.top), paint, pattern);
  }

  @override
  bool shouldRepaint(covariant _KlineCompositePainter oldDelegate) {
    return oldDelegate.bars != bars ||
        oldDelegate.combineFrames != combineFrames ||
        oldDelegate.k0ConfirmSignals != k0ConfirmSignals ||
        oldDelegate.barFeatures != barFeatures ||
        oldDelegate.k0Lines != k0Lines ||
        oldDelegate.k1BarViews != k1BarViews ||
        oldDelegate.k1CombineFrames != k1CombineFrames ||
        oldDelegate.k1Analysis != k1Analysis ||
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
        oldDelegate.truncationCheck != truncationCheck ||
        oldDelegate.showBuildingDash != showBuildingDash ||
        oldDelegate.defaultK0Policy != defaultK0Policy ||
        oldDelegate.judgmentHistoryByKn != judgmentHistoryByKn;
  }
}
