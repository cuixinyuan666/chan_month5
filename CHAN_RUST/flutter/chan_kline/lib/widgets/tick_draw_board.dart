import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';
import '../compute/k1_bar_view_compute.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chart_indicator.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
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

  /// 把当前选中分笔移动到 [target] 位置。
  TickDrawBoardModel moveSelectedTo(int target) {
    if (!hasSelection) return this;
    final i = safeSelected;
    final t = target.clamp(0, points.length - 1);
    if (t == i) return this;
    final next = [...points];
    final moved = next.removeAt(i);
    next.insert(t, moved);
    return copyWith(points: next, selected: t);
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
    required this.onChanged,
    required this.onMainIndicatorsChanged,
    required this.onSubIndicatorsChanged,
    required this.onSave,
    required this.onClose,
  });

  final TickDrawBoardModel model;
  final KlineCombineBundle bundle;
  final Set<MainChartIndicator> mainIndicators;
  final Set<SubChartIndicator> subIndicators;
  final bool truncationCheck;
  final bool earlyDynamicUnit;
  final bool showBuildingDash;
  final ValueChanged<TickDrawBoardModel> onChanged;
  final ValueChanged<Set<MainChartIndicator>> onMainIndicatorsChanged;
  final ValueChanged<Set<SubChartIndicator>> onSubIndicatorsChanged;
  final VoidCallback onSave;
  final VoidCallback onClose;

  @override
  State<TickDrawBoard> createState() => _TickDrawBoardState();
}

class _TickDrawBoardState extends State<TickDrawBoard> {
  /// 画板内所有窗口共享一份视口：放大/缩小/平移/十字线全同步。
  final ChartSyncController _sync =
      ChartSyncController(sharedViewport: true);
  final CrosshairTooltipBridge _tooltipBridge = CrosshairTooltipBridge();

  bool _dragging = false;
  int? _runStart;
  int? _runEnd;
  Offset _tapDown = Offset.zero;
  bool _tapMoved = false;

  TickDrawBoardModel get model => widget.model;
  KlineCombineBundle get bundle => widget.bundle;

  @override
  void dispose() {
    _sync.dispose();
    _tooltipBridge.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final bars = model.toTickBars();
    final k1Views = buildK1BarViews(bundle.k1Bars);
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    final theme = Theme.of(context);
    return Material(
      color: theme.colorScheme.surface,
      child: SafeArea(
        child: Column(
          children: [
            _toolbar(theme),
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
                                theme,
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

  Widget _toolbar(ThemeData theme) {
    final onSurface = theme.colorScheme.onSurface;
    final hasSel = model.hasSelection;
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          Text('分笔画板', style: TextStyle(color: onSurface)),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: normalizeLevelWindowCount(model.windowCount),
            dropdownColor: theme.colorScheme.surfaceContainerHighest,
            style: TextStyle(color: onSurface),
            items: [
              for (final count in kLevelWindowCountChoices)
                DropdownMenuItem(value: count, child: Text('$count窗')),
            ],
            onChanged: (count) {
              if (count != null) widget.onChanged(model.copyWith(windowCount: count));
            },
          ),
          const SizedBox(width: 12),
          Text(
            hasSel
                ? '已选第 ${model.safeSelected + 1}/${model.points.length} 笔（再点同根取消）'
                : '点击 K 线选中；未选中时拖拽为十字线/平移',
            style: TextStyle(color: onSurface.withValues(alpha: 0.7), fontSize: 12),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '增加（在选中后插入）',
            onPressed: () => widget.onChanged(model.addPoint()),
            icon: Icon(Icons.add, color: onSurface),
          ),
          IconButton(
            tooltip: '减少（删除选中）',
            onPressed: hasSel ? () => widget.onChanged(model.removePoint()) : null,
            icon: Icon(Icons.remove, color: hasSel ? onSurface : onSurface.withValues(alpha: 0.3)),
          ),
          IconButton(
            tooltip: '复制（复制选中）',
            onPressed: hasSel ? () => widget.onChanged(model.duplicatePoint()) : null,
            icon: Icon(Icons.copy, color: hasSel ? onSurface : onSurface.withValues(alpha: 0.3)),
          ),
          const Spacer(),
          TextButton(onPressed: widget.onSave, child: const Text('保存并加载')),
          IconButton(
            tooltip: '关闭',
            onPressed: widget.onClose,
            icon: Icon(Icons.close, color: onSurface),
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
      mainIndicators: widget.mainIndicators,
      subIndicators: widget.subIndicators,
      onMainIndicatorsChanged: widget.onMainIndicatorsChanged,
      onSubIndicatorsChanged: widget.onSubIndicatorsChanged,
      indicatorsEnabled: true,
      autoFollowLatest: true,
      sync: _sync,
      tooltipBridge: _tooltipBridge,
      dockTooltipPanel: true,
    );
    if (level != 0) return chart;
    return LayoutBuilder(
      builder: (context, constraints) {
        final vp = _sync.viewportFor(0);
        final n = math.max(1, model.points.length);
        final width = constraints.maxWidth;
        final height = constraints.maxHeight;
        final slotWidth = vp.barSlotWidth(width);
        final selected = model.safeSelected;
        return Stack(
          fit: StackFit.expand,
          children: [
            chart,
            // 只处理点击（不含拖动）：点 K 线选中；拖动仍归原图平移/十字线。
            // 用 Listener 而不是 GestureDetector，避免抢掉指标按钮的点击。
            Positioned.fill(
              child: Listener(
                behavior: HitTestBehavior.translucent,
                onPointerDown: (e) {
                  _tapDown = e.localPosition;
                  _tapMoved = false;
                },
                onPointerMove: (e) {
                  if ((e.localPosition - _tapDown).distance > 4) {
                    _tapMoved = true;
                  }
                },
                onPointerUp: (e) {
                  if (!_tapMoved && _tapDown.dy > _topOverlayGuard) {
                    _onTapSelect(e.localPosition, width, n);
                  }
                },
              ),
            ),
            if (_dragging && _runStart != null && _runEnd != null &&
                _runEnd! > _runStart!)
              Positioned(
                left: vp.barCenterX(_runStart!, width) - slotWidth / 2,
                width: slotWidth * (_runEnd! - _runStart! + 1),
                top: 0,
                bottom: 0,
                child: IgnorePointer(
                  child: CustomPaint(
                    painter: _SamePriceBandPainter(),
                  ),
                ),
              ),
            if (model.hasSelection) ...[
              // 聚焦框：只显示选中的那一根。
              Positioned(
                left: vp.barCenterX(selected, width) - math.max(5, slotWidth / 2),
                width: math.max(10, slotWidth),
                top: _topOverlayGuard,
                bottom: 0,
                child: IgnorePointer(
                  child: CustomPaint(painter: _FocusBandPainter()),
                ),
              ),
              // 选中态整块可拖：拖非 K 线区域也改选中 K 线（题意：选中后进入编辑）。
              Positioned(
                left: 0,
                right: 0,
                top: _topOverlayGuard,
                bottom: 0,
                child: GestureDetector(
                  behavior: HitTestBehavior.opaque,
                  onTapUp: (d) => _onTapSelect(d.localPosition, width, n),
                  onPanStart: (_) {
                    setState(() {
                      _dragging = true;
                      _runStart = null;
                      _runEnd = null;
                    });
                  },
                  onPanUpdate: (d) => _onDrag(
                    d.localPosition,
                    width,
                    height,
                    bars,
                  ),
                  onPanEnd: (_) {
                    setState(() {
                      _dragging = false;
                      _runStart = null;
                      _runEnd = null;
                    });
                  },
                  onPanCancel: () {
                    setState(() {
                      _dragging = false;
                      _runStart = null;
                      _runEnd = null;
                    });
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }

  void _onTapSelect(Offset local, double width, int n) {
    final vp = _sync.viewportFor(0);
    final i = vp.barIndexAtCanvasX(local.dx, width, n);
    final next = model.hasSelection && model.safeSelected == i
        ? model.clearSelection()
        : model.selectPoint(i);
    widget.onChanged(next);
    if (!next.hasSelection) {
      setState(() {
        _dragging = false;
        _runStart = null;
        _runEnd = null;
      });
    }
  }

  void _onDrag(Offset local, double width, double height, List<KlineBar> bars) {
    final vp = _sync.viewportFor(0);
    final n = math.max(1, model.points.length);
    final mainH = height * _sync.mainFraction;
    final plotH = math.max(
      1.0,
      mainH - KlineViewport.padT - KlineViewport.padB,
    );
    final range = vp.priceRangeFor(vp.visibleBars(bars));
    final price = range.priceFromY(local.dy, KlineViewport.padT, plotH);
    final target = vp.barIndexAtCanvasX(local.dx, width, n);
    var next = model;
    if (next.safeSelected != target) next = next.moveSelectedTo(target);
    next = next.setSelectedPrice(price);
    final run = _priceRun(next, next.safeSelected);
    setState(() {
      _runStart = run.start;
      _runEnd = run.end;
    });
    widget.onChanged(next);
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

  Widget _buildDockedTooltipPanel(ThemeData theme, double h) {
    return ValueListenableBuilder<List<CrosshairTooltipRow>>(
      valueListenable: _tooltipBridge.rows,
      builder: (context, rows, _) {
        return Container(
          decoration: BoxDecoration(
            border: Border(
              right: BorderSide(
                color: theme.colorScheme.outline.withValues(alpha: 0.3),
              ),
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

  /// 顶部指标按钮/胶囊条占位：点击选中与拖拽条都从这里往下开始。
  static const double _topOverlayGuard = 56;
}

class _FocusBandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0x3342A5F5)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xCC42A5F5)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _FocusBandPainter oldDelegate) => false;
}

class _SamePriceBandPainter extends CustomPainter {
  @override
  void paint(Canvas canvas, Size size) {
    final rect = Rect.fromLTWH(1, 1, size.width - 2, size.height - 2);
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0x22FFC107)
        ..style = PaintingStyle.fill,
    );
    canvas.drawRect(
      rect,
      Paint()
        ..color = const Color(0xEEFFC107)
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.5,
    );
  }

  @override
  bool shouldRepaint(covariant _SamePriceBandPainter oldDelegate) => false;
}
