import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../backtest/order_models.dart';
import '../backtest/signal_event.dart';
import '../backtest/strategy_signal_painter.dart';
import '../compute/k0_combine_compute.dart';
import '../compute/k1_combine_compute.dart';
import '../compute/k1_bar_view_compute.dart';
import '../compute/chart_view_compute.dart';
import '../compute/fractal_judgment_compute.dart';
import '../compute/zs_signal_compute.dart';
import '../compute/class1_bs_compute.dart';
import '../compute/class2_bs_compute.dart';
import '../compute/class_n_bs_compute.dart';
import '../compute/bs_verdict_compute.dart';
import '../compute/kn_volume_series_compute.dart';
import '../compute/adjacent_ratio_compute.dart';
import '../compute/line_slope_compute.dart';
import '../compute/fx_extend_line_compute.dart';
import '../compute/trend_line_compute.dart';
import '../compute/trend_model_compute.dart';
import '../compute/math_classic_compute.dart';
import '../compute/demark_compute.dart';
import '../compute/divergence_compute.dart';
import '../compute/divergence_freeze_store.dart';
import '../compute/math_series_freeze_store.dart';
import '../compute/step_rhythm_compute.dart';
import '../models/divergence_algo.dart';
import '../models/math_indicator_config.dart';
import '../compute/level_unit_bar_view_compute.dart';
import '../compute/zs_compute.dart';
import '../compute/chip_profile_compute.dart';
import '../compute/tick_dist_profile_compute.dart';
import '../compute/profile_peak_classify.dart';
import '../history/msg_history.dart';
import '../bridge/chan_bridge.dart';
import '../models/kline_combine_bundle.dart';
import '../models/zs_frame.dart';
import '../models/buy1_frame.dart';
import '../models/sell1_frame.dart';
import '../models/buy2_frame.dart';
import '../models/sell2_frame.dart';
import '../models/buy_n_frame.dart';
import '../models/sell_n_frame.dart';
import '../models/bs_verdict_frame.dart';
import '../models/k0_confirm_signal.dart';
import '../models/bar_crosshair_feature.dart';
import '../models/k0_line.dart';
import '../models/k1_bar.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/chart_indicator.dart';
import '../models/chip_config.dart';
import '../models/tick_dist_config.dart';
import '../models/kline_combine_frame.dart';
import '../models/bar_feature_lookup.dart';
import '../models/incremental_lookup.dart';
import '../models/level_models.dart';
import '../models/k1_analysis.dart';
import 'chart_level_line_style.dart';
import 'crosshair_tooltip_panel.dart';
import 'fractal_confirm_paint.dart';
import 'indicator_picker_chip.dart';
import 'kline_axis_format.dart';
import 'kline_chip.dart';
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

/// 主/副图指标全屏层（点空白关闭）。
enum _IndicatorFullscreenPane { none, main, sub }

/// 主图同级别连线配色（与 [ChartLevelLineStyle] 同层同色）。
abstract final class ChartLineColors {
  /// K0连线 = 展示层 K0 蓝
  static Color get bi => ChartLevelLineStyle.colorForDisplayKn(0);
  /// K1连线 = 展示层 K1 黄
  static Color get seg => ChartLevelLineStyle.colorForDisplayKn(1);
}

/// K 线图：主图 + 副图（可多指标叠加），支持高度分割拖动。
class KlineChart extends StatefulWidget {
  const KlineChart({
    super.key,
    required this.bars,
    this.period = 'tick',
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
    this.zsK0Frames = const [],
    this.buy1K0Frames = const [],
    this.sell1K0Frames = const [],
    this.buy2K0Frames = const [],
    this.sell2K0Frames = const [],
    this.buyNK0Frames = const [],
    this.sellNK0Frames = const [],
    this.defaultK0Policy = 'pending',
    this.truncationCheck = true,
    this.showBuildingDash = true,
    this.judgmentHistoryByKn = const {},
    this.zsJudgmentHistoryByKn = const {},
    this.zsConfirmHistoryByKn = const {},
    this.buy1HistoryByKn = const {},
    this.sell1HistoryByKn = const {},
    this.buy2HistoryByKn = const {},
    this.sell2HistoryByKn = const {},
    this.buyNHistoryByKn = const {},
    this.sellNHistoryByKn = const {},
    this.bsVerdictHistoryByKn = const {},
    this.overlayBsVerdictWrong = true,
    this.adjacentRatioHistoryByKn = const {},
    this.stepRhythmHistoryByKn = const {},
    this.lineSlopeHistoryByKn = const {},
    this.onMainIndicatorsChanged,
    this.onSubIndicatorsChanged,
    this.indicatorsEnabled = true,
    this.autoFollowLatest = false,
    this.isPlaying = false,
    this.onTapStepBack,
    this.onTapPlay,
    this.onTapStepForward,
    this.onLongPressReset,
    this.onLongPressReload,
    this.onLongPressRunToEnd,
    this.chipConfig = const ChipConfig(),
    this.tickDistConfig = const TickDistConfig(),
    this.mathIndicatorConfig = const MathIndicatorConfig(),
    this.mathFreezeStore,
    this.diverFreezeStore,
    this.chipOnlyMode = false,
    this.lookupEngine,
    this.strategySignals = const [],
    this.strategyFills = const [],
    this.strategyRoundBySignalId = const {},
    this.highlightedStrategyIds = const {},
    this.focusBarIdx,
    this.focusBarEpoch = 0,
    this.onStrategySignalTap,
    this.mobileLayout = false,
  });

  final List<KlineBar> bars;
  /// 加载周期键（tick=分笔画点；其它画蜡烛）
  final String period;
  final List<KlineCombineFrame> combineFrames;
  final List<K0ConfirmSignal> k0ConfirmSignals;
  final List<BarCrosshairFeature> barFeatures;
  final List<K0Line> k0Lines;
  final List<K1BarView> k1BarViews;
  final List<KlineCombineFrame> k1CombineFrames;
  final K1AnalysisBundle k1Analysis;

  /// N 段流水线全量输出（十字线 as-of 重绘与 tooltip N 段块查表用）
  final List<LevelBundle> levels;
  /// K0中枢（原生分钟K段；Rust zs_k0_frames）
  final List<ZSFrame> zsK0Frames;
  /// K0一买（Rust buy1_k0_frames）
  final List<Buy1Frame> buy1K0Frames;
  /// K0一卖（Rust sell1_k0_frames）
  final List<Sell1Frame> sell1K0Frames;
  /// K0二买（Rust buy2_k0_frames）
  final List<Buy2Frame> buy2K0Frames;
  /// K0二卖（Rust sell2_k0_frames）
  final List<Sell2Frame> sell2K0Frames;
  /// K0三类+买
  final List<BuyNFrame> buyNK0Frames;
  /// K0三类+卖
  final List<SellNFrame> sellNK0Frames;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final String defaultK0Policy;
  /// 截断监察：十字线 as-of 本地重算K1合并时与 Rust 同开关
  final bool truncationCheck;
  /// 构建中/未确认元素虚线开关：开=末组合并框虚线 + K0/K1/KN 构建中连线虚线；关=全部实线（不区分构建中）
  final bool showBuildingDash;
  /// 分型判断会话事件日志（main 步进累积；换股才清空）
  final Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn;
  /// 中枢判断会话历史（与中枢同号）
  final Map<int, List<ZsSignalEvent>> zsJudgmentHistoryByKn;
  /// 中枢确认会话历史（与中枢同号）
  final Map<int, List<ZsSignalEvent>> zsConfirmHistoryByKn;
  /// 一类买会话事件日志（对齐分型判断：成立当步冻结 x）
  final Map<int, List<Buy1Frame>> buy1HistoryByKn;
  /// 一类卖会话事件日志
  final Map<int, List<Sell1Frame>> sell1HistoryByKn;
  /// 二类买会话事件日志
  final Map<int, List<Buy2Frame>> buy2HistoryByKn;
  /// 二类卖会话事件日志
  final Map<int, List<Sell2Frame>> sell2HistoryByKn;
  /// 三类+买会话事件日志
  final Map<int, List<BuyNFrame>> buyNHistoryByKn;
  /// 三类+卖会话事件日志
  final Map<int, List<SellNFrame>> sellNHistoryByKn;
  /// BSP 在线对错会话
  final Map<int, List<BsVerdictFrame>> bsVerdictHistoryByKn;
  /// 错标叠加 X
  final bool overlayBsVerdictWrong;
  /// Kn相邻比例会话历史（显示层 → 点列）
  final Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn;
  /// Kn步进节奏会话历史
  final Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn;
  /// Kn连线斜率会话历史
  final Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn;
  final ValueChanged<Set<MainChartIndicator>>? onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>>? onSubIndicatorsChanged;
  /// 无数据时禁止点主/副图指标入口
  final bool indicatorsEnabled;
  final bool autoFollowLatest;
  /// 是否正在逐K播放（中间区单击立即暂停，不走双击延迟）
  final bool isPlaying;
  /// 筹码分布配置（总开关/桶宽/峰线等）
  final ChipConfig chipConfig;
  /// 笔数分布配置（主图左侧；仅 K0）
  final TickDistConfig tickDistConfig;
  /// 数学指标参数（均线/通道/MACD/BOLL/RSI/KDJ/Demark）
  final MathIndicatorConfig mathIndicatorConfig;
  /// Math 会话冻结仓（有则主图/副图/十字读仓，禁整表回写）
  final MathSeriesFreezeStore? mathFreezeStore;
  /// 背驰会话冻结仓（本层力度；旧格不改）
  final DivergenceFreezeStore? diverFreezeStore;
  /// chip 分支：仅显示筹码分布，关闭所有缠论渲染
  final bool chipOnlyMode;
  /// 会话增量 Lookup；Painter / 十字 / chip 复用同一份，禁止各画一次 Full build。
  final IncrementalBarFeatureLookup? lookupEngine;

  /// 策略买/卖点：有成交才画，位置用成交根；与缠论 1Ba 分开。
  final List<SignalEvent> strategySignals;
  final List<Fill> strategyFills;
  final Map<String, int> strategyRoundBySignalId;
  final Set<String> highlightedStrategyIds;
  /// 报告点交易时把这根 K 滚进视窗
  final int? focusBarIdx;
  final int focusBarEpoch;
  final ValueChanged<SignalEvent>? onStrategySignalTap;
  /// 手机布局：指标 chip 全宽、不预留桌面窗控区
  final bool mobileLayout;

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
  /// 主/副图指标 chip 默认收纳，主/副各一钮
  bool _mainIndicatorChipsExpanded = false;
  bool _subIndicatorChipsExpanded = false;
  _IndicatorFullscreenPane _fullscreenPane = _IndicatorFullscreenPane.none;
  /// 手机双指缩放：累计 scale 基准
  bool _pinchScaling = false;
  double _pinchScaleBaseline = 1.0;
  Size _chartSize = Size.zero;

  /// 左中右热区：用 Listener 优先吃点击（避免卡顿时被 GestureDetector 拖拽抢走）
  Offset? _zonePointerDown;
  int? _zonePointerId;
  bool _zoneMoved = false;
  static const _zoneTapSlop = 18.0;
  /// 最近一帧主图上下界（供 pointer 热区回调）
  double _zonePlotTop = KlineViewport.padT;
  double _zoneContentBottom = 0;
  PriceRange? _hitPriceRange;
  double _hitMainH = 1;

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
  final _subChipBarKey = GlobalKey();
  final _mainChipBarKey = GlobalKey();
  double _subChipBarHeight = KlineViewport.subIndicatorChipBand;
  double _mainChipBarHeight = 0;

  /// 十字线 as-of 中枢 bundle 缓存（逐K当下 Rust 重算）
  int? _zsAsOfCacheKey;
  KlineCombineBundle? _zsAsOfBundle;
  /// 同帧 asOf 视图：Painter / 十字 / chip 复用，禁止三次 Math 短前缀
  int? _incAsOfLookupKey;
  int _incAsOfLookupGen = -1;
  Map<int, Map<String, dynamic>>? _incAsOfByIdx;
  int _incAsOfTotalLevels = 0;
  int _incAsOfMaxBs = 9;

  KlineCombineBundle? _bundleForZsAsOf(int? asOf) {
    if (asOf == null) return null;
    // chip 分支无缠论数据：禁止 as-of 全量 FFI（日志：2.6万根≈13–18s 卡死）
    // 踩坑：chipOnlyMode 下 _bundleForZsAsOf 必须返回 null，
    // 否则 paint() 会走 asOf 短前缀 Full FFI；十字每帧移动会卡死。
    if (widget.chipOnlyMode) {
      return null;
    }
    if (_zsAsOfCacheKey == asOf && _zsAsOfBundle != null) {
      return _zsAsOfBundle;
    }
    final slice = widget.bars.where((b) => b.idx <= asOf).toList();
    if (slice.isEmpty) return null;
    try {
      final bundle = ChanBridge.instance.buildKlineCombineBundle(
        slice,
        truncationCheck: widget.truncationCheck,
      );
      _zsAsOfCacheKey = asOf;
      _zsAsOfBundle = bundle;
      return bundle;
    } catch (_) {
      return null;
    }
  }

  /// 一次 step 一份 Lookup：引擎热路径；无引擎才回落 Full（测试/筹码）。
  BarFeatureLookup _lookupForPaint({
    int? asOf,
    KlineCombineBundle? asOfBundle,
    List<CrosshairTooltipRow> zsAfterK0 = const [],
    Map<int, List<CrosshairTooltipRow>> knZsAfterKn = const {},
    Set<SubChartIndicator> subIndicators = const {},
  }) {
    final engine = widget.lookupEngine;
    if (engine != null && !engine.isEmpty) {
      if (asOf != null &&
          asOfBundle != null &&
          asOf < engine.step) {
        if (_incAsOfLookupKey != asOf ||
            _incAsOfLookupGen != engine.gen ||
            _incAsOfByIdx == null) {
          final view = engine.asOfView(
            asOf: asOf,
            asOfBundle: asOfBundle,
            prefixBars: widget.bars.where((b) => b.idx <= asOf).toList(),
          );
          _incAsOfByIdx = view.byIdx;
          _incAsOfTotalLevels = view.totalLevels;
          _incAsOfMaxBs = view.maxBsClass;
          _incAsOfLookupKey = asOf;
          _incAsOfLookupGen = engine.gen;
        }
        return BarFeatureLookup.fromCached(
          byIdx: _incAsOfByIdx!,
          totalLevels: _incAsOfTotalLevels,
          zsAfterK0: zsAfterK0,
          knZsAfterKn: knZsAfterKn,
          maxBsClass: _incAsOfMaxBs,
        );
      }
      return engine.toLookup(
        zsAfterK0: zsAfterK0,
        knZsAfterKn: knZsAfterKn,
      );
    }
    final tipLevels = asOf != null
        ? (asOfBundle?.levels ?? const <LevelBundle>[])
        : widget.levels;
    final tipK0Confirms = asOf != null
        ? (asOfBundle?.k0Confirms ?? const <K0ConfirmSignal>[])
        : widget.k0ConfirmSignals;
    final tipZsK0 = asOf != null
        ? (asOfBundle?.zsK0Frames ?? const <ZSFrame>[])
        : widget.zsK0Frames;
    return BarFeatureLookup.build(
      bars: widget.bars,
      combineFrames: _effectiveK0CombineFrames,
      k0Confirms: tipK0Confirms,
      barFeatures: widget.barFeatures,
      k0Lines: widget.k0Lines,
      k1Analysis: widget.k1Analysis,
      levels: tipLevels,
      k1CombineFrames: _effectiveK1CombineFrames,
      buy1HistoryByKn: widget.buy1HistoryByKn,
      sell1HistoryByKn: widget.sell1HistoryByKn,
      buy2HistoryByKn: widget.buy2HistoryByKn,
      sell2HistoryByKn: widget.sell2HistoryByKn,
      buyNHistoryByKn: widget.buyNHistoryByKn,
      sellNHistoryByKn: widget.sellNHistoryByKn,
      adjacentRatioHistoryByKn: widget.adjacentRatioHistoryByKn,
      stepRhythmHistoryByKn: widget.stepRhythmHistoryByKn,
      lineSlopeHistoryByKn: widget.lineSlopeHistoryByKn,
      subIndicators: subIndicators,
      truncationCheck: widget.truncationCheck,
      judgmentHistoryByKn: widget.judgmentHistoryByKn,
      zsJudgmentHistoryByKn: widget.zsJudgmentHistoryByKn,
      zsConfirmHistoryByKn: widget.zsConfirmHistoryByKn,
      asOf: asOf,
      zsAfterK0: zsAfterK0,
      knZsAfterKn: knZsAfterKn,
      mathIndicatorConfig: widget.mathIndicatorConfig,
      mathFreezeStore: widget.mathFreezeStore,
      diverFreezeStore: widget.diverFreezeStore,
      zsK0Frames: tipZsK0,
    );
  }

  Set<SubChartIndicator> get _activeSubs => widget.subIndicators;

  Set<MainChartIndicator> get _activeMains => widget.mainIndicators;

  /// 左上角单击灰度关闭的指标（仍在选择集中，再点可打开）
  Set<MainChartIndicator> _mutedMains = {};
  Set<SubChartIndicator> _mutedSubs = {};

  /// 实际绘制/读数用：已选减去灰度关闭
  Set<MainChartIndicator> get _drawnMains =>
      _activeMains.difference(_mutedMains);
  Set<SubChartIndicator> get _drawnSubs => _activeSubs.difference(_mutedSubs);

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

  /// 选择集增删后同步静音集。
  /// 重要：新勾选且非 [isDefaultDrawnMain]/[isDefaultDrawnSub] 的项默认进 muted
  ///（左上角删除线灰度，仍在选择集；再点才绘制）。已静音项取消勾选后从集里摘掉。
  void _syncMutedWithSelection({
    Set<MainChartIndicator>? previousMains,
    Set<SubChartIndicator>? previousSubs,
  }) {
    final oldM = previousMains ?? <MainChartIndicator>{};
    final oldS = previousSubs ?? <SubChartIndicator>{};
    final addedM = _activeMains.difference(oldM);
    final addedS = _activeSubs.difference(oldS);
    _mutedMains = {
      ..._mutedMains.intersection(_activeMains),
      for (final e in addedM)
        if (!isDefaultDrawnMain(e)) e,
    };
    _mutedSubs = {
      ..._mutedSubs.intersection(_activeSubs),
      for (final e in addedS)
        if (!isDefaultDrawnSub(e) &&
            // 学习观察：MACD 类背驰连带的同号 MACD 立即绘制（不进静音）
            !(e.kind == SubIndicatorKind.macd &&
                hasMacdDivergenceForKn(_activeSubs, e.kn)))
          e,
    };
    // 已勾 MACD 类背驰时强制取消同号 MACD 静音（含先前已 muted 的）
    for (final e in _activeSubs) {
      if (e.kind == SubIndicatorKind.divergence &&
          isMacdDivergenceAlgo(e.diverAlgo)) {
        _mutedSubs.remove(SubChartIndicator.macd(e.kn));
      }
    }
  }

  void _measureSubChipBar() {
    if (!mounted) return;
    final renderBox =
        _subChipBarKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      final measured = renderBox.size.height + 4;
      final h = math.min(measured, KlineViewport.subIndicatorChipMaxBand);
      if ((h - _subChipBarHeight).abs() > 0.5) {
        setState(() => _subChipBarHeight = h);
      }
    }
  }

  void _measureMainChipBar() {
    if (!mounted || !_mainIndicatorChipsExpanded) {
      if (_mainChipBarHeight != 0) {
        setState(() => _mainChipBarHeight = 0);
      }
      return;
    }
    final renderBox =
        _mainChipBarKey.currentContext?.findRenderObject() as RenderBox?;
    if (renderBox != null && renderBox.hasSize) {
      final h = math.min(
        renderBox.size.height + 2,
        KlineViewport.mainIndicatorChipMaxBand,
      );
      if ((h - _mainChipBarHeight).abs() > 0.5) {
        setState(() => _mainChipBarHeight = h);
      }
    }
  }

  double _resolveMainPlotTop(BuildContext context) {
    if (!widget.mobileLayout) return KlineViewport.padT;
    final safeTop = MediaQuery.paddingOf(context).top;
    final chipExtra = _mainIndicatorChipsExpanded ? _mainChipBarHeight : 0.0;
    return safeTop +
        KlineViewport.mainIndicatorToggleBand +
        chipExtra;
  }

  void _closeTooltipKeepCrosshair() {
    if (!_crosshairShowTooltip) return;
    setState(() => _crosshairMode = CrosshairMode.linesOnly);
  }

  @override
  void initState() {
    super.initState();
    _resetViewport();
    // 层全选关联项默认静音非核心绘制项（删除线灰度）
    _syncMutedWithSelection();
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
      // 贴右步进 / autoFollowLatest：bars 变长后十字线吸附新最右端（步进当下性）
      if (widget.autoFollowLatest &&
          _crosshairEnabled &&
          widget.bars.isNotEmpty) {
        _crosshairBarIdx = widget.bars.length - 1;
        _crosshairX = _viewport.barCenterX(_crosshairBarIdx!, _chartSize.width);
        _crosshairY ??= KlineViewport.padT + 40;
        _crosshairPinRightmost = true;
      } else if (_crosshairPinRightmost &&
          _crosshairEnabled &&
          widget.bars.isNotEmpty) {
        _crosshairBarIdx = widget.bars.length - 1;
        _crosshairX = _viewport.barCenterX(_crosshairBarIdx!, _chartSize.width);
        _crosshairY ??= KlineViewport.padT + 40;
      } else {
        _crosshairX = null;
        _crosshairY = null;
        _crosshairBarIdx = null;
      }
    }

    // 选择栏增删后：保留仍勾选的静音态；新关联非默认绘制项默认静音
    if (oldWidget.mainIndicators != widget.mainIndicators ||
        oldWidget.subIndicators != widget.subIndicators) {
      _syncMutedWithSelection(
        previousMains: oldWidget.mainIndicators,
        previousSubs: oldWidget.subIndicators,
      );
    }

    // C：大序列跳末/换股后后台预热筹码前缀（不堵 UI；口径同同步 build）
    if ((lenChanged || seriesChanged) &&
        widget.bars.length >= 2048 &&
        widget.chipConfig.enabled) {
      unawaited(
        ChipProfileCompute.warmUpInBackground(
          widget.bars,
          bucketStep: widget.chipConfig.bucketStep,
        ),
      );
    }

    if (widget.focusBarEpoch != oldWidget.focusBarEpoch &&
        widget.focusBarIdx != null) {
      _viewport.ensureBarVisible(widget.focusBarIdx!);
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
    final y = pos.dy.clamp(plotTop, contentBottom);
    // 同 K 且 Y 几乎不变：跳过 setState，提升跟手
    if (barIdx == _crosshairBarIdx &&
        _crosshairY != null &&
        (_crosshairY! - y).abs() < 0.75) {
      return;
    }
    _crosshairBarIdx = barIdx;
    _crosshairX = _viewport.barCenterX(barIdx, _chartSize.width);
    _crosshairY = y;
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
  /// 十字线+tooltip：上/下滚动 tooltip；左/右移十字线（自管连发，吞系统 repeat）。
  /// 十字线无 tooltip：左/右移线；未激活：左=步退、右=步进。
  bool _handleHardwareKey(KeyEvent event) {
    final key = event.logicalKey;
    final isLeft = key == LogicalKeyboardKey.arrowLeft;
    final isRight = key == LogicalKeyboardKey.arrowRight;
    final isUp = key == LogicalKeyboardKey.arrowUp;
    final isDown = key == LogicalKeyboardKey.arrowDown;

    // tooltip 上下滚动（允许系统 repeat）
    if (isUp || isDown) {
      if (!_crosshairShowTooltip) return false;
      if (event is KeyUpEvent) return true;
      if (event is KeyDownEvent || event is KeyRepeatEvent) {
        _scrollTooltipBy(isDown ? 48.0 : -48.0);
        return true;
      }
      return false;
    }

    if (!isLeft && !isRight) return false;

    // 左/右：吞掉系统 KeyRepeatEvent，改由自管连发，避免双步进
    if (event is KeyRepeatEvent) {
      return true;
    }
    if (event is KeyDownEvent) {
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

  /// 十字线开启时 K0合并框：优先 Rust asOfBundle.frames（与合并序同源）；
  /// bundle 失败→空（禁 Dart 本地重建冒充、禁末态框）；非十字用会话帧。
  List<KlineCombineFrame> get _effectiveK0CombineFrames {
    if (!_crosshairEnabled || _crosshairBarIdx == null) {
      return widget.combineFrames;
    }
    final asOf = _crosshairAsOfIdx();
    final bundle = _bundleForZsAsOf(asOf);
    if (bundle == null) return const [];
    return bundle.frames;
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

  /// as-of K1 bar 重建：优先 asOfBundle.levels（与主图/量柱同源），失败=空。
  List<K1Bar> _asOfK1Bars({bool includeBuilding = true}) {
    final asOf = _crosshairAsOfIdx();
    final bundle = _bundleForZsAsOf(asOf);
    return asOfK1Bars(
      bars: widget.bars,
      levels: bundle?.levels ?? const <LevelBundle>[],
      barFeatures: widget.barFeatures,
      defaultK0Policy: widget.defaultK0Policy,
      asOf: asOf,
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
    // tick 周期十字时间也到秒
    final secondLike = widget.period == 'tick' || KlineAxisFormat.isSecondLike(widget.bars);
    final timePart = KlineAxisFormat.xLabel(bar.timeText,
        minuteLike: minuteLike, secondLike: secondLike);

    // chip 分支：只拼 OHLC 轻量行，禁止全表 BarFeatureLookup / 缠论 as-of
    if (widget.chipOnlyMode) {
      final out = <CrosshairTooltipRow>[
        CrosshairTooltipRow.kv('日期时间', timePart),
        const CrosshairTooltipRow.separator(),
        CrosshairTooltipRow.kv('K0 idx', CrosshairTooltipRow.boxNum(bar.idx)),
        CrosshairTooltipRow.kv(
          'K0',
          CrosshairTooltipRow.boxNumInString(
            'O${bar.open.toStringAsFixed(2)} '
            'H${bar.high.toStringAsFixed(2)} '
            'L${bar.low.toStringAsFixed(2)} '
            'C${bar.close.toStringAsFixed(2)} '
            'V${bar.volume}',
          ),
        ),
      ];
      return out;
    }

    final asOf = _crosshairEnabled && _crosshairBarIdx != null
        ? _crosshairAsOfIdx()
        : null;
    final asOfBundle = _bundleForZsAsOf(asOf);
    // tooltip 应显尽显：中枢不按主图勾选过滤，按 maxKn 全层输出
    final maxKn = chartMaxKn(levels: widget.levels, k0Lines: widget.k0Lines);
    final allZs = buildMainIndicatorCatalog(maxKn)
        .where((e) => e.kind == MainIndicatorKind.zs)
        .toSet();
    final zsRows = zsCrosshairTooltipRows(
      asOfIdx: bar.idx,
      mainIndicators: allZs,
      combineFrames: widget.combineFrames,
      levels: widget.levels,
      barFeatures: widget.barFeatures,
      asOf: asOf,
      bars: widget.bars,
      truncationCheck: widget.truncationCheck,
      zsK0Frames: widget.zsK0Frames,
      asOfBundle: asOfBundle,
    );
    final k0Zs = zsRows.where((r) => r.label.startsWith('K0中枢')).toList();
    final knZs = <int, List<CrosshairTooltipRow>>{};
    for (final ind in allZs) {
      if (ind.kn <= 0) continue;
      final prefix = 'K${ind.kn}中枢';
      final part = zsRows.where((r) => r.label.startsWith(prefix)).toList();
      if (part.isEmpty) continue;
      knZs[ind.kn] = [...(knZs[ind.kn] ?? []), ...part];
    }
    // 副图计算全 catalog 喂入（tooltip 不按勾选门控）
    final allSubs = buildSubIndicatorCatalog(
      maxKn,
      truncationCheck: widget.truncationCheck,
    ).toSet();
    final lookup = _lookupForPaint(
      asOf: asOf,
      asOfBundle: asOfBundle,
      zsAfterK0: k0Zs,
      knZsAfterKn: knZs,
      subIndicators: allSubs,
    );
    // K0 筹码峰 / 笔数峰：与主图 profile 同 cutoff，按本根高低编号
    final cut = asOf ?? bar.idx;
    final step = widget.chipConfig.bucketStep;
    final chipPeaks = classifyProfilePeaks(
      profile: ChipProfileCompute.compute(
        bars: widget.bars,
        cutoffX: cut,
        bucketStep: step,
      ),
      low: bar.low,
      high: bar.high,
    );
    final tickPeaks = classifyProfilePeaks(
      profile: TickDistProfileCompute.compute(
        bars: widget.bars,
        cutoffX: cut,
        bucketStep: step,
      ),
      low: bar.low,
      high: bar.high,
    );
    final out = lookup.crosshairTooltipRows(
      bar.idx,
      timePart: timePart,
      subIndicators: allSubs,
      chipPeaks: chipPeaks,
      tickPeaks: tickPeaks,
    );
    return out;
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

  void _onPointerDown(PointerDownEvent e) {
    // 鼠标中键：快速显示(含十字)/隐藏 tooltip（不关十字线）
    if (e.buttons & kMiddleMouseButton != 0) {
      _toggleTooltipKeepCrosshair(e.localPosition);
      _zonePointerDown = null;
      _zonePointerId = null;
      _zoneMoved = false;
      return;
    }
    _zonePointerDown = e.localPosition;
    _zonePointerId = e.pointer;
    _zoneMoved = false;
  }

  void _onPointerMove(PointerMoveEvent e, double mainPlotH, double contentBottom) {
    if (_zonePointerId == e.pointer &&
        _zonePointerDown != null &&
        (e.localPosition - _zonePointerDown!).distance > _zoneTapSlop) {
      _zoneMoved = true;
    }
    if (_splitDragging) {
      _onSplitMove(e);
      return;
    }
    if (_crosshairEnabled) {
      _zoneMoved = true;
      _updateCrosshairAt(
        e.localPosition,
        KlineViewport.padT,
        contentBottom,
      );
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
  }

  void _onPointerUp(PointerUpEvent e) {
    if (_splitDragging) {
      _onSplitUp(e);
      _zonePointerDown = null;
      _zonePointerId = null;
      return;
    }
    _panning = false;
    _panStart = null;

    // 高优先：位移小于 slop 视为左/中/右热区点击（不依赖 GestureDetector 胜出）
    final down = _zonePointerDown;
    final isZoneTap = _zonePointerId == e.pointer &&
        down != null &&
        !_zoneMoved &&
        (e.localPosition - down).distance <= _zoneTapSlop;
    _zonePointerDown = null;
    _zonePointerId = null;
    if (isZoneTap) {
      _onZoneTapAt(e.localPosition, _zonePlotTop, _zoneContentBottom);
    }
  }

  void _onPointerLeave() {
    _panning = false;
    _panStart = null;
    _zonePointerDown = null;
    _zonePointerId = null;
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

  /// 中键：无十字→开十字+tooltip；有 tooltip→只藏 tooltip；仅线→再显 tooltip。
  void _toggleTooltipKeepCrosshair(Offset pos) {
    final plotTop = _zonePlotTop;
    final contentBottom = _zoneContentBottom > 0
        ? _zoneContentBottom
        : math.max(plotTop + 40, _chartSize.height - 8);
    setState(() {
      switch (_crosshairMode) {
        case CrosshairMode.off:
          _crosshairMode = CrosshairMode.withTooltip;
          _tooltipScrollBarIdx = null;
          _updateCrosshairAt(pos, plotTop, contentBottom);
        case CrosshairMode.withTooltip:
          _crosshairMode = CrosshairMode.linesOnly;
        case CrosshairMode.linesOnly:
          _crosshairMode = CrosshairMode.withTooltip;
          _resetTooltipScrollIfNeeded(_crosshairBarIdx);
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

  bool _tryTapStrategySignal(Offset local, double plotTop) {
    if (widget.onStrategySignalTap == null ||
        widget.strategySignals.isEmpty ||
        _hitPriceRange == null) {
      return false;
    }
    final plotH = math.max(1.0, _hitMainH - KlineViewport.padB - plotTop);
    final asOf = _crosshairEnabled && _crosshairBarIdx != null
        ? widget.bars[_crosshairBarIdx!.clamp(0, widget.bars.length - 1)].idx
        : null;
    final hit = hitTestStrategySignal(
      local: local,
      signals: widget.strategySignals,
      bars: widget.bars,
      viewport: _viewport,
      priceRange: _hitPriceRange!,
      canvasW: _chartSize.width,
      plotTop: plotTop,
      plotH: plotH,
      asOf: asOf,
      fills: widget.strategyFills,
    );
    if (hit == null) return false;
    widget.onStrategySignalTap!(hit.signal);
    return true;
  }

  void _onZoneTapAt(Offset local, double plotTop, double contentBottom) {
    if (widget.bars.isEmpty) return;
    if (_tryTapStrategySignal(local, plotTop)) return;

    final mainH = _hitMainH;
    if (widget.mobileLayout &&
        widget.indicatorsEnabled &&
        !_crosshairEnabled &&
        _tryOpenFullscreenFromTap(local, mainH, plotTop)) {
      _middleTapTimer?.cancel();
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      return;
    }

    final zone = _hotZone(local);

    // 十字线激活：屏蔽步退/步进/播放，只保留中间双击切三态 + 点击跟线
    if (_crosshairEnabled) {
      if (zone != 1) {
        _middleTapTimer?.cancel();
        _lastMiddleTapAt = null;
        _lastMiddleTapPos = null;
        _updateCrosshairAt(local, plotTop, contentBottom);
        return;
      }
      final now = DateTime.now();
      final last = _lastMiddleTapAt;
      final lastPos = _lastMiddleTapPos;
      if (last != null &&
          lastPos != null &&
          now.difference(last).inMilliseconds <= _doubleTapMs &&
          (local - lastPos).distance < 48) {
        _middleTapTimer?.cancel();
        _lastMiddleTapAt = null;
        _lastMiddleTapPos = null;
        _cycleCrosshair(local, plotTop, contentBottom);
        return;
      }
      _lastMiddleTapAt = now;
      _lastMiddleTapPos = local;
      _middleTapTimer?.cancel();
      // 单击只跟线，不触发播放
      _updateCrosshairAt(local, plotTop, contentBottom);
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

    // 中间：播放中 → 立即暂停（高优先，不等双击窗口）
    if (widget.isPlaying) {
      _middleTapTimer?.cancel();
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      widget.onTapPlay?.call();
      return;
    }

    // 中间未播放：自管双击=十字线三态；单击延迟后播放
    final now = DateTime.now();
    final last = _lastMiddleTapAt;
    final lastPos = _lastMiddleTapPos;
    if (last != null &&
        lastPos != null &&
        now.difference(last).inMilliseconds <= _doubleTapMs &&
        (local - lastPos).distance < 48) {
      _middleTapTimer?.cancel();
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      _cycleCrosshair(local, plotTop, contentBottom);
      return;
    }
    _lastMiddleTapAt = now;
    _lastMiddleTapPos = local;
    _middleTapTimer?.cancel();
    _middleTapTimer = Timer(const Duration(milliseconds: _doubleTapMs), () {
      _lastMiddleTapAt = null;
      _lastMiddleTapPos = null;
      widget.onTapPlay?.call();
    });
  }

  /// 手机：点主/副图区打开指标全屏（左/右热区仍留给步进）。
  bool _tryOpenFullscreenFromTap(Offset local, double mainH, double plotTop) {
    if (local.dy >= mainH + 2) {
      _openIndicatorFullscreen(_IndicatorFullscreenPane.sub);
      return true;
    }
    if (local.dy >= plotTop + 20 && local.dy < mainH - KlineViewport.xAxisH) {
      final zone = _hotZone(local);
      if (zone == 0 || zone == 2) return false;
      _openIndicatorFullscreen(_IndicatorFullscreenPane.main);
      return true;
    }
    return false;
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
    if (widget.mobileLayout || widget.bars.isEmpty || _splitDragging) return;
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

  /// 手机：双指捏合缩放 X + 双指平移（单指不拖图）。
  void _onPinchScaleStart(ScaleStartDetails d) {
    if (!widget.mobileLayout || widget.bars.isEmpty) return;
    // 十字线开启：单指/双指都只跟线，禁止缩放平移抢手势
    if (_crosshairEnabled) {
      _pinchScaling = false;
      _panning = false;
      _panStart = null;
      return;
    }
    _pinchScaling = true;
    _pinchScaleBaseline = 1.0;
    _panning = false;
    _panStart = null;
  }

  void _onPinchScaleUpdate(ScaleUpdateDetails d, double mainPlotH) {
    if (!widget.mobileLayout || !_pinchScaling || widget.bars.isEmpty) return;
    if (_crosshairEnabled) return;
    _viewport.markUserAdjusted();
    if (d.scale != _pinchScaleBaseline) {
      final factor = d.scale / _pinchScaleBaseline;
      _pinchScaleBaseline = d.scale;
      if (factor != 1.0 && _chartSize.width > 0) {
        _viewport.zoomXAt(factor, d.localFocalPoint.dx, _chartSize.width);
      }
    }
    if (d.focalPointDelta != Offset.zero) {
      _viewport.panByPixels(
        d.focalPointDelta.dx,
        d.focalPointDelta.dy,
        _chartSize.width,
        mainPlotH,
      );
    }
    _scheduleRedraw();
  }

  void _onPinchScaleEnd(ScaleEndDetails d) {
    _pinchScaling = false;
    _pinchScaleBaseline = 1.0;
  }

  Widget _buildMainIndicatorToggleButton() {
    return Material(
      color: const Color(0xCC1A1A1A),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => setState(() {
          _mainIndicatorChipsExpanded = !_mainIndicatorChipsExpanded;
          if (!_mainIndicatorChipsExpanded) {
            _mainChipBarHeight = 0;
          }
        }),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            _mainIndicatorChipsExpanded
                ? Icons.expand_less
                : Icons.expand_more,
            size: 18,
            color: const Color(0xFFE2E8F0),
          ),
        ),
      ),
    );
  }

  Widget _buildSubIndicatorToggleButton() {
    return Material(
      color: const Color(0xCC1A1A1A),
      borderRadius: BorderRadius.circular(4),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () => setState(() {
          _subIndicatorChipsExpanded = !_subIndicatorChipsExpanded;
          if (!_subIndicatorChipsExpanded) {
            _subChipBarHeight = KlineViewport.subIndicatorChipBand;
          }
        }),
        child: Padding(
          padding: const EdgeInsets.all(6),
          child: Icon(
            _subIndicatorChipsExpanded
                ? Icons.expand_less
                : Icons.expand_more,
            size: 18,
            color: const Color(0xFFE2E8F0),
          ),
        ),
      ),
    );
  }

  void _openIndicatorFullscreen(_IndicatorFullscreenPane pane) {
    if (!widget.indicatorsEnabled) return;
    setState(() => _fullscreenPane = pane);
  }

  void _closeIndicatorFullscreen() {
    if (_fullscreenPane == _IndicatorFullscreenPane.none) return;
    setState(() => _fullscreenPane = _IndicatorFullscreenPane.none);
  }

  Widget _buildFullscreenIndicatorOverlay(double w, double h) {
    if (_fullscreenPane == _IndicatorFullscreenPane.none) return const SizedBox.shrink();
    final isMain = _fullscreenPane == _IndicatorFullscreenPane.main;
    final title = isMain ? '主图指标' : '副图指标';
    final marginH = math.max(12.0, w * 0.04);
    final marginV = math.max(36.0, h * 0.06);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: _closeIndicatorFullscreen,
        child: Container(
          color: const Color(0x99000000),
          alignment: Alignment.center,
          padding: EdgeInsets.fromLTRB(marginH, marginV, marginH, marginV),
          child: GestureDetector(
            onTap: () {},
            child: Material(
              color: const Color(0xF01A1A1A),
              borderRadius: BorderRadius.circular(10),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(12, 10, 12, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Row(
                      children: [
                        Text(
                          title,
                          style: const TextStyle(
                            fontSize: 14,
                            fontWeight: FontWeight.w600,
                            color: Color(0xFFE2E8F0),
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          tooltip: '关闭',
                          visualDensity: VisualDensity.compact,
                          onPressed: _closeIndicatorFullscreen,
                          icon: const Icon(Icons.close, size: 20, color: Color(0xFF94A3B8)),
                        ),
                      ],
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: isMain
                          ? IndicatorPickerChip(
                              entries: () {
                                final list = _mainCatalog
                                    .where(_activeMains.contains)
                                    .toList()
                                  ..sort((a, b) {
                                    final lv =
                                        a.displayLevel.compareTo(b.displayLevel);
                                    if (lv != 0) return lv;
                                    final c = a.kind.categoryOrder
                                        .compareTo(b.kind.categoryOrder);
                                    if (c != 0) return c;
                                    return a.kn.compareTo(b.kn);
                                  });
                                return [
                                  for (final e in list)
                                    IndicatorChipEntry(
                                      label: e.label,
                                      displayLevel: e.displayLevel,
                                      muted: _mutedMains.contains(e),
                                      onTapToggle: () => _toggleMuteMain(e),
                                    ),
                                ];
                              }(),
                              onTapDropdown: () => _pickMainIndicators(context),
                              maxWidth: w - marginH * 2 - 24,
                              emptyHint: 'K0',
                              horizontalScroll: true,
                            )
                          : IndicatorPickerChip(
                              entries: () {
                                final values = _subChipValueByInd();
                                final list = _subCatalog
                                    .where(_activeSubs.contains)
                                    .toList()
                                  ..sort((a, b) {
                                    final lv = a.displayLevel
                                        .compareTo(b.displayLevel);
                                    if (lv != 0) return lv;
                                    final c = a.kind.categoryOrder
                                        .compareTo(b.kind.categoryOrder);
                                    if (c != 0) return c;
                                    final ai = a.diverAlgo?.index ?? -1;
                                    final bi = b.diverAlgo?.index ?? -1;
                                    if (ai != bi) return ai.compareTo(bi);
                                    return a.kn.compareTo(b.kn);
                                  });
                                return [
                                  for (final e in list)
                                    IndicatorChipEntry(
                                      label: e.label,
                                      displayLevel: e.displayLevel,
                                      muted: _mutedSubs.contains(e),
                                      valueText: values[e],
                                      onTapToggle: () => _toggleMuteSub(e),
                                    ),
                                ];
                              }(),
                              onTapDropdown: () => _pickSubIndicators(context),
                              maxWidth: w - marginH * 2 - 24,
                              emptyHint: '未选',
                              horizontalScroll: true,
                            ),
                    ),
                    const SizedBox(height: 8),
                    Align(
                      alignment: Alignment.centerRight,
                      child: TextButton(
                        onPressed: () => isMain
                            ? _pickMainIndicators(context)
                            : _pickSubIndicators(context),
                        child: const Text('打开完整选择器'),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }

  void _onSplitDown(PointerDownEvent e) {
    if (e.kind == PointerDeviceKind.mouse &&
        e.buttons != kPrimaryMouseButton) {
      return;
    }
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

  /// 单击左上角名称：灰度关闭 / 再点打开（不从选择集移除）。
  void _toggleMuteMain(MainChartIndicator item) {
    setState(() {
      if (_mutedMains.contains(item)) {
        _mutedMains = Set<MainChartIndicator>.from(_mutedMains)..remove(item);
      } else {
        _mutedMains = Set<MainChartIndicator>.from(_mutedMains)..add(item);
      }
    });
  }

  /// 单击左上角名称：灰度关闭 / 再点打开。
  void _toggleMuteSub(SubChartIndicator item) {
    setState(() {
      if (_mutedSubs.contains(item)) {
        _mutedSubs = Set<SubChartIndicator>.from(_mutedSubs)..remove(item);
      } else {
        _mutedSubs = Set<SubChartIndicator>.from(_mutedSubs)..add(item);
      }
    });
  }

  /// 副图 chip 后方读数：十字线当步 / 否则末根；与旧右上读数同源。
  /// 踩坑：勿在 painter 右上再画独立读数框；值挂 IndicatorChipEntry.valueText。
  Map<SubChartIndicator, String> _subChipValueByInd() {
    if (widget.bars.isEmpty || _activeSubs.isEmpty) return const {};
    final barIdx = (_crosshairEnabled && _crosshairBarIdx != null)
        ? _crosshairBarIdx!
        : widget.bars.length - 1;
    final bar = widget.bars[barIdx.clamp(0, widget.bars.length - 1)];
    final asOf = (_crosshairEnabled && _crosshairBarIdx != null)
        ? bar.idx
        : null;
    final asOfBundle =
        widget.chipOnlyMode ? null : _bundleForZsAsOf(asOf);
    final lookup = _lookupForPaint(
      asOf: asOf,
      asOfBundle: asOfBundle,
      subIndicators: _activeSubs,
    );
    final out = <SubChartIndicator, String>{};
    for (final e in _activeSubs) {
      final rows = lookup.crosshairSubRows(bar.idx, {e});
      out[e] = rows.isNotEmpty ? rows.first.value : '0';
    }
    return out;
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
        _hitPriceRange = priceRange;
        _hitMainH = mainH;

        final cursor = _crosshairEnabled
            ? SystemMouseCursors.precise
            : (_panning ? SystemMouseCursors.grabbing : SystemMouseCursors.grab);
        final plotTop = _resolveMainPlotTop(context);
        _zonePlotTop = plotTop;
        _zoneContentBottom = contentBottom;

        final segAsOf = _crosshairEnabled && _crosshairBarIdx != null
            ? _crosshairAsOfIdx()
            : null;
        final zsAsOfBundle =
            widget.chipOnlyMode ? null : _bundleForZsAsOf(segAsOf);
        // 十字 asOf：连线/量柱/合并等统一只吃 asOfBundle（失败=空，禁会话末态+裁x）
        final paintLevels = segAsOf != null
            ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
            : widget.levels;
        final paintZsK0 = segAsOf != null
            ? (zsAsOfBundle?.zsK0Frames ?? const <ZSFrame>[])
            : widget.zsK0Frames;
        final paintK0Confirms = segAsOf != null
            ? (zsAsOfBundle?.k0Confirms ?? const <K0ConfirmSignal>[])
            : widget.k0ConfirmSignals;

        WidgetsBinding.instance.addPostFrameCallback((_) {
          _measureSubChipBar();
          _measureMainChipBar();
        });

        final paintLookup = widget.chipOnlyMode
            ? BarFeatureLookup.empty()
            : _lookupForPaint(
                asOf: segAsOf,
                asOfBundle: zsAsOfBundle,
                subIndicators: _drawnSubs,
              );

        _KlineCompositePainter paintLayer(_ChartPaintLayer layer) =>
            _KlineCompositePainter(
              bars: widget.bars,
              period: widget.period,
              combineFrames: _effectiveK0CombineFrames,
              k0ConfirmSignals: paintK0Confirms,
              barFeatures: widget.barFeatures,
              k0Lines: widget.k0Lines,
              k1BarViews: _effectiveK1BarViews,
              k1CombineFrames: _effectiveK1CombineFrames,
              k1Analysis: widget.k1Analysis,
              levels: paintLevels,
              zsK0Frames: paintZsK0,
              buy1K0Frames: widget.buy1K0Frames,
              sell1K0Frames: widget.sell1K0Frames,
              buy2K0Frames: widget.buy2K0Frames,
              sell2K0Frames: widget.sell2K0Frames,
              buyNK0Frames: widget.buyNK0Frames,
              sellNK0Frames: widget.sellNK0Frames,
              zsAsOfBundle: zsAsOfBundle,
              mainIndicators: _drawnMains,
              subIndicators: _drawnSubs,
              viewport: _viewport,
              priceRange: priceRange,
              visible: visible,
              mainH: mainH,
              volH: volH,
              mainPlotTop: plotTop,
              crosshairEnabled: _crosshairEnabled,
              crosshairShowTooltip: _crosshairShowTooltip,
              crosshairX: _crosshairX,
              crosshairY: _crosshairY,
              crosshairBarIdx: _crosshairBarIdx,
              truncationCheck: widget.truncationCheck,
              showBuildingDash: widget.showBuildingDash,
              subChipBarHeight: _subChipBarHeight,
              defaultK0Policy: widget.defaultK0Policy,
              segAsOf: segAsOf,
              judgmentHistoryByKn: widget.judgmentHistoryByKn,
              zsJudgmentHistoryByKn: widget.zsJudgmentHistoryByKn,
              zsConfirmHistoryByKn: widget.zsConfirmHistoryByKn,
              buy1HistoryByKn: widget.buy1HistoryByKn,
              sell1HistoryByKn: widget.sell1HistoryByKn,
              buy2HistoryByKn: widget.buy2HistoryByKn,
              sell2HistoryByKn: widget.sell2HistoryByKn,
              buyNHistoryByKn: widget.buyNHistoryByKn,
              sellNHistoryByKn: widget.sellNHistoryByKn,
              bsVerdictHistoryByKn: widget.bsVerdictHistoryByKn,
              overlayBsVerdictWrong: widget.overlayBsVerdictWrong,
              adjacentRatioHistoryByKn: widget.adjacentRatioHistoryByKn,
              stepRhythmHistoryByKn: widget.stepRhythmHistoryByKn,
              lineSlopeHistoryByKn: widget.lineSlopeHistoryByKn,
              chipConfig: widget.chipConfig,
              tickDistConfig: widget.tickDistConfig,
              mathIndicatorConfig: widget.mathIndicatorConfig,
              mathFreezeStore: widget.mathFreezeStore,
              diverFreezeStore: widget.diverFreezeStore,
              chipOnlyMode: widget.chipOnlyMode,
              layer: layer,
              featureLookup: layer == _ChartPaintLayer.chip
                  ? BarFeatureLookup.empty()
                  : paintLookup,
            );

        final chartSize = Size(w, mainH + volH);
        final overlayTop = widget.mobileLayout
            ? MediaQuery.paddingOf(context).top
            : 0.0;
        return Stack(
          clipBehavior: Clip.hardEdge,
          children: [
            // A：底图 / 筹码 / 十字 三层独立重绘
            RepaintBoundary(
              child: CustomPaint(
                size: chartSize,
                painter: paintLayer(_ChartPaintLayer.base),
              ),
            ),
            if (widget.strategySignals.isNotEmpty)
              RepaintBoundary(
                child: CustomPaint(
                  size: chartSize,
                  painter: StrategySignalPainter(
                    bars: widget.bars,
                    signals: widget.strategySignals,
                    fills: widget.strategyFills,
                    roundBySignalId: widget.strategyRoundBySignalId,
                    highlightedIds: widget.highlightedStrategyIds,
                    viewport: _viewport,
                    priceRange: priceRange,
                    mainH: mainH,
                    asOf: segAsOf,
                    isTickPeriod: widget.period == 'tick',
                  ),
                ),
              ),
            RepaintBoundary(
              child: CustomPaint(
                size: chartSize,
                painter: paintLayer(_ChartPaintLayer.chip),
              ),
            ),
            RepaintBoundary(
              child: CustomPaint(
                size: chartSize,
                painter: paintLayer(_ChartPaintLayer.crosshair),
              ),
            ),
            Positioned.fill(
              child: widget.mobileLayout
                  ? Listener(
                      behavior: HitTestBehavior.opaque,
                      onPointerDown: _onPointerDown,
                      onPointerMove: (e) => _onPointerMove(
                        e,
                        mainH - KlineViewport.padT - KlineViewport.padB,
                        contentBottom,
                      ),
                      onPointerUp: _onPointerUp,
                      child: GestureDetector(
                        behavior: HitTestBehavior.opaque,
                        onLongPressStart: _onZoneLongPress,
                        onScaleStart: _onPinchScaleStart,
                        onScaleUpdate: (d) => _onPinchScaleUpdate(
                          d,
                          mainH - KlineViewport.padT - KlineViewport.padB,
                        ),
                        onScaleEnd: _onPinchScaleEnd,
                        child: const SizedBox.expand(),
                      ),
                    )
                  : MouseRegion(
                      cursor: cursor,
                      onExit: (_) => _onPointerLeave(),
                      onHover: (e) {
                        if (!_panning) {
                          _updateCrosshairAt(
                            e.localPosition,
                            plotTop,
                            contentBottom,
                          );
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
            // 十字线 tooltip：可滚动 + 右上角关闭（保留十字线）
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
                  child: CrosshairTooltipPanel(
                    rows: rows,
                    scrollController: _tooltipScroll,
                    maxWidth: maxW,
                    maxHeight: maxH,
                    onClose: _closeTooltipKeepCrosshair,
                  ),
                );
              }),
            // 主副图分割：显式拖动手柄（不再隐式拖整条）
            if (_showSubPane)
              Positioned(
                left: 0,
                right: 0,
                top: mainH - 14,
                height: 28,
                child: Center(
                  child: Listener(
                    behavior: HitTestBehavior.opaque,
                    onPointerDown: _onSplitDown,
                    onPointerMove: _onSplitMove,
                    onPointerUp: _onSplitUp,
                    child: MouseRegion(
                      cursor: SystemMouseCursors.resizeUpDown,
                      child: Container(
                        width: 44,
                        height: 22,
                        decoration: BoxDecoration(
                          color: _splitDragging
                              ? const Color(0xDD1E3A5F)
                              : const Color(0xCC1A1A1A),
                          border: Border.all(
                            color: _splitDragging
                                ? const Color(0xFF42A5F5)
                                : const Color(0x55FFFFFF),
                          ),
                          borderRadius: BorderRadius.circular(11),
                        ),
                        child: Icon(
                          Icons.drag_handle,
                          size: 16,
                          color: _splitDragging
                              ? const Color(0xFF42A5F5)
                              : const Color(0xFFE2E8F0),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            // 主图指标收纳：裁切在主图区内，不侵入副图
            Positioned(
              left: 0,
              top: overlayTop,
              right: 0,
              height: mainH - overlayTop,
              child: ClipRect(
                child: Stack(
                  clipBehavior: Clip.hardEdge,
                  children: [
                    Positioned(
                      left: 0,
                      top: 0,
                      child: _buildMainIndicatorToggleButton(),
                    ),
                    if (_mainIndicatorChipsExpanded)
                      Positioned(
                        left: widget.mobileLayout ? 72 : 76,
                        top: 0,
                        right: widget.mobileLayout ? 52 : 140,
                        child: Builder(
                          key: _mainChipBarKey,
                          builder: (_) => IgnorePointer(
                          ignoring: !widget.indicatorsEnabled,
                          child: Opacity(
                            opacity: widget.indicatorsEnabled ? 1 : 0.35,
                            child: IndicatorPickerChip(
                              entries: () {
                                final list = _mainCatalog
                                    .where(_activeMains.contains)
                                    .toList()
                                  ..sort((a, b) {
                                    final lv =
                                        a.displayLevel.compareTo(b.displayLevel);
                                    if (lv != 0) return lv;
                                    final c = a.kind.categoryOrder
                                        .compareTo(b.kind.categoryOrder);
                                    if (c != 0) return c;
                                    return a.kn.compareTo(b.kn);
                                  });
                                return [
                                  for (final e in list)
                                    IndicatorChipEntry(
                                      label: e.label,
                                      displayLevel: e.displayLevel,
                                      muted: _mutedMains.contains(e),
                                      onTapToggle: () => _toggleMuteMain(e),
                                    ),
                                ];
                              }(),
                              onTapDropdown: () => _pickMainIndicators(context),
                              maxWidth: widget.mobileLayout
                                  ? math.max(80.0, w - 80)
                                  : math.max(120.0, w - 220),
                              emptyHint: 'K0',
                              horizontalScroll: widget.mobileLayout,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            if (_showSubPane)
              Positioned(
                left: 0,
                top: mainH,
                right: 0,
                height: volH,
                child: ClipRect(
                  child: Stack(
                    clipBehavior: Clip.hardEdge,
                    children: [
                      Positioned(
                        left: KlineViewport.padL,
                        top: 2,
                        child: _buildSubIndicatorToggleButton(),
                      ),
                      if (_subIndicatorChipsExpanded)
                        Positioned(
                          left: KlineViewport.padL,
                          top: 2,
                          right: 4,
                          child: Builder(
                            key: _subChipBarKey,
                            builder: (_) => IgnorePointer(
                              ignoring: !widget.indicatorsEnabled,
                              child: Opacity(
                                opacity: widget.indicatorsEnabled ? 1 : 0.35,
                                child: Padding(
                                  padding: EdgeInsets.only(
                                    left: widget.mobileLayout ? 68 : 72,
                                  ),
                                  child: IndicatorPickerChip(
                                    entries: () {
                                      final values = _subChipValueByInd();
                                      final list = _subCatalog
                                          .where(_activeSubs.contains)
                                          .toList()
                                        ..sort((a, b) {
                                          final lv = a.displayLevel
                                              .compareTo(b.displayLevel);
                                          if (lv != 0) return lv;
                                          final c = a.kind.categoryOrder
                                              .compareTo(b.kind.categoryOrder);
                                          if (c != 0) return c;
                                          final ai =
                                              a.diverAlgo?.index ?? -1;
                                          final bi =
                                              b.diverAlgo?.index ?? -1;
                                          if (ai != bi) return ai.compareTo(bi);
                                          return a.kn.compareTo(b.kn);
                                        });
                                      return [
                                        for (final e in list)
                                          IndicatorChipEntry(
                                            label: e.label,
                                            displayLevel: e.displayLevel,
                                            muted: _mutedSubs.contains(e),
                                            valueText: values[e],
                                            onTapToggle: () => _toggleMuteSub(e),
                                          ),
                                      ];
                                    }(),
                                    onTapDropdown: () =>
                                        _pickSubIndicators(context),
                                    maxWidth: widget.mobileLayout
                                        ? math.max(80.0, w - KlineViewport.padL - 8)
                                        : math.max(
                                            100.0,
                                            w - KlineViewport.padL - 24,
                                          ),
                                    emptyHint: '未选',
                                    horizontalScroll: widget.mobileLayout,
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            _buildFullscreenIndicatorOverlay(w, h),
          ],
        );
      },
    );
  }
}

/// 图表分层：底图（蜡烛/缠论/轴）/筹码/十字线，互不拖累重绘。
/// 踩坑：之前所有绘制都在一个 CustomPaint 里，十字线移动时 shouldRepaint=true
/// 导致蜡烛和筹码也要重绘（尤其 5 万根 K 线 + 前缀索引查找）。拆三层后：
///   — base：只有蜡烛/缠论/坐标轴变动时重绘
///   — chip：只有筹码数据/几何变动时重绘
///   — crosshair：纯鼠标移动，只重绘十字线（极轻量）
enum _ChartPaintLayer { base, chip, crosshair }

class _KlineCompositePainter extends CustomPainter {
  _KlineCompositePainter({
    required this.bars,
    this.period = 'tick',
    required this.combineFrames,
    required this.k0ConfirmSignals,
    required this.barFeatures,
    required this.k0Lines,
    required this.k1BarViews,
    required this.k1CombineFrames,
    required this.k1Analysis,
    required this.levels,
    this.zsK0Frames = const [],
    this.buy1K0Frames = const [],
    this.sell1K0Frames = const [],
    this.buy2K0Frames = const [],
    this.sell2K0Frames = const [],
    this.buyNK0Frames = const [],
    this.sellNK0Frames = const [],
    this.zsAsOfBundle,
    required this.mainIndicators,
    required this.subIndicators,
    required this.viewport,
    required this.priceRange,
    required this.visible,
    required this.mainH,
    required this.volH,
    this.mainPlotTop = KlineViewport.padT,
    required this.crosshairEnabled,
    required this.crosshairShowTooltip,
    required this.crosshairX,
    required this.crosshairY,
    required this.crosshairBarIdx,
    this.truncationCheck = true,
    this.showBuildingDash = true,
    this.subChipBarHeight = KlineViewport.subIndicatorChipBand,
    this.defaultK0Policy = 'pending',
    this.segAsOf,
    this.judgmentHistoryByKn = const {},
    this.zsJudgmentHistoryByKn = const {},
    this.zsConfirmHistoryByKn = const {},
    this.buy1HistoryByKn = const {},
    this.sell1HistoryByKn = const {},
    this.buy2HistoryByKn = const {},
    this.sell2HistoryByKn = const {},
    this.buyNHistoryByKn = const {},
    this.sellNHistoryByKn = const {},
    this.bsVerdictHistoryByKn = const {},
    this.overlayBsVerdictWrong = true,
    this.adjacentRatioHistoryByKn = const {},
    this.stepRhythmHistoryByKn = const {},
    this.lineSlopeHistoryByKn = const {},
    this.chipConfig = const ChipConfig(),
    this.tickDistConfig = const TickDistConfig(),
    this.mathIndicatorConfig = const MathIndicatorConfig(),
    this.mathFreezeStore,
    this.diverFreezeStore,
    this.chipOnlyMode = false,
    this.layer = _ChartPaintLayer.base,
    required this.featureLookup,
  });

  /// 分层绘制：底图/筹码/十字 独立 shouldRepaint（计算口径不变）
  final _ChartPaintLayer layer;
  final List<KlineBar> bars;
  final String period;
  final List<KlineCombineFrame> combineFrames;
  final List<K0ConfirmSignal> k0ConfirmSignals;
  final List<BarCrosshairFeature> barFeatures;
  final List<K0Line> k0Lines;
  final List<K1BarView> k1BarViews;
  final List<KlineCombineFrame> k1CombineFrames;
  final K1AnalysisBundle k1Analysis;
  final List<LevelBundle> levels;
  final List<ZSFrame> zsK0Frames;
  final List<Buy1Frame> buy1K0Frames;
  final List<Sell1Frame> sell1K0Frames;
  final List<Buy2Frame> buy2K0Frames;
  final List<Sell2Frame> sell2K0Frames;
  final List<BuyNFrame> buyNK0Frames;
  final List<SellNFrame> sellNK0Frames;
  final KlineCombineBundle? zsAsOfBundle;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final BarFeatureLookup featureLookup;
  final KlineViewport viewport;
  final PriceRange priceRange;
  final List<KlineBar> visible;
  final double mainH;
  final double volH;
  final double mainPlotTop;
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
  /// 副图左上指标开关按钮实际高度（自 px 落点下方 2px 起算；动态测量防覆盖）
  final double subChipBarHeight;
  /// 与 asOfK1Bars 同构的默认 K0 策略（pending/purged）
  final String defaultK0Policy;
  /// 十字线 as-of 2 段连线截止 K（null=末态全量）
  final int? segAsOf;

  /// 分型判断会话事件日志（步进追加；绘制扫全部历史点）
  final Map<int, List<FractalJudgmentEvent>> judgmentHistoryByKn;
  /// 中枢判断会话历史
  final Map<int, List<ZsSignalEvent>> zsJudgmentHistoryByKn;
  /// 中枢确认会话历史
  final Map<int, List<ZsSignalEvent>> zsConfirmHistoryByKn;
  /// 一类买会话事件日志（对齐分型判断）
  final Map<int, List<Buy1Frame>> buy1HistoryByKn;
  /// 一类卖会话事件日志
  final Map<int, List<Sell1Frame>> sell1HistoryByKn;
  /// 二类买会话事件日志
  final Map<int, List<Buy2Frame>> buy2HistoryByKn;
  /// 二类卖会话事件日志
  final Map<int, List<Sell2Frame>> sell2HistoryByKn;
  /// 三类+买会话事件日志
  final Map<int, List<BuyNFrame>> buyNHistoryByKn;
  /// 三类+卖会话事件日志
  final Map<int, List<SellNFrame>> sellNHistoryByKn;
  /// BSP 在线对错会话
  final Map<int, List<BsVerdictFrame>> bsVerdictHistoryByKn;
  /// 错标叠加 X
  final bool overlayBsVerdictWrong;
  /// Kn相邻比例会话历史
  final Map<int, List<AdjacentRatioPoint>> adjacentRatioHistoryByKn;
  /// Kn步进节奏会话历史
  final Map<int, List<StepRhythmLinePoint>> stepRhythmHistoryByKn;
  /// Kn连线斜率会话历史
  final Map<int, List<LineSlopePoint>> lineSlopeHistoryByKn;
  /// 筹码分布配置
  final ChipConfig chipConfig;
  /// 笔数分布配置（主图左侧）
  final TickDistConfig tickDistConfig;
  /// 数学指标参数
  final MathIndicatorConfig mathIndicatorConfig;
  /// Math 会话冻结仓（有则读仓）
  final MathSeriesFreezeStore? mathFreezeStore;
  /// 背驰会话冻结仓（有则读仓）
  final DivergenceFreezeStore? diverFreezeStore;
  /// chip 分支：仅显示筹码分布，关闭所有缠论渲染
  final bool chipOnlyMode;

  @override
  void paint(Canvas canvas, Size size) {
    final plotTop = mainPlotTop;
    final plotBottom = mainH - KlineViewport.padB;
    final plotH = math.max(1.0, plotBottom - plotTop);
    // 筹码右 / 笔数左：叠在主图两侧；蜡烛坐标系不变
    final showChip = chipConfig.enabled && bars.isNotEmpty;
    final showTickDist = tickDistConfig.enabled && bars.isNotEmpty;
    final chipPaneW = showChip ? math.max(24.0, chipConfig.paneWidth) : 0.0;
    final tickPaneW =
        showTickDist ? math.max(24.0, tickDistConfig.paneWidth) : 0.0;
    final plotW = math.max(1.0, size.width - KlineViewport.padL - KlineViewport.padR);
    final span = math.max(viewport.xSpan, 1e-6);
    final slotW = plotW / span;
    final barW = _candleBodyW(slotW);
    final xAxisTop = contentBottom;
    final plotLeft = KlineViewport.padL + tickPaneW;
    final plotRight = math.max(plotLeft + 40, size.width - chipPaneW);

    if (layer == _ChartPaintLayer.crosshair) {
      if (crosshairEnabled && crosshairX != null && crosshairY != null) {
        _drawCrosshair(canvas, size, contentBottom, plotTop, priceRange);
      }
      return;
    }

    if (layer == _ChartPaintLayer.chip) {
      canvas.save();
      canvas.clipRect(
        Rect.fromLTWH(0, plotTop, size.width, math.max(1, mainH - plotTop)),
      );
      final cut = bars.isEmpty ? 0 : (segAsOf ?? bars.last.idx);
      final yOf = (double p) => priceRange.yOf(p, plotTop, plotH);
      if (showTickDist) {
        // 笔数分布：主图左侧；桶宽与筹码共用，价轴对齐
        final step = chipConfig.bucketStep;
        final profile = TickDistProfileCompute.compute(
          bars: bars,
          cutoffX: cut,
          bucketStep: step,
        );
        ChipProfilePainter.draw(
          canvas: canvas,
          profile: profile,
          config: tickDistConfig.toChipConfig().copyWith(bucketStep: step),
          plotLeft: plotLeft,
          plotRight: plotRight,
          plotTop: plotTop,
          plotBottom: plotBottom,
          yOfPrice: yOf,
          highlightKn: 0,
          alignLeft: true,
        );
      }
      if (showChip) {
        final profile = ChipProfileCompute.compute(
          bars: bars,
          cutoffX: cut,
          bucketStep: chipConfig.bucketStep,
        );
        ({double b, double s, double w})? hoverBar;
        if (crosshairEnabled &&
            crosshairBarIdx != null &&
            crosshairBarIdx! >= 0 &&
            crosshairBarIdx! < bars.length) {
          hoverBar = _singleBarChipSums(bars[crosshairBarIdx!]);
        }
        ChipProfilePainter.draw(
          canvas: canvas,
          profile: profile,
          config: chipConfig,
          plotLeft: plotLeft,
          plotRight: plotRight,
          plotTop: plotTop,
          plotBottom: plotBottom,
          yOfPrice: yOf,
          highlightKn: 0,
          hoverBar: hoverBar,
        );
      }
      canvas.restore();
      return;
    }

    // —— base：蜡烛 / 缠论 / 坐标轴（不含筹码与十字）——
    canvas.save();
    canvas.clipRect(
      Rect.fromLTWH(0, plotTop, size.width, math.max(1, mainH - plotTop)),
    );
    final chanDraw = !chipOnlyMode;
    // 方案B：K0 蜡烛/合并/连线 kn==0
    final showK0 = !chipOnlyMode
        ? mainIndicators.contains(const MainChartIndicator.kn(0))
        : true;
    if (showK0) {
      _drawCandles(canvas, size.width, plotTop, plotH, barW, slotW);
    }
    if (chanDraw && mainIndicators.isNotEmpty) {
      for (final ind in mainIndicators) {
        if (ind.kind == MainIndicatorKind.combine) {
          if (ind.kn == 0) {
            _drawKlineCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW);
          } else if (ind.kn == 1) {
            _drawK1CombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW);
          } else {
            _drawLevelCombineOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
          }
        } else if (ind.kind == MainIndicatorKind.kn) {
          if (ind.kn == 1) {
            _drawK1Candles(
                canvas, size.width, plotTop, plotH, barW, slotW, faint: true);
          } else if (ind.kn >= 2) {
            _drawLevelUnitCandlesOnMainChart(
                canvas, size.width, plotTop, plotH, barW, slotW, ind.kn);
          }
        } else if (ind.kind == MainIndicatorKind.line) {
          if (ind.kn == 0) {
            _drawK0Lines(canvas, size.width, plotTop, plotH, slotW);
          } else {
            _drawK1LinesForLevel(
                canvas, size.width, plotTop, plotH, slotW, ind.kn);
          }
        } else if (ind.kind == MainIndicatorKind.zs) {
          _drawZSOnMainChart(
            canvas,
            size.width,
            plotTop,
            plotH,
            barW,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.fxTripleParallel) {
          _drawFxTripleParallel(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.fxQuadPair) {
          _drawFxQuadPair(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.trendLine) {
          _drawTrendLine(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.meanLine) {
          _drawMeanLine(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.trendChannel) {
          _drawTrendChannel(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.boll) {
          _drawBoll(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.demark) {
          _drawDemarkMain(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        } else if (ind.kind == MainIndicatorKind.stepRhythm) {
          _drawStepRhythmMain(
            canvas,
            size.width,
            plotTop,
            plotH,
            slotW,
            ind.kn,
          );
        }
      }
    }
    _drawYLabels(
      canvas,
      size.width,
      plotTop,
      plotH,
      priceRange,
      onLeft: showChip || showTickDist,
      leftX: showTickDist ? plotLeft + 2 : null,
    );
    canvas.restore();

    if (chanDraw && subIndicators.isNotEmpty) {
      canvas.save();
      canvas.clipRect(Rect.fromLTWH(0, mainH, size.width, math.max(1, volH)));
      _drawSubCharts(canvas, size.width, mainH, barW, slotW);
      canvas.restore();
    }

    _drawXAxis(canvas, size.width, xAxisTop);
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
    // 方案B：种子框首段 structure level==0
    _drawSeedPhaseLines(canvas, w, plotTop, plotH, slotW, level: 0, style: null);
  }

  /// 取 as-of 当下该层种子框快照（逐K冻结，与 tooltip/ML 同源）
  LevelSnap? _asOfSeedSnap(int level) {
    if (barFeatures.isEmpty || bars.isEmpty) return null;
    final asOf = segAsOf ?? bars.last.idx;
    if (asOf < 0) return null;
    final idx = asOf.clamp(0, barFeatures.length - 1);
    final feat = barFeatures[idx];
    // 方案B：只按 lv.level 匹配，允许 level==0
    for (final s in feat.levels) {
      if (s.level == level) return s;
    }
    return null;
  }

  double _polePriceAt(int x, {required bool useHigh}) {
    if (x < 0 || x >= bars.length) return 0;
    return useHigh ? bars[x].high : bars[x].low;
  }

  /// 种子框画线全层同构入口：UNKNOWN→开口虚线；JUDGE/CONFIRM→ABC（互斥）。
  void _drawSeedPhaseLines(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required int level,
    required ChartLevelLineStyle? style,
  }) {
    _drawSeedUnknownOpenTip(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      level: level,
      style: style,
    );
    _drawSeedAbcLines(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      level: level,
      style: style,
    );
  }

  /// 种子 UNKNOWN 开口虚线（方案2·D2·S-b，全层同构）：有 group1 才画。
  void _drawSeedUnknownOpenTip(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required int level,
    required ChartLevelLineStyle? style,
  }) {
    final snap = _asOfSeedSnap(level);
    if (snap == null) return;
    final asOf = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);
    final line = computeSeedUnknownOpenTip(
      bars: bars,
      asOf: asOf,
      seedBoxX1: snap.seedBoxX1,
      seedBoxX2: snap.seedBoxX2,
      seedBoxHigh: snap.seedBoxHigh,
      seedBoxLow: snap.seedBoxLow,
      seedLeaveDir: snap.seedLeaveDir,
      firstFxState: snap.firstFxState,
      seedConfirmed: snap.seedConfirmed,
    );
    if (line == null) return;
    _paintDisplayBuildingLines(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      lines: [line],
      style: style,
    );
  }

  /// 种子框画线：JUDGE→两线虚；CONFIRM→A→B 由冻结段承担，仅画 B→C 虚线
  void _drawSeedAbcLines(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required int level,
    required ChartLevelLineStyle? style,
  }) {
    final snap = _asOfSeedSnap(level);
    if (snap == null) return;
    final state = snap.firstFxState;
    if (state != 'JUDGE' && state != 'CONFIRM') return;
    if (snap.drawAX < 0 || snap.drawBX < 0) return;
    if (snap.seedFx != 'TOP' && snap.seedFx != 'BOTTOM') return;

    final seedTop = snap.seedFx == 'TOP';
    final aPrice = _polePriceAt(snap.drawAX, useHigh: seedTop);
    final bPrice = _polePriceAt(snap.drawBX, useHigh: !seedTop);

    void paintSeg(int x0, double p0, int x1, double p1, {required bool dashed}) {
      final geomMin = math.min(x0, x1);
      final geomMax = math.max(x0, x1);
      if (geomMax < viewport.viewXMin - 1 || geomMin > viewport.viewXMax + 1) {
        return;
      }
      final a = Offset(
        _barCenterX(x0, w, slotW),
        priceRange.yOf(p0, plotTop, plotH),
      );
      final b = Offset(
        _barCenterX(x1, w, slotW),
        priceRange.yOf(p1, plotTop, plotH),
      );
      if (style != null) {
        final paint = Paint()
          ..color = style.color
          ..strokeWidth = dashed ? style.buildingStrokeWidth : style.strokeWidth
          ..style = PaintingStyle.stroke;
        _drawStyledSegmentLine(
          canvas,
          a,
          b,
          paint,
          style,
          building: dashed && showBuildingDash,
        );
      } else {
        final paint = Paint()
          ..color = ChartLineColors.bi.withValues(alpha: dashed ? 0.55 : 1.0)
          ..strokeWidth = dashed ? 1.4 : 1.6
          ..style = PaintingStyle.stroke;
        if (dashed && showBuildingDash) {
          _drawDashedLine(canvas, a, b, paint);
        } else {
          canvas.drawLine(a, b, paint);
        }
      }
    }

    if (state == 'JUDGE') {
      paintSeg(snap.drawAX, aPrice, snap.drawBX, bPrice, dashed: true);
      if (snap.drawCX >= 0) {
        final cPrice = _polePriceAt(snap.drawCX, useHigh: seedTop);
        paintSeg(snap.drawBX, bPrice, snap.drawCX, cPrice, dashed: true);
      }
    } else {
      // CONFIRM：A→B 实线由已冻结 LevelSegment 绘制；此处只补 B→C 虚线
      if (snap.drawCX >= 0) {
        final cPrice = _polePriceAt(snap.drawCX, useHigh: seedTop);
        paintSeg(snap.drawBX, bPrice, snap.drawCX, cPrice, dashed: true);
      }
    }
  }

  /// 种子合并框叠加（确认前可虚线，确认后实线；色=同层合并色）
  void _drawSeedBoxOverlay(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW, {
    required int level,
    List<double> buildingDashPattern = const [4, 3],
  }) {
    final snap = _asOfSeedSnap(level);
    if (snap == null || snap.seedBoxSeq < 0) return;
    if (snap.seedBoxX1 < 0 || snap.seedBoxX2 < 0) return;
    if (!snap.seedBoxHigh.isFinite || !snap.seedBoxLow.isFinite) return;

    final frame = KlineCombineFrame(
      x1: snap.seedBoxX1,
      x2: snap.seedBoxX2,
      t1: '',
      t2: '',
      high: snap.seedBoxHigh,
      low: snap.seedBoxLow,
      fx: snap.seedFx == 'UNKNOWN' ? 'UNKNOWN' : snap.seedFx,
      count: 1,
    );
    // 种子框跟该层合并同色（方案B：level=displayKn）
    final seedColor = ChartLevelLineStyle.forDisplayKn(level).color;
    _drawCombineFramesOnMainChart(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      [frame],
      seedColor,
      seedColor.withValues(alpha: 0.12),
      lastAsBuilding: !snap.seedConfirmed && showBuildingDash,
      buildingDashPattern: buildingDashPattern,
    );
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
    // 方案B：K0连线 structure level==0；分型判断 kn==0
    final frozenIdx = <int>{
      for (final s in asOfLevelSegments(
        levels: levels,
        level: 0,
        asOf: tailIdx,
      ))
        s.idx,
    };
    final liveJudgments = collectFractalJudgmentEvents(
      kn: 0,
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

  /// 方案B：指定层连线（kn≥1 → K{kn}连线）；勾哪层画哪层。
  void _drawK1LinesForLevel(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (kn < 1) return;
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
      _drawSeedPhaseLines(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        level: kn,
        style: ChartLevelLineStyle.forDisplayKn(kn),
      );
      return;
    }
    // 回退：仅 K1 且无 levels 时用旧 k1Analysis
    if (kn != 1) return;
    final style = ChartLevelLineStyle.forDisplayKn(1);
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
        level: 1,
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

    final style = ChartLevelLineStyle.forDisplayKn(kn);
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
    // 种子合并框：用 LevelSnap.seed_box_*（全层同构，不限 displayFrames.first）
    _drawSeedBoxOverlay(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      level: kn,
      buildingDashPattern: style.buildingDashPattern,
    );
  }

  /// 取某层（kn≥1）的单元 view（用于合并框横向对齐 / KN 指标画淡实体），含十字线 as-of 重算。
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

  /// 主图 Kn三型平移线（方案B：kn==displayKn）。
  void _drawFxTripleParallel(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (kn < 0 || bars.isEmpty) return;
    final displayKn = kn;
    final asOf = segAsOf;
    // 十字 asOf：层/确认只认 asOfBundle（失败=空，禁末态）
    final lv = asOf != null
        ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
        : levels;
    final k0 = asOf != null
        ? (zsAsOfBundle?.k0Confirms ?? const <K0ConfirmSignal>[])
        : k0ConfirmSignals;
    final poles = collectLevelFxPoles(
      displayKn: displayKn,
      bars: bars,
      k0Confirms: k0,
      levels: lv,
      asOf: asOf,
    );
    // 无十字：仅最新窗；有十字：近邻窗（与 tip 同口径）
    final focusX = asOf;
    final rays = selectFxExtendRays(
      calcAllTripleGroups(poles),
      focusX: focusX,
    );
    for (final ray in rays) {
      _paintFxExtendRay(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        ray: ray,
        displayKn: displayKn,
      );
    }
  }

  /// 主图 Kn四型对线（两顶线 + 两底线）。方案B：kn==displayKn。
  void _drawFxQuadPair(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (kn < 0 || bars.isEmpty) return;
    final displayKn = kn;
    final asOf = segAsOf;
    final lv = asOf != null
        ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
        : levels;
    final k0 = asOf != null
        ? (zsAsOfBundle?.k0Confirms ?? const <K0ConfirmSignal>[])
        : k0ConfirmSignals;
    final poles = collectLevelFxPoles(
      displayKn: displayKn,
      bars: bars,
      k0Confirms: k0,
      levels: lv,
      asOf: asOf,
    );
    final focusX = asOf;
    final rays = selectFxExtendRays(
      calcAllQuadGroups(poles),
      focusX: focusX,
    );
    for (final ray in rays) {
      _paintFxExtendRay(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        ray: ray,
        displayKn: displayKn,
      );
    }
  }

  /// 主图 Kn均线（kn=显示层；收盘价滑窗 MEAN）。
  void _drawMeanLine(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final frozen = mathFreezeStore?.mean(kn);
    final Map<int, List<double?>> seriesMap;
    if (frozen != null) {
      seriesMap = frozen;
    } else {
      final lv = asOf != null
          ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
          : levels;
      seriesMap = computeMeanSeriesForLevel(
        displayKn: kn,
        bars: bars,
        levels: lv,
        periods: mathIndicatorConfig.meanPeriods,
        asOf: asOf,
      );
    }
    final periods = seriesMap.keys.toList()..sort();
    for (var i = 0; i < periods.length; i++) {
      final t = periods[i];
      final series = seriesMap[t];
      if (series == null) continue;
      final hue = (i * 0.17) % 1.0;
      final color = HSVColor.fromAHSV(1, hue * 360, 0.75, 0.95).toColor();
      _paintPriceSeries(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        series: series,
        color: color,
        strokeWidth: 1.2,
      );
    }
  }

  /// 主图 Kn通道（MAX 上轨 + MIN 下轨）。
  void _drawTrendChannel(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final frozen = mathFreezeStore?.channel(kn);
    final Map<int, ({List<double?> max, List<double?> min})> seriesMap;
    if (frozen != null) {
      seriesMap = frozen;
    } else {
      final lv = asOf != null
          ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
          : levels;
      seriesMap = computeChannelSeriesForLevel(
        displayKn: kn,
        bars: bars,
        levels: lv,
        periods: mathIndicatorConfig.channelPeriods,
        asOf: asOf,
      );
    }
    final periods = seriesMap.keys.toList()..sort();
    for (var i = 0; i < periods.length; i++) {
      final t = periods[i];
      final pair = seriesMap[t];
      if (pair == null) continue;
      final hue = (0.05 + i * 0.21) % 1.0;
      final top = HSVColor.fromAHSV(1, hue * 360, 0.8, 0.95).toColor();
      final bot = HSVColor.fromAHSV(1, ((hue + 0.45) % 1.0) * 360, 0.8, 0.9)
          .toColor();
      _paintPriceSeries(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        series: pair.max,
        color: top,
        strokeWidth: 1.4,
      );
      _paintPriceSeries(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        series: pair.min,
        color: bot,
        strokeWidth: 1.4,
      );
    }
  }

  /// 按 K0 下标连价序列（null 段断开；十字 asOf 时右侧 x>asOf 不画）。
  void _paintPriceSeries(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required List<double?> series,
    required Color color,
    double strokeWidth = 1.2,
  }) {
    final paint = Paint()
      ..color = color
      ..strokeWidth = strokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round
      ..strokeJoin = StrokeJoin.round;
    final maxX = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);
    Offset? prev;
    for (var i = 0; i < bars.length && i < series.length; i++) {
      final idx = bars[i].idx;
      // 十字开启：右侧(idx>asOf)不画，与蜡烛/成交量同构
      if (idx > maxX) {
        prev = null;
        continue;
      }
      final v = series[i];
      if (v == null) {
        prev = null;
        continue;
      }
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) {
        prev = null;
        continue;
      }
      final pt = Offset(
        _barCenterX(idx, w, slotW),
        priceRange.yOf(v, plotTop, plotH),
      );
      if (prev != null) {
        canvas.drawLine(prev, pt, paint);
      }
      prev = pt;
    }
  }

  /// 主图 Kn布林带（MID/UP/DOWN）。
  void _drawBoll(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final BollK0Series boll = mathFreezeStore?.boll(kn) ??
        computeBollForLevel(
          displayKn: kn,
          bars: bars,
          levels: asOf != null
              ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
              : levels,
          n: mathIndicatorConfig.bollN,
          asOf: asOf,
        );
    final midColor = ChartLevelLineStyle.colorForDisplayKn(kn);
    _paintPriceSeries(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      series: boll.mid,
      color: midColor,
      strokeWidth: 1.4,
    );
    _paintPriceSeries(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      series: boll.up,
      color: midColor.withValues(alpha: 0.55),
      strokeWidth: 1.0,
    );
    _paintPriceSeries(
      canvas,
      w,
      plotTop,
      plotH,
      slotW,
      series: boll.down,
      color: midColor.withValues(alpha: 0.55),
      strokeWidth: 1.0,
    );
  }

  /// 主图 Kn Demark：锚在 K0 最低价上方；多标记垂直排；买/卖与类型分色。
  void _drawDemarkMain(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int displayKn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final DemarkK0Series demark = mathFreezeStore?.demark(displayKn) ??
        computeDemarkForLevel(
          displayKn: displayKn,
          bars: bars,
          levels: asOf != null
              ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
              : levels,
          config: mathIndicatorConfig,
          asOf: asOf,
        );
    final maxX = asOf ?? bars.last.idx;
    final fontSize = math.max(8.0, slotW * 0.45);
    final lineH = fontSize + 1.5;
    final tp = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );
    for (var i = 0; i < bars.length && i < demark.marksAt.length; i++) {
      final raw = demark.marksAt[i];
      if (raw == null || raw.isEmpty) continue;
      final bar = bars[i];
      final x = bar.idx;
      if (x > maxX) continue;
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) continue;
      final marks = BarFeatureLookup.orderDemarkMarksForPaint(raw);
      final cx = _barCenterX(x, w, slotW);
      // 锚 K0 最低价，文字自低点向上叠
      var y = priceRange.yOf(bar.low, plotTop, plotH) - 2;
      for (final m in marks) {
        final isComplete = m.type == 'complete';
        tp.text = TextSpan(
          text: BarFeatureLookup.formatDemarkMark(m),
          style: TextStyle(
            color: _demarkMarkColor(m),
            fontSize: isComplete ? fontSize + 0.5 : fontSize,
            fontWeight: isComplete || m.type == 'setup'
                ? FontWeight.w700
                : FontWeight.w500,
          ),
        );
        tp.layout();
        y -= tp.height;
        tp.paint(canvas, Offset(cx - tp.width / 2, y));
        y -= (lineH - tp.height).clamp(0.0, lineH);
      }
    }
  }

  /// Demark：买(dir<0)红系、卖(dir>0)绿系；完成信号最醒目；countdown 换档区分。
  Color _demarkMarkColor(DemarkMark m) {
    final isBuy = m.dir < 0;
    if (m.type == 'complete') {
      return isBuy ? const Color(0xFFB91C1C) : const Color(0xFF15803D);
    }
    if (m.type == 'setup') {
      return isBuy ? const Color(0xFFDC2626) : const Color(0xFF16A34A);
    }
    return isBuy ? const Color(0xFFF97316) : const Color(0xFF0D9488);
  }

  /// 主图 Kn趋势线（父段内支撑/压力；子线层同号）。方案B：kn==displayKn。
  void _drawTrendLine(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int kn,
  ) {
    if (kn < 0 || bars.isEmpty) return;
    final displayKn = kn;
    final asOf = segAsOf;
    // 十字 asOf：只认 asOfBundle（失败=空，禁末态）
    final lv = asOf != null
        ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
        : levels;
    final rays = selectFxExtendRays(
      calcTrendLineGroupsForLevel(
        displayKn: displayKn,
        levels: lv,
        asOf: asOf,
      ),
      focusX: asOf,
    );
    for (final ray in rays) {
      _paintFxExtendRay(
        canvas,
        w,
        plotTop,
        plotH,
        slotW,
        ray: ray,
        displayKn: displayKn,
      );
    }
  }

  /// 画延伸射线：可选弦 (x1,y1)→(x0,y0)，再自 (x0,y0) 外推。
  /// 十字 asOf：右端截到 asOf 柱心（与蜡烛/均线同构，不向未来画）；无十字仍到视口右缘。
  void _paintFxExtendRay(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW, {
    required FxExtendRay ray,
    required int displayKn,
  }) {
    final style = ChartLevelLineStyle.forDisplayKn(displayKn);
    final paint = Paint()
      ..color = style.color.withValues(alpha: style.buildingAlpha)
      ..strokeWidth = style.buildingStrokeWidth
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;

    final asOf = segAsOf;
    // 锚点已在 asOf 右侧：整条不画
    if (asOf != null && ray.x0 > asOf) return;

    // 弦：左锚 → 右锚（左锚若越过 asOf 则跳过弦，只画开口）
    if (ray.x1 != null &&
        ray.y1 != null &&
        (asOf == null || ray.x1! <= asOf)) {
      final ax = _barCenterX(ray.x1!.round(), w, slotW);
      final ay = priceRange.yOf(ray.y1!, plotTop, plotH);
      final bx = _barCenterX(ray.x0.round(), w, slotW);
      final by = priceRange.yOf(ray.y0, plotTop, plotH);
      _drawPatternLine(
        canvas,
        Offset(ax, ay),
        Offset(bx, by),
        paint,
        style.buildingDashPattern,
      );
    }

    // 向右外推：无十字→视口右缘；有 asOf→截到 asOf
    final viewEnd = viewport.xToIndex(w - KlineViewport.padR, w);
    final endBarF =
        asOf != null ? math.min(viewEnd, asOf.toDouble()) : viewEnd;
    if (endBarF <= ray.x0) return;
    final endPrice = ray.y0 + ray.slope * (endBarF - ray.x0);
    final sx = _barCenterX(ray.x0.round(), w, slotW);
    final sy = priceRange.yOf(ray.y0, plotTop, plotH);
    final ex = asOf != null
        ? _barCenterX(endBarF.round(), w, slotW)
        : (w - KlineViewport.padR);
    final ey = priceRange.yOf(endPrice, plotTop, plotH);
    _drawPatternLine(
      canvas,
      Offset(sx, sy),
      Offset(ex, ey),
      paint,
      style.buildingDashPattern,
    );
  }

  /// 主图 Kn中枢框：强制消费 Rust zs_* JSON（K0=分钟K段；Kn=连线段）。
  /// 自定义：框内斜线填充，与「Kn合并」纯色半透明框区分（全层同构）。
  void _drawZSOnMainChart(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double barW,
    double slotW,
    int kn,
  ) {
    final frames = computeZsFramesAtAsOf(
      kn: kn,
      combineFrames: combineFrames,
      levels: levels,
      barFeatures: barFeatures,
      asOf: zsAsOfBundle != null ? segAsOf : null,
      bars: bars,
      truncationCheck: truncationCheck,
      zsK0Frames: zsK0Frames,
      asOfBundle: zsAsOfBundle,
    );
    if (frames.isEmpty) return;

    final style = ChartLevelLineStyle.forZS(kn);
    final stroke = Paint()
      ..color = style.color.withValues(alpha: 0.9)
      ..strokeWidth = 1.4
      ..style = PaintingStyle.stroke;
    final hatch = Paint()
      ..color = style.color.withValues(alpha: 0.82)
      ..strokeWidth = 1.6
      ..style = PaintingStyle.stroke;
    // 自定义：中枢框填充加深，与合并框半透明纯色更易辨
    final wash = Paint()..color = style.color.withValues(alpha: 0.22);

    for (var i = 0; i < frames.length; i++) {
      final f = frames[i];
      if (f.x2 < viewport.viewXMin - 1 || f.x1 > viewport.viewXMax + 1) {
        continue;
      }
      final (xLeft, xRight) = _combineFrameHSpan(f.x1, f.x2, w, slotW, barW);
      final yHigh = priceRange.yOf(f.high, plotTop, plotH);
      final yLow = priceRange.yOf(f.low, plotTop, plotH);
      var top = math.min(yHigh, yLow);
      var bottom = math.max(yHigh, yLow);
      if ((bottom - top).abs() < 3.0) {
        final mid = (top + bottom) / 2;
        top = mid - 1.5;
        bottom = mid + 1.5;
      }

      final rect = Rect.fromLTRB(
        math.min(xLeft, xRight),
        top,
        math.max(xLeft, xRight),
        bottom,
      );
      // 浅底 + 斜线填充（与合并框纯色区分）
      canvas.drawRect(rect, wash);
      _fillHatchRect(canvas, rect, hatch);
      // 虚实线跟 is_sure：确认离开定型→实线；动态离开/末开放→虚线（禁未来）
      // 只画框，不画「Kn中枢xx」文字（与 tooltip「Kn中枢」对齐、减遮挡）
      final useDash = !f.isSure && showBuildingDash;
      if (useDash) {
        _strokeDashedRect(canvas, rect, stroke, const [4, 4]);
      } else {
        canvas.drawRect(rect, stroke);
      }
    }
  }

  /// Kn中枢框内斜线填充（自定义图形，区分合并框；加深便于辨认）。
  void _fillHatchRect(Canvas canvas, Rect rect, Paint paint) {
    if (rect.width < 1 || rect.height < 1) return;
    canvas.save();
    canvas.clipRect(rect);
    const step = 5.0;
    final start = rect.left - rect.height;
    for (var x = start; x < rect.right; x += step) {
      canvas.drawLine(
        Offset(x, rect.bottom),
        Offset(x + rect.height, rect.top),
        paint,
      );
    }
    canvas.restore();
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

  /// 单层 N 段（方案B：level≥1）已冻结段 + 构建中段。
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
    if (level < 1) return;
    final style = ChartLevelLineStyle.forDisplayKn(level);
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
    // tick：一字线画点；其它周期：红涨绿跌实体+影线
    const up = Color(0xFFE53935);
    const down = Color(0xFF26A69A);
    final wick = Paint()..strokeWidth = 1.2;
    final drawDots = period == 'tick';
    final dotR = math.max(1.2, math.min(barW * 0.45, slotW * 0.35));

    // 踩坑：之前 _drawCandles 遍历 bars 全部索引（5 万+），每帧都在空转循环；
    // 改为只扫视口附近 ±2 根，大幅降低滚动/缩放时的 CPU 开销。
    final i0 = (viewport.viewXMin.floor() - 2).clamp(0, bars.length - 1);
    final i1 = (viewport.viewXMax.ceil() + 2).clamp(0, bars.length - 1);
    for (var i = i0; i <= i1; i++) {
      final idx = bars[i].idx;
      // 十字线激活时，按当步截断：右侧(idx>segAsOf)的 K0 蜡烛不绘制，与 K1/K2/.../Kn 各层一致
      final asOf = segAsOf;
      if (asOf != null && idx > asOf) continue;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) continue;
      final b = bars[i];
      final cx = _barCenterX(idx, w, slotW);
      // 一字线 open==close：相对前收着色，避免全红
      final Color color;
      if (drawDots) {
        if (i > 0 && b.close != bars[i - 1].close) {
          color = b.close > bars[i - 1].close ? up : down;
        } else {
          color = up;
        }
      } else {
        color = b.isUp ? up : down;
      }

      if (drawDots) {
        final y = priceRange.yOf(b.close, plotTop, plotH);
        canvas.drawCircle(Offset(cx, y), dotR, Paint()..color = color);
        continue;
      }

      final x = cx - barW / 2;
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
    // 方案B：K0 displayKn=0
    final k0Style = ChartLevelLineStyle.forDisplayKn(0);
    _drawCombineFramesOnMainChart(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      combineFrames,
      k0Style.color,
      k0Style.color.withValues(alpha: 0.13),
      lastAsBuilding: showBuildingDash,
      buildingDashPattern: k0Style.buildingDashPattern,
    );
    // 种子框（K0合并层=structure 0）
    _drawSeedBoxOverlay(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      level: 0,
      buildingDashPattern: ChartLevelLineStyle.forDisplayKn(0).buildingDashPattern,
    );
  }

  /// 主图 K线合并 / K1合并线框：按真实价格坐标叠加。
  /// [lastAsBuilding]=true 时：末框虚线（构建中合并），前框实线（已冻结）；只画框不标「顶/底」。
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
      // 末组虚线=构建中；其余实线=已冻结；主图合并框只画框，不标「顶/底」
      final building = lastAsBuilding && i == last;
      if (building) {
        _strokeDashedRect(canvas, rect, framePaint, buildingDashPattern);
      } else {
        canvas.drawRect(rect, framePaint);
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
      // 方案B：K1 displayKn=1
      final k1Style = ChartLevelLineStyle.forDisplayKn(1);
      _drawCombineFramesOnMainChart(
        canvas,
        w,
        plotTop,
        plotH,
        barW,
        slotW,
        k1CombineFrames,
        k1Style.color.withValues(alpha: 0.85),
        k1Style.color.withValues(alpha: 0.08),
        alignK1CombineWithViews: true,
        // 末组=构建中合并（虚线）；前组=已冻结合并（实线）；showBuildingDash 关则全实线
        lastAsBuilding: showBuildingDash,
        buildingDashPattern: k1Style.buildingDashPattern,
      );
    }
    // 种子框（K1合并层=structure 1）
    _drawSeedBoxOverlay(
      canvas,
      w,
      plotTop,
      plotH,
      barW,
      slotW,
      level: 1,
      buildingDashPattern: ChartLevelLineStyle.forDisplayKn(1).buildingDashPattern,
    );
  }

  void _drawSubCharts(
    Canvas canvas,
    double w,
    double volTop,
    double barW,
    double slotW,
  ) {
    final chipBand = math.min(
      subChipBarHeight,
      KlineViewport.subIndicatorChipMaxBand,
    );
    final innerTop = volTop + chipBand;
    final innerBottom = contentBottom - 4;
    final innerH = math.max(
      KlineViewport.minSubMarkerPlotH,
      innerBottom - innerTop,
    );
    if (innerH <= 0) return;

    if (subIndicators.any((e) => e.kind == SubIndicatorKind.volume)) {
      final volKns = subIndicators
          .where((e) => e.kind == SubIndicatorKind.volume)
          .map((e) => e.kn)
          .toList()
        ..sort();
      // 全层一次算：K0 原生；K(n+1)=下层增量在本层单元上累加步进
      final allVol = computeAllKnVolumeSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      // Kn>0 买入量系列，用于红绿叠柱
      final allBuyVol = computeAllKnBuyVolumeSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      for (final kn in volKns) {
        _drawVolume(
          canvas,
          w,
          innerTop,
          innerBottom,
          innerH,
          barW,
          slotW,
          kn: kn,
          allVolSeries: allVol,
          allBuyVolSeries: allBuyVol,
          // Kn>0 传入该层 B/S 历史打点，用于 B/S 方向着色；K0 传 null 保持原逻辑
          buy1Frames: kn > 0 ? _buy1FramesForKn(kn) : null,
          sell1Frames: kn > 0 ? _sell1FramesForKn(kn) : null,
        );
      }
    }
    // Kn笔数：与成交量同设计逻辑，复用 _drawVolume
    if (subIndicators.any((e) => e.kind == SubIndicatorKind.tickCount)) {
      final tickKns = subIndicators
          .where((e) => e.kind == SubIndicatorKind.tickCount)
          .map((e) => e.kn)
          .toList()
        ..sort();
      final allTick = computeAllKnTickCountSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      final allBuyTick = computeAllKnBuyTickCountSeries(
        bars: bars,
        levels: levels,
        barFeatures: barFeatures,
      );
      for (final kn in tickKns) {
        _drawVolume(
          canvas,
          w,
          innerTop,
          innerBottom,
          innerH,
          barW,
          slotW,
          kn: kn,
          allVolSeries: allTick,
          allBuyVolSeries: allBuyTick,
          buy1Frames: kn > 0 ? _buy1FramesForKn(kn) : null,
          sell1Frames: kn > 0 ? _sell1FramesForKn(kn) : null,
        );
      }
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
    // Kn中枢确认：实心；色=上个框相对前一枢抬高红/下移绿
    final zsConfirmKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.zsConfirm)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (var i = 0; i < zsConfirmKns.length; i++) {
      _drawKnZsSignalSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        zsConfirmKns[i],
        historyByKn: zsConfirmHistoryByKn,
        hollow: false,
        stackRank: i,
        stackCount: zsConfirmKns.length,
      );
    }
    // Kn中枢判断：空心；离开窗上个 + 确认同拍共点（对象=未确认框，非新芽）
    final zsJudgeKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.zsJudgment)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (var i = 0; i < zsJudgeKns.length; i++) {
      _drawKnZsSignalSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        zsJudgeKns[i],
        historyByKn: zsJudgmentHistoryByKn,
        hollow: true,
        stackRank: i,
        stackCount: zsJudgeKns.length,
      );
    }
    // BS标记全局 stack：所有类型/kns/classes 共用计数，避免文字重叠
    final class1Kns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.buy1)
        .map((e) => e.kn)
        .toList()
      ..sort();
    final class2Kns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.buy2)
        .map((e) => e.kn)
        .toList()
      ..sort();
    final classNItems = subIndicators
        .where((e) => e.kind == SubIndicatorKind.buyN && e.bsClass != null)
        .toList()
      ..sort((a, b) {
        final c = a.kn.compareTo(b.kn);
        if (c != 0) return c;
        return (a.bsClass ?? 0).compareTo(b.bsClass ?? 0);
      });
    for (final kn in class1Kns) {
      _drawKnClass1BsSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    for (final kn in class2Kns) {
      _drawKnClass2BsSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    for (final ind in classNItems) {
      _drawKnClassNBsSubChart(
        canvas, w, innerTop, innerH, barW, slotW, ind.kn, ind.bsClass!,
      );
    }
    // Kn相邻比例：折线 + 1.000/1.382 参考线（动态计算：冻段+展示轨虚线）
    final ratioKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.adjacentRatio)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (final kn in ratioKns) {
      _drawAdjacentRatioSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    // Kn连线斜率：折线 + 0 轴虚线（动态：冻段+展示轨）
    // （Kn节奏已迁主图 MainIndicatorKind.stepRhythm）
    final slopeKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.lineSlope)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (final kn in slopeKns) {
      _drawLineSlopeSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    // Kn MACD / RSI / KDJ
    final macdKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.macd)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (final kn in macdKns) {
      _drawMacdSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    final rsiKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.rsi)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (final kn in rsiKns) {
      _drawRsiSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    final kdjKns = subIndicators
        .where((e) => e.kind == SubIndicatorKind.kdj)
        .map((e) => e.kn)
        .toList()
      ..sort();
    for (final kn in kdjKns) {
      _drawKdjSubChart(canvas, w, innerTop, innerH, barW, slotW, kn);
    }
    // Kn Demark 已迁主图
    // Kn背驰：ratio 折线 + diver 柱（1/-1/0）
    final diverItems = subIndicators
        .where((e) =>
            e.kind == SubIndicatorKind.divergence && e.diverAlgo != null)
        .toList()
      ..sort((a, b) {
        final c = a.kn.compareTo(b.kn);
        if (c != 0) return c;
        return (a.diverAlgo?.index ?? 0).compareTo(b.diverAlgo?.index ?? 0);
      });
    for (final ind in diverItems) {
      _drawDivergenceSubChart(
        canvas,
        w,
        innerTop,
        innerH,
        barW,
        slotW,
        ind.kn,
        ind.diverAlgo!,
      );
    }
  }

  /// 副图 Kn背驰：ratio 折线；diver 在事件变化点画 ±1 短柱。
  void _drawDivergenceSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int displayKn,
    DivergenceAlgo algo,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final lv = asOf != null
        ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
        : levels;
    final zsK0 = asOf != null
        ? (zsAsOfBundle?.zsK0Frames ?? const <ZSFrame>[])
        : zsK0Frames;
    // 优先读会话冻结仓；无仓再现场算（单测/冷启动）
    Map<DivergenceAlgo, DivergenceAlgoK0Series> map;
    final frozen = diverFreezeStore?.level(displayKn);
    if (frozen != null) {
      map = truncateDivergenceMap(frozen, bars.length, asOf: asOf);
    } else {
      map = computeDivergenceForLevel(
        displayKn: displayKn,
        bars: bars,
        levels: lv,
        zsK0Frames: zsK0,
        config: mathIndicatorConfig,
        asOf: asOf,
        mathFreezeStore: mathFreezeStore,
      );
    }
    final series = map[algo];
    if (series == null) return;
    final maxX = asOf ?? bars.last.idx;
    var minV = -1.0;
    var maxV = 1.0;
    var any = false;
    for (var i = 0; i < bars.length && i < series.ratioAt.length; i++) {
      if (bars[i].idx > maxX) continue;
      final r = series.ratioAt[i];
      if (r == null || !r.isFinite) continue;
      if (!any) {
        minV = r;
        maxV = r;
        any = true;
      } else {
        if (r < minV) minV = r;
        if (r > maxV) maxV = r;
      }
    }
    if (minV > -1) minV = -1;
    if (maxV < 1) maxV = 1;
    if ((maxV - minV).abs() < 1e-12) {
      minV -= 1e-6;
      maxV += 1e-6;
    }
    final span = math.max(1e-9, maxV - minV);
    double subY(double v) => innerTop + (maxV - v) / span * innerH;

    final zeroPaint = Paint()
      ..color = const Color(0x6694A3B8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    _drawDashedLine(
      canvas,
      Offset(KlineViewport.padL, subY(0)),
      Offset(w - KlineViewport.padR, subY(0)),
      zeroPaint,
    );

    // 学习观察：十字 asOf 下，背驰副图高亮比较两段整 Kn 区间（全体算法）
    // in=蓝 / out=琥珀；MACD 类另在 MACD 副图按贡献柱差异高亮
    if (asOf != null && diverFreezeStore != null) {
      final cmp = diverFreezeStore!.spanAtOrBefore(displayKn, asOf);
      if (cmp != null) {
        void paintBand(int lo, int hi, Color color) {
          final a = lo < hi ? lo : hi;
          final b = lo < hi ? hi : lo;
          for (var x = a; x <= b; x++) {
            if (x > maxX) continue;
            if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
              continue;
            }
            final cx = _barCenterX(x, w, slotW);
            final half = math.max(1.0, slotW * 0.45);
            canvas.drawRect(
              Rect.fromLTRB(cx - half, innerTop, cx + half, innerTop + innerH),
              Paint()..color = color,
            );
          }
        }

        paintBand(cmp.inLoX, cmp.inHiX, const Color(0x552563EB));
        paintBand(cmp.outLoX, cmp.outHiX, const Color(0x55F59E0B));
      }
    }

    final upBar = Paint()..color = const Color(0xCCDC2626);
    final dnBar = Paint()..color = const Color(0xCC16A34A);
    final halfW = math.max(1.0, barW * 0.3);
    var prevFlag = 0;
    for (var i = 0; i < bars.length && i < series.diverAt.length; i++) {
      final x = bars[i].idx;
      if (x > maxX) continue;
      final flag = series.diverAt[i];
      final changed = flag != prevFlag;
      prevFlag = flag;
      if (!changed || flag == 0) continue;
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) continue;
      final cx = _barCenterX(x, w, slotW);
      final y0 = subY(0);
      final y1 = subY(flag.toDouble());
      final top = math.min(y0, y1);
      final bot = math.max(y0, y1);
      canvas.drawRect(
        Rect.fromLTRB(
            cx - halfW, top, cx + halfW, bot < top + 1 ? top + 1 : bot),
        flag > 0 ? upBar : dnBar,
      );
    }

    final linePaint = Paint()
      ..color = ChartLevelLineStyle.colorForDisplayKn(displayKn)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Offset? prev;
    for (var i = 0; i < bars.length && i < series.ratioAt.length; i++) {
      final x = bars[i].idx;
      if (x > maxX) {
        prev = null;
        continue;
      }
      final r = series.ratioAt[i];
      if (r == null || !r.isFinite) {
        prev = null;
        continue;
      }
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
        prev = null;
        continue;
      }
      final pt = Offset(_barCenterX(x, w, slotW), subY(r));
      if (prev != null) canvas.drawLine(prev, pt, linePaint);
      prev = pt;
    }
  }

  /// 副图 Kn相邻比例。
  void _drawAdjacentRatioSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int displayKn,
  ) {
    final hist = adjacentRatioHistoryByKn[displayKn] ?? const [];
    if (hist.isEmpty || bars.isEmpty) return;
    final asOf = segAsOf ?? bars.last.idx;
    var minV = 0.0;
    var maxV = 1.382;
    for (final p in hist) {
      if (p.x > asOf) continue;
      if (p.ratio < minV) minV = p.ratio;
      if (p.ratio > maxV) maxV = p.ratio;
    }
    final span = math.max(1e-9, maxV - minV);
    double subY(double v) => innerTop + (maxV - v) / span * innerH;

    // 参考线 1.000 / 1.382
    final refPaint = Paint()
      ..color = const Color(0x6694A3B8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final ref in [1.0, 1.382]) {
      if (ref < minV || ref > maxV) continue;
      final y = subY(ref);
      _drawDashedLine(
        canvas,
        Offset(KlineViewport.padL, y),
        Offset(w - KlineViewport.padR, y),
        refPaint,
      );
    }

    final linePaint = Paint()
      ..color = const Color(0xFF2563EB)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Offset? prev;
    final sorted = [...hist]..sort((a, b) => a.x.compareTo(b.x));
    for (final p in sorted) {
      if (p.x > asOf) {
        prev = null;
        continue;
      }
      if (p.x < viewport.viewXMin - 1 || p.x > viewport.viewXMax + 1) {
        prev = null;
        continue;
      }
      final pt = Offset(_barCenterX(p.x, w, slotW), subY(p.ratio));
      if (prev != null) canvas.drawLine(prev, pt, linePaint);
      prev = pt;
    }
  }

  /// 副图 Kn连线斜率：折线连相邻有点 K0；仅画 0 轴虚线；升/降点色区分。
  void _drawLineSlopeSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int displayKn,
  ) {
    final hist = lineSlopeHistoryByKn[displayKn] ?? const [];
    if (hist.isEmpty || bars.isEmpty) return;
    final asOf = segAsOf ?? bars.last.idx;
    var minV = 0.0;
    var maxV = 0.0;
    var any = false;
    for (final p in hist) {
      if (p.x > asOf) continue;
      if (!any) {
        minV = p.slope;
        maxV = p.slope;
        any = true;
      } else {
        if (p.slope < minV) minV = p.slope;
        if (p.slope > maxV) maxV = p.slope;
      }
    }
    if (!any) return;
    // 保证 0 轴落在可视内
    if (minV > 0) minV = 0;
    if (maxV < 0) maxV = 0;
    if ((maxV - minV).abs() < 1e-12) {
      minV -= 1e-6;
      maxV += 1e-6;
    }
    final span = math.max(1e-9, maxV - minV);
    double subY(double v) => innerTop + (maxV - v) / span * innerH;

    final zeroPaint = Paint()
      ..color = const Color(0x6694A3B8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    _drawDashedLine(
      canvas,
      Offset(KlineViewport.padL, subY(0)),
      Offset(w - KlineViewport.padR, subY(0)),
      zeroPaint,
    );

    final layerColor = ChartLevelLineStyle.colorForDisplayKn(displayKn);
    final linePaint = Paint()
      ..color = layerColor
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final upDot = Paint()
      ..color = const Color(0xFFE11D48)
      ..style = PaintingStyle.fill;
    final downDot = Paint()
      ..color = const Color(0xFF2563EB)
      ..style = PaintingStyle.fill;

    Offset? prev;
    final sorted = [...hist]..sort((a, b) => a.x.compareTo(b.x));
    for (final p in sorted) {
      if (p.x > asOf) {
        prev = null;
        continue;
      }
      if (p.x < viewport.viewXMin - 1 || p.x > viewport.viewXMax + 1) {
        prev = null;
        continue;
      }
      final pt = Offset(_barCenterX(p.x, w, slotW), subY(p.slope));
      if (prev != null) canvas.drawLine(prev, pt, linePaint);
      canvas.drawCircle(pt, 2.2, p.dir == 'up' ? upDot : downDot);
      prev = pt;
    }
  }

  /// 副图 Kn MACD：DIF/DEA 线 + MACD 柱。
  void _drawMacdSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int displayKn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final MacdK0Series macd = mathFreezeStore?.macd(displayKn) ??
        computeMacdForLevel(
          displayKn: displayKn,
          bars: bars,
          levels: asOf != null
              ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
              : levels,
          fast: mathIndicatorConfig.macdFast,
          slow: mathIndicatorConfig.macdSlow,
          signal: mathIndicatorConfig.macdSignal,
          asOf: asOf,
        );
    final maxX = asOf ?? bars.last.idx;
    var minV = 0.0;
    var maxV = 0.0;
    var any = false;
    final dif = macd.dif;
    final dea = macd.dea;
    final histArr = macd.macd;
    final nMacd = math.min(bars.length, math.min(dif.length, math.min(dea.length, histArr.length)));
    for (var i = 0; i < nMacd; i++) {
      if (bars[i].idx > maxX) continue;
      for (final v in [dif[i], dea[i], histArr[i]]) {
        if (v == null) continue;
        if (!any) {
          minV = v;
          maxV = v;
          any = true;
        } else {
          if (v < minV) minV = v;
          if (v > maxV) maxV = v;
        }
      }
    }
    if (!any) return;
    if (minV > 0) minV = 0;
    if (maxV < 0) maxV = 0;
    if ((maxV - minV).abs() < 1e-12) {
      minV -= 1e-6;
      maxV += 1e-6;
    }
    final span = math.max(1e-9, maxV - minV);
    double subY(double v) => innerTop + (maxV - v) / span * innerH;

    final zeroPaint = Paint()
      ..color = const Color(0x6694A3B8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    _drawDashedLine(
      canvas,
      Offset(KlineViewport.padL, subY(0)),
      Offset(w - KlineViewport.padR, subY(0)),
      zeroPaint,
    );

    // 学习观察：十字 asOf 下按算法差异高亮实际贡献柱
    // area=同号连续段；peak/full_area=整段同向柱；diff=整段全部非空柱；peak 另标极值点
    // in=蓝半透明底，out=琥珀半透明底
    final macdAlgo = macdDivergenceAlgoForKn(subIndicators, displayKn);
    if (asOf != null &&
        macdAlgo != null &&
        diverFreezeStore != null) {
      final cmp = diverFreezeStore!.spanAtOrBefore(displayKn, asOf);
      final hl = cmp == null
          ? null
          : buildDivergenceMacdHighlight(
              algo: macdAlgo,
              span: cmp,
              macdHist: histArr,
            );
      if (hl != null) {
        void paintXs(List<int> xs, Color color) {
          for (final x in xs) {
            if (x > maxX) continue;
            if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
              continue;
            }
            final cx = _barCenterX(x, w, slotW);
            final half = math.max(1.0, slotW * 0.45);
            canvas.drawRect(
              Rect.fromLTRB(cx - half, innerTop, cx + half, innerTop + innerH),
              Paint()..color = color,
            );
          }
        }

        void paintPeakMark(int? peakX, Color color) {
          if (peakX == null || peakX > maxX) return;
          if (peakX < viewport.viewXMin - 1 || peakX > viewport.viewXMax + 1) {
            return;
          }
          final cx = _barCenterX(peakX, w, slotW);
          final half = math.max(1.5, slotW * 0.5);
          canvas.drawRect(
            Rect.fromLTRB(
              cx - half,
              innerTop,
              cx + half,
              innerTop + innerH,
            ),
            Paint()
              ..color = color
              ..style = PaintingStyle.stroke
              ..strokeWidth = 2,
          );
        }

        paintXs(hl.inXs, const Color(0x552563EB)); // in 蓝
        paintXs(hl.outXs, const Color(0x55F59E0B)); // out 琥珀
        if (hl.algo == DivergenceAlgo.peak) {
          paintPeakMark(hl.inPeakX, const Color(0xFF2563EB));
          paintPeakMark(hl.outPeakX, const Color(0xFFF59E0B));
        }
      }
    }

    final upBar = Paint()..color = const Color(0xCCDC2626);
    final dnBar = Paint()..color = const Color(0xCC16A34A);
    final halfW = math.max(1.0, barW * 0.35);
    for (var i = 0; i < nMacd; i++) {
      final x = bars[i].idx;
      if (x > maxX) continue;
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) continue;
      final hist = histArr[i];
      if (hist == null) continue;
      final cx = _barCenterX(x, w, slotW);
      final y0 = subY(0);
      final y1 = subY(hist);
      final top = math.min(y0, y1);
      final bot = math.max(y0, y1);
      canvas.drawRect(
        Rect.fromLTRB(cx - halfW, top, cx + halfW, bot < top + 1 ? top + 1 : bot),
        hist >= 0 ? upBar : dnBar,
      );
    }

    final difPaint = Paint()
      ..color = const Color(0xFF2563EB)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final deaPaint = Paint()
      ..color = const Color(0xFFF59E0B)
      ..strokeWidth = 1.2
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    Offset? prevDif;
    Offset? prevDea;
    for (var i = 0; i < nMacd; i++) {
      final x = bars[i].idx;
      if (x > maxX) {
        prevDif = null;
        prevDea = null;
        continue;
      }
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
        prevDif = null;
        prevDea = null;
        continue;
      }
      final cx = _barCenterX(x, w, slotW);
      final d = dif[i];
      if (d != null) {
        final pt = Offset(cx, subY(d));
        if (prevDif != null) canvas.drawLine(prevDif, pt, difPaint);
        prevDif = pt;
      } else {
        prevDif = null;
      }
      final e = dea[i];
      if (e != null) {
        final pt = Offset(cx, subY(e));
        if (prevDea != null) canvas.drawLine(prevDea, pt, deaPaint);
        prevDea = pt;
      } else {
        prevDea = null;
      }
    }
  }

  /// 副图 Kn RSI：0–100 折线 + 30/70 参考线。
  void _drawRsiSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int displayKn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final List<double?> rsi = mathFreezeStore?.rsi(displayKn) ??
        computeRsiForLevel(
          displayKn: displayKn,
          bars: bars,
          levels: asOf != null
              ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
              : levels,
          period: mathIndicatorConfig.rsiPeriod,
          asOf: asOf,
        );
    const minV = 0.0;
    const maxV = 100.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final refPaint = Paint()
      ..color = const Color(0x6694A3B8)
      ..strokeWidth = 1
      ..style = PaintingStyle.stroke;
    for (final ref in [30.0, 70.0]) {
      final y = subY(ref);
      _drawDashedLine(
        canvas,
        Offset(KlineViewport.padL, y),
        Offset(w - KlineViewport.padR, y),
        refPaint,
      );
    }
    final linePaint = Paint()
      ..color = ChartLevelLineStyle.colorForDisplayKn(displayKn)
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final maxX = asOf ?? bars.last.idx;
    final nRsi = math.min(bars.length, rsi.length);
    Offset? prev;
    for (var i = 0; i < nRsi; i++) {
      final x = bars[i].idx;
      if (x > maxX) {
        prev = null;
        continue;
      }
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
        prev = null;
        continue;
      }
      final v = rsi[i];
      if (v == null) {
        prev = null;
        continue;
      }
      final pt = Offset(_barCenterX(x, w, slotW), subY(v));
      if (prev != null) canvas.drawLine(prev, pt, linePaint);
      prev = pt;
    }
  }

  /// 副图 Kn KDJ：K/D/J 三线。
  void _drawKdjSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int displayKn,
  ) {
    if (bars.isEmpty) return;
    final asOf = segAsOf;
    final KdjK0Series kdj = mathFreezeStore?.kdj(displayKn) ??
        computeKdjForLevel(
          displayKn: displayKn,
          bars: bars,
          levels: asOf != null
              ? (zsAsOfBundle?.levels ?? const <LevelBundle>[])
              : levels,
          period: mathIndicatorConfig.kdjPeriod,
          asOf: asOf,
        );
    const minV = 0.0;
    const maxV = 100.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final maxX = asOf ?? bars.last.idx;
    final paints = <Paint>[
      Paint()
        ..color = const Color(0xFF2563EB)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
      Paint()
        ..color = const Color(0xFFF59E0B)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
      Paint()
        ..color = const Color(0xFF9333EA)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round,
    ];
    final series = [kdj.k, kdj.d, kdj.j];
    for (var si = 0; si < series.length; si++) {
      final s = series[si];
      final nKdj = math.min(bars.length, s.length);
      Offset? prev;
      for (var i = 0; i < nKdj; i++) {
        final x = bars[i].idx;
        if (x > maxX) {
          prev = null;
          continue;
        }
        if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) {
          prev = null;
          continue;
        }
        final v = s[i];
        if (v == null) {
          prev = null;
          continue;
        }
        final pt = Offset(_barCenterX(x, w, slotW), subY(v.clamp(minV, maxV)));
        if (prev != null) canvas.drawLine(prev, pt, paints[si]);
        prev = pt;
      }
    }
  }

  /// 升组暖色（同父级 roundRef 共用一色：0-0/0-1/0-2…）
  static const _rhythmWarmColors = <Color>[
    Color(0xFFE11D48), // 玫红
    Color(0xFFF59E0B), // 琥珀
    Color(0xFFF97316), // 橙
    Color(0xFFEF4444), // 红
    Color(0xFFD97706), // 深琥珀
    Color(0xFFFB7185), // 浅玫
    Color(0xFFEA580C), // 深橙
    Color(0xFFB45309), // 棕橙
    Color(0xFFF43F5E), // 玫
  ];

  /// 降组冷色（同父级 roundRef 共用一色）
  static const _rhythmCoolColors = <Color>[
    Color(0xFF2563EB), // 蓝
    Color(0xFF0EA5E9), // 天蓝
    Color(0xFF14B8A6), // 青
    Color(0xFF6366F1), // 靛
    Color(0xFF06B6D4), // 青蓝
    Color(0xFF3B82F6), // 亮蓝
    Color(0xFF8B5CF6), // 紫（偏冷）
    Color(0xFF0284C7), // 深蓝
    Color(0xFF0D9488), // 深青
  ];

  Color _rhythmColorFor(StepRhythmLinePoint p) {
    final palette = p.dir == 'up' ? _rhythmWarmColors : _rhythmCoolColors;
    return palette[p.roundRef.clamp(0, palette.length - 1)];
  }

  /// 主图 Kn步进节奏：value=节奏投影价，挂价轴；Δx==1 点线续连；名在左侧；同父级同色；升暖降冷。
  void _drawStepRhythmMain(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    double slotW,
    int displayKn,
  ) {
    final hist = stepRhythmHistoryByKn[displayKn] ?? const [];
    if (hist.isEmpty || bars.isEmpty) return;
    final asOf = segAsOf ?? bars.last.idx;
    final visible = hist.where((e) => e.x <= asOf).toList();
    if (visible.isEmpty) return;

    // 按 key 分组（不同 label/组不混连）
    final byKey = <String, List<StepRhythmLinePoint>>{};
    for (final p in visible) {
      byKey.putIfAbsent(p.key, () => []).add(p);
    }
    final tp = TextPainter(
      textAlign: TextAlign.right,
      textDirection: TextDirection.ltr,
    );
    for (final entry in byKey.entries) {
      final pts = entry.value..sort((a, b) => a.x.compareTo(b.x));
      if (pts.isEmpty) continue;
      final color = _rhythmColorFor(pts.first);
      final linePaint = Paint()
        ..color = color.withValues(alpha: 0.85)
        ..strokeWidth = 1.2
        ..style = PaintingStyle.stroke
        ..strokeCap = StrokeCap.round;
      final dotPaint = Paint()
        ..color = color
        ..style = PaintingStyle.fill;

      StepRhythmLinePoint? prevP;
      Offset? prevPt;
      Offset? labelAnchor; // 左侧标名：取视口内最左点
      for (final p in pts) {
        if (p.x < viewport.viewXMin - 1 || p.x > viewport.viewXMax + 1) {
          prevP = null;
          prevPt = null;
          continue;
        }
        // value 已是节奏投影价（挂分型锚点价附近），直接映射主图价轴
        final pt = Offset(
          _barCenterX(p.x, w, slotW),
          priceRange.yOf(p.value, plotTop, plotH),
        );
        // 仅相邻 K0（Δx==1）点线续连；中间无值则断开（不自动跨缺口）
        if (prevP != null && prevPt != null && p.x - prevP.x == 1) {
          _drawDashedLine(canvas, prevPt, pt, linePaint);
        }
        // K0 颗粒度打点（对准柱心）
        canvas.drawCircle(pt, 2.2, dotPaint);
        labelAnchor ??= pt;
        prevP = p;
        prevPt = pt;
      }
      // 名称显示在左侧（相对该系列视口内最左点）
      if (labelAnchor != null) {
        tp.text = TextSpan(
          text: pts.first.label,
          style: TextStyle(
            color: color,
            fontSize: 9,
            fontWeight: FontWeight.w600,
          ),
        );
        tp.layout();
        final lx = (labelAnchor.dx - tp.width - 4).clamp(2.0, w - tp.width);
        tp.paint(canvas, Offset(lx, labelAnchor.dy - tp.height / 2));
      }
    }
  }

  /// 取某层一买：只扫会话历史（对齐分型判断；禁止 asOf/末态覆盖消点）。
  List<Buy1Frame> _buy1FramesForKn(int kn) =>
      buy1HistoryForKn(buy1HistoryByKn, kn);

  /// 取某层一卖：同上。
  List<Sell1Frame> _sell1FramesForKn(int kn) =>
      sell1HistoryForKn(sell1HistoryByKn, kn);

  List<Buy2Frame> _buy2FramesForKn(int kn) =>
      buy2HistoryForKn(buy2HistoryByKn, kn);

  List<Sell2Frame> _sell2FramesForKn(int kn) =>
      sell2HistoryForKn(sell2HistoryByKn, kn);

  List<BuyNFrame> _buyNFramesForKn(int kn, int cls) =>
      buyNHistoryForKn(buyNHistoryByKn, kn).where((e) => e.cls == cls).toList();

  List<SellNFrame> _sellNFramesForKn(int kn, int cls) =>
      sellNHistoryForKn(sellNHistoryByKn, kn)
          .where((e) => e.cls == cls)
          .toList();

  bool _bsMarkIsWrong({
    required int kn,
    required String side,
    required int cls,
    required int segIdx,
    required String label,
  }) {
    if (!overlayBsVerdictWrong) return false;
    final asOf = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);
    final v = verdictAtAsOf(
      bsVerdictHistoryForKn(bsVerdictHistoryByKn, kn),
      level: kn,
      side: side,
      cls: cls,
      segIdx: segIdx,
      label: label,
      asOf: asOf,
    );
    return v != null && v.isWrong;
  }

  void _paintWrongX(Canvas canvas, double cx, double y, double r) {
    final p = Paint()
      ..color = const Color(0xFFE53935)
      ..strokeWidth = math.max(1.6, r * 0.42)
      ..style = PaintingStyle.stroke
      ..strokeCap = StrokeCap.round;
    final d = r * 0.95;
    canvas.drawLine(Offset(cx - d, y - d), Offset(cx + d, y + d), p);
    canvas.drawLine(Offset(cx + d, y - d), Offset(cx - d, y + d), p);
  }

  /// 副图 Kn一类BS：扫会话历史；S 在上(+1)、B 在下(-1)；暖B冷S。
  /// 踩坑：只画「首次发现 x」不够——同动态 Kn 延伸步必须已在 history 里有本步 x。
  /// 注意：cx 不加 dx — BS标记必须与主图 K0 / 十字线严格对齐。
  void _drawKnClass1BsSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int kn,
  ) {
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    // S 上方 / B 下方
    final ySell = subY(1.0);
    final yBuy = subY(-1.0);
    final buyColor = ChartLevelLineStyle.forBSP(1, true);
    final sellColor = ChartLevelLineStyle.forBSP(1, false);
    final maxX = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);
    final buyFrames = _buy1FramesForKn(kn);
    final sellFrames = _sell1FramesForKn(kn);
    final tp = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );

    void paintMark({
      required int x,
      required String label,
      required double yMark,
      required Color color,
      required bool labelBelow,
      bool wrong = false,
    }) {
      if (x < 0
       || x > maxX) return;
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) return;
      final cx = _barCenterX(x, w, slotW);
      final r = math.max(2.5, barW * 0.28);
      canvas.drawCircle(Offset(cx, yMark), r, Paint()..color = color);
      if (wrong) _paintWrongX(canvas, cx, yMark, r);
      tp.text = TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: math.max(8.0, barW * 0.55),
          fontWeight: FontWeight.w600,
        ),
      );
      tp.layout();
      final ty = labelBelow ? yMark + r + 1 : yMark - r - 1 - tp.height;
      tp.paint(canvas, Offset(cx - tp.width / 2, ty));
    }

    for (final p in buyFrames) {
      paintMark(
        x: p.x,
        label: p.label,
        yMark: yBuy,
        color: buyColor,
        labelBelow: false,
        wrong: _bsMarkIsWrong(
          kn: kn,
          side: 'B',
          cls: 1,
          segIdx: p.segIdx,
          label: p.label,
        ),
      );
    }
    for (final p in sellFrames) {
      paintMark(
        x: p.x,
        label: p.label,
        yMark: ySell,
        color: sellColor,
        labelBelow: true,
        wrong: _bsMarkIsWrong(
          kn: kn,
          side: 'S',
          cls: 1,
          segIdx: p.segIdx,
          label: p.label,
        ),
      );
    }
  }

  /// 副图 Kn二类BS：S上B下；二类暖/冷色阶。
  void _drawKnClass2BsSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int kn,
  ) {
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final ySell = subY(1.0);
    final yBuy = subY(-1.0);
    final buyColor = ChartLevelLineStyle.forBSP(2, true);
    final sellColor = ChartLevelLineStyle.forBSP(2, false);
    final maxX = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);
    final buyFrames = _buy2FramesForKn(kn);
    final sellFrames = _sell2FramesForKn(kn);
    final tp = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );

    void paintMark({
      required int x,
      required String label,
      required double yMark,
      required Color color,
      required bool labelBelow,
      bool wrong = false,
    }) {
      if (x < 0 || x > maxX) return;
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) return;
      final cx = _barCenterX(x, w, slotW);
      final r = math.max(2.5, barW * 0.28);
      canvas.drawCircle(Offset(cx, yMark), r, Paint()..color = color);
      if (wrong) _paintWrongX(canvas, cx, yMark, r);
      tp.text = TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: math.max(8.0, barW * 0.55),
          fontWeight: FontWeight.w600,
        ),
      );
      tp.layout();
      final ty = labelBelow ? yMark + r + 1 : yMark - r - 1 - tp.height;
      tp.paint(canvas, Offset(cx - tp.width / 2, ty));
    }

    for (final p in buyFrames) {
      paintMark(
        x: p.x,
        label: p.label,
        yMark: yBuy,
        color: buyColor,
        labelBelow: false,
        wrong: _bsMarkIsWrong(
          kn: kn,
          side: 'B',
          cls: 2,
          segIdx: p.segIdx,
          label: p.label,
        ),
      );
    }
    for (final p in sellFrames) {
      paintMark(
        x: p.x,
        label: p.label,
        yMark: ySell,
        color: sellColor,
        labelBelow: true,
        wrong: _bsMarkIsWrong(
          kn: kn,
          side: 'S',
          cls: 2,
          segIdx: p.segIdx,
          label: p.label,
        ),
      );
    }
  }

  /// 副图 Kn N类BS（cls≥3）：同框按序标；S上B下；冷暖分族。
  void _drawKnClassNBsSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int kn,
    int cls,
  ) {
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final ySell = subY(1.0);
    final yBuy = subY(-1.0);
    final buyColor = ChartLevelLineStyle.forBSP(cls, true);
    final sellColor = ChartLevelLineStyle.forBSP(cls, false);
    final maxX = segAsOf ?? (bars.isEmpty ? -1 : bars.last.idx);
    final buyFrames = _buyNFramesForKn(kn, cls);
    final sellFrames = _sellNFramesForKn(kn, cls);
    final tp = TextPainter(
      textAlign: TextAlign.center,
      textDirection: TextDirection.ltr,
    );

    void paintMark({
      required int x,
      required String label,
      required double yMark,
      required Color color,
      required bool labelBelow,
      bool wrong = false,
    }) {
      if (x < 0 || x > maxX) return;
      if (x < viewport.viewXMin - 1 || x > viewport.viewXMax + 1) return;
      final cx = _barCenterX(x, w, slotW);
      final r = math.max(2.5, barW * 0.28);
      canvas.drawCircle(Offset(cx, yMark), r, Paint()..color = color);
      if (wrong) _paintWrongX(canvas, cx, yMark, r);
      tp.text = TextSpan(
        text: label,
        style: TextStyle(
          color: color,
          fontSize: math.max(8.0, barW * 0.55),
          fontWeight: FontWeight.w600,
        ),
      );
      tp.layout();
      final ty = labelBelow ? yMark + r + 1 : yMark - r - 1 - tp.height;
      tp.paint(canvas, Offset(cx - tp.width / 2, ty));
    }

    for (final p in buyFrames) {
      paintMark(
        x: p.x,
        label: p.label,
        yMark: yBuy,
        color: buyColor,
        labelBelow: false,
        wrong: _bsMarkIsWrong(
          kn: kn,
          side: 'B',
          cls: cls,
          segIdx: p.segIdx,
          label: p.label,
        ),
      );
    }
    for (final p in sellFrames) {
      paintMark(
        x: p.x,
        label: p.label,
        yMark: ySell,
        color: sellColor,
        labelBelow: true,
        wrong: _bsMarkIsWrong(
          kn: kn,
          side: 'S',
          cls: cls,
          segIdx: p.segIdx,
          label: p.label,
        ),
      );
    }
  }

  /// 副图成交量：K0=原生；Kn=下层增量在本层单元上动态累加（共享极点归已确认段）。
  /// Kn>0 时用 allBuyVolSeries 做红绿叠柱：下绿（卖出）上红（买入）。
  void _drawVolume(
    Canvas canvas,
    double w,
    double innerTop,
    double innerBottom,
    double innerH,
    double barW,
    double slotW, {
    required int kn,
    required Map<int, List<double>> allVolSeries,
    Map<int, List<double>>? allBuyVolSeries,
    List<Buy1Frame>? buy1Frames,
    List<Sell1Frame>? sell1Frames,
  }) {
    if (bars.isEmpty) return;
    final series = allVolSeries[kn];
    if (series == null || series.isEmpty) return;
    var maxV = 1.0;
    for (final v in series) {
      if (v > maxV) maxV = v;
    }
    // 多层叠画时用层色；K0 仍涨红跌绿半透明
    final levelTint = kn <= 0
        ? null
        : ChartLevelLineStyle.forZS(kn).color.withValues(alpha: 0.55);
    // tick 周期：所有层都按 K0 分笔方向着色（B 红 / S 绿 / 无 BS 灰），不再看涨跌
    final tickColored = period == 'tick';
    // Kn>0 买入量系列，用于红绿叠柱
    final List<double>? buySeries;
    if (kn > 0 && allBuyVolSeries != null) {
      buySeries = allBuyVolSeries[kn];
    } else {
      buySeries = null;
    }
    final hasStacked = buySeries != null && buySeries.isNotEmpty;
    // Kn>0 B/S 着色：用该层 buy1HistoryByKn / sell1HistoryByKn 历史打点
    final asOf = segAsOf;
    final maxX = asOf ?? bars.last.idx;
    final Set<int> buyIdxs;
    final Set<int> sellIdxs;
    final b1 = buy1Frames;
    final s1 = sell1Frames;
    final hasBsColored = kn > 0 && b1 != null && s1 != null;
    if (hasBsColored) {
      buyIdxs = b1.where((f) => f.x <= maxX).map((f) => f.x).toSet();
      sellIdxs = s1.where((f) => f.x <= maxX).map((f) => f.x).toSet();
    } else {
      buyIdxs = const <int>{};
      sellIdxs = const <int>{};
    }
    final nVol = math.min(bars.length, series.length);
    for (var i = 0; i < nVol; i++) {
      final idx = bars[i].idx;
      // 十字线激活时，按当步截断：右侧(idx>asOf)的成交量不绘制
      if (asOf != null && idx > asOf) continue;
      if (idx < viewport.viewXMin - 1 || idx > viewport.viewXMax + 1) continue;
      final vol = series[i];
      if (vol <= 0) continue;
      final b = bars[i];
      final cx = _barCenterX(idx, w, slotW);
      final x = cx - barW / 2;
      final bh = vol / maxV * innerH;
      if (hasStacked) {
        // Kn>0 红绿叠柱：下绿（卖出）上红（买入）
        final buyVol =
            (i < buySeries!.length ? buySeries[i] : 0.0).clamp(0.0, vol);
        final sellVol = vol - buyVol;
        final buyH = buyVol / maxV * innerH;
        final sellH = sellVol / maxV * innerH;
        if (sellH > 0) {
          canvas.drawRect(
            Rect.fromLTWH(x, innerBottom - sellH, barW, sellH),
            Paint()..color = const Color(0x6626A69A),
          );
        }
        if (buyH > 0) {
          canvas.drawRect(
            Rect.fromLTWH(x, innerBottom - sellH - buyH, barW, buyH),
            Paint()..color = const Color(0x66E53935),
          );
        }
      } else {
        final Color color;
        // 颜色优先级：tickColored（B红/S绿/灰）> bsColored > levelTint > K0涨跌
        if (tickColored) {
          // tick 周期：所有层继承 K0 分笔方向色
          color = _tickSideColor(b);
        } else if (hasBsColored) {
          if (buyIdxs.contains(idx)) {
            color = const Color(0x66E53935);
          } else if (sellIdxs.contains(idx)) {
            color = const Color(0x6626A69A);
          } else {
            color = const Color(0x669CA3AF);
          }
        } else if (levelTint != null) {
          color = levelTint;
        } else {
          color = b.isUp
              ? const Color(0x66E53935)
              : const Color(0x6626A69A);
        }
        canvas.drawRect(
          Rect.fromLTWH(x, innerBottom - bh, barW, bh),
          Paint()..color = color,
        );
      }
    }
  }

  /// 逐笔方向色：优先 metrics.tick_side（""|"B"|"S"）；老数据兜底按 bins 推断。
  Color _tickSideColor(KlineBar b) {
    final side = b.metrics['tick_side'];
    if (side is String) {
      if (side == 'B') return const Color(0x66E53935);
      if (side == 'S') return const Color(0x6626A69A);
      return const Color(0x669CA3AF);
    }
    bool hasQty(List<dynamic>? v) {
      if (v == null) return false;
      for (final e in v) {
        if ((e as num).toDouble() > 0) return true;
      }
      return false;
    }

    final bins = b.metrics['chip_tick_bins'];
    if (bins is Map) {
      if (hasQty(bins['b'] as List<dynamic>?)) {
        return const Color(0x66E53935);
      }
      if (hasQty(bins['s'] as List<dynamic>?)) {
        return const Color(0x6626A69A);
      }
    }
    return const Color(0x669CA3AF);
  }

  /// 单层 Kn 分型确认（自定义色：底分型红 / 顶分型蓝；形状按 Kn）。
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

    // 十字线激活时按当步截断：右侧(x>asOf)确认点不画，与成交量/分型判断同构
    final asOf = segAsOf;
    void paintPoint(int x, int value) {
      if (asOf != null && x > asOf) return;
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

    // 方案B：labelKn==0（K0分型确认）只画 k0ConfirmSignals
    if (labelKn == 0) {
      for (final s in k0ConfirmSignals) {
        paintPoint(s.x, s.value);
      }
      return;
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
    }
  }

  /// 副图 Kn 分型判断（自定义色同确认：底红顶蓝；半透明空心；扫会话历史）。
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
    // 方案B：分型判断 kn≥0
    if (bars.isEmpty || labelKn < 0) return;
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

  /// Kn中枢判断/确认副图（与分型同标记；确认实心、判断空心；升红降绿同色）。
  void _drawKnZsSignalSubChart(
    Canvas canvas,
    double w,
    double innerTop,
    double innerH,
    double barW,
    double slotW,
    int kn, {
    required Map<int, List<ZsSignalEvent>> historyByKn,
    required bool hollow,
    int stackRank = 0,
    int stackCount = 1,
  }) {
    if (bars.isEmpty) return;
    const minV = -1.0;
    const maxV = 1.0;
    final span = maxV - minV;
    double subY(double v) => innerTop + (maxV - v) / span * innerH;
    final y0 = subY(0);
    final shape = confirmMarkerShapeForKn(kn);
    final dx = confirmStackOffsetX(
      rank: stackRank,
      count: stackCount,
      barW: barW,
    );
    final history = historyByKn[kn] ?? const <ZsSignalEvent>[];
    final maxX = segAsOf ?? bars.last.idx;
    for (final e in history) {
      if (e.x < 0 || e.x > maxX) continue;
      if (e.value == 0) continue;
      if (e.x < viewport.viewXMin - 1 || e.x > viewport.viewXMax + 1) continue;
      final cx = _barCenterX(e.x, w, slotW) + dx;
      final yp = subY(e.value.toDouble());
      paintFractalConfirmMarker(
        canvas,
        cx: cx,
        y0: y0,
        yp: yp,
        value: e.value,
        shape: shape,
        barW: barW,
        withOutline: stackCount > 1,
        fillAlpha: hollow ? 0.45 : 1.0,
        hollow: hollow,
        colorOverride: ZsSignalColors.of(e.value),
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
    // 方案B：labelKn==0 只读 barFeatures；kn≥1 用 bundle.confirms
    if (labelKn == 0 && barFeatures.isNotEmpty) {
      series = List<int>.generate(
        n,
        (i) => i < barFeatures.length ? barFeatures[i].fractalPeakDist : 0,
      );
      color = const Color(0xFF38BDF8);
    } else if (bundle != null) {
      series = _peakDistSeries(n, bundle.confirms);
      color = ChartLevelLineStyle.forDisplayKn(level).color;
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

    // 十字线激活时按当步截断：右侧(idx>asOf)极点距折线不画，与主图/成交量同构
    final asOf = segAsOf;
    Offset? prev;
    for (var i = 0; i < series.length; i++) {
      final idx = bars[i].idx;
      if (asOf != null && idx > asOf) {
        prev = null;
        continue;
      }
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
  /// 自定义：向下截断=底分型截断→红；顶分型截断→蓝（与分型确认同色，另加橙描边）。
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

    // 十字线激活时按当步截断：右侧(x>asOf)截断点不画，与分型确认/成交量同构
    final asOf = segAsOf;
    void paintPoint(int x, int value) {
      if (asOf != null && x > asOf) return;
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
    // 方案B：labelKn==0 只画 k0ConfirmSignals；kn≥1 用 LevelBundle
    if (labelKn == 0) {
      for (final s in k0ConfirmSignals) {
        if (!s.truncated) continue;
        paintPoint(s.x, s.value);
      }
      return;
    }
    if (bundle != null) {
      for (final c in bundle.confirms) {
        if (!c.truncated) continue;
        if ((c.fx == 'TOP' || c.fx == 'BOTTOM') && c.value != 0) {
          paintPoint(c.x, c.value);
        }
      }
    }
  }

  /// 主图 Y 轴价签；[onLeft]=true 时画在左侧（避让右侧筹码）；[leftX] 可指定左锚（笔数分布右侧）。
  void _drawYLabels(
    Canvas canvas,
    double w,
    double plotTop,
    double plotH,
    PriceRange pr, {
    bool onLeft = false,
    double? leftX,
  }) {
    const style = TextStyle(color: Color(0x99FFFFFF), fontSize: 9);
    for (var i = 0; i <= 4; i++) {
      final p = pr.max - pr.span * i / 4;
      final y = plotTop + plotH * i / 4;
      final tp = TextPainter(
        text: TextSpan(text: p.toStringAsFixed(2), style: style),
        textDirection: TextDirection.ltr,
      )..layout();
      final lx = onLeft
          ? (leftX ?? (KlineViewport.padL + 2))
          : w - tp.width - 3;
      tp.paint(canvas, Offset(lx, y - tp.height / 2));
    }
  }

  void _drawXAxis(Canvas canvas, double w, double axisTop) {
    if (bars.isEmpty) return;

    final plotW = math.max(1.0, w - KlineViewport.padL - KlineViewport.padR);
    final span = math.max(viewport.xSpan, 1e-6);
    final minuteLike = KlineAxisFormat.isMinuteLike(visible.isNotEmpty ? visible : bars);
    // tick 周期：X 轴标签到秒（同分钟秒位有递进，分钟切换自然变化）
    final secondLike = period == 'tick' ||
        KlineAxisFormat.isSecondLike(visible.isNotEmpty ? visible : bars);
    final i0 = viewport.viewXMin.floor().clamp(0, bars.length - 1);
    final sample = KlineAxisFormat.xLabel(bars[i0].timeText,
        minuteLike: minuteLike, secondLike: secondLike);
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

      final label = KlineAxisFormat.xLabel(bars[xi].timeText,
          minuteLike: minuteLike, secondLike: secondLike);
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
    final plotH = math.max(1.0, mainH - mainPlotTop - KlineViewport.padB);

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
    // 筹码开启：价签改左侧，避免被右侧筹码挡住（设置总开关控制，仅K0）
    final chipOn = chipConfig.enabled;
    final lx = chipOn ? KlineViewport.padL + 2 : size.width - lw - 3;
    canvas.drawRect(Rect.fromLTWH(lx, ly, lw, lh), labelBg);
    canvas.drawRect(Rect.fromLTWH(lx, ly, lw, lh), labelBorder);
    tp.paint(canvas, Offset(lx + 6, ly + 4));

    // tooltip 改由 Flutter 覆盖层绘制（表格对齐 + 可滚动半透明）
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

  /// 十字悬停单根筹码量：取该根 chip_tick_bins 的 B/S/灰 累计（无 bins 返回 null）。
  ({double b, double s, double w})? _singleBarChipSums(KlineBar bar) {
    final bins = bar.metrics['chip_tick_bins'];
    if (bins is! Map) return null;
    double qty(String key) {
      final v = bins[key];
      if (v is! List) return 0.0;
      var s = 0.0;
      for (final e in v) {
        s += (e as num).toDouble();
      }
      return s;
    }

    final bsum = qty('b');
    final ssum = qty('s');
    final wsum = qty('w');
    if (bsum <= 0 && ssum <= 0 && wsum <= 0) return null;
    return (b: bsum, s: ssum, w: wsum);
  }

  @override
  bool shouldRepaint(covariant _KlineCompositePainter oldDelegate) {
    if (oldDelegate.layer != layer) return true;
    final geomChanged = oldDelegate.mainH != mainH ||
        oldDelegate.volH != volH ||
        oldDelegate.mainPlotTop != mainPlotTop ||
        oldDelegate.viewport.viewXMin != viewport.viewXMin ||
        oldDelegate.viewport.viewXMax != viewport.viewXMax ||
        oldDelegate.viewport.yZoomRatio != viewport.yZoomRatio ||
        oldDelegate.viewport.yShiftRatio != viewport.yShiftRatio ||
        oldDelegate.priceRange.min != priceRange.min ||
        oldDelegate.priceRange.max != priceRange.max;
    final dataChanged = oldDelegate.bars != bars ||
        oldDelegate.period != period ||
        oldDelegate.combineFrames != combineFrames ||
        oldDelegate.k0ConfirmSignals != k0ConfirmSignals ||
        oldDelegate.barFeatures != barFeatures ||
        oldDelegate.k0Lines != k0Lines ||
        oldDelegate.k1BarViews != k1BarViews ||
        oldDelegate.k1CombineFrames != k1CombineFrames ||
        oldDelegate.k1Analysis != k1Analysis ||
        oldDelegate.levels != levels ||
        oldDelegate.zsK0Frames != zsK0Frames ||
        oldDelegate.buy1K0Frames != buy1K0Frames ||
        oldDelegate.sell1K0Frames != sell1K0Frames ||
        oldDelegate.buy2K0Frames != buy2K0Frames ||
        oldDelegate.sell2K0Frames != sell2K0Frames ||
        oldDelegate.buyNK0Frames != buyNK0Frames ||
        oldDelegate.sellNK0Frames != sellNK0Frames ||
        oldDelegate.zsAsOfBundle != zsAsOfBundle ||
        oldDelegate.mainIndicators != mainIndicators ||
        oldDelegate.subIndicators != subIndicators ||
        oldDelegate.truncationCheck != truncationCheck ||
        oldDelegate.showBuildingDash != showBuildingDash ||
        oldDelegate.subChipBarHeight != subChipBarHeight ||
        oldDelegate.defaultK0Policy != defaultK0Policy ||
        oldDelegate.judgmentHistoryByKn != judgmentHistoryByKn ||
        oldDelegate.zsJudgmentHistoryByKn != zsJudgmentHistoryByKn ||
        oldDelegate.zsConfirmHistoryByKn != zsConfirmHistoryByKn ||
        oldDelegate.buy1HistoryByKn != buy1HistoryByKn ||
        oldDelegate.sell1HistoryByKn != sell1HistoryByKn ||
        oldDelegate.buy2HistoryByKn != buy2HistoryByKn ||
        oldDelegate.sell2HistoryByKn != sell2HistoryByKn ||
        oldDelegate.buyNHistoryByKn != buyNHistoryByKn ||
        oldDelegate.sellNHistoryByKn != sellNHistoryByKn ||
        oldDelegate.bsVerdictHistoryByKn != bsVerdictHistoryByKn ||
        oldDelegate.overlayBsVerdictWrong != overlayBsVerdictWrong ||
        oldDelegate.adjacentRatioHistoryByKn != adjacentRatioHistoryByKn ||
        oldDelegate.stepRhythmHistoryByKn != stepRhythmHistoryByKn ||
        oldDelegate.lineSlopeHistoryByKn != lineSlopeHistoryByKn ||
        oldDelegate.chipOnlyMode != chipOnlyMode ||
        oldDelegate.chipConfig != chipConfig ||
        oldDelegate.tickDistConfig != tickDistConfig ||
        oldDelegate.mathIndicatorConfig != mathIndicatorConfig ||
        !identical(oldDelegate.featureLookup.byIdx, featureLookup.byIdx);

    switch (layer) {
      case _ChartPaintLayer.base:
        // 不含 crosshairX/Y：纯移价位线不重画蜡烛；chipConfig 变→价签左右切换
        return dataChanged ||
            geomChanged ||
            oldDelegate.segAsOf != segAsOf ||
            oldDelegate.crosshairEnabled != crosshairEnabled;
      case _ChartPaintLayer.chip:
        return dataChanged ||
            geomChanged ||
            oldDelegate.segAsOf != segAsOf ||
            oldDelegate.chipConfig != chipConfig;
      case _ChartPaintLayer.crosshair:
        return geomChanged ||
            oldDelegate.crosshairEnabled != crosshairEnabled ||
            oldDelegate.crosshairShowTooltip != crosshairShowTooltip ||
            oldDelegate.crosshairX != crosshairX ||
            oldDelegate.crosshairY != crosshairY ||
            oldDelegate.crosshairBarIdx != crosshairBarIdx ||
            oldDelegate.segAsOf != segAsOf ||
            oldDelegate.subIndicators != subIndicators ||
            oldDelegate.chipConfig != chipConfig ||
            oldDelegate.bars != bars;
    }
  }
}
