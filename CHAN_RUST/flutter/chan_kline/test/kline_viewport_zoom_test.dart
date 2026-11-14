import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int i, double low, double high) => KlineBar(
      idx: i,
      timeMs: i * 60000,
      timeText: '$i',
      open: low,
      high: high,
      low: low,
      close: high,
      volume: 1,
      amount: 1,
    );

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

  group('KlineViewport.syncWindowOnStep 步进最新K居中', () {
    test('每步最新K落在视窗正中', () {
      final vp = KlineViewport()..resetForBarCount(50);
      // 用户缩放后视窗跨 20 根，最新K当前正好贴着右边界。
      vp.markUserAdjusted();
      vp.viewXMin = 30;
      vp.viewXMax = 50;

      vp.syncWindowOnStep(50);

      expect(vp.xSpan, closeTo(20, 1e-9));
      expect(50, closeTo(vp.viewXMin + vp.xSpan * 0.5, 1e-9));
      expect(50, lessThan(vp.viewXMax), reason: '最新K必须在可视区内，且不贴右边界');
    });

    test('连续步进时最新K始终停在同一相对位置', () {
      final vp = KlineViewport()..resetForBarCount(20);
      vp.markUserAdjusted();
      vp.viewXMin = 0;
      vp.viewXMax = 16;

      for (var i = 20; i <= 25; i++) {
        vp.syncWindowOnStep(i);
        expect(i, closeTo(vp.viewXMin + vp.xSpan * 0.5, 1e-9),
            reason: '第i 步最新K应固定在视窗正中');
      }
      expect(vp.xSpan, closeTo(16, 1e-9), reason: '跟随不得改用户设好的缩放');
    });

    test('单图未手动调过视图时仍展示全量，不强制居中', () {
      final vp = KlineViewport()..resetForBarCount(10);
      vp.syncWindowOnStep(12);
      expect(vp.viewXMin, 0);
      expect(vp.viewXMax, 12);
    });

    test('子窗口没手动调过也居中，数据短时左侧留白', () {
      final vp = KlineViewport()..resetForBarCount(10);

      vp.syncWindowOnStep(12, centerLatest: true);

      expect(vp.xSpan, closeTo(40, 1e-9), reason: '未缩放的子窗口默认看 40 根');
      expect(12, closeTo(vp.viewXMin + vp.xSpan * 0.5, 1e-9));
      expect(vp.viewXMin, lessThan(0), reason: '数据不够长时左侧留白，不把最新K顶到最右');
    });

    test('子窗口连续步进时最新K始终停在正中', () {
      final vp = KlineViewport()..resetForBarCount(5);

      for (var i = 5; i <= 60; i++) {
        vp.syncWindowOnStep(i, centerLatest: true);
        expect(i, closeTo(vp.viewXMin + vp.xSpan * 0.5, 1e-9),
            reason: '第i 步最新K应固定在视窗正中');
      }
    });

    test('最新K靠左时也拉到视窗正中', () {
      final vp = KlineViewport()..resetForBarCount(100);
      vp.markUserAdjusted();
      vp.viewXMin = 0;
      vp.viewXMax = 40;

      vp.syncWindowOnStep(100);

      expect(100, closeTo(vp.viewXMin + vp.xSpan * 0.5, 1e-9));
      expect(vp.viewXMin, greaterThanOrEqualTo(vp.allXMin));
    });

    test('数据刚起步时左侧留白，最新K仍在正中而不是被顶到最右', () {
      final vp = KlineViewport()..resetForBarCount(5);
      vp.markUserAdjusted();
      // 用户缩放到只看 20 根，但总共才 8 根。
      vp.viewXMin = 0;
      vp.viewXMax = 20;

      vp.syncWindowOnStep(8);

      expect(vp.xSpan, closeTo(20, 1e-9), reason: '跟随不得改用户设好的缩放');
      expect(8, closeTo(vp.viewXMin + vp.xSpan * 0.5, 1e-9));
      expect(vp.viewXMin, lessThan(0), reason: '左侧留白，视窗不被数据起点顶回去');
    });
  });

  group('KlineViewport.centerLatestVertically 步进垂直居中', () {
    test('最新K远高于可见区间时，平移把它拉回中部', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 10; i++) _bar(i, 10, 12),
        _bar(10, 30, 32),
      ];
      final vp = KlineViewport()..resetForBarCount(bars.length);
      vp.yShiftRatio = -2.0;

      vp.centerLatestVertically(bars, 10);

      final range = vp.priceRangeFor(bars);
      final mid = (bars[10].high + bars[10].low) / 2;
      expect(mid, closeTo((range.min + range.max) / 2, 1e-6),
          reason: '最新K的中间价应落在价格区间正中');
    });

    test('最新K远低于可见区间时同样拉回中部', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 10; i++) _bar(i, 30, 32),
        _bar(10, 10, 12),
      ];
      final vp = KlineViewport()..resetForBarCount(bars.length);
      vp.yShiftRatio = 2.0;

      vp.centerLatestVertically(bars, 10);

      final range = vp.priceRangeFor(bars);
      final mid = (bars[10].high + bars[10].low) / 2;
      expect(mid, closeTo((range.min + range.max) / 2, 1e-6));
    });

    test('已经在中部时不再额外平移', () {
      final bars = <KlineBar>[for (var i = 0; i < 6; i++) _bar(i, 10, 12)];
      final vp = KlineViewport()..resetForBarCount(bars.length);
      vp.yShiftRatio = 1.5;

      vp.centerLatestVertically(bars, 5);

      expect(vp.yShiftRatio, closeTo(0, 1e-9));
    });

    test('只看最新一根时，历史高低再远也不影响居中', () {
      // 子窗口按本层最新 K 居中：只把最新一根传进来，历史 K 不参与。
      // 单根 K 高低相等时平移量应为 0（价格区间会被自动各扩 0.5，
      // 这里直接断言平移量，不走被撑开后的价格区间）。
      final latestOnly = <KlineBar>[_bar(10, 30, 30)];
      final vp = KlineViewport()..resetForBarCount(11);
      vp.yShiftRatio = -2.0;

      vp.centerLatestVertically(latestOnly, 10);

      expect(vp.yShiftRatio, closeTo(0, 1e-9));
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
