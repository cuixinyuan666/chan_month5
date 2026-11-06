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

  group('KlineViewport.syncWindowOnStep 最新K靠右固定', () {
    test('每步最新K落在距右边界约1/4，不等滑出右边界才拽', () {
      final vp = KlineViewport()..resetForBarCount(50);
      // 用户缩放后视窗跨 20 根，最新K当前正好贴着右边界。
      vp.markUserAdjusted();
      vp.viewXMin = 30;
      vp.viewXMax = 50;

      vp.syncWindowOnStep(50);

      // 最新K位置 = viewXMin + span * 0.75，即距右边界 span * 0.25。
      expect(vp.xSpan, closeTo(20, 1e-9));
      expect(50, closeTo(vp.viewXMin + vp.xSpan * 0.75, 1e-9));
      expect(50, lessThan(vp.viewXMax),
          reason: '最新K必须在可视区内，且不贴着右边界');
    });

    test('连续步进时最新K始终停在同一相对位置', () {
      final vp = KlineViewport()..resetForBarCount(20);
      vp.markUserAdjusted();
      vp.viewXMin = 0;
      vp.viewXMax = 16;

      for (var i = 20; i <= 25; i++) {
        vp.syncWindowOnStep(i);
        expect(i, closeTo(vp.viewXMin + vp.xSpan * 0.75, 1e-9),
            reason: '第i 步最新K应固定在距右边界 1/4');
      }
      expect(vp.xSpan, closeTo(16, 1e-9), reason: '跟随不得改用户设好的缩放');
    });

    test('未手动调过视图时仍展示全量，不强制靠右', () {
      final vp = KlineViewport()..resetForBarCount(10);
      vp.syncWindowOnStep(12);
      expect(vp.viewXMin, 0);
      expect(vp.viewXMax, 12);
    });

    test('最新K靠左时也拉到距右边界1/4', () {
      final vp = KlineViewport()..resetForBarCount(100);
      vp.markUserAdjusted();
      vp.viewXMin = 0;
      vp.viewXMax = 40;

      vp.syncWindowOnStep(100);

      expect(100, closeTo(vp.viewXMin + vp.xSpan * 0.75, 1e-9));
      expect(vp.viewXMin, greaterThanOrEqualTo(vp.allXMin));
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
