import 'package:chan_kline/chart/tick_dot_geometry.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

/// K0（分笔）圆点渲染口径：价格区间要留出圆点半径余量，避免最上/最下圆点被裁。
void main() {
  test('分笔圆点半径与图表绘制同口径', () {
    final vp = KlineViewport();
    vp.resetForBarCount(100);
    final slotW = vp.barSlotWidth(800);
    final barW = 1.0 > slotW * 0.65 ? 1.0 : slotW * 0.65;
    final dotR = barW * 0.45 < slotW * 0.35 ? barW * 0.45 : slotW * 0.35;
    // 圆点半径必须大于 1.2 像素下限，否则点会看不见。
    expect(dotR, greaterThanOrEqualTo(1.2));
  });

  test('价格区间按可见 K 极值给出，K0 圆点需自行留余量', () {
    final bars = [
      const KlineBar(
        timeMs: 0,
        timeText: '2026/07/10 09:30:00',
        open: 10,
        high: 12,
        low: 8,
        close: 10,
        volume: 1,
        amount: 0,
      ),
    ];
    final vp = KlineViewport();
    vp.resetForBarCount(1);
    final range = vp.priceRangeFor(bars);
    // 区间等于极值：正好落在绘图区上下边界，圆点会被裁一半。
    expect(range.max, closeTo(12.0, 1e-9));
    expect(range.min, closeTo(8.0, 1e-9));
  });

  test('初始加载视窗包含全部 K（不裁掉首尾圆点）', () {
    final vp = KlineViewport();
    vp.resetForBarCount(50);
    vp.showAllBars();
    final visible = vp.visibleBars([
      for (var i = 0; i < 50; i++)
        KlineBar(
          idx: i,
          timeMs: i * 60000,
          timeText: '2026/07/10 09:30:00',
          open: 10,
          high: 11,
          low: 9,
          close: 10,
          volume: 1,
          amount: 0,
        ),
    ]);
    expect(visible.length, 50);
    expect(visible.first.idx, 0);
    expect(visible.last.idx, 49);
  });

  test('圆点余量按像素除以绘图高度换算，不能乘', () {
    // 4 元的价格跨度、400 像素高、圆点半径 4 像素：
    // 正确留量是 4 * 4 / 400 = 0.04 元；
    // 若误写成乘，留量会变成 4 * 400 / 4 = 400 元，圆点全挤在中间。
    const raw = PriceRange(8, 12);
    final padded = tickDotPaddedRange(raw: raw, dotR: 4, plotH: 400);
    expect(padded.min, closeTo(7.96, 1e-9));
    expect(padded.max, closeTo(12.04, 1e-9));
  });
}
