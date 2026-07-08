import 'package:chan_kline/compute/bi_virtual_bar_view_compute.dart';
import 'package:chan_kline/models/bi_virtual_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  BiVirtualBar bi(int idx, int x1, int x2) => BiVirtualBar(
        idx: idx,
        dir: 1,
        x1: x1,
        x2: x2,
        open: 1,
        high: 2,
        low: 0.5,
        close: 1.5,
        confirmX: x2,
      );

  test('相邻笔共享分型时于衔接 K 左/右半侧无缝衔接', () {
    final views = buildBiVirtualBarViews([
      bi(0, 1, 8),
      bi(1, 6, 12),
    ]);
    expect(views[0].viewX1, 1);
    expect(views[0].viewX2, 8);
    expect(views[0].endAtLeftHalf, isTrue);
    expect(views[1].viewX1, 8);
    expect(views[1].viewX2, 12);
    expect(views[1].startAtRightHalf, isTrue);
    expect(views[0].viewX2, views[1].viewX1);
  });

  test('相邻笔恰共端点时衔接 K 半侧锚定', () {
    final views = buildBiVirtualBarViews([
      bi(0, 1, 8),
      bi(1, 8, 12),
    ]);
    expect(views[0].viewX2, 8);
    expect(views[1].viewX1, 8);
    expect(views[0].endAtLeftHalf, isTrue);
    expect(views[1].startAtRightHalf, isTrue);
  });

  test('无交叠时 view 与 raw 一致', () {
    final views = buildBiVirtualBarViews([
      bi(0, 0, 2),
      bi(1, 5, 7),
    ]);
    expect(views[0].viewX1, 0);
    expect(views[0].viewX2, 2);
    expect(views[1].viewX1, 5);
    expect(views[1].viewX2, 7);
  });

  test('OHLC 仍取自完整 BiVirtualBar', () {
    final raw = bi(0, 1, 4);
    final views = buildBiVirtualBarViews([raw]);
    expect(views.single.high, raw.high);
    expect(views.single.rawX2, 4);
  });
}
