import 'package:chan_kline/widgets/chart_sync_controller.dart';
import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 层级分窗联动（第二版口径）：
/// - 每窗一份独立视口，缩放/平移互不牵连；
/// - 十字线任一窗可开，开启时全窗切到主窗视口，关闭时各自还原；
/// - 主副比例、副图胶囊条、as-of 缓存仍全窗共享。
void main() {
  /// 造一份「各窗视口明显不同」的状态，便于验证接管与还原。
  void seedDistinctViewports(ChartSyncController sync) {
    for (var lv = 0; lv < 4; lv++) {
      final vp = sync.viewportFor(lv)..resetForBarCount(500);
      // 每层错开：层号越大，看到的历史越早、纵向缩放越不同。
      vp.viewXMin = 100.0 * lv;
      vp.viewXMax = 100.0 * lv + 60;
      vp.yZoomRatio = 1.0 + lv * 0.25;
      vp.yShiftRatio = lv * 0.1;
      vp.ready = true;
    }
  }

  group('每窗独立视口', () {
    test('不同层拿到不同对象，互不影响', () {
      final sync = ChartSyncController();
      final k0 = sync.viewportFor(0)..resetForBarCount(500);
      final k1 = sync.viewportFor(1)..resetForBarCount(500);
      expect(identical(k0, k1), isFalse);

      final k1Before = k1.viewXMin;
      k0.panByPixels(-120, 0, 640, 400);
      expect(k1.viewXMin, closeTo(k1Before, 1e-9), reason: 'K0 平移不得带动 K1');

      k0.zoomXAt(1.3, 0, 640);
      expect(k1.xSpan, closeTo(499, 1e-9), reason: 'K0 缩放不得带动 K1');
    });

    test('同一层重复取仍是同一份（重建窗沿用原缩放）', () {
      final sync = ChartSyncController();
      final first = sync.viewportFor(3)..resetForBarCount(300);
      first.viewXMin = 42;
      expect(identical(sync.viewportFor(3), first), isTrue);
      expect(sync.viewportFor(3).viewXMin, 42);
    });

    test('各窗视口不同 → 同一根 K 落点不同（确实不再全窗跟随）', () {
      final sync = ChartSyncController();
      seedDistinctViewports(sync);
      final x0 = sync.viewportFor(0).barCenterX(300, 640);
      final x1 = sync.viewportFor(1).barCenterX(300, 640);
      expect(x0, isNot(closeTo(x1, 1e-6)));
    });
  });

  group('十字线接管与还原', () {
    test('开启时其余窗切到主窗同一视口；关闭后各自还原', () {
      final sync = ChartSyncController();
      seedDistinctViewports(sync);
      final k0Before = _snap(sync.viewportFor(0));
      final k1Before = _snap(sync.viewportFor(1));
      final k2Before = _snap(sync.viewportFor(2));

      sync.publishCrosshair(on: true, barIdx: 250, price: 12.3, ownerLevel: 0);
      expect(sync.crosshairOn, isTrue);
      expect(sync.crosshairOwnerLevel, 0);
      expect(sync.crosshairBarIdx, 250);
      expect(sync.crosshairPrice, 12.3);
      for (final lv in <int>[1, 2, 3]) {
        expect(sync.viewportFor(lv).viewXMin, closeTo(k0Before['xMin']!, 1e-9));
        expect(sync.viewportFor(lv).viewXMax, closeTo(k0Before['xMax']!, 1e-9));
        expect(sync.viewportFor(lv).yZoomRatio,
            closeTo(k0Before['yZoom']!, 1e-9));
        expect(
            sync.viewportFor(lv).yShiftRatio, closeTo(k0Before['yShift']!, 1e-9));
      }
      // 主窗自己不动。
      expect(sync.viewportFor(0).viewXMin, closeTo(k0Before['xMin']!, 1e-9));

      sync.publishCrosshair(on: false);
      expect(sync.crosshairOn, isFalse);
      for (final lv in <int>[1, 2]) {
        final before = lv == 1 ? k1Before : k2Before;
        expect(sync.viewportFor(lv).viewXMin, closeTo(before['xMin']!, 1e-9));
        expect(sync.viewportFor(lv).viewXMax, closeTo(before['xMax']!, 1e-9));
        expect(sync.viewportFor(lv).yZoomRatio, closeTo(before['yZoom']!, 1e-9));
        expect(
            sync.viewportFor(lv).yShiftRatio, closeTo(before['yShift']!, 1e-9));
      }
    });

    test('换主窗：新主窗视口接管，关闭后所有窗（含原主窗）还原', () {
      final sync = ChartSyncController();
      seedDistinctViewports(sync);
      final before = <int, Map<String, double>>{
        for (var lv = 0; lv < 4; lv++) lv: _snap(sync.viewportFor(lv)),
      };

      sync.publishCrosshair(on: true, barIdx: 100, price: 5, ownerLevel: 0);
      // 用户在 K1 窗点线 → K1 成为主窗。
      sync.publishCrosshair(on: true, barIdx: 101, price: 5.1, ownerLevel: 1);
      expect(sync.crosshairOwnerLevel, 1);
      expect(sync.crosshairBarIdx, 101);
      final k1 = _snap(sync.viewportFor(1));
      for (final lv in <int>[0, 2, 3]) {
        expect(sync.viewportFor(lv).viewXMin, closeTo(k1['xMin']!, 1e-9));
        expect(sync.viewportFor(lv).yZoomRatio, closeTo(k1['yZoom']!, 1e-9));
      }

      sync.publishCrosshair(on: false);
      for (var lv = 0; lv < 4; lv++) {
        expect(sync.viewportFor(lv).viewXMin,
            closeTo(before[lv]!['xMin']!, 1e-9),
            reason: 'K$lv 关闭后必须回到开十字线前的位置');
        expect(sync.viewportFor(lv).viewXMax,
            closeTo(before[lv]!['xMax']!, 1e-9));
      }
    });

    test('十字线开着时主窗缩放/平移，其余窗继续跟随', () {
      final sync = ChartSyncController();
      seedDistinctViewports(sync);
      sync.publishCrosshair(on: true, barIdx: 50, price: 9, ownerLevel: 0);

      final vp0 = sync.viewportFor(0);
      vp0.viewXMin = 10;
      vp0.viewXMax = 20;
      vp0.yZoomRatio = 2.0;
      // 主窗改完后再次广播（bar/价格不变）也要把新视口抄出去。
      sync.publishCrosshair(on: true, barIdx: 50, price: 9, ownerLevel: 0);
      for (final lv in <int>[1, 2, 3]) {
        expect(sync.viewportFor(lv).viewXMin, 10);
        expect(sync.viewportFor(lv).viewXMax, 20);
        expect(sync.viewportFor(lv).yZoomRatio, 2.0);
      }
    });

    test('同一状态重复广播不抖动', () {
      final sync = ChartSyncController();
      seedDistinctViewports(sync);
      var notified = 0;
      sync.addListener(() => notified++);

      sync.publishCrosshair(on: true, barIdx: 37, price: 12.345, ownerLevel: 0);
      expect(notified, 1);
      sync.publishCrosshair(on: true, barIdx: 37, price: 12.345, ownerLevel: 0);
      expect(notified, 1, reason: '位置没变不应触发重建风暴');
      sync.publishCrosshair(on: true, barIdx: 38, price: 12.35, ownerLevel: 0);
      expect(notified, 2);
    });

    test('关闭后再次开启：重新记录当时的视口（不沿用上一次快照）', () {
      final sync = ChartSyncController();
      seedDistinctViewports(sync);
      sync.publishCrosshair(on: true, barIdx: 10, price: 1, ownerLevel: 0);
      sync.publishCrosshair(on: false);

      // 用户把 K1 挪到别处，再开一次十字线。
      final k1 = sync.viewportFor(1)..viewXMin = 777;
      sync.publishCrosshair(on: true, barIdx: 20, price: 2, ownerLevel: 0);
      expect(k1.viewXMin, isNot(777), reason: '开启时被主窗接管');
      sync.publishCrosshair(on: false);
      expect(sync.viewportFor(1).viewXMin, 777, reason: '还原到第二次开启前');
    });
  });

  group('全窗共享项', () {
    test('主副比例：一个值全窗照用，同一值不重复通知', () {
      final sync = ChartSyncController();
      var notified = 0;
      sync.addListener(() => notified++);
      sync.setMainFraction(0.5);
      sync.setMainFraction(0.5);
      expect(notified, 1);
      sync.setMainFraction(0.6);
      expect(notified, 2);
      expect(sync.mainFraction, 0.6);
    });

    test('副图胶囊条只增不减，重置回默认', () {
      final sync = ChartSyncController();
      expect(sync.subChipBand, KlineViewport.subIndicatorChipBand);

      sync.setSubChipBand(31);
      expect(sync.subChipBand, 31);
      // 不同层胶囊条换行数不同：小的高度不能把已量到的大高度压回去。
      sync.setSubChipBand(27);
      expect(sync.subChipBand, 31);
      // 超过上限按上限算。
      sync.setSubChipBand(999);
      expect(sync.subChipBand, KlineViewport.subIndicatorChipMaxBand);

      sync.resetSubChipBand();
      expect(sync.subChipBand, KlineViewport.subIndicatorChipBand);
    });

    test('as-of 缓存全窗共享：同 (asOf, gen) 命中，任一项变化即失效', () {
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

  group('价格 ↔ 像素（十字横线按价格广播）', () {
    test('priceFromY 与 yOf 互逆', () {
      const range = PriceRange(95, 140);
      const plotTop = 28.0;
      const plotH = 512.0;
      for (final y in <double>[28, 100, 260.5, 512]) {
        final price = range.priceFromY(y, plotTop, plotH);
        expect(range.yOf(price, plotTop, plotH), closeTo(y, 1e-9));
      }
    });

    test('同视口同区间 → 同一价格落在同一行', () {
      const plotTop = 28.0;
      const plotH = 480.0;
      const priceRange = PriceRange(90, 110);
      final price = priceRange.priceFromY(233.0, plotTop, plotH);
      final ys = <double>[
        for (var i = 0; i < 10; i++) priceRange.yOf(price, plotTop, plotH),
      ];
      expect(ys.toSet().length, 1);
      expect(ys.first, closeTo(233.0, 1e-9));
    });
  });
}

Map<String, double> _snap(KlineViewport v) => <String, double>{
      'xMin': v.viewXMin,
      'xMax': v.viewXMax,
      'yZoom': v.yZoomRatio,
      'yShift': v.yShiftRatio,
    };
