import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('KlineViewport.zoomXAt', () {
    test('放大后贴近右缘仍可继续横向缩放', () {
      final vp = KlineViewport()..resetForBarCount(101);
      vp.viewXMin = 88;
      vp.viewXMax = 108;
      final spanBefore = vp.xSpan;

      vp.zoomXAt(1.5, 400, 800);

      expect(vp.xSpan, lessThan(spanBefore));
      expect(vp.xSpan, greaterThan(vp.minSpanFor(101)));
    });

    test('右缘超出时左移视窗而非硬拽回导致 span 卡死', () {
      final vp = KlineViewport()..resetForBarCount(101);
      vp.viewXMin = 95;
      vp.viewXMax = 115;
      final spanBefore = vp.xSpan;

      vp.zoomXAt(2.0, 400, 800);

      expect(vp.xSpan, lessThan(spanBefore));
      expect(vp.viewXMax, lessThanOrEqualTo(vp.allXMax + vp.xSpan * 2 + 0.01));
    });
  });

  group('KlineViewport.zoomYBy', () {
    test('纵向缩放可连续应用', () {
      final vp = KlineViewport()..resetForBarCount(10);
      vp.yZoomRatio = 10.0;
      vp.zoomYBy(1.2);
      expect(vp.yZoomRatio, greaterThan(10.0));
      vp.zoomYBy(0.5);
      expect(vp.yZoomRatio, lessThan(12.0));
    });
  });
}
