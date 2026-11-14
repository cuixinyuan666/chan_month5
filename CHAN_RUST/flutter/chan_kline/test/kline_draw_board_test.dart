import 'package:chan_kline/widgets/kline_draw_board.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('一次拖动生成一根，并按交易分钟推进', () {
    final draft = buildKlineDrawDraft(10.2, 10.8);
    expect(draft.open, 10.2);
    expect(draft.close, 10.8);
    expect(draft.high, 10.8);
    expect(draft.low, 10.2);

    final down = buildKlineDrawDraft(11, 10.4);
    expect(down.high, 11);
    expect(down.low, 10.4);

    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10.2, high: 10.8, low: 10.2, close: 10.8),
    );
    final bars = model.toBars();
    expect(bars, hasLength(1));
    expect(bars.single.timeText, '2026/07/10 09:30:00');
    expect(bars.single.open, 10.2);
    expect(bars.single.close, 10.8);
  });

  test('默认四窗，层级与周期分开选择', () {
    final model = KlineDrawBoardModel.initial()
        .withWindowMode(2, const KlineDrawWindowMode.period('30m'))
        .withWindowCount(6);
    expect(model.windowCount, 6);
    expect(model.modeAt(0).label, 'K0');
    expect(model.modeAt(1).label, 'K1');
    expect(model.modeAt(1).displayLevel, 1);
    expect(model.modeAt(2).label, '30\u5206\u949f');
    expect(model.modeAt(2).displayLevel, 0);
    expect(model.modeAt(2).chartPeriod, '30m');
    expect(
      model.withWindowMode(0, const KlineDrawWindowMode.period('5m')).modeAt(0).label,
      'K0',
    );
  });

  test('增加复制同价，减少删除，上下拖动只改影线', () {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 11, low: 10, close: 11),
    );
    final added = model.addSameAfterSelected();
    expect(added.candles, hasLength(2));
    expect(added.selected, 1);
    expect(added.candles[1].close, 11);

    final raised = added.moveSelectedExtreme(12);
    expect(raised.candles[1].high, 12);
    expect(raised.candles[1].open, 10);
    expect(raised.candles[1].close, 11);

    final removed = raised.removeSelected();
    expect(removed.candles, hasLength(1));
  });
}
