import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

/// K线画板视口口径：各窗独立、少根 K 不被拉散。
void main() {
  group('minViewSpan：少根 K 不让槽宽撑满画布', () {
    test('默认口径不变：10 根 K 的跨度是 9', () {
      final vp = KlineViewport()..resetForBarCount(10);
      expect(vp.xSpan, closeTo(9, 1e-9));
    });

    test('画板设 24 后，10 根 K 仍至少留 24 个槽位', () {
      final vp = KlineViewport()
        ..minViewSpan = 24
        ..resetForBarCount(10);
      expect(vp.xSpan, closeTo(24, 1e-9));
      expect(vp.allXMax, 9, reason: '数据边界仍按真实根数');
    });

    test('画板只有 1 根 K 时也不把单个槽撑满画布', () {
      final vp = KlineViewport()
        ..minViewSpan = 24
        ..resetForBarCount(1);
      expect(vp.xSpan, closeTo(24, 1e-9));
    });

    test('showAllBars 也守住最小跨度', () {
      final vp = KlineViewport()
        ..minViewSpan = 24
        ..resetForBarCount(2);
      vp.showAllBars();
      expect(vp.xSpan, greaterThanOrEqualTo(24));
    });
  });
}
