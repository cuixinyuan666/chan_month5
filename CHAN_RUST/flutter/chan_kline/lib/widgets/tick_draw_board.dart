import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';
import '../chart/tick_dot_geometry.dart';
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

  double _dragDy = 0;
  double _dragStartPrice = 0;
  /// 最近一次 K0 窗格的尺寸：拖动回调里要重算价格区间。
  double _lastPaneWidth = 0;
  double _lastPaneHeight = 0;

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
        child: Stack(
          children: [
            Positioned.fill(
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
      // 画板：点圆点选中 / 拖圆点改价，都在 KlineChart 内部判定，
      // 不用覆盖层，避免抢掉图表自身的平移/十字/滚轮手势。
      onTickDotTap: level == 0 ? _onTickDotTap : null,
      onTickDotDrag: level == 0 ? _onTickDotDrag : null,
      onTickDotDragEnd: level == 0 ? _endDrag : null,
      selectedTickIdx: level == 0 && model.hasSelection ? model.safeSelected : -1,
      tooltipBridge: _tooltipBridge,
      dockTooltipPanel: true,
    );
    if (level != 0) return chart;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        if (level == 0) {
          _lastPaneWidth = width;
          _lastPaneHeight = height;
        }
        final g = _geometry(width, height, bars);
        Offset dotAt(int i) => g.centerOf(i, bars[i].close);
        final selected = model.safeSelected;
        final selDot = model.hasSelection ? dotAt(selected) : Offset.zero;
        // 聚焦框边长 = 圆点直径 + 两侧各留一点缝，圆心与圆点圆心重合。
        final focusSide = g.dotR * 2 + 10;
        return Stack(
          fit: StackFit.expand,
          children: [
            chart,
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
              // 聚焦标识：四个箭头沿对角线指向圆心。
              Positioned(
                left: selDot.dx - focusSide / 2,
                top: selDot.dy - focusSide / 2,
                width: focusSide,
                height: focusSide,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _FocusArrowsPainter(dotR: g.dotR),
                  ),
                ),
              ),
            if (model.hasSelection)
              // 三个编辑按钮：放在选中 K 线右侧无遮挡处，避开其它 K 线。
              ..._selectionActions(selDot, width, height, g),
          ],
        );
      },
    );
  }

  /// 点中分笔圆点：选中它；再点同一根则取消选中。
  void _onTickDotTap(int idx) {
    final next = model.hasSelection && model.safeSelected == idx
        ? model.clearSelection()
        : model.selectPoint(idx);
    widget.onChanged(next);
  }

  /// 拖动分笔圆点：按纵向位移改价格（网格吸附）。
  void _onTickDotDrag(int idx, double dx, double dy) {
    // 按下时若该点尚未选中，先选中它，随后到达的位移就能直接改价，
    // 不必等用户先点一下再拖。
    if (!model.hasSelection || model.safeSelected != idx) {
      widget.onChanged(model.selectPoint(idx));
      _dragDy = 0;
      return;
    }
    final g = _geometry(_lastPaneWidth, _lastPaneHeight, model.toTickBars());
    if (_dragDy == 0) {
      _dragStartPrice = model.points[idx].price;
    }
    _dragDy += dy;
    final span = math.max(1e-9, g.range.max - g.range.min);
    final price = _dragStartPrice - _dragDy * span / math.max(1.0, g.plotH);
    final next = model.setSelectedPrice(price);
    _updateFlash(next);
    widget.onChanged(next);
  }

  /// 选中 K 线右侧的三个编辑按钮（增加/减少/复制），竖向排列。
  /// 位置：选中点右侧；右边放不下时翻到左侧，避免压住其它 K 线。
  List<Widget> _selectionActions(
    Offset selDot,
    double width,
    double height,
    TickDotGeometry g,
  ) {
    const btn = 24.0;
    const gap = 2.0;
    // 竖排：水平方向只占一个按钮宽，垂直方向占 三个按钮 + 两道间隙。
    final totalH = btn * 3 + gap * 2;
    final rightSpace = width - selDot.dx - g.dotR - 4;
    final onRight = rightSpace >= btn;
    final left = onRight
        ? selDot.dx + g.dotR + 4
        : math.max(0.0, selDot.dx - g.dotR - 4 - btn);
    // 垂直位置：以选中点为中心上下展开，但别压到顶部指标条与底部留白。
    final top = (selDot.dy - totalH / 2)
        .clamp(
          KlineViewport.padT.toDouble(),
          math.max(0.0, height - totalH),
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
              color: AppPalette.canvasBg.withValues(alpha: 0.8),
              shape: BoxShape.circle,
              border: Border.all(color: AppPalette.border),
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
        width: btn,
        height: totalH,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            circle(Icons.add, '增加（在选中后插入）', () {
              widget.onChanged(model.addPoint());
            }),
            const SizedBox(height: gap),
            circle(Icons.remove, '减少（删除选中）', () {
              widget.onChanged(model.removePoint());
            }),
            const SizedBox(height: gap),
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

  /// 与 KlineChart 的 tick 圆点完全同口径的几何：半径、留白后的价格区间
  /// 都走 [tick_dot_geometry]，聚焦框圆心才能落在圆点圆心上。
  TickDotGeometry _geometry(
    double width,
    double height,
    List<KlineBar> bars,
  ) {
    final vp = _sync.viewportFor(0);
    final mainH = height * _sync.mainFraction;
    const plotTop = KlineViewport.padT;
    final plotH = math.max(1.0, mainH - plotTop - KlineViewport.padB);
    final slotW = vp.barSlotWidth(width);
    final dotR = tickDotRadius(slotW);
    final range = tickDotPaddedRange(
      raw: vp.priceRangeFor(vp.visibleBars(bars)),
      dotR: dotR,
      plotH: plotH,
    );
    return TickDotGeometry(
      viewport: vp,
      slotW: slotW,
      dotR: dotR,
      plotTop: plotTop,
      plotH: plotH,
      width: width,
      range: range,
    );
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

  /// 拖动结束：清掉同价闪烁与拖动累计量。
  void _endDrag() {
    _dragDy = 0;
    if (_flashRun == null) return;
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

/// 聚焦标识：四个箭头沿对角线指向圆心，箭头尖端落在圆点边缘。
class _FocusArrowsPainter extends CustomPainter {
  const _FocusArrowsPainter({required this.dotR});

  /// 圆点半径：箭头尖端停在圆心外这么远，避免压进圆点里。
  final double dotR;

  @override
  void paint(Canvas canvas, Size size) {
    final half = size.width / 2;
    final halfH = size.height / 2;
    final color = AppPalette.rgb(0xFF42A5F5);
    final paint = Paint()
      ..color = color
      ..style = PaintingStyle.fill
      ..isAntiAlias = true;
    // 四角相对圆心的对角方向。
    const dirs = [
      Offset(-1, -1),
      Offset(1, -1),
      Offset(1, 1),
      Offset(-1, 1),
    ];
    const headHalf = 3.0;
    for (final d in dirs) {
      final n = d / math.sqrt(d.dx * d.dx + d.dy * d.dy);
      // 箭头尖端落在圆点边缘（圆心外 dotR），箭尾贴在正方形角上，
      // 这样四支箭头沿对角线指向圆心，且紧贴圆点。
      final tip = Offset(
        half + n.dx * dotR,
        halfH + n.dy * dotR,
      );
      final tail = Offset(
        half + n.dx * (half - 2),
        halfH + n.dy * (halfH - 2),
      );
      final path = Path()
        ..moveTo(tip.dx, tip.dy)
        ..lineTo(
          tail.dx - n.dy * headHalf,
          tail.dy + n.dx * headHalf,
        )
        ..lineTo(
          tail.dx + n.dy * headHalf,
          tail.dy - n.dx * headHalf,
        )
        ..close();
      canvas.drawPath(path, paint);
    }
  }

  @override
  bool shouldRepaint(covariant _FocusArrowsPainter oldDelegate) =>
      oldDelegate.dotR != dotR;
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
