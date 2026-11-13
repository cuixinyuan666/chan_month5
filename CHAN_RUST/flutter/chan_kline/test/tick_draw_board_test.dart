import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/tick_draw_board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 画板口径：选中语义、增删复制、同价框、窗口数量、画布数据。
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

  test('未选中时增加按钮追加到末尾并选中新点', () {
    final model = const TickDrawBoardModel(
      points: [
        TickDrawPoint(price: 10),
        TickDrawPoint(price: 11),
      ],
      windowCount: 2,
    );
    expect(model.hasSelection, isFalse);
    final added = model.addPoint();
    expect(added.points.length, 3);
    expect(added.points.last.price, 11);
    expect(added.safeSelected, 2);
  });

  test('\u4efb\u610f\u4e00\u6839\u5206\u7b14\u90fd\u80fd\u5355\u72ec\u6539\u4ef7\uff0c\u5176\u4f59\u4e0d\u52a8', () {
    // \u6bcf\u6839 K0 \u90fd\u5e94\u8be5\u80fd\u76f4\u63a5\u4e0a\u4e0b\u62d6\uff1a\u6539\u7684\u53ea\u662f\u88ab\u6309\u4f4f\u7684\u90a3\u4e00\u6839\uff0c
    // \u4e0d\u80fd\u53ea\u80fd\u9760\u62d6\u522b\u7684\u6839\u6765\u95f4\u63a5\u6539\u5b83\u7684\u76f8\u5bf9\u4f4d\u7f6e\u3002
    final model = const TickDrawBoardModel(
      points: [
        TickDrawPoint(price: 10),
        TickDrawPoint(price: 12),
        TickDrawPoint(price: 11),
      ],
      windowCount: 2,
    );
    final moved = model.selectPoint(1).setSelectedPrice(12.4);
    expect(moved.points.map((p) => p.price).toList(), [10, 12.4, 11]);
    // \u5e8f\u53f7\u4e0e\u5217\u8868\u4f4d\u7f6e\u4e00\u4e00\u5bf9\u5e94\uff0c\u547d\u4e2d\u5224\u5b9a\u624d\u80fd\u6309\u5230\u753b\u51fa\u6765\u7684\u90a3\u6839\u3002
    expect(moved.toTickBars().map((b) => b.idx).toList(), [0, 1, 2]);
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
