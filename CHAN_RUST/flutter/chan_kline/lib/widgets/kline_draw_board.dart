import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/kline_candle_geometry.dart';
import '../chart/level_window_layout.dart';
import '../compute/k1_bar_view_compute.dart';
import '../compute/kline_period_aggregate.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chart_indicator.dart';
import '../models/chip_config.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/pre_first_fractal_mode.dart';
import '../models/tick_dist_config.dart';
import 'package:chan_kline/theme/app_palette.dart';
import 'candle_wick.dart';
import 'chart_sync_controller.dart';
import 'crosshair_tooltip_bridge.dart';
import 'crosshair_tooltip_panel.dart';
import 'kline_chart.dart';
import 'kline_viewport.dart';
import 'level_chart_grid.dart';

const Map<String, String> kKlineDrawPeriods = <String, String>{
  '1m': '1\u5206\u949f',
  '5m': '5\u5206\u949f',
  '15m': '15\u5206\u949f',
  '30m': '30\u5206\u949f',
  '60m': '60\u5206\u949f',
  '2h': '2\u5c0f\u65f6',
  '4h': '4\u5c0f\u65f6',
  '1d': '1\u65e5',
  '3d': '3\u65e5',
  '1w': '1\u5468',
  '1mon': '1\u6708',
  '3mon': '3\u6708',
  '6mon': '6\u6708',
  '9mon': '9\u6708',
  '12mon': '12\u6708',
  '1y': '1\u5e74',
  '3y': '3\u5e74',
  '6y': '6\u5e74',
};

class KlineDrawCandle {
  const KlineDrawCandle({
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    this.volume = 1,
  });

  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
}

class KlineDrawDraft {
  const KlineDrawDraft({
    required this.open,
    required this.high,
    required this.low,
    required this.close,
  });

  final double open;
  final double high;
  final double low;
  final double close;

  /// 带上拖动路径的极值（帮助文字承诺：路径最高=最高价，路径最低=最低价）。
  KlineDrawDraft withExtremes(double hi, double lo) => KlineDrawDraft(
        open: open,
        close: close,
        high: math.max(hi, math.max(open, close)),
        low: math.min(lo, math.min(open, close)),
      );
}

class KlineDrawWindowMode {
  const KlineDrawWindowMode.level(this.level) : period = null;
  const KlineDrawWindowMode.period(this.period) : level = 0;

  final int level;
  final String? period;

  bool get isLevel => period == null;

  String get label => isLevel ? 'K$level' : (kKlineDrawPeriods[period] ?? period!);

  int get displayLevel => isLevel ? level : 0;

  String get chartPeriod => period ?? '1m';
}

class KlineDrawBoardModel {
  const KlineDrawBoardModel({
    required this.candles,
    required this.windowCount,
    required this.windowModes,
    this.selected = -1,
    this.priceStep = 0.01,
    this.start = '2026/07/10 09:30:00',
  });

  final List<KlineDrawCandle> candles;
  final int windowCount;
  final List<KlineDrawWindowMode> windowModes;
  final int selected;
  final double priceStep;
  final String start;

  factory KlineDrawBoardModel.initial({int windowCount = 4}) {
    final count = normalizeLevelWindowCount(windowCount);
    return KlineDrawBoardModel(
      candles: const [],
      windowCount: count,
      windowModes: defaultKlineDrawWindowModes(count),
    );
  }

  bool get hasSelection =>
      candles.isNotEmpty && selected >= 0 && selected < candles.length;

  KlineDrawWindowMode modeAt(int slot) =>
      slot >= 0 && slot < windowModes.length
          ? windowModes[slot]
          : const KlineDrawWindowMode.level(0);

  KlineDrawBoardModel copyWith({
    List<KlineDrawCandle>? candles,
    int? windowCount,
    List<KlineDrawWindowMode>? windowModes,
    int? selected,
  }) =>
      KlineDrawBoardModel(
        candles: candles ?? this.candles,
        windowCount: windowCount ?? this.windowCount,
        windowModes: windowModes ?? this.windowModes,
        selected: selected ?? this.selected,
        priceStep: priceStep,
        start: start,
      );

  KlineDrawBoardModel withWindowCount(int count) {
    final next = normalizeLevelWindowCount(count);
    return copyWith(
      windowCount: next,
      windowModes: resizeKlineDrawWindowModes(windowModes, next),
    );
  }

  KlineDrawBoardModel withWindowMode(int slot, KlineDrawWindowMode mode) {
    if (slot < 0 || slot >= windowModes.length) return this;
    if (slot == 0 && (mode.period != null || mode.level != 0)) return this;
    final next = [...windowModes];
    next[slot] = mode;
    return copyWith(windowModes: next);
  }

  KlineDrawBoardModel addCandle(KlineDrawCandle candle) {
    final next = [...candles, candle];
    return copyWith(candles: next, selected: next.length - 1);
  }

  /// 在 [index] 处插入一根 K 线；index 为 null 或越界时追加到末尾。
  ///
  /// 画板的核心口径：新 K 落在光标所在的 K 位置，而不是永远排在最后。
  KlineDrawBoardModel insertCandleAt(KlineDrawCandle candle, int? index) {
    final at = (index == null || index < 0 || index > candles.length)
        ? candles.length
        : index;
    final next = [...candles]..insert(at, candle);
    return copyWith(candles: next, selected: at);
  }

  KlineDrawBoardModel select(int index) {
    if (candles.isEmpty) return this;
    return copyWith(selected: index.clamp(0, candles.length - 1));
  }

  KlineDrawBoardModel clearSelection() => copyWith(selected: -1);

  KlineDrawBoardModel deleteSelected() {
    if (!hasSelection) return this;
    final next = [...candles]..removeAt(selected);
    return copyWith(
      candles: next,
      selected: next.isEmpty ? -1 : math.min(selected, next.length - 1),
    );
  }

  KlineDrawBoardModel addSameAfterSelected() {
    if (!hasSelection) return this;
    final next = [...candles];
    next.insert(selected + 1, candles[selected]);
    return copyWith(candles: next, selected: selected + 1);
  }

  KlineDrawBoardModel removeSelected() => deleteSelected();

  /// 整根平移第 [index] 根 K：四价同移 [delta]（正=价格上移），形状不变。
  ///
  /// 2026-11-16 用户明确：废弃「按部位改价」（拖影线端点改最高/最低会把
  /// 价格区间撑爆，其余已画 K 被压成一条线）。改为整根平移。
  ///
  /// 钳制（防压缩的核心）：平移后四价必须落在 [clampLo, clampHi]——即按下
  /// 瞬间**全体可见 K（含自己）**的极值并集。并集只可能缩小、绝不扩大，
  /// 其余已画 K 的像素高度不会塌缩；区间外的 K 也可自由移进并集内。
  /// clampLo/Hi 为 null（板上仅这一根 K，没有别人可压）时不钳。
  ///
  /// 按下瞬间「选中」还没回传到模型（要等父组件重建才生效），若此时只认
  /// [selected]，第一帧位移会被吞掉。故按**下标**平移，与选中状态解耦。
  KlineDrawBoardModel moveCandleAt(
    int index,
    double delta, {
    required double? clampLo,
    required double? clampHi,
  }) {
    if (index < 0 || index >= candles.length) return this;
    final c = candles[index];
    final lo = clampLo;
    final hi = clampHi;
    if (lo == null || hi == null) {
      return _moveCandleBy(index, delta);
    }
    // 价格上移空间（high 到并集上沿）与下移空间（low 到并集下沿）。
    final maxUp = (hi - c.high).clamp(0.0, double.infinity);
    final maxDown = (c.low - lo).clamp(0.0, double.infinity);
    return _moveCandleBy(index, delta.clamp(-maxDown, maxUp));
  }

  /// 不钳制的整根平移（四价同移 [delta]，形状不变）。
  KlineDrawBoardModel _moveCandleBy(int index, double delta) {
    if (index < 0 || index >= candles.length || delta == 0) return this;
    final c = candles[index];
    final next = [...candles];
    next[index] = KlineDrawCandle(
      open: c.open + delta,
      high: c.high + delta,
      low: c.low + delta,
      close: c.close + delta,
      volume: c.volume,
    );
    return copyWith(candles: next);
  }

  List<KlineBar> toBars() {
    final begin = _parseDrawTime(start);
    final out = <KlineBar>[];
    for (var i = 0; i < candles.length; i++) {
      final t = _advanceTradingMinute(begin, i);
      final c = candles[i];
      out.add(KlineBar(
        idx: i,
        timeMs: t.millisecondsSinceEpoch,
        timeText: _formatDrawTime(t),
        open: _roundPrice(c.open),
        high: _roundPrice(c.high),
        low: _roundPrice(c.low),
        close: _roundPrice(c.close),
        volume: c.volume,
        amount: 0,
      ));
    }
    return out;
  }
}

List<KlineDrawWindowMode> defaultKlineDrawWindowModes(int count) {
  // 2026-11-16 用户指定画板四窗默认：左上=画板 1分钟 K0、右上=1分钟 K2、
  // 左下=5分钟 K0、右下=15分钟 K0。操作窗 slot0 固定 K0 不可改周期。
  const seeded = <KlineDrawWindowMode>[
    KlineDrawWindowMode.level(0),
    KlineDrawWindowMode.level(2),
    KlineDrawWindowMode.period('5m'),
    KlineDrawWindowMode.period('15m'),
  ];
  return [
    for (var i = 0; i < count; i++)
      i < seeded.length ? seeded[i] : KlineDrawWindowMode.level(i),
  ];
}

List<KlineDrawWindowMode> resizeKlineDrawWindowModes(
  List<KlineDrawWindowMode> current,
  int count,
) {
  final defaults = defaultKlineDrawWindowModes(count);
  return [
    for (var i = 0; i < count; i++)
      i == 0
          ? const KlineDrawWindowMode.level(0)
          : (i < current.length ? current[i] : defaults[i]),
  ];
}

KlineDrawDraft buildKlineDrawDraft(double startPrice, double endPrice) {
  final open = startPrice;
  final close = endPrice;
  return KlineDrawDraft(
    open: open,
    close: close,
    high: math.max(open, close),
    low: math.min(open, close),
  );
}

DateTime _parseDrawTime(String raw) {
  final m = RegExp(
    r'(\d{4})\D(\d{1,2})\D(\d{1,2})(?:\D(\d{1,2}):(\d{1,2})(?::(\d{1,2}))?)?',
  ).firstMatch(raw.trim());
  if (m == null) return DateTime(2026, 7, 10, 9, 30);
  return DateTime(
    int.parse(m.group(1)!),
    int.parse(m.group(2)!),
    int.parse(m.group(3)!),
    int.parse(m.group(4) ?? '9'),
    int.parse(m.group(5) ?? '30'),
    int.parse(m.group(6) ?? '0'),
  );
}

DateTime _advanceTradingMinute(DateTime begin, int offset) {
  var t = DateTime(begin.year, begin.month, begin.day, begin.hour, begin.minute);
  var left = offset;
  while (left > 0) {
    t = t.add(const Duration(minutes: 1));
    final minutes = t.hour * 60 + t.minute;
    if (minutes == 11 * 60 + 31) {
      t = DateTime(t.year, t.month, t.day, 13);
    } else if (minutes > 15 * 60) {
      final next = t.add(const Duration(days: 1));
      t = DateTime(next.year, next.month, next.day, 9, 30);
    }
    final now = t.hour * 60 + t.minute;
    if (now >= 9 * 60 + 30 && now <= 11 * 60 + 30 ||
        now >= 13 * 60 && now <= 15 * 60) {
      left--;
    }
  }
  return t;
}

String _formatDrawTime(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${two(t.month)}/${two(t.day)} '
      '${two(t.hour)}:${two(t.minute)}:00';
}

double _roundPrice(double v) => (v * 100).roundToDouble() / 100;

class KlineDrawBoard extends StatefulWidget {
  const KlineDrawBoard({
    super.key,
    required this.model,
    required this.bundle,
    this.bundleForBars,
    this.preFirstFractalMode = PreFirstFractalMode.seedBox,
    required this.mainIndicators,
    required this.subIndicators,
    required this.truncationCheck,
    required this.earlyDynamicUnit,
    required this.showBuildingDash,
    required this.chipConfig,
    required this.tickDistConfig,
    required this.onChanged,
    required this.onMainIndicatorsChanged,
    required this.onSubIndicatorsChanged,
  });

  final KlineDrawBoardModel model;
  final KlineCombineBundle bundle;
  /// 周期窗按「本窗聚合 bars」重算缠论结构（中枢/连线/分型/合并）。
  /// 画板的 bundle 原本只由 1m 数据算一份，5m/15m 直接复用会把 K0 结构
  /// 画到只有 N/5、N/15 根 K 的窗上——用户看到的「显示左上角 1m K0 指标」。
  /// null = 退化为共用 [bundle]（旧行为，测试/零数据场景）。
  final KlineCombineBundle Function(List<KlineBar>)? bundleForBars;
  /// 画板是原始 K 线操作窗：首分型前按引擎原框画（种子框口径），
  /// 不套主图默认「高高」重并——高高口径 low 取 max，会让首框下沿
  /// 高于首根 K 的真实低点，下影线露在框外，被用户判为「合并框错误」。
  final PreFirstFractalMode preFirstFractalMode;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final bool truncationCheck;
  final bool earlyDynamicUnit;
  final bool showBuildingDash;
  final ChipConfig chipConfig;
  final TickDistConfig tickDistConfig;
  final ValueChanged<KlineDrawBoardModel> onChanged;
  final ValueChanged<Set<MainChartIndicator>> onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>> onSubIndicatorsChanged;

  @override
  State<KlineDrawBoard> createState() => _KlineDrawBoardState();
}

class _KlineDrawBoardState extends State<KlineDrawBoard> {
  final ChartSyncController _sync = ChartSyncController();
  final CrosshairTooltipBridge _tooltipBridge = CrosshairTooltipBridge();
  final ScrollController _tooltipScroll = ScrollController();
  KlineDrawDraft? _draft;
  double _lastPaneHeight = 600;
  /// 周期窗 bundle 缓存：同一 model 同一帧只按周期算一次，避免拖动时每帧跑 FFI。
  KlineDrawBoardModel? _cachedModel;
  final Map<String, KlineCombineBundle> _periodBundles =
      <String, KlineCombineBundle>{};

  KlineDrawBoardModel get model => widget.model;
  KlineCombineBundle get bundle => widget.bundle;
  /// 草稿 K 落在光标所在的 K 下标（null=落在末尾）。
  int? _draftBarIdx;
  /// 画板自己算出来的 K0 视口几何（与图表绘制同源）。
  KlineDrawGeometry? _geom;
  /// 最近一次 K0 窗格尺寸（拖动回调里要重算价格区间）。
  double _lastPaneWidth = 0;
  /// 本次拖动路径上的价格极值（帮助文字承诺的口径）。
  double? _pathHigh;
  double? _pathLow;
  /// 本次拖动冻结的基准几何（拖动期间价格区间会变，不冻结会漂移）。
  KlineDrawGeometry? _dragBaseGeom;
  /// 本次拖动的钳制下沿：按下瞬间除被拖 K 之外其余可见 K 的最低价。
  /// null = 板上只有这一根（没有别人可压，不钳）。
  double? _dragClampLo;
  /// 本次拖动的钳制上沿：按下瞬间除被拖 K 之外其余可见 K 的最高价。
  double? _dragClampHi;

  @override
  void initState() {
    super.initState();
    _tooltipBridge.scrollController = _tooltipScroll;
  }

  @override
  void dispose() {
    _tooltipScroll.dispose();
    _sync.dispose();
    _tooltipBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    // 草稿 K **不进** chart 的 bars：进了会让价格区间跟着草稿走，
    // 拖动过程中像素↔价格映射会漂移（拖动自己追自己，还凭空多出影线）。
    // 草稿改由 _pane 的覆盖层画（与主图同源几何，但不参与区间计算）。
    final bars = model.toBars();
    final views = buildK1BarViews(bundle.k1Bars);
    return Material(
      color: AppPalette.canvasBg,
      child: LayoutBuilder(
        builder: (context, constraints) {
          return ValueListenableBuilder<bool>(
            valueListenable: _tooltipBridge.shown,
            builder: (context, shown, _) {
              return Row(
                children: [
                  Offstage(
                    offstage: !shown,
                    child: SizedBox(
                      width: _tooltipPanelWidth,
                      child: _tooltipPanel(constraints.maxHeight),
                    ),
                  ),
                  Expanded(
                    child: LevelChartGrid(
                      count: model.windowCount,
                      levels: [
                        for (final mode in model.windowModes) mode.displayLevel,
                      ],
                      maxKn: 99,
                      // 2026-11-16：左上角操作窗固定显示「1分钟 K0」，
                      // 不给下拉。层级窗统一带「1分钟」前缀（右上=1分钟 K2），
                      // 周期窗显示自身周期名（左下=5分钟、右下=15分钟）。
                      badgeTextBuilder: (slot, level) {
                        final m = model.modeAt(slot);
                        return m.isLevel ? '1\u5206\u949f ${m.label}' : m.label;
                      },
                      paneBuilder: (context, slot, level, primary) => _pane(
                        slot: slot,
                        primary: slot == 0,
                        bars: bars,
                        k1Views: views,
                      ),
                    ),
                  ),
                ],
              );
            },
          );
        },
      ),
    );
  }

  Widget _tooltipPanel(double height) {
    return ValueListenableBuilder<List<CrosshairTooltipRow>>(
      valueListenable: _tooltipBridge.rows,
      builder: (context, rows, _) => CrosshairTooltipPanel(
        rows: rows,
        scrollController: _tooltipScroll,
        maxWidth: _tooltipPanelWidth,
        maxHeight: height,
      ),
    );
  }

  /// 周期窗的缠论结构必须与本窗 bars 同源。
  ///
  /// 层级窗（含 slot0 操作窗、右上 K2 窗）与 1m 窗沿用共用 bundle；
  /// 只有 5m/15m/… 周期窗在 [bundleForBars] 存在时按本窗聚合 bars 重算。
  /// 同一 model 内按周期缓存，拖动每一帧不会重复跑 FFI。
  KlineCombineBundle _bundleForPane({
    required bool usePeriod,
    required String period,
    required List<KlineBar> paneBars,
  }) {
    final cb = widget.bundleForBars;
    if (!usePeriod || cb == null) return bundle;
    if (!identical(_cachedModel, model)) {
      _cachedModel = model;
      _periodBundles.clear();
    }
    return _periodBundles.putIfAbsent(period, () => cb(paneBars));
  }

  Widget _pane({
    required int slot,
    required bool primary,
    required List<KlineBar> bars,
    required List<K1BarView> k1Views,
  }) {
    final mode = model.modeAt(slot);
    // 2026-11-16：各窗不再共用同一份 1 分钟数据。
    // 操作窗（slot0）与层级窗（K1 等）保持原始 1m；周期窗按目标周期
    // 由 N 根连续 1 分钟 K 聚合（5m=5 根、15m=15 根，其余周期同理）。
    final paneBars = mode.isLevel || mode.period == '1m'
        ? bars
        : aggregateKlineBarsByPeriod(bars, mode.period!);
    // 2026-11-16：周期窗不能复用 1m 的 bundle（否则中枢/连线/分型全是 K0 的）。
    // 按本窗聚合 bars 重算一份；层级窗与 1m 窗零回归。
    final usePeriodBundle =
        !mode.isLevel && mode.period != null && mode.period != '1m';
    final paneBundle = _bundleForPane(
      usePeriod: usePeriodBundle,
      period: mode.chartPeriod,
      paneBars: paneBars,
    );
    final paneViews = usePeriodBundle && widget.bundleForBars != null
        ? buildK1BarViews(paneBundle.k1Bars)
        : k1Views;
    return Stack(
      fit: StackFit.expand,
      children: [
        KlineChart(
          key: ValueKey<String>(
            'kline-draw-$slot-${mode.displayLevel}-${mode.chartPeriod}',
          ),
          interactive: true,
          ownsKeyboard: primary,
          displayLevel: mode.displayLevel,
          // 视口按槽位独立：不能按 displayLevel，否则操作窗/5m/15m 共用一份，
          // 少根 K 的窗会把共享视口复位成 xSpan=1，连带缩放失效、间距畸变。
          viewportKey: slot,
          // 十字线按 slot 认主窗：四窗 displayLevel 可能相同（5m/15m 都是 0），
          // 用层号会互判为主窗、联动失效；按 timeMs 对位让不同周期落在同一时刻。
          crosshairOwnerKey: slot,
          crosshairMatchMode: CrosshairMatchMode.timeMs,
          viewportMinSpan: 24,
          // 画板固定按引擎原框画首分型前的合并框（种子框），不套用主图
          // 默认「高高」重并（其 low 取 max 会漏掉首根 K 的真实低点）。
          preFirstFractalMode: widget.preFirstFractalMode,
          forceSubPane: true,
          bars: paneBars,
          period: mode.chartPeriod,
          // 下列缠论结构一律取本窗 bundle：周期窗=聚合 bars 重算，层级窗=共用。
          combineFrames: paneBundle.frames,
          k0ConfirmSignals: paneBundle.k0Confirms,
          barFeatures: paneBundle.barFeatures,
          k0Lines: paneBundle.k0Lines,
          k1BarViews: paneViews,
          k1CombineFrames: paneBundle.k1CombineFrames,
          k1Analysis: paneBundle.k1Analysis,
          levels: paneBundle.levels,
          zsK0Frames: paneBundle.zsK0Frames,
          buy1K0Frames: paneBundle.buy1K0Frames,
          sell1K0Frames: paneBundle.sell1K0Frames,
          buy2K0Frames: paneBundle.buy2K0Frames,
          sell2K0Frames: paneBundle.sell2K0Frames,
          buyNK0Frames: paneBundle.buyNK0Frames,
          sellNK0Frames: paneBundle.sellNK0Frames,
          defaultK0Policy: paneBundle.defaultK0Policy,
          stepIdx: paneBars.isEmpty ? 0 : paneBars.length - 1,
          stepSerial: paneBars.length,
          mainIndicators: widget.mainIndicators,
          subIndicators: widget.subIndicators,
          truncationCheck: widget.truncationCheck,
          earlyDynamicUnit: widget.earlyDynamicUnit,
          showBuildingDash: widget.showBuildingDash,
          chipConfig: widget.chipConfig,
          tickDistConfig: widget.tickDistConfig,
          sync: _sync,
          tooltipBridge: _tooltipBridge,
          dockTooltipPanel: true,
          onCandleDraw: primary ? _onDraw : null,
          // 绘制锚：点击选中一根 K 后，它中心以右的空白都允许起笔画新 K
          // （2026-11-16：不再限制在槽位右缘/最右边）。
          candleDrawAnchorIdx:
              primary ? (model.hasSelection ? model.selected : -1) : -1,
          // 抓取/拖动：K线画板专用通道（分笔画板不接，互不影响）。
          // 2026-11-16 起为整根平移：抓本体任意处拖动，形状不变，
          // 钳制在按下时其余可见 K 的极值区间内（防其余 K 被压成一条线）。
          onCandleGrab: primary ? _grabCandle : null,
          onCandleDrag: primary ? _dragCandle : null,
          onCandleDragEnd: primary ? _endCandleDrag : null,
          onViewportChanged: primary ? _onViewportChanged : null,
          onMainIndicatorsChanged: widget.onMainIndicatorsChanged,
          onSubIndicatorsChanged: widget.onSubIndicatorsChanged,
        ),
        if (primary && model.candles.isEmpty && _draft == null)
          const IgnorePointer(
            child: Center(
              child: Text('\u6309\u4f4f\u5de6\u952e\u62d6\u52a8\uff0c\u677e\u624b\u751f\u6210\u4e00\u6839 1 \u5206\u949f K \u7ebf'),
            ),
          ),
        if (!primary)
          Positioned(
            left: 8,
            top: 30,
            child: DropdownButton<String>(
              value: mode.isLevel ? 'K${mode.level}' : mode.period,
              items: [
                for (var level = 1; level <= 9; level++)
                  DropdownMenuItem(value: 'K$level', child: Text('K$level')),
                for (final e in kKlineDrawPeriods.entries)
                  if (e.key != '1m')
                    DropdownMenuItem(value: e.key, child: Text(e.value)),
              ],
              onChanged: (v) {
                if (v == null) return;
                final next = v.startsWith('K')
                    ? KlineDrawWindowMode.level(int.parse(v.substring(1)))
                    : KlineDrawWindowMode.period(v);
                widget.onChanged(model.withWindowMode(slot, next));
              },
            ),
          ),
        if (primary)
          LayoutBuilder(builder: (context, constraints) {
            _lastPaneWidth = constraints.maxWidth;
            _lastPaneHeight = constraints.maxHeight;
            _geom = _geometry(_lastPaneWidth, _lastPaneHeight);
            if (!model.hasSelection) return const SizedBox.shrink();
            final box = _selectedBox(constraints.biggest);
            if (box == null) return const SizedBox.shrink();
            return Stack(children: [
              // 聚焦标识最底层：四支三角箭头，与分笔画板的聚焦视觉一致。
              // 框即 `_selectedBox`，已随缩放/平移更新，聚焦自动跟随。
              Positioned.fill(
                child: IgnorePointer(
                  child: CustomPaint(painter: _FocusArrowsPainter(box: box)),
                ),
              ),
              Positioned(
                left: box.center.dx - 12,
                top: math.max(30, box.top - 28),
                child: _roundAction(Icons.add, () {
                  widget.onChanged(model.addSameAfterSelected());
                }),
              ),
              Positioned(
                left: box.center.dx - 12,
                top: math.min(constraints.maxHeight - 30, box.bottom + 4),
                child: _roundAction(Icons.remove, () {
                  widget.onChanged(model.removeSelected());
                }),
              ),
            ]);
          }),
        if (primary && _draft != null)
          Positioned.fill(
            child: IgnorePointer(
              child: CustomPaint(
                painter: _DraftCandlePainter(
                  draft: _draft!,
                  geom: _geom,
                  barIdx: _draftBarIdx,
                  barCount: model.candles.length,
                ),
              ),
            ),
          ),
      ],
    );
  }

  /// K0 视口几何：与 KlineChart 的绘制口径逐项对齐。
  ///
  /// 关键：**用可见 K 的价格区间**（图表实际画的那一段），不用全量；
  /// plotTop 走 KlineViewport.padT（桌面布局，KlineChart._resolveMainPlotTop
  /// 在非 mobile 下就返回 padT）；plotH = mainH - padT - padB，**不用魔数 56**。
  KlineDrawGeometry? _geometry(double width, double height) {
    final vp = _sync.viewportFor(0);
    if (!vp.ready || width <= 0 || height <= 0) return null;
    final mainH = height * _sync.mainFraction;
    const plotTop = KlineViewport.padT;
    final plotH = math.max(1.0, mainH - plotTop - KlineViewport.padB);
    final visible = vp.visibleBars(model.toBars());
    if (visible.isEmpty) return null;
    final range = vp.priceRangeFor(visible);
    return KlineDrawGeometry(
      viewport: vp,
      range: range,
      plotTop: plotTop,
      plotH: plotH,
      canvasWidth: width,
    );
  }

  Rect? _selectedBox(Size size) {
    if (!model.hasSelection || size.width <= 0 || size.height <= 0) return null;
    final g = _geometry(size.width, size.height);
    if (g == null) return null;
    final bars = model.toBars();
    final idx = model.selected;
    if (idx < 0 || idx >= bars.length) return null;
    final c = bars[idx];
    final x = g.viewport.barCenterX(idx, size.width);
    final top = g.yOf(c.high);
    final bottom = g.yOf(c.low);
    return Rect.fromLTRB(x - 8, top, x + 8, bottom);
  }

  /// 按住某根 K 线：选中它，并冻结本次拖动的基准几何与钳制区间。
  ///
  /// 钳制区间 = 按下瞬间**全体可见 K（含被拖 K 自己）**的极值并集
  /// [min(low), max(high)]。被拖 K 平移时四价被钳在该并集内 → 并集绝不
  /// 扩大，其余已画 K 的像素高度不会塌缩（不会被压成一条线，
  /// 2026-11-16 用户明确）；并集内的来回移动不受限（拖过头还能拖回来）。
  /// 板上**只有这一根**可见 K 时不钳（没有别人可压，随便移）。
  /// 基准几何必须冻结：拖动中价格区间会随被拖 K 变，不冻结会漂移（拖不准）。
  void _grabCandle(int index) {
    final bars = model.toBars();
    if (index < 0 || index >= bars.length) return;
    _dragBaseGeom = _geom ?? _geometry(_lastPaneWidth, _lastPaneHeight);
    final vp = _sync.viewportFor(0);
    final visible = vp.ready ? vp.visibleBars(bars) : const <KlineBar>[];
    var lo = double.infinity;
    var hi = double.negativeInfinity;
    var otherSeen = false;
    for (final b in visible) {
      if (b.idx != index) otherSeen = true;
      lo = math.min(lo, b.low);
      hi = math.max(hi, b.high);
    }
    final clamp = otherSeen && lo.isFinite && hi.isFinite;
    _dragClampLo = clamp ? lo : null;
    _dragClampHi = clamp ? hi : null;
    if (!model.hasSelection || model.selected != index) {
      widget.onChanged(model.select(index));
    }
  }

  /// 拖动整根 K 平移：像素位移 → 价格位移（与绘制互逆，拖 1 像素动 1 像素）。
  ///
  /// [dy] 是「从按下点到当前点」的累计位移（图表侧固定按下点不重置）。
  /// 映射用按下时冻结的几何；线性映射下价格位移 = -dy * span/plotH，
  /// 与锚定哪一价无关。
  void _dragCandle(int index, double dx, double dy) {
    final g = _dragBaseGeom;
    if (g == null) return;
    final bars = model.toBars();
    if (index < 0 || index >= bars.length) return;
    final delta = g.priceAt(g.yOf(bars[index].close) + dy) -
        g.priceAt(g.yOf(bars[index].close));
    widget.onChanged(
      // 钳制区间为 null（板上仅这一根 K，没有别人可压）时 moveCandleAt 不钳。
      model.moveCandleAt(
        index,
        delta,
        clampLo: _dragClampLo,
        clampHi: _dragClampHi,
      ),
    );
  }

  /// 拖动结束：清掉冻结的基准（下次拖动重新冻结）。
  void _endCandleDrag() {
    _dragBaseGeom = null;
    _dragClampLo = null;
    _dragClampHi = null;
  }

  /// 视口（缩放/平移/换数据）变化后重算几何与选中框。
  void _onViewportChanged() {
    if (!mounted) return;
    setState(() => _geom = _geometry(_lastPaneWidth, _lastPaneHeight));
  }

  Widget _roundAction(IconData icon, VoidCallback onTap) {
    return Material(
      color: AppPalette.surfaceAlt,
      shape: const CircleBorder(),
      child: InkWell(
        customBorder: const CircleBorder(),
        onTap: onTap,
        child: SizedBox(
          width: 24,
          height: 24,
          child: Icon(icon, size: 14, color: AppPalette.textPrimary),
        ),
      ),
    );
  }

  /// 新 K 落点：必在选中 K 右方（下标 ≥ 选中+1）；无选中（空板）放行。
  /// cursorBarIdx==null（指针在可见槽位之外）时追加到末尾，天然 ≥ 选中+1。
  int? _clampDrawIndex(int? cursorBarIdx) {
    if (!model.hasSelection) return cursorBarIdx;
    if (cursorBarIdx == null) return null;
    return math.max(cursorBarIdx, model.selected + 1);
  }
  void _onDraw(
    double startPrice,
    double currentPrice,
    bool finished,
    int? cursorBarIdx,
  ) {
    if (!finished) {
      // 累积路径极值：起点与当前点都算路径上的点。
      _pathHigh = _pathHigh == null
          ? math.max(startPrice, currentPrice)
          : math.max(_pathHigh!, math.max(startPrice, currentPrice));
      _pathLow = _pathLow == null
          ? math.min(startPrice, currentPrice)
          : math.min(_pathLow!, math.min(startPrice, currentPrice));
      setState(() {
        _draft = buildKlineDrawDraft(startPrice, currentPrice)
            .withExtremes(_pathHigh!, _pathLow!);
        _draftBarIdx = _clampDrawIndex(cursorBarIdx);
      });
      return;
    }
    // 落盘：用整段路径累积的极值（帮助文字承诺：路径最高=最高价，最低=最低价）。
    final hi = _pathHigh ?? math.max(startPrice, currentPrice);
    final lo = _pathLow ?? math.min(startPrice, currentPrice);
    final candle = KlineDrawCandle(
      open: startPrice,
      close: currentPrice,
      high: math.max(hi, math.max(startPrice, currentPrice)),
      low: math.min(lo, math.min(startPrice, currentPrice)),
    );
    setState(() {
      _draft = null;
      _draftBarIdx = null;
      _pathHigh = null;
      _pathLow = null;
    });
    // 新 K 落在选中 K 右方（钳制后的下标），拖回左方也不会落到选中左侧。
    widget.onChanged(model.insertCandleAt(candle, _clampDrawIndex(cursorBarIdx)));
  }

  static const double _tooltipPanelWidth = 360;
}

/// 画板草稿 K 的覆盖层绘制：与主图蜡烛同源几何（`kline_candle_geometry.dart`）。
///
/// 草稿**不进**主图的 bars（进了会让价格区间跟着草稿变，拖动时映射漂移），
/// 所以单独画一层；几何仍走同一套 `candleGeometryOf`，故画出来与真 K 一致。
class _DraftCandlePainter extends CustomPainter {
  _DraftCandlePainter({
    required this.draft,
    required this.geom,
    required this.barIdx,
    required this.barCount,
  });

  final KlineDrawDraft draft;
  final KlineDrawGeometry? geom;
  final int? barIdx;
  final int barCount;

  @override
  void paint(Canvas canvas, Size size) {
    final g = geom;
    if (g == null) return;
    final at = (barIdx == null || barIdx! < 0 || barIdx! > barCount)
        ? barCount
        : barIdx!;
    final bar = KlineBar(
      idx: at,
      timeMs: 0,
      timeText: '',
      open: draft.open,
      high: draft.high,
      low: draft.low,
      close: draft.close,
      volume: 0,
      amount: 0,
    );
    final geo = g.geometryOf(bar, at);
    final color = draft.close >= draft.open
        ? AppPalette.rgb(0xFFE53935)
        : AppPalette.rgb(0xFF26A69A);
    // 影线：只画实体之外的两段（与主图 _drawCandleWick 同语义）。
    final wickW = candleWickWidth(geo.barW);
    final wick = Paint()
      ..color = color
      ..style = PaintingStyle.fill;
    if (geo.yHigh < geo.bodyTop - 0.5) {
      canvas.drawRect(
        Rect.fromLTRB(
          geo.cx - wickW / 2,
          geo.yHigh,
          geo.cx + wickW / 2,
          geo.bodyTop,
        ),
        wick,
      );
    }
    if (geo.yLow > geo.bodyBottom + 0.5) {
      canvas.drawRect(
        Rect.fromLTRB(
          geo.cx - wickW / 2,
          geo.bodyBottom,
          geo.cx + wickW / 2,
          geo.yLow,
        ),
        wick,
      );
    }
    // 实体：半透明填充 + 实边，表示「还没落定」。
    canvas.drawRect(
      geo.bodyRect,
      Paint()..color = color.withValues(alpha: 0.45),
    );
    canvas.drawRect(
      geo.bodyRect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.2,
    );
  }

  @override
  bool shouldRepaint(covariant _DraftCandlePainter oldDelegate) {
    return oldDelegate.draft.open != draft.open ||
        oldDelegate.draft.close != draft.close ||
        oldDelegate.draft.high != draft.high ||
        oldDelegate.draft.low != draft.low ||
        oldDelegate.barIdx != barIdx ||
        oldDelegate.barCount != barCount ||
        oldDelegate.geom != geom;
  }
}

/// 聚焦标识：四支三角箭头沿对角线指向框中心，尖端停在框角。
///
/// 视觉与分笔画板的聚焦箭头一致（同色、同三角造型），但本类为
/// K线画板私有实现，不借用、不改动分笔画板的源文件。
class _FocusArrowsPainter extends CustomPainter {
  const _FocusArrowsPainter({required this.box});

  final Rect box;
  static const double _arm = 3.5; // 箭头半宽（垂直于对角线方向）
  static const double _len = 8; // 尾端离框角的外伸长度

  @override
  void paint(Canvas canvas, Size size) {
    final paint = Paint()
      ..color = AppPalette.rgb(0xFF42A5F5)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    const dirs = [Offset(-1, -1), Offset(1, -1), Offset(1, 1), Offset(-1, 1)];
    for (final d in dirs) {
      // 尖端=框角（沿对角线指向中心），尾=沿对角线往外 8px。
      final corner = Offset(
        d.dx > 0 ? box.right : box.left,
        d.dy > 0 ? box.bottom : box.top,
      );
      final tail = corner + d * _len;
      final perp = Offset(-d.dy, d.dx);
      final path = Path()
        ..moveTo(corner.dx, corner.dy)
        ..lineTo(tail.dx - perp.dx * _arm, tail.dy - perp.dy * _arm)
        ..lineTo(tail.dx + perp.dx * _arm, tail.dy + perp.dy * _arm)
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FocusArrowsPainter oldDelegate) =>
      oldDelegate.box != box;
}
