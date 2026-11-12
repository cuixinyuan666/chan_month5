import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/tick_draw_board.dart';
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
    expect(model.hasSelection, isFalse, reason: '初始不选中，拖拽只走十字线');
    expect(model.selectPoint(0).hasSelection, isTrue);
    expect(model.selectPoint(0).clearSelection().hasSelection, isFalse);

    final added = model.addPoint();
    expect(added.points.length, 2);
    expect(added.hasSelection, isTrue);

    final duplicated = added.duplicatePoint();
    expect(duplicated.points.length, 3);

    final priced = duplicated.setSelectedPrice(10.017);
    expect(priced.points[priced.safeSelected].price, closeTo(10.02, 1e-9));

    final removed = priced.removePoint();
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
