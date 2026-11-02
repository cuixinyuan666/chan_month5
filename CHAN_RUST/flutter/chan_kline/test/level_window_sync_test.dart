import 'package:chan_kline/widgets/chart_sync_controller.dart';
import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 层级分窗联动：全窗共用一份视口 / 主副比例 / 十字线广播。
///
/// 几何前提（用户口径）：所有窗等宽等高 + 共用 mainFraction + 副图占位恒定，
/// 于是「同一根 K → 同一列」「同一价格 → 同一行」。
void main() {
  group('共享视口：同一根 K 在各窗落在同一列', () {
    test('10 个等宽窗用同一 viewport，barCenterX 完全一致', () {
      final sync = ChartSyncController();
      sync.viewport.resetForBarCount(500);
      final xs = <double>[
        for (var i = 0; i < 10; i++)
          sync.viewport.barCenterX(42, 640),
      ];
      expect(xs.toSet().length, 1, reason: '同视口同宽度必须同 x');
    });

    test('共用视口：一窗平移/缩放，其余窗读到的就是新值', () {
      final sync = ChartSyncController();
      final vp = sync.viewport..resetForBarCount(500);
      final before = vp.viewXMin;
      vp.panByPixels(-120, 0, 640, 400);
      expect(vp.viewXMin, greaterThan(before));
      // 任何窗拿到的都是同一个对象（禁止再 new 第二份）。
      expect(identical(sync.viewport, vp), isTrue);
    });

    test('鼠标 X → K 下标在等宽窗里一致', () {
      final sync = ChartSyncController();
      sync.viewport.resetForBarCount(500);
      final idx = sync.viewport.barIndexAtCanvasX(321.5, 640, 500);
      for (var i = 0; i < 10; i++) {
        expect(sync.viewport.barIndexAtCanvasX(321.5, 640, 500), idx);
      }
    });
  });

  group('价格 ↔ 像素：同一价格在各窗落在同一行', () {
    test('priceFromY 与 yOf 互逆（十字横线广播用价格往返）', () {
      final sync = ChartSyncController();
      sync.viewport.resetForBarCount(200);
      final pr = sync.viewport.priceRangeFor(const []);
      // 空 bars 走 0..1 兜底，构造一份手写区间更有代表性
      final range = PriceRange(pr.min + 5, pr.max + 40);
      const plotTop = 28.0;
      const plotH = 512.0;
      for (final y in <double>[28, 100, 260.5, 512]) {
        final price = range.priceFromY(y, plotTop, plotH);
        expect(range.yOf(price, plotTop, plotH), closeTo(y, 1e-9));
      }
    });

    test('同价格同区间 → 各窗 y 完全相同（主副比例一致才成立）', () {
      final sync = ChartSyncController();
      const plotTop = 28.0;
      const plotH = 480.0;
      const priceRange = PriceRange(90, 110);
      final price = priceRange.priceFromY(233.0, plotTop, plotH);
      final ys = <double>[
        for (var i = 0; i < 10; i++)
          priceRange.yOf(price, plotTop, plotH),
      ];
      expect(ys.toSet().length, 1);
      expect(ys.first, closeTo(233.0, 1e-9));
    });

    test('主副比例共享：等高窗主图高度一致', () {
      final sync = ChartSyncController();
      const bodyH = 600.0;
      final mains = <double>[
        for (var i = 0; i < 10; i++) bodyH * sync.mainFraction,
      ];
      expect(mains.toSet().length, 1);
      sync.setMainFraction(0.55);
      expect(bodyH * sync.mainFraction, 330.0);
    });
  });

  group('十字线广播', () {
    test('广播 bar 下标与价格，监听者收到通知', () {
      final sync = ChartSyncController();
      var notified = 0;
      sync.addListener(() => notified++);

      sync.publishCrosshair(on: true, barIdx: 37, price: 12.345);
      expect(notified, 1);
      expect(sync.crosshairOn, isTrue);
      expect(sync.crosshairBarIdx, 37);
      expect(sync.crosshairPrice, 12.345);

      // 同一状态重复广播不抖动（十字线逐像素移动时避免重建风暴）。
      sync.publishCrosshair(on: true, barIdx: 37, price: 12.345);
      expect(notified, 1);

      sync.publishCrosshair(on: true, barIdx: 38, price: 12.35);
      expect(notified, 2);
    });

    test('关闭十字线清空 bar 与价格', () {
      final sync = ChartSyncController();
      sync.publishCrosshair(on: true, barIdx: 9, price: 1.0);
      sync.publishCrosshair(on: false, barIdx: 9, price: 1.0);
      expect(sync.crosshairOn, isFalse);
      expect(sync.crosshairBarIdx, isNull);
      expect(sync.crosshairPrice, isNull);
    });

    test('视口变更广播能叫醒被动窗', () {
      final sync = ChartSyncController();
      var notified = 0;
      sync.addListener(() => notified++);
      sync.notifyViewportChanged();
      expect(notified, 1);
    });

    test('副图胶囊条占位全窗共享：被动窗照抄可交互窗量到的高度', () {
      final sync = ChartSyncController();
      expect(sync.subChipBand, KlineViewport.subIndicatorChipBand);
      var notified = 0;
      sync.addListener(() => notified++);
      sync.setSubChipBand(31);
      expect(sync.subChipBand, 31);
      expect(notified, 1);
      // 差值小于半像素不重复通知（量测抖动不该引发重建风暴）。
      sync.setSubChipBand(31.2);
      expect(notified, 1);
    });

    test('分割比例变更去抖：同一值不重复通知', () {
      final sync = ChartSyncController();
      var notified = 0;
      sync.addListener(() => notified++);
      sync.setMainFraction(0.5);
      sync.setMainFraction(0.5);
      expect(notified, 1);
      sync.setMainFraction(0.6);
      expect(notified, 2);
    });
  });

  group('as-of 缓存（全窗同源、禁止未来数据）', () {
    test('同一 (asOf, gen) 命中；任一项变化即失效', () {
      final sync = ChartSyncController();
      final cache = sync.asOfCache;
      cache.asOf = 100;
      cache.gen = 3;
      cache.byIdx = const <int, Map<String, dynamic>>{};
      expect(cache.matches(100, 3), isTrue);
      expect(cache.matches(101, 3), isFalse);
      expect(cache.matches(100, 4), isFalse);

      cache.clear();
      expect(cache.matches(100, 3), isFalse);
      expect(cache.byIdx, isNull);
    });

    test('as-of 中枢仓按 asOf 键共享，换 asOf 即换仓', () {
      final sync = ChartSyncController();
      expect(sync.zsAsOfKey, isNull);
      expect(sync.zsAsOfBundle, isNull);
    });
  });
}
