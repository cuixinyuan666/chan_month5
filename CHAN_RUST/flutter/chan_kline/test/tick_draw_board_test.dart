import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/tick_draw_board.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('窗口数量、增删复制和网格吸附', () {
    final model = TickDrawBoardModel.fromBars(const [
      KlineBar(
        timeMs: 0,
        timeText: '2026/07/10 09:30:00',
        open: 10,
        high: 10,
        low: 10,
        close: 10,
        volume: 1,
        amount: 0,
      ),
    ]).copyWith(windowCount: 4);

    expect(model.windowCount, 4);
    final added = model.addPoint().duplicatePoint();
    expect(added.points.length, 3);

    final moved = added.movePoint(1, const Offset(30, -20), rowHeight: 200);
    expect(moved.points[2].price, closeTo(10.02, 1e-9));

    final removed = moved.removePoint();
    expect(removed.points.length, 2);
  });

  test('保存数据沿用自定义 OHLC 分笔口径', () {
    final model = const TickDrawBoardModel(
      points: [
        TickDrawPoint(price: 10, volume: 2),
        TickDrawPoint(price: 10.25, volume: 3),
      ],
      windowCount: 2,
      start: '2026/07/10 09:30:00',
    );

    final bars = model.toTickBars();
    expect(bars.map((bar) => bar.timeText).toList(), [
      '2026/07/10 09:30:00',
      '2026/07/10 09:30:03',
    ]);
    expect(bars[1].open, bars[1].high);
    expect(bars[1].low, bars[1].close);
    expect(bars[1].volume, 3);
  });
}
