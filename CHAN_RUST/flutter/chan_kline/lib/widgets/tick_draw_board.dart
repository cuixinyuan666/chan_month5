import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';
import '../compute/chart_view_compute.dart';
import '../models/k1_bar.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../theme/app_palette.dart';

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
      start: bars.first.timeText,
    );
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

  TickDrawBoardModel movePoint(int index, Offset delta, {required double rowHeight}) {
    if (index < 0 || index >= points.length) return this;
    final priceSteps = -(delta.dy / math.max(1, rowHeight / 20)).round();
    final slotSteps = (delta.dx / 28).round();
    final next = [...points];
    final moved = next.removeAt(index);
    final target = (index + slotSteps).clamp(0, next.length);
    next.insert(
      target,
      moved.copyWith(
        price: _snap(moved.price + priceSteps * priceStep),
      ),
    );
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

  List<K1Bar> generatedBars({
    required int level,
    required KlineCombineBundle bundle,
  }) {
    if (level <= 0 || level >= bundle.levels.length) return const [];
    return levelBundleVirtualK1Bars(bundle.levels[level - 1]);
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

class TickDrawBoard extends StatelessWidget {
  const TickDrawBoard({
    super.key,
    required this.model,
    required this.bundle,
    required this.onChanged,
    required this.onSave,
    required this.onClose,
  });

  final TickDrawBoardModel model;
  final KlineCombineBundle bundle;
  final ValueChanged<TickDrawBoardModel> onChanged;
  final VoidCallback onSave;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final grid = LevelWindowGrid(model.windowCount);
    return Material(
      color: const Color(0xCC111827),
      child: SafeArea(
        child: Column(
          children: [
            _toolbar(context),
            Expanded(
              child: Column(
                children: [
                  for (var row = 0; row < grid.rows; row++)
                    Expanded(
                      child: Row(
                        children: [
                          for (var col = 0; col < grid.cols; col++)
                            Expanded(child: _pane(row * grid.cols + col)),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(BuildContext context) {
    return Container(
      height: 48,
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
              if (count != null) onChanged(model.copyWith(windowCount: count));
            },
          ),
          const Spacer(),
          IconButton(
            tooltip: '增加',
            onPressed: () => onChanged(model.addPoint()),
            icon: const Icon(Icons.add, color: Colors.white),
          ),
          IconButton(
            tooltip: '减少',
            onPressed: () => onChanged(model.removePoint()),
            icon: const Icon(Icons.remove, color: Colors.white),
          ),
          IconButton(
            tooltip: '复制',
            onPressed: () => onChanged(model.duplicatePoint()),
            icon: const Icon(Icons.copy, color: Colors.white),
          ),
          TextButton(onPressed: onSave, child: const Text('保存并加载')),
          IconButton(
            tooltip: '关闭',
            onPressed: onClose,
            icon: const Icon(Icons.close, color: Colors.white),
          ),
        ],
      ),
    );
  }

  Widget _pane(int level) {
    final bars = level == 0
        ? model.toTickBars()
        : model.generatedBars(level: level, bundle: bundle);
    return Container(
      margin: const EdgeInsets.all(4),
      decoration: BoxDecoration(
        border: Border.all(color: AppPalette.rgb(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.all(4),
            child: Text('K$level', style: const TextStyle(color: Colors.white70, fontSize: 12)),
          ),
          Expanded(
            child: level == 0 ? _editablePane(bars.cast<KlineBar>()) : _generatedPane(bars.cast<K1Bar>()),
          ),
        ],
      ),
    );
  }

  Widget _editablePane(List<KlineBar> bars) {
    return LayoutBuilder(
      builder: (context, constraints) {
        return GestureDetector(
          onPanUpdate: (details) => onChanged(
            model.movePoint(
              model.safeSelected,
              details.delta,
              rowHeight: constraints.maxHeight,
            ),
          ),
          child: CustomPaint(
            painter: _TickGridPainter(
              values: [for (final bar in bars) bar.close],
              selected: model.safeSelected,
              editable: true,
            ),
            child: const SizedBox.expand(),
          ),
        );
      },
    );
  }

  Widget _generatedPane(List<K1Bar> bars) {
    return CustomPaint(
      painter: _TickGridPainter(
        values: [for (final bar in bars) bar.close],
        selected: -1,
        editable: false,
      ),
      child: const SizedBox.expand(),
    );
  }
}

class _TickGridPainter extends CustomPainter {
  const _TickGridPainter({
    required this.values,
    required this.selected,
    required this.editable,
  });

  final List<double> values;
  final int selected;
  final bool editable;

  @override
  void paint(Canvas canvas, Size size) {
    final grid = Paint()
      ..color = const Color(0x33475569)
      ..strokeWidth = 1;
    for (var i = 1; i < 6; i++) {
      final y = size.height * i / 6;
      canvas.drawLine(Offset(0, y), Offset(size.width, y), grid);
    }
    for (var i = 1; i < values.length; i++) {
      final x = size.width * i / math.max(1, values.length);
      canvas.drawLine(Offset(x, 0), Offset(x, size.height), grid);
    }
    if (values.isEmpty) return;
    final minValue = values.reduce(math.min);
    final maxValue = values.reduce(math.max);
    final span = math.max(0.01, maxValue - minValue);
    final paint = Paint()
      ..color = editable ? Colors.white : Colors.lightBlueAccent
      ..strokeWidth = 1.5
      ..style = PaintingStyle.stroke;
    final path = Path();
    for (var i = 0; i < values.length; i++) {
      final x = values.length == 1 ? size.width / 2 : size.width * i / (values.length - 1);
      final y = size.height - ((values[i] - minValue) / span) * (size.height - 12) - 6;
      if (i == 0) {
        path.moveTo(x, y);
      } else {
        path.lineTo(x, y);
      }
      if (i == selected) {
        canvas.drawCircle(Offset(x, y), 4, Paint()..color = Colors.orangeAccent);
      }
    }
    canvas.drawPath(path, paint);
  }

  @override
  bool shouldRepaint(covariant _TickGridPainter oldDelegate) {
    return oldDelegate.values != values || oldDelegate.selected != selected;
  }
}
