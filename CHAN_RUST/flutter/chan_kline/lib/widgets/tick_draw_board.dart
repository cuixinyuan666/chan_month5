import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';
import '../compute/k1_bar_view_compute.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chart_indicator.dart';
import '../models/chip_config.dart';
import '../models/k1_bar_view.dart';
import '../models/tick_dist_config.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../theme/app_palette.dart';
import 'chart_sync_controller.dart';
import 'crosshair_tooltip_bridge.dart';
import 'crosshair_tooltip_panel.dart';
import 'kline_chart.dart';
import 'kline_viewport.dart';
import 'level_chart_grid.dart';

/// 画板顶边栏高度（与主界面标题条同高）。
const double kTickDrawCaptionBarHeight = 28.0;

/// 顶边栏紧凑按钮：严格 28×28，自绘 hover 底色（不用 IconButton 的 48px 命中区）。
class _CaptionButton extends StatefulWidget {
  const _CaptionButton({
    required this.tooltip,
    required this.onTap,
    required this.child,
  });

  final String tooltip;
  final VoidCallback? onTap;
  final Widget child;

  @override
  State<_CaptionButton> createState() => _CaptionButtonState();
}

class _CaptionButtonState extends State<_CaptionButton> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final enabled = widget.onTap != null;
    return Tooltip(
      message: widget.tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: MouseRegion(
        cursor: enabled ? SystemMouseCursors.click : SystemMouseCursors.basic,
        onEnter: (_) => setState(() => _hovered = true),
        onExit: (_) => setState(() => _hovered = false),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: widget.onTap,
          child: Container(
            width: kTickDrawCaptionBarHeight,
            height: kTickDrawCaptionBarHeight,
            alignment: Alignment.center,
            color: _hovered && enabled
                ? AppPalette.rgb(0x33FFFFFF)
                : const Color(0x00000000),
            child: Opacity(
              opacity: enabled ? 1.0 : 0.4,
              child: widget.child,
            ),
          ),
        ),
      ),
    );
  }
}

/// 分笔画板的纯数据口径：只编辑 K0，K1 及以上由现有缠论计算自动生成。
class TickDrawPoint {
  const TickDrawPoint({
    required this.price,
    this.volume = 1,
  });

  final double price;
  final double volume;

  TickDrawPoint copyWith({double? price, double? volume}) => TickDrawPoint(
        price: price ?? this.price,
        volume: volume ?? this.volume,
      );
}

class TickDrawBoardModel {
  const TickDrawBoardModel({
    required this.points,
    required this.windowCount,
    this.selected = -1,
    this.priceStep = 0.01,
    this.start = '2026/07/10 09:30:00',
  });

  final List<TickDrawPoint> points;
  final int windowCount;

  /// 被选中的分笔下标；-1=未选中（未选中时拖拽只走十字线/平移）。
  final int selected;
  final double priceStep;
  final String start;

  bool get hasSelection =>
      points.isNotEmpty && selected >= 0 && selected < points.length;

  int get safeSelected =>
      points.isEmpty ? 0 : (hasSelection ? selected : 0);

  TickDrawBoardModel copyWith({
    List<TickDrawPoint>? points,
    int? windowCount,
    int? selected,
    double? priceStep,
    String? start,
  }) {
    final nextPoints = points ?? this.points;
    final nextSelected = selected ?? this.selected;
    return TickDrawBoardModel(
      points: nextPoints,
      windowCount: normalizeLevelWindowCount(windowCount ?? this.windowCount),
      selected: nextPoints.isEmpty || nextSelected < 0
          ? -1
          : nextSelected.clamp(0, nextPoints.length - 1),
      priceStep: priceStep ?? this.priceStep,
      start: start ?? this.start,
    );
  }

  static TickDrawBoardModel fromBars(List<KlineBar> bars) {
    if (bars.isEmpty) {
      return const TickDrawBoardModel(
        points: [TickDrawPoint(price: 10)],
        windowCount: kLevelWindowDefaultCount,
      );
    }
    return TickDrawBoardModel(
      points: [
        for (final bar in bars) TickDrawPoint(price: bar.close, volume: bar.volume),
      ],
      windowCount: kLevelWindowDefaultCount,
      start: bars.first.timeText,
    );
  }

  TickDrawBoardModel selectPoint(int index) {
    if (points.isEmpty) return this;
    return copyWith(selected: index.clamp(0, points.length - 1));
  }

  TickDrawBoardModel clearSelection() => copyWith(selected: -1);

  TickDrawBoardModel addPoint() {
    if (points.isEmpty) {
      return copyWith(points: const [TickDrawPoint(price: 10)], selected: 0);
    }
    if (!hasSelection) {
      final next = [...points, points.last];
      return copyWith(points: next, selected: next.length - 1);
    }
    final i = safeSelected;
    final seed = points[i];
    final next = [...points]..insert(i + 1, seed);
    return copyWith(points: next, selected: i + 1);
  }

  TickDrawBoardModel removePoint() {
    if (!hasSelection || points.length <= 1) return this;
    final i = safeSelected;
    final next = [...points]..removeAt(i);
    return copyWith(points: next, selected: math.max(0, i - 1));
  }

  TickDrawBoardModel duplicatePoint() {
    if (!hasSelection) return this;
    return addPoint();
  }

  /// 设置当前选中分笔的价格（按 [priceStep] 网格吸附）。
  TickDrawBoardModel setSelectedPrice(double price) {
    if (!hasSelection) return this;
    final i = safeSelected;
    final next = [...points];
    next[i] = next[i].copyWith(price: _snap(price));
    return copyWith(points: next);
  }

  double _snap(double value) {
    final step = priceStep <= 0 ? 0.01 : priceStep;
    return (value / step).round() * step;
  }

  List<KlineBar> toTickBars() {
    final startTime = _parse(start) ?? DateTime(2026, 7, 10, 9, 30);
    return [
      for (var i = 0; i < points.length; i++)
        _barAt(startTime.add(Duration(seconds: i * 3)), i, points[i]),
    ];
  }
}

KlineBar _barAt(DateTime time, int idx, TickDrawPoint point) {
  final price = point.price;
  final text =
      '${time.year.toString().padLeft(4, '0')}/${time.month.toString().padLeft(2, '0')}/${time.day.toString().padLeft(2, '0')} '
      '${time.hour.toString().padLeft(2, '0')}:${time.minute.toString().padLeft(2, '0')}:${time.second.toString().padLeft(2, '0')}';
  return KlineBar(
    idx: idx,
    timeMs: time.millisecondsSinceEpoch,
    timeText: text,
    open: price,
    high: price,
    low: price,
    close: price,
    volume: point.volume,
    amount: 0,
  );
}

DateTime? _parse(String text) {
  final match = RegExp(
    r'(\d{4})\/(\d{1,2})\/(\d{1,2}) (\d{1,2}):(\d{1,2})(?::(\d{1,2}))?',
  ).firstMatch(text.trim());
  if (match == null) return null;
  return DateTime(
    int.parse(match.group(1)!),
    int.parse(match.group(2)!),
    int.parse(match.group(3)!),
    int.parse(match.group(4)!),
    int.parse(match.group(5)!),
    match.group(6) == null ? 0 : int.parse(match.group(6)!),
  );
}

/// 分笔画板：窗口直接用原 `KlineChart`（K 线形态/指标/十字线全同原分窗）。
///
/// 交互：
/// - 点击 K0 任意一根 K 线 → 选中并聚焦；
/// - 未选中：拖拽就是原图平移/十字线；
/// - 已选中：拖住该根 K 线的竖条 → 改价格（网格吸附）、左右拖动换位置；
/// - 拖动过程中与相邻同价 K 线合并成一个临时同价框提示；
/// - 复制 / 删除只作用于当前选中的 K 线。
class TickDrawBoard extends StatefulWidget {
  const TickDrawBoard({
    super.key,
    required this.model,
    required this.bundle,
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
    required this.onSave,
    required this.onClose,
    required this.onMinimize,
    required this.onMaximize,
  });

  final TickDrawBoardModel model;
  final KlineCombineBundle bundle;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final bool truncationCheck;
  final bool earlyDynamicUnit;
  final bool showBuildingDash;
  final ChipConfig chipConfig;
  final TickDistConfig tickDistConfig;
  final ValueChanged<TickDrawBoardModel> onChanged;
  final ValueChanged<Set<MainChartIndicator>> onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>> onSubIndicatorsChanged;
  final VoidCallback onSave;
  final VoidCallback onClose;
  final VoidCallback onMinimize;
  final VoidCallback onMaximize;

  @override
  State<TickDrawBoard> createState() => _TickDrawBoardState();
}

class _TickDrawBoardState extends State<TickDrawBoard>
    with SingleTickerProviderStateMixin {
  /// 画板内各窗口与主图分窗同口径：每窗一份视口，缩放/平移互不联动；
  /// 十字线仍按原分窗规则由「主窗」接管并广播。
  final ChartSyncController _sync = ChartSyncController();
  final CrosshairTooltipBridge _tooltipBridge = CrosshairTooltipBridge();

  /// 同价闪烁：只在两/多根同价瞬间亮一下，不限制上下移动。
  late final AnimationController _flash = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 520),
  );
  ({int start, int end})? _flashRun;
  String? _flashKey;

  Offset _tapDown = Offset.zero;
  int _tapButtons = 0;
  bool _tapMoved = false;
  double _dragDy = 0;
  double _dragStartPrice = 0;

  TickDrawBoardModel get model => widget.model;
  KlineCombineBundle get bundle => widget.bundle;

  @override
  void dispose() {
    _flash.dispose();
    _sync.dispose();
    _tooltipBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bars = model.toTickBars();
    final k1Views = buildK1BarViews(bundle.k1Bars);
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    return Material(
      color: AppPalette.canvasBg,
      child: SafeArea(
        child: Column(
          children: [
            _toolbar(),
            Expanded(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  return ValueListenableBuilder<bool>(
                    valueListenable: _tooltipBridge.shown,
                    builder: (context, shown, _) {
                      return Row(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          Offstage(
                            offstage: !shown,
                            child: SizedBox(
                              width: _tooltipPanelWidth,
                              child: _buildDockedTooltipPanel(
                                constraints.maxHeight,
                              ),
                            ),
                          ),
                          Expanded(
                            child: LevelChartGrid(
                              count: model.windowCount,
                              levels: [
                                for (var i = 0; i < model.windowCount; i++) i,
                              ],
                              maxKn: maxKn,
                              paneBuilder: (context, slot, level, primary) =>
                                  _pane(
                                level: level,
                                bars: bars,
                                k1Views: k1Views,
                              ),
                            ),
                          ),
                        ],
                      );
                    },
                  );
                },
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 画板顶边栏：名称在左上、窗口下拉在最小化左侧、保存并加载、最小化/最大化/关闭。
  Widget _toolbar() {
    final onSurface = AppPalette.textPrimary;
    return Container(
      height: kTickDrawCaptionBarHeight,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        color: AppPalette.surface,
        border: Border(bottom: BorderSide(color: AppPalette.border)),
      ),
      child: Row(
        children: [
          Text(
            '分笔画板',
            style: TextStyle(color: onSurface, fontSize: 12),
          ),
          const Spacer(),
          DropdownButton<int>(
            value: normalizeLevelWindowCount(model.windowCount),
            dropdownColor: AppPalette.surfaceAlt,
            style: TextStyle(color: onSurface, fontSize: 12),
            underline: const SizedBox.shrink(),
            isDense: true,
            items: [
              for (final count in kLevelWindowCountChoices)
                DropdownMenuItem(value: count, child: Text('$count窗')),
            ],
            onChanged: (count) {
              if (count != null) widget.onChanged(model.copyWith(windowCount: count));
            },
          ),
          const SizedBox(width: 6),
          _CaptionButton(
            tooltip: '最小化',
            onTap: widget.onMinimize,
            child: Icon(Icons.remove, size: 14, color: onSurface),
          ),
          _CaptionButton(
            tooltip: '最大化',
            onTap: widget.onMaximize,
            child: Icon(Icons.crop_square, size: 13, color: onSurface),
          ),
          _CaptionButton(
            tooltip: '关闭',
            onTap: widget.onClose,
            child: Icon(Icons.close, size: 14, color: onSurface),
          ),
          const SizedBox(width: 4),
          TextButton(
            onPressed: widget.onSave,
            style: TextButton.styleFrom(
              foregroundColor: onSurface,
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 8),
            ),
            child: const Text('保存并加载', style: TextStyle(fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Widget _pane({
    required int level,
    required List<KlineBar> bars,
    required List<K1BarView> k1Views,
  }) {
    final chart = KlineChart(
      key: ValueKey<String>('tick-draw-$level-${model.windowCount}'),
      interactive: true,
      ownsKeyboard: level == 0,
      displayLevel: level,
      forceSubPane: true,
      bars: bars,
      period: 'tick',
      combineFrames: bundle.frames,
      k0ConfirmSignals: bundle.k0Confirms,
      barFeatures: bundle.barFeatures,
      k0Lines: bundle.k0Lines,
      k1BarViews: k1Views,
      k1CombineFrames: bundle.k1CombineFrames,
      k1Analysis: bundle.k1Analysis,
      levels: bundle.levels,
      zsK0Frames: bundle.zsK0Frames,
      buy1K0Frames: bundle.buy1K0Frames,
      sell1K0Frames: bundle.sell1K0Frames,
      buy2K0Frames: bundle.buy2K0Frames,
      sell2K0Frames: bundle.sell2K0Frames,
      buyNK0Frames: bundle.buyNK0Frames,
      sellNK0Frames: bundle.sellNK0Frames,
      defaultK0Policy: bundle.defaultK0Policy,
      stepIdx: bars.length - 1,
      stepSerial: model.points.length,
      truncationCheck: widget.truncationCheck,
      earlyDynamicUnit: widget.earlyDynamicUnit,
      showBuildingDash: widget.showBuildingDash,
      chipConfig: widget.chipConfig,
      tickDistConfig: widget.tickDistConfig,
      mainIndicators: widget.mainIndicators,
      subIndicators: widget.subIndicators,
      onMainIndicatorsChanged: widget.onMainIndicatorsChanged,
      onSubIndicatorsChanged: widget.onSubIndicatorsChanged,
      indicatorsEnabled: true,
      autoFollowLatest: true,
      sync: _sync,
      onViewportChanged: level == 0 ? _onViewportChanged : null,
      tooltipBridge: _tooltipBridge,
      dockTooltipPanel: true,
    );
    if (level != 0) return chart;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final g = _geometry(width, height, bars);
        Offset dotAt(int i) => Offset(
              g.vp.barCenterX(i, width),
              g.range.yOf(bars[i].close, KlineViewport.padT, g.plotH),
            );
        final selected = model.safeSelected;
        final selDot = model.hasSelection ? dotAt(selected) : Offset.zero;
        final focusSide = math.max(6.0, g.dotR * 2 + 4);
        final dragSide = math.max(10.0, g.dotR * 2 + 6);
        return Stack(
          fit: StackFit.expand,
          children: [
            chart,
            // 点击必须落在圆点 K 线附近才算选中；空白处只取消选中。
            // 用 Listener 不抢指针竞技场：原双轮/中键/拖拽十字操作全部保留。
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  _tapDown = e.localPosition;
                  _tapButtons = e.buttons;
                  _tapMoved = false;
                },
                onPointerMove: (e) {
                  if ((e.localPosition - _tapDown).distance > 4) {
                    _tapMoved = true;
                  }
                },
                onPointerUp: (e) {
                  // 只认左键单击：中键/右键的十字线老操作原样放行。
                  if (_tapMoved || _tapButtons != 1) return;
                  // 命中现算：放大/缩小后视口已变，不能复用 build 时的旧坐标。
                  final now = _geometry(width, height, bars);
                  final hit = _hitDot(
                    e.localPosition,
                    bars,
                    (i) => Offset(
                      now.vp.barCenterX(i, width),
                      now.range.yOf(
                        bars[i].close,
                        KlineViewport.padT,
                        now.plotH,
                      ),
                    ),
                    now.dotR,
                  );
                  if (hit == null) {
                    if (model.hasSelection) {
                      widget.onChanged(model.clearSelection());
                    }
                    return;
                  }
                  final next = model.hasSelection && model.safeSelected == hit
                      ? model.clearSelection()
                      : model.selectPoint(hit);
                  widget.onChanged(next);
                },
              ),
            ),
            if (_flashRun != null)
              AnimatedBuilder(
                animation: _flash,
                builder: (context, _) {
                  final t = (1 - _flash.value).clamp(0.0, 1.0);
                  if (t <= 0.01) return const SizedBox.shrink();
                  final a = dotAt(_flashRun!.start);
                  final b = dotAt(_flashRun!.end);
                  final r = math.max(4.0, g.dotR + 3);
                  return Positioned(
                    left: a.dx - r,
                    top: a.dy - r,
                    width: (b.dx - a.dx).abs() + r * 2,
                    height: r * 2,
                    child: IgnorePointer(
                      child: Opacity(
                        opacity: t,
                        child: CustomPaint(painter: _SamePriceBandPainter()),
                      ),
                    ),
                  );
                },
              ),
            if (model.hasSelection)
              // 聚焦光点：以正方形为基准，四角沿对角线向内指向圆点。
              Positioned(
                left: selDot.dx - focusSide / 2,
                top: selDot.dy - focusSide / 2,
                width: focusSide,
                height: focusSide,
                child: IgnorePointer(
                  child: CustomPaint(painter: _FocusCornersPainter()),
                ),
              ),
            if (model.hasSelection)
              // 三个编辑按钮：放在选中 K 线右侧无遮挡处，避开其它 K 线。
              ..._selectionActions(selDot, width, height, g),
            if (model.hasSelection)
              // 拖动热区只放在圆点上：上下改价。
              // 绝不整块覆盖画布，否则会抢走主图的平移手势（缩小后拖拽失效）。
              Positioned(
                left: selDot.dx - dragSide / 2,
                top: selDot.dy - dragSide / 2,
                width: dragSide,
                height: dragSide,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onPanStart: (_) {
                    _dragDy = 0;
                    _dragStartPrice = model.points[selected].price;
                  },
                  onPanUpdate: (d) =>
                      _onDragVertical(d.delta.dy, g.range, g.plotH),
                  onPanEnd: (_) => _endDrag(),
                  onPanCancel: _endDrag,
                ),
              ),
          ],
        );
      },
    );
  }

  /// 选中 K 线右侧的三个编辑按钮（增加/减少/复制）。
  /// 位置：选中点右侧；右边放不下时翻到左侧，避免压住其它 K 线。
  List<Widget> _selectionActions(
    Offset selDot,
    double width,
    double height,
    ({
      KlineViewport vp,
      PriceRange range,
      double plotH,
      double slotW,
      double dotR,
    }) g,
  ) {
    const btn = 24.0;
    const gap = 2.0;
    final total = btn * 3 + gap * 2;
    final rightSpace = width - selDot.dx - g.dotR - 4;
    final onRight = rightSpace >= total;
    final left = onRight
        ? selDot.dx + g.dotR + 4
        : math.max(0.0, selDot.dx - g.dotR - 4 - total);
    // 垂直位置：靠近选中点，但别压到顶部指标条。
    final top = (selDot.dy - btn / 2)
        .clamp(
          KlineViewport.padT.toDouble(),
          math.max(0.0, height - btn),
        )
        .toDouble();
    Widget circle(IconData icon, String tip, VoidCallback? onTap) {
      return Tooltip(
        message: tip,
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTap: onTap,
          child: Container(
            width: btn,
            height: btn,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: AppPalette.rgb(0xCC1A1A1A),
              shape: BoxShape.circle,
              border: Border.all(color: AppPalette.rgb(0x55FFFFFF)),
            ),
            child: Icon(
              icon,
              size: 13,
              color: onTap == null
                  ? AppPalette.textSecondary
                  : AppPalette.textPrimary,
            ),
          ),
        ),
      );
    }

    return [
      Positioned(
        left: left,
        top: top,
        width: total.toDouble(),
        height: btn,
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            circle(Icons.add, '增加（在选中后插入）', () {
              widget.onChanged(model.addPoint());
            }),
            const SizedBox(width: gap),
            circle(Icons.remove, '减少（删除选中）', () {
              widget.onChanged(model.removePoint());
            }),
            const SizedBox(width: gap),
            circle(Icons.copy, '复制（复制选中）', () {
              widget.onChanged(model.duplicatePoint());
            }),
          ],
        ),
      ),
    ];
  }

  void _onViewportChanged() {
    if (mounted) setState(() {});
  }

  /// 与 KlineChart 的 tick 圆点完全同口径的几何：
  /// barW = max(1, slotW*0.65)，dotR = max(1.2, min(barW*0.45, slotW*0.35))。
  ({
    KlineViewport vp,
    PriceRange range,
    double plotH,
    double slotW,
    double dotR,
  }) _geometry(
    double width,
    double height,
    List<KlineBar> bars,
  ) {
    final vp = _sync.viewportFor(0);
    final mainH = height * _sync.mainFraction;
    final plotH = math.max(
      1.0,
      mainH - KlineViewport.padT - KlineViewport.padB,
    );
    final range = vp.priceRangeFor(vp.visibleBars(bars));
    final slotW = vp.barSlotWidth(width);
    final dotR = math.max(1.2, slotW * 0.2925);
    return (vp: vp, range: range, plotH: plotH, slotW: slotW, dotR: dotR);
  }

  int? _hitDot(
    Offset p,
    List<KlineBar> bars,
    Offset Function(int) dotAt,
    double hitR,
  ) {
    int? best;
    var bestD = hitR;
    for (var i = 0; i < bars.length; i++) {
      final d = (dotAt(i) - p).distance;
      if (d <= bestD) {
        bestD = d;
        best = i;
      }
    }
    return best;
  }

  void _onDragVertical(double dy, PriceRange range, double plotH) {
    if (!model.hasSelection) return;
    _dragDy += dy;
    final span = math.max(1e-9, range.max - range.min);
    final price = _dragStartPrice - _dragDy * span / math.max(1.0, plotH);
    final next = model.setSelectedPrice(price);
    _updateFlash(next);
    widget.onChanged(next);
  }

  void _updateFlash(TickDrawBoardModel m) {
    final run = _priceRun(m, m.safeSelected);
    if (run.end > run.start) {
      final key = '${m.points[m.safeSelected].price}/${run.start}/${run.end}';
      if (key != _flashKey) {
        _flashKey = key;
        setState(() => _flashRun = run);
        _flash.forward(from: 0);
      }
    } else if (_flashRun != null) {
      setState(() {
        _flashRun = null;
        _flashKey = null;
      });
    }
  }

  void _endDrag() {
    setState(() {
      _flashRun = null;
      _flashKey = null;
    });
  }

  ({int start, int end}) _priceRun(TickDrawBoardModel m, int index) {
    final price = m.points[index].price;
    var start = index;
    var end = index;
    while (start > 0 &&
        (m.points[start - 1].price - price).abs() < 1e-9) {
      start--;
    }
    while (end < m.points.length - 1 &&
        (m.points[end + 1].price - price).abs() < 1e-9) {
      end++;
    }
    return (start: start, end: end);
  }

  Widget _buildDockedTooltipPanel(double h) {
    return ValueListenableBuilder<List<CrosshairTooltipRow>>(
      valueListenable: _tooltipBridge.rows,
      builder: (context, rows, _) {
        return Container(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(color: AppPalette.border),
            ),
          ),
          child: CrosshairTooltipPanel(
            rows: rows,
            scrollController: _tooltipBridge.scrollController!,
            maxWidth: _tooltipPanelWidth,
            maxHeight: h,
            onClose: () {
              _tooltipBridge.suppressTooltipUntilMs =
                  DateTime.now().millisecondsSinceEpoch + 600;
              _tooltipBridge.shown.value = false;
              _tooltipBridge.onRequestClose?.call();
            },
          ),
        );
      },
    );
  }

  static const double _tooltipPanelWidth = 360;
}

/// 聚焦光点：以正方形为基准，四角各放一个沿对角线向内指向圆点的小光点。
class _FocusCornersPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    final halfH = size.height / 2;
    final r = math.max(1.6, size.width * 0.13);
    // 四角相对圆心（正方形中心）的对角方向单位向量。
    const dirs = [
      Offset(-1, -1),
      Offset(1, -1),
      Offset(1, 1),
      Offset(-1, 1),
    ];
    final paint = Paint()
      ..color = AppPalette.rgb(0xFF42A5F5)
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    for (final d in dirs) {
      final n = d / math.sqrt(d.dx * d.dx + d.dy * d.dy);
      final center = Offset(half + n.dx * (half - r * 1.2),
          halfH + n.dy * (halfH - r * 1.2));
      canvas.drawCircle(center, r, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FocusCornersPainter oldDelegate) => false;
}

class _SamePriceBandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppPalette.rgb(0x22FFC107)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = AppPalette.rgb(0xEEFFC107)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SamePriceBandPainter oldDelegate) => false;
}
