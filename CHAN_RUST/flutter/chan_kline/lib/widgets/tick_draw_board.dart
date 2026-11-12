import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';
import '../compute/k1_bar_view_compute.dart';
import '../models/chart_indicator.dart';
import '../models/k1_bar_view.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import 'kline_chart.dart';
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
    this.selected = 0,
    this.priceStep = 0.01,
    this.start = '2026/07/10 09:30:00',
  });

  final List<TickDrawPoint> points;
  final int windowCount;
  final int selected;
  final double priceStep;
  final String start;

  int get safeSelected =>
      points.isEmpty ? 0 : selected.clamp(0, points.length - 1);

  TickDrawBoardModel copyWith({
    List<TickDrawPoint>? points,
    int? windowCount,
    int? selected,
    double? priceStep,
    String? start,
  }) {
    final nextPoints = points ?? this.points;
    return TickDrawBoardModel(
      points: nextPoints,
      windowCount: normalizeLevelWindowCount(windowCount ?? this.windowCount),
      selected: nextPoints.isEmpty
          ? 0
          : (selected ?? this.selected).clamp(0, nextPoints.length - 1),
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
      selected: bars.length - 1,
      start: bars.first.timeText,
    );
  }

  TickDrawBoardModel selectPoint(int index) {
    if (points.isEmpty) return this;
    return copyWith(selected: index.clamp(0, points.length - 1));
  }

  TickDrawBoardModel addPoint() {
    final i = safeSelected;
    final seed = points.isEmpty ? const TickDrawPoint(price: 10) : points[i];
    final next = [...points]..insert(i + 1, seed);
    return copyWith(points: next, selected: i + 1);
  }

  TickDrawBoardModel removePoint() {
    if (points.length <= 1) return this;
    final i = safeSelected;
    final next = [...points]..removeAt(i);
    return copyWith(points: next, selected: math.max(0, i - 1));
  }

  TickDrawBoardModel duplicatePoint() => addPoint();

  /// 设置当前选中分笔的价格（按 [priceStep] 网格吸附）。
  TickDrawBoardModel setSelectedPrice(double price) {
    if (points.isEmpty) return this;
    final i = safeSelected;
    final next = [...points];
    next[i] = next[i].copyWith(price: _snap(price));
    return copyWith(points: next);
  }

  /// 沿时间轴平移当前选中分笔（正数向后、负数向前），选中位置跟随。
  TickDrawBoardModel shiftSelected(int delta) {
    if (points.isEmpty || delta == 0) return this;
    final i = safeSelected;
    final target = (i + delta).clamp(0, points.length - 1);
    if (target == i) return this;
    final next = [...points];
    final moved = next.removeAt(i);
    next.insert(target, moved);
    return copyWith(points: next, selected: target);
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
/// K0 额外叠一层拖拽编辑手势；K1 及以上只读。
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
  bool _dragMode = false;
  double _dragStartPrice = 0;
  int _dragAppliedSteps = 0;
  double _dragAccumDx = 0;
  double _dragAccumDy = 0;

  TickDrawBoardModel get model => widget.model;
  KlineCombineBundle get bundle => widget.bundle;

  @override
  Widget build(BuildContext context) {
    final bars = model.toTickBars();
    final k1Views = buildK1BarViews(bundle.k1Bars);
    final maxKn = chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
    return Material(
      color: const Color(0xF2121722),
      child: SafeArea(
        child: Column(
          children: [
            _toolbar(),
            Expanded(
              child: LevelChartGrid(
                count: model.windowCount,
                levels: [for (var i = 0; i < model.windowCount; i++) i],
                maxKn: maxKn,
                paneBuilder: (context, slot, level, primary) => _pane(
                  level: level,
                  bars: bars,
                  k1Views: k1Views,
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar() {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          const Text('分笔画板', style: TextStyle(color: Colors.white)),
          const SizedBox(width: 8),
          DropdownButton<int>(
            value: normalizeLevelWindowCount(model.windowCount),
            dropdownColor: const Color(0xFF1F2937),
            style: const TextStyle(color: Colors.white),
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
            '选中第 ${model.safeSelected + 1}/${model.points.length} 笔',
            style: const TextStyle(color: Colors.white70, fontSize: 12),
          ),
          const SizedBox(width: 8),
          IconButton(
            tooltip: '增加',
            onPressed: () => widget.onChanged(model.addPoint()),
            icon: const Icon(Icons.add, color: Colors.white),
          ),
          IconButton(
            tooltip: '减少',
            onPressed: () => widget.onChanged(model.removePoint()),
            icon: const Icon(Icons.remove, color: Colors.white),
          ),
          IconButton(
            tooltip: '复制',
            onPressed: () => widget.onChanged(model.duplicatePoint()),
            icon: const Icon(Icons.copy, color: Colors.white),
          ),
          FilterChip(
            label: const Text('拖拽'),
            selected: _dragMode,
            onSelected: (v) => setState(() => _dragMode = v),
          ),
          const Spacer(),
          TextButton(onPressed: widget.onSave, child: const Text('保存并加载')),
          IconButton(
            tooltip: '关闭',
            onPressed: widget.onClose,
            icon: const Icon(Icons.close, color: Colors.white),
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
      interactive: level == 0 ? !_dragMode : true,
      ownsKeyboard: level == 0 && !_dragMode,
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
    );
    if (level != 0 || !_dragMode) return chart;
    return Stack(
      fit: StackFit.expand,
      children: [
        chart,
        _dragLayer(),
      ],
    );
  }

  Widget _dragLayer() {
    return LayoutBuilder(
      builder: (context, constraints) {
        final bars = model.toTickBars();
        final span = _priceSpan(bars);
        final n = math.max(1, model.points.length);
        final slotWidth = constraints.maxWidth / n;
        return GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (d) {
            final i = (d.localPosition.dx / slotWidth).floor().clamp(0, n - 1);
            widget.onChanged(model.selectPoint(i));
          },
          onPanStart: (d) {
            final i = (d.localPosition.dx / slotWidth).floor().clamp(0, n - 1);
            _dragStartPrice = model.points[i].price;
            _dragAppliedSteps = 0;
            _dragAccumDx = 0;
            _dragAccumDy = 0;
            widget.onChanged(model.selectPoint(i));
          },
          onPanUpdate: (d) {
            _dragAccumDx += d.delta.dx;
            _dragAccumDy += d.delta.dy;
            var next = model;
            final steps = slotWidth <= 0 ? 0 : (_dragAccumDx / slotWidth).round();
            final deltaSteps = steps - _dragAppliedSteps;
            if (deltaSteps != 0) {
              next = next.shiftSelected(deltaSteps);
              _dragAppliedSteps = steps;
            }
            final price = _dragStartPrice -
                (_dragAccumDy / math.max(1, constraints.maxHeight)) * span;
            widget.onChanged(next.setSelectedPrice(price));
          },
          onPanEnd: (_) {
            _dragAppliedSteps = 0;
          },
        );
      },
    );
  }

  double _priceSpan(List<KlineBar> bars) {
    if (bars.isEmpty) return 0.01;
    var hi = double.negativeInfinity;
    var lo = double.infinity;
    for (final bar in bars) {
      hi = math.max(hi, bar.high);
      lo = math.min(lo, bar.low);
    }
    return math.max(0.01, hi - lo);
  }
}
