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
    expect(model.modeAt(1).label, 'K2');
    expect(model.modeAt(1).displayLevel, 2);
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

  test('整根平移：四价同移，形状不变，钳制在全体可见 K 的极值并集内', () {
    // 两根 K：A（10/12/9/11）、B（20 一字）。全体并集 = [9, 20]。
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    ).addCandle(
      const KlineDrawCandle(open: 20, high: 20, low: 20, close: 20),
    );
    // 向上平移 0.5：四价同 +0.5，形状不变；最高 12.5 仍在并集 [9,20] 内。
    final up = model.moveCandleAt(0, 0.5, clampLo: 9, clampHi: 20);
    expect(up.candles[0].open, 10.5);
    expect(up.candles[0].close, 11.5);
    expect(up.candles[0].high, 12.5);
    expect(up.candles[0].low, 9.5);
    // B 不动。
    expect(up.candles[1].close, 20);

    // 向上拖过头：high 只能到并集上沿 20（B 的顶），不能越过。
    final upClamped = model.moveCandleAt(0, 100, clampLo: 9, clampHi: 20);
    expect(upClamped.candles[0].high, 20);
    expect(upClamped.candles[0].open, 18.0); // 形状仍不变（open=high-2）

    // 向下拖过头：low 只能到并集下沿 9（自己的旧低，来回可走）。
    final downClamped = model.moveCandleAt(0, -100, clampLo: 9, clampHi: 20);
    expect(downClamped.candles[0].low, 9);
    expect(downClamped.candles[0].high, 12); // 原地不动

    // 拖 B 向下：low 只能降到 A 的最高价 12（并集下沿之上无并集外空间，
    // 但 12 ≥ clampLo=9？不——B 的 low 到 12 时 high=12，仍在并集内）。
    final bDown = model.moveCandleAt(1, -100, clampLo: 9, clampHi: 20);
    expect(bDown.candles[1].low, 9); // 一字 K 一路降到并集下沿
    expect(bDown.candles[1].high, 9);

    // 平移量恰好在区间内：完整生效。
    final free = model.moveCandleAt(1, -2, clampLo: 9, clampHi: 20);
    expect(free.candles[1].close, 18);

    // 越界下标：原样返回。
    expect(
      model.moveCandleAt(9, 1, clampLo: 0, clampHi: 100).candles.length,
      2,
    );

    // 板上仅一根 K（钳制区间 null）：不钳，自由平移（没有别人可压）。
    final single = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    final moved = single.moveCandleAt(0, 50, clampLo: null, clampHi: null);
    expect(moved.candles[0].high, 62);
    expect(moved.candles[0].low, 59);
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
