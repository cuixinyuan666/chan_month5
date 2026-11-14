import 'package:chan_kline/chart/kline_candle_geometry.dart';
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

  test('增加复制同价，减少删除', () {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 11, low: 10, close: 11),
    );
    final added = model.addSameAfterSelected();
    expect(added.candles, hasLength(2));
    expect(added.selected, 1);
    expect(added.candles[1].close, 11);

    final removed = added.removeSelected();
    expect(removed.candles, hasLength(1));
  });

  test('部位拖动：实体改开/收盘，影线改高/低，四价互不干扰', () {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    // 拖上影线端点 → 只改最高价
    final hi = model.moveSelectedPart(CandlePart.high, 13);
    expect(hi.candles[0].high, 13);
    expect(hi.candles[0].open, 10);
    expect(hi.candles[0].close, 11);
    expect(hi.candles[0].low, 9);

    // 拖下影线端点 → 只改最低价
    final lo = model.moveSelectedPart(CandlePart.low, 8);
    expect(lo.candles[0].low, 8);
    expect(lo.candles[0].high, 12);

    // 拖实体 → 改收盘价（阳线上半是收盘）
    final body = model.moveSelectedPart(CandlePart.bodyClose, 11.5);
    expect(body.candles[0].close, 11.5);
    expect(body.candles[0].open, 10);

    // 拖实体 → 改开盘价
    final open = model.moveSelectedPart(CandlePart.bodyOpen, 9.5);
    expect(open.candles[0].open, 9.5);
    expect(open.candles[0].close, 11);

    // 不变量：影线不得落进实体
    final bad = model.moveSelectedPart(CandlePart.high, 10.5);
    expect(bad.candles[0].high, greaterThanOrEqualTo(11)); // max(open,close)=11
    final badLow = model.moveSelectedPart(CandlePart.low, 10.5);
    expect(badLow.candles[0].low, lessThanOrEqualTo(10)); // min(open,close)=10
  });

  test('新 K 落在光标位置而不是末尾', () {
    final m0 = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 10, low: 10, close: 10),
    );
    final m1 = m0.addCandle(
      const KlineDrawCandle(open: 20, high: 20, low: 20, close: 20),
    );
    final m2 = m1.insertCandleAt(
      const KlineDrawCandle(open: 15, high: 15, low: 15, close: 15),
      1,
    );
    expect(m2.candles.map((c) => c.open).toList(), [10, 15, 20]);
    expect(m2.selected, 1);

    // 下标越界/null → 追加到末尾
    final tail = m1.insertCandleAt(
      const KlineDrawCandle(open: 15, high: 15, low: 15, close: 15),
      null,
    );
    expect(tail.candles.map((c) => c.open).toList(), [10, 20, 15]);
    expect(tail.selected, 2);
  });

  test('草稿带路径极值：路径最高=最高价，路径最低=最低价', () {
    final bare = buildKlineDrawDraft(10, 11);
    expect(bare.high, 11);
    expect(bare.low, 10);

    final withPath = bare.withExtremes(12.5, 9.5);
    expect(withPath.high, 12.5);
    expect(withPath.low, 9.5);
    expect(withPath.open, 10);
    expect(withPath.close, 11);

    // 极值不得破坏 K 线不变量
    final clamped = bare.withExtremes(9, 12);
    expect(clamped.high, 11);
    expect(clamped.low, 10);
  });
}
