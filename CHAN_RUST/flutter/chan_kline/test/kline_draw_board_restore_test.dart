import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/kline_draw_board.dart';
import 'package:flutter_test/flutter_test.dart';

/// 打开画板时从已保存数据还原（2026-11-17 用户明确：重开不许从空板开始）。
void main() {
  List<KlineBar> bars() => [
        KlineBar(
          idx: 0,
          timeMs: 0,
          timeText: '2026/07/10 09:30:00',
          open: 10.22,
          high: 10.30,
          low: 9.46,
          close: 9.50,
          volume: 7,
          amount: 0,
        ),
        KlineBar(
          idx: 1,
          timeMs: 0,
          timeText: '2026/07/10 09:31:00',
          open: 9.85,
          high: 9.90,
          low: 9.74,
          close: 9.74,
          volume: 3,
          amount: 0,
        ),
        KlineBar(
          idx: 2,
          timeMs: 0,
          timeText: '2026/07/10 09:32:00',
          open: 9.74,
          high: 9.80,
          low: 9.70,
          close: 9.78,
          volume: 5,
          amount: 0,
        ),
      ];

  test('从 K 线还原：根数、四价、量与起始时间都对得上', () {
    final model = KlineDrawBoardModel.fromBars(bars());
    expect(model.candles.length, 3);
    expect(model.start, '2026/07/10 09:30:00');
    expect(model.candles.first.open, 10.22);
    expect(model.candles.first.high, 10.30);
    expect(model.candles.first.low, 9.46);
    expect(model.candles.first.close, 9.50);
    expect(model.candles.first.volume, 7);
    expect(model.selected, -1, reason: '恢复后不应自动选中某根');
  });

  test('还原后再 toBars：时间与 OHLC 往返一致', () {
    final model = KlineDrawBoardModel.fromBars(bars());
    final out = model.toBars();
    expect(out.length, 3);
    expect(out[0].timeText, '2026/07/10 09:30:00');
    expect(out[1].timeText, '2026/07/10 09:31:00');
    expect(out[2].timeText, '2026/07/10 09:32:00');
    expect(out[1].open, 9.85);
    expect(out[1].high, 9.90);
    expect(out[1].low, 9.74);
    expect(out[1].close, 9.74);
    expect(out[1].volume, 3);
  });

  test('空数据回落到空板（不抛异常）', () {
    final model = KlineDrawBoardModel.fromBars(const []);
    expect(model.candles, isEmpty);
    expect(model.windowCount, 4);
    expect(model.windowModes.length, 4);
  });

  test('恢复后窗口布局用默认四窗，且操作窗仍是 1m-K0', () {
    final model = KlineDrawBoardModel.fromBars(bars());
    expect(model.windowCount, 4);
    expect(model.modeAt(0).period, '1m');
    expect(model.modeAt(0).level, 0);
    expect(model.modeAt(0).displayLevel, 0);
  });
}
