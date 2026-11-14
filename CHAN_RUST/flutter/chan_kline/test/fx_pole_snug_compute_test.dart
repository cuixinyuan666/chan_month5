import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/fx_extend_line_compute.dart';
import 'package:chan_kline/compute/fx_pole_snug_compute.dart';
import 'package:chan_kline/compute/parent_span_collect.dart';
import 'package:chan_kline/compute/trend_line_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';

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

K0ConfirmSignal _k0Conf({
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

LevelConfirm _lvConf({
  required int confirmX,
  required String fx,
  required int pole,
  required double price,
}) {
  return LevelConfirm(
    x: confirmX,
    fx: fx,
    value: fx == 'TOP' ? -1 : 1,
    fractalX1: pole,
    fractalX2: pole,
    fractalHigh: price,
    fractalLow: price,
    poleX: pole,
  );
}

LevelSegmentN _seg({
  required int idx,
  required int dir,
  required int beginPoleX,
  required int endPoleX,
  required double beginVal,
  required double endVal,
  int? endConfirmX,
}) {
  final beginLow = dir > 0 ? beginVal : 0.0;
  final beginHigh = dir < 0 ? beginVal : 0.0;
  final endHigh = dir > 0 ? endVal : 0.0;
  final endLow = dir < 0 ? endVal : 0.0;
  return LevelSegmentN(
    idx: idx,
    dir: dir,
    beginConfirmX: beginPoleX,
    endConfirmX: endConfirmX ?? endPoleX,
    beginPoleX: beginPoleX,
    endPoleX: endPoleX,
    high: dir > 0 ? endVal : beginVal,
    low: dir > 0 ? beginVal : endVal,
    beginFractalHigh: beginHigh,
    beginFractalLow: beginLow,
    endFractalHigh: endHigh,
    endFractalLow: endLow,
  );
}

List<KlineBar> _bars0to10() {
  return [
    for (var i = 0; i <= 10; i++)
      _bar(i, high: 20.0 + i, low: 5.0 + i * 0.5),
  ];
}

void main() {
  group('calcMinDistFitLine', () {
    test('2 点唯一确定斜率', () {
      final line = calcMinDistFitLine(
        const [FitPoint(0, 10), FitPoint(4, 14)],
        dir: 1,
        side: TrendLineSide.inside,
      );
      expect(line, isNotNull);
      expect(line!.slope, closeTo(1.0, 1e-12));
    });

    test('≥3 点距离和最小', () {
      final line = calcMinDistFitLine(
        const [
          FitPoint(0, 10),
          FitPoint(2, 11),
          FitPoint(4, 12),
          FitPoint(6, 13),
        ],
        dir: 1,
        side: TrendLineSide.inside,
      );
      expect(line, isNotNull);
      expect(line!.slope, closeTo(0.5, 1e-12));
    });
  });

  group('collectPolesInParentSpan', () {
    test('只收父段内同型极点', () {
      const parent = ParentSpan(
        beginX: 0,
        endX: 10,
        confirmMax: 10,
        idx: 0,
        dir: 1,
      );
      final poles = [
        const FxPole(x: 2, price: 8, fx: 'BOTTOM', confirmX: 3),
        const FxPole(x: 12, price: 9, fx: 'BOTTOM', confirmX: 13),
        const FxPole(x: 6, price: 10, fx: 'TOP', confirmX: 7),
      ];
      final out = collectPolesInParentSpan(
        poles: poles,
        parent: parent,
        fx: 'BOTTOM',
      );
      expect(out.length, 1);
      expect(out.first.x, 2);
    });
  });

  group('calcBottomSnugGroupsForLevel', () {
    test('父段内 1 个底极点 → 空', () {
      final bars = _bars0to10();
      final levels = [
        LevelBundle(
          level: 1,
          segments: [
            _seg(
              idx: 0,
              dir: 1,
              beginPoleX: 0,
              endPoleX: 10,
              beginVal: 10,
              endVal: 18,
              endConfirmX: 10,
            ),
          ],
        ),
      ];
      final k0 = [
        _k0Conf(confirmX: 3, fx: 'BOTTOM', pole: 2),
      ];
      expect(
        calcBottomSnugGroupsForLevel(
          displayKn: 0,
          bars: bars,
          k0Confirms: k0,
          levels: levels,
        ),
        isEmpty,
      );
    });

    test('上升父段内 ≥2 底极点 → 1 组 bottomSnug 射线', () {
      final bars = [
        for (var i = 0; i <= 10; i++)
          _bar(
            i,
            high: 20.0 + i,
            low: i == 2
                ? 8.0
                : i == 6
                    ? 10.0
                    : 5.0 + i * 0.5,
          ),
      ];
      final levels = [
        LevelBundle(
          level: 1,
          segments: [
            _seg(
              idx: 0,
              dir: 1,
              beginPoleX: 0,
              endPoleX: 10,
              beginVal: 10,
              endVal: 18,
              endConfirmX: 10,
            ),
          ],
        ),
      ];
      final k0 = [
        _k0Conf(confirmX: 3, fx: 'BOTTOM', pole: 2),
        _k0Conf(confirmX: 7, fx: 'BOTTOM', pole: 6),
      ];
      final groups = calcBottomSnugGroupsForLevel(
        displayKn: 0,
        bars: bars,
        k0Confirms: k0,
        levels: levels,
      );
      expect(groups.length, 1);
      expect(groups.first.rays.length, 1);
      final r = groups.first.rays.first;
      expect(r.kind, 'bottomSnug');
      expect(r.slope, closeTo(0.5, 1e-12));
      expect(r.x0, 2);
      expect(r.x1, isNull);

      final px = bottomSnugPriceReadout(groups, atX: 8, focusX: 5);
      expect(px, closeTo(11.0, 1e-9));
    });

    test('下降父段跳过底极贴合', () {
      final bars = _bars0to10();
      final levels = [
        LevelBundle(
          level: 1,
          segments: [
            _seg(
              idx: 0,
              dir: -1,
              beginPoleX: 0,
              endPoleX: 10,
              beginVal: 18,
              endVal: 10,
              endConfirmX: 10,
            ),
          ],
        ),
      ];
      final k0 = [
        _k0Conf(confirmX: 3, fx: 'BOTTOM', pole: 2),
        _k0Conf(confirmX: 7, fx: 'BOTTOM', pole: 6),
      ];
      expect(
        calcBottomSnugGroupsForLevel(
          displayKn: 0,
          bars: bars,
          k0Confirms: k0,
          levels: levels,
        ),
        isEmpty,
      );
    });

    test('两个父段 → 两组独立', () {
      final bars = [
        for (var i = 0; i <= 20; i++)
          _bar(
            i,
            high: 30.0 + i,
            low: i == 2
                ? 8.0
                : i == 6
                    ? 10.0
                    : i == 10
                        ? 12.0
                        : i == 14
                            ? 14.0
                            : 5.0 + i * 0.3,
          ),
      ];
      final levels = [
        LevelBundle(
          level: 1,
          segments: [
            _seg(
              idx: 0,
              dir: 1,
              beginPoleX: 0,
              endPoleX: 8,
              beginVal: 10,
              endVal: 14,
              endConfirmX: 8,
            ),
            _seg(
              idx: 1,
              dir: 1,
              beginPoleX: 8,
              endPoleX: 18,
              beginVal: 14,
              endVal: 20,
              endConfirmX: 18,
            ),
          ],
        ),
      ];
      final k0 = [
        _k0Conf(confirmX: 3, fx: 'BOTTOM', pole: 2),
        _k0Conf(confirmX: 7, fx: 'BOTTOM', pole: 6),
        _k0Conf(confirmX: 11, fx: 'BOTTOM', pole: 10),
        _k0Conf(confirmX: 15, fx: 'BOTTOM', pole: 14),
      ];
      final groups = calcBottomSnugGroupsForLevel(
        displayKn: 0,
        bars: bars,
        k0Confirms: k0,
        levels: levels,
      );
      expect(groups.length, 2);
    });

    test('asOf 截断父段', () {
      final bars = _bars0to10();
      final levels = [
        LevelBundle(
          level: 1,
          segments: [
            _seg(
              idx: 0,
              dir: 1,
              beginPoleX: 0,
              endPoleX: 10,
              beginVal: 10,
              endVal: 18,
              endConfirmX: 10,
            ),
          ],
        ),
      ];
      final k0 = [
        _k0Conf(confirmX: 3, fx: 'BOTTOM', pole: 2),
        _k0Conf(confirmX: 7, fx: 'BOTTOM', pole: 6),
      ];
      expect(
        calcBottomSnugGroupsForLevel(
          displayKn: 0,
          bars: bars,
          k0Confirms: k0,
          levels: levels,
          asOf: 5,
        ),
        isEmpty,
      );
      expect(
        calcBottomSnugGroupsForLevel(
          displayKn: 0,
          bars: bars,
          k0Confirms: k0,
          levels: levels,
          asOf: 10,
        ),
        isNotEmpty,
      );
    });
  });

  group('calcTopSnugGroupsForLevel', () {
    test('下降父段内 ≥2 顶极点 → topSnug', () {
      final bars = [
        for (var i = 0; i <= 10; i++)
          _bar(
            i,
            high: i == 2
                ? 18.0
                : i == 6
                    ? 16.0
                    : 20.0 + i,
            low: 5.0 + i * 0.5,
          ),
      ];
      final levels = [
        LevelBundle(
          level: 1,
          confirms: [
            _lvConf(confirmX: 3, fx: 'TOP', pole: 2, price: 18),
            _lvConf(confirmX: 7, fx: 'TOP', pole: 6, price: 16),
          ],
          segments: [],
        ),
        LevelBundle(
          level: 2,
          segments: [
            _seg(
              idx: 0,
              dir: -1,
              beginPoleX: 0,
              endPoleX: 10,
              beginVal: 20,
              endVal: 12,
              endConfirmX: 10,
            ),
          ],
        ),
      ];
      final groups = calcTopSnugGroupsForLevel(
        displayKn: 1,
        bars: bars,
        levels: levels,
      );
      expect(groups.length, 1);
      expect(groups.first.rays.first.kind, 'topSnug');
      expect(groups.first.rays.first.slope, closeTo(-0.5, 1e-12));

      final px = topSnugPriceReadout(groups, atX: 8, focusX: 5);
      expect(px, closeTo(15.0, 1e-9));
    });
  });

  group('selectFxExtendGroups', () {
    test('无焦点=最新组', () {
      final groups = [
        FxExtendGroup(
          poleMinX: 0,
          poleMaxX: 8,
          confirmMax: 8,
          rays: const [
            FxExtendRay(x0: 6, y0: 10, slope: 0.5, kind: 'bottomSnug'),
          ],
        ),
        FxExtendGroup(
          poleMinX: 8,
          poleMaxX: 18,
          confirmMax: 18,
          rays: const [
            FxExtendRay(x0: 14, y0: 14, slope: 0.5, kind: 'bottomSnug'),
          ],
        ),
      ];
      final sel = selectFxExtendGroups(groups);
      expect(sel.first.confirmMax, 18);
    });
  });

  group('catalog', () {
    test('maxKn≥2 时含 K0/K1 底顶极贴合', () {
      final cat = buildMainIndicatorCatalog(3);
      expect(
        cat.any((e) =>
            e.kind == MainIndicatorKind.fxBottomSnug &&
            e.kn == 0 &&
            e.label == 'K0底极贴合线'),
        isTrue,
      );
      expect(
        cat.any((e) =>
            e.kind == MainIndicatorKind.fxTopSnug &&
            e.kn == 1 &&
            e.label == 'K1顶极贴合线'),
        isTrue,
      );
    });

    test('maxKn<2 仅 K0 占位', () {
      final cat = buildMainIndicatorCatalog(1);
      expect(cat.where((e) => e.kind == MainIndicatorKind.fxBottomSnug).length,
          1);
      expect(cat.where((e) => e.kind == MainIndicatorKind.fxTopSnug).length, 1);
    });
  });
}
