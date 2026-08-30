import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/fx_extend_line_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';

KlineBar _bar(int idx, {required double high, required double low}) {
  final mid = (high + low) / 2;
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: mid,
    high: high,
    low: low,
    close: mid,
    volume: 1,
    amount: 1,
  );
}

/// 极点落在单根：fractalX1=fractalX2=pole
K0ConfirmSignal _conf({
  required int confirmX,
  required String fx,
  required int pole,
}) {
  return K0ConfirmSignal(
    x: confirmX,
    fx: fx,
    value: fx == 'TOP' ? -1 : 1,
    fractalX1: pole,
    fractalX2: pole,
  );
}

void main() {
  group('calcTripleParallelRay', () {
    test('TBT：两顶斜率过底', () {
      // 顶@0 p=12, 底@2 p=8, 顶@4 p=14 → slope=(14-12)/4=0.5；过底 y=8+0.5*(x-2)
      final poles = [
        const FxPole(x: 0, price: 12, fx: 'TOP', confirmX: 1),
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 4, price: 14, fx: 'TOP', confirmX: 5),
      ];
      final r = calcTripleParallelRay(poles);
      expect(r, isNotNull);
      expect(r!.kind, 'triple');
      expect(r.x0, 2);
      expect(r.y0, 8);
      expect(r.slope, closeTo(0.5, 1e-12));
    });

    test('BTB 镜像：两底斜率过顶', () {
      final poles = [
        const FxPole(x: 0, price: 10, fx: 'BOTTOM', confirmX: 1),
        const FxPole(x: 2, price: 16, fx: 'TOP', confirmX: 3),
        const FxPole(x: 4, price: 8, fx: 'BOTTOM', confirmX: 5),
      ];
      final r = calcTripleParallelRay(poles);
      expect(r, isNotNull);
      expect(r!.x0, 2);
      expect(r.y0, 16);
      // slope=(8-10)/4=-0.5
      expect(r.slope, closeTo(-0.5, 1e-12));
    });

    test('不足 3 → null；非两同+一异 → null', () {
      expect(calcTripleParallelRay(const []), isNull);
      expect(
        calcTripleParallelRay([
          const FxPole(x: 0, price: 1, fx: 'TOP', confirmX: 1),
          const FxPole(x: 1, price: 2, fx: 'TOP', confirmX: 2),
          const FxPole(x: 2, price: 3, fx: 'TOP', confirmX: 3),
        ]),
        isNull,
      );
    });
  });

  group('calcQuadPairRays', () {
    test('两顶+两底各一条', () {
      final poles = [
        const FxPole(x: 0, price: 12, fx: 'TOP', confirmX: 1),
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 4, price: 14, fx: 'TOP', confirmX: 5),
        const FxPole(x: 6, price: 7, fx: 'BOTTOM', confirmX: 7),
      ];
      final rays = calcQuadPairRays(poles);
      expect(rays.length, 2);
      final top = rays.firstWhere((e) => e.kind == 'topPair');
      final bot = rays.firstWhere((e) => e.kind == 'bottomPair');
      expect(top.slope, closeTo((14 - 12) / 4, 1e-12));
      expect(top.x0, 4); // 较右顶
      expect(top.x1, 0);
      expect(bot.slope, closeTo((7 - 8) / 4, 1e-12));
      expect(bot.x0, 6);
    });

    test('不足 4 → 空', () {
      expect(
        calcQuadPairRays([
          const FxPole(x: 0, price: 1, fx: 'TOP', confirmX: 1),
          const FxPole(x: 1, price: 0, fx: 'BOTTOM', confirmX: 2),
          const FxPole(x: 2, price: 2, fx: 'TOP', confirmX: 3),
        ]),
        isEmpty,
      );
    });
  });

  group('滑动窗累积', () {
    test('三型：5 极点 → 多组窗（步进增多）', () {
      // T B T B T → 窗0 TBT、窗1 BTB、窗2 TBT 均合格
      final poles = [
        const FxPole(x: 0, price: 12, fx: 'TOP', confirmX: 1),
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 4, price: 14, fx: 'TOP', confirmX: 5),
        const FxPole(x: 6, price: 7, fx: 'BOTTOM', confirmX: 7),
        const FxPole(x: 8, price: 15, fx: 'TOP', confirmX: 9),
      ];
      final all = calcAllTripleParallelRays(poles);
      expect(all.length, 3);
      expect(all.map((e) => e.x0).toList(), [2, 4, 6]);
    });

    test('四型：5 极点 → 两窗对线', () {
      final poles = [
        const FxPole(x: 0, price: 12, fx: 'TOP', confirmX: 1),
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 4, price: 14, fx: 'TOP', confirmX: 5),
        const FxPole(x: 6, price: 7, fx: 'BOTTOM', confirmX: 7),
        const FxPole(x: 8, price: 15, fx: 'TOP', confirmX: 9),
      ];
      // 窗0: TBTB → 2 线；窗1: BTBT → 2 线
      final all = calcAllQuadPairRays(poles);
      expect(all.length, 4);
    });

    test('asOf 截断：窗数随前缀增长', () {
      final bars = [
        for (var i = 0; i <= 10; i++)
          _bar(i, high: 10.0 + i, low: 5.0 + i * 0.1),
      ];
      final confirms = [
        _conf(confirmX: 2, fx: 'TOP', pole: 0),
        _conf(confirmX: 4, fx: 'BOTTOM', pole: 2),
        _conf(confirmX: 6, fx: 'TOP', pole: 4),
        _conf(confirmX: 8, fx: 'BOTTOM', pole: 6),
      ];
      final at6 = collectLevelFxPoles(
        displayKn: 0,
        bars: bars,
        k0Confirms: confirms,
        asOf: 6,
      );
      expect(calcAllTripleParallelRays(at6).length, 1);
      final at8 = collectLevelFxPoles(
        displayKn: 0,
        bars: bars,
        k0Confirms: confirms,
        asOf: 8,
      );
      expect(calcAllTripleParallelRays(at8).length, 2);
    });

    test('select：无焦点=最新；焦点=近邻窗', () {
      final poles = [
        const FxPole(x: 0, price: 12, fx: 'TOP', confirmX: 1),
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 4, price: 14, fx: 'TOP', confirmX: 5),
        const FxPole(x: 6, price: 7, fx: 'BOTTOM', confirmX: 7),
        const FxPole(x: 8, price: 15, fx: 'TOP', confirmX: 9),
      ];
      final groups = calcAllTripleGroups(poles);
      expect(groups.length, 3);
      final latest = selectFxExtendGroups(groups, focusX: null);
      expect(latest.length, 1);
      expect(latest.first.rays.first.x0, 6); // 末窗异型底
      final near = selectFxExtendGroups(groups, focusX: 1);
      expect(near.length, 1);
      expect(near.first.poleMinX, 0); // 含 x=0..4 的首窗最近
    });

    test('tip 读数=延长线落到 atX 的价格', () {
      // TBT：两顶 slope=0.5，过底(2,8) → 在 x=6 价=8+0.5*4=10
      final poles = [
        const FxPole(x: 0, price: 12, fx: 'TOP', confirmX: 1),
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 4, price: 14, fx: 'TOP', confirmX: 5),
      ];
      final g = calcAllTripleGroups(poles);
      expect(triplePriceReadout(g, atX: 6, focusX: 2), closeTo(10, 1e-9));
      final ray = const FxExtendRay(
        x0: 4,
        y0: 14,
        slope: 0.5,
        kind: 'topPair',
        x1: 0,
        y1: 12,
      );
      expect(rayPriceAt(ray, 8), closeTo(16, 1e-9));
    });
  });

  group('catalog', () {
    test('主图含三型/四型且默认 K0 纳入', () {
      final cat = buildMainIndicatorCatalog(2);
      final t = cat.where((e) => e.kind == MainIndicatorKind.fxTripleParallel);
      final q = cat.where((e) => e.kind == MainIndicatorKind.fxQuadPair);
      // 方案B：连线族 kn==displayKn
      expect(t.map((e) => e.kn), [0, 1]);
      expect(q.map((e) => e.kn), [0, 1]);
      expect(t.every((e) => e.label.contains('三型平移线')), isTrue);
      expect(q.every((e) => e.label.contains('四型对线')), isTrue);

      final d = defaultMainIndicatorsK0();
      expect(
        d.any((e) => e.kind == MainIndicatorKind.fxTripleParallel),
        isFalse,
      );
      expect(d.any((e) => e.kind == MainIndicatorKind.fxQuadPair), isFalse);
      final lv0 = mainIndicatorsForLevel(0, buildMainIndicatorCatalog(1));
      expect(
        lv0.any((e) => e.kind == MainIndicatorKind.fxTripleParallel),
        isTrue,
      );
    });
  });
}
