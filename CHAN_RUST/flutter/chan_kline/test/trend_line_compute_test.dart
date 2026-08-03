import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/fx_extend_line_compute.dart';
import 'package:chan_kline/compute/trend_line_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/level_models.dart';

TrendLineBi _bi({
  required int beginX,
  required int endX,
  required double beginVal,
  required double endVal,
  required int dir,
}) {
  return TrendLineBi(
    beginX: beginX,
    endX: endX,
    beginVal: beginVal,
    endVal: endVal,
    dir: dir,
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
  // begin/end fractal 价写入，供 _segBeginVal/_segEndVal
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

void main() {
  group('calcTrendLine', () {
    test('不足 3 子线 → null', () {
      expect(
        calcTrendLine([
          _bi(beginX: 0, endX: 2, beginVal: 10, endVal: 12, dir: 1),
          _bi(beginX: 2, endX: 4, beginVal: 12, endVal: 8, dir: -1),
        ], TrendLineSide.inside),
        isNull,
      );
    });

    test('≥3 子线产出有限斜率线', () {
      // 上涨段末笔向上：隔笔取 4,2,0
      final lst = [
        _bi(beginX: 0, endX: 2, beginVal: 10, endVal: 14, dir: 1),
        _bi(beginX: 2, endX: 4, beginVal: 14, endVal: 11, dir: -1),
        _bi(beginX: 4, endX: 6, beginVal: 11, endVal: 16, dir: 1),
        _bi(beginX: 6, endX: 8, beginVal: 16, endVal: 12, dir: -1),
        _bi(beginX: 8, endX: 10, beginVal: 12, endVal: 18, dir: 1),
      ];
      final support = calcTrendLine(lst, TrendLineSide.inside);
      final resist = calcTrendLine(lst, TrendLineSide.outside);
      expect(support, isNotNull);
      expect(resist, isNotNull);
      expect(support!.slope.isFinite, isTrue);
      expect(resist!.slope.isFinite, isTrue);
    });
  });

  group('calcTrendLineGroupsForLevel', () {
    test('K0：父 level2 + 子 level1 ≥3 → 一组撑/压', () {
      final childSegs = [
        _seg(
          idx: 0,
          dir: 1,
          beginPoleX: 0,
          endPoleX: 2,
          beginVal: 10,
          endVal: 14,
        ),
        _seg(
          idx: 1,
          dir: -1,
          beginPoleX: 2,
          endPoleX: 4,
          beginVal: 14,
          endVal: 11,
        ),
        _seg(
          idx: 2,
          dir: 1,
          beginPoleX: 4,
          endPoleX: 6,
          beginVal: 11,
          endVal: 16,
        ),
        _seg(
          idx: 3,
          dir: -1,
          beginPoleX: 6,
          endPoleX: 8,
          beginVal: 16,
          endVal: 12,
        ),
        _seg(
          idx: 4,
          dir: 1,
          beginPoleX: 8,
          endPoleX: 10,
          beginVal: 12,
          endVal: 18,
        ),
      ];
      final parentSegs = [
        _seg(
          idx: 0,
          dir: 1,
          beginPoleX: 0,
          endPoleX: 10,
          beginVal: 10,
          endVal: 18,
          endConfirmX: 10,
        ),
      ];
      final levels = [
        LevelBundle(level: 1, segments: childSegs),
        LevelBundle(level: 2, segments: parentSegs),
      ];
      final groups = calcTrendLineGroupsForLevel(
        displayKn: 0,
        levels: levels,
      );
      expect(groups.length, 1);
      expect(groups.first.rays.any((e) => e.kind == 'support'), isTrue);
      expect(groups.first.rays.any((e) => e.kind == 'resistance'), isTrue);

      final tip = trendLinePriceReadout(groups, atX: 10, focusX: 5);
      expect(tip.support, isNotNull);
      expect(tip.resistance, isNotNull);
    });

    test('无父层 → 空；asOf 截断可致空', () {
      final levels = [
        LevelBundle(
          level: 1,
          segments: [
            _seg(
              idx: 0,
              dir: 1,
              beginPoleX: 0,
              endPoleX: 2,
              beginVal: 10,
              endVal: 12,
            ),
          ],
        ),
      ];
      expect(
        calcTrendLineGroupsForLevel(displayKn: 0, levels: levels),
        isEmpty,
      );

      final childSegs = [
        for (var i = 0; i < 5; i++)
          _seg(
            idx: i,
            dir: i.isEven ? 1 : -1,
            beginPoleX: i * 2,
            endPoleX: i * 2 + 2,
            beginVal: 10.0 + i,
            endVal: 11.0 + i,
            endConfirmX: i * 2 + 2,
          ),
      ];
      final parentSegs = [
        _seg(
          idx: 0,
          dir: 1,
          beginPoleX: 0,
          endPoleX: 10,
          beginVal: 10,
          endVal: 15,
          endConfirmX: 10,
        ),
      ];
      final full = [
        LevelBundle(level: 1, segments: childSegs),
        LevelBundle(level: 2, segments: parentSegs),
      ];
      // asOf 过早：父段尚未确认 → 空
      expect(
        calcTrendLineGroupsForLevel(displayKn: 0, levels: full, asOf: 3),
        isEmpty,
      );
      expect(
        calcTrendLineGroupsForLevel(displayKn: 0, levels: full, asOf: 10),
        isNotEmpty,
      );
    });

    test('select：无焦点=最新组', () {
      // 两个父段各 ≥3 子
      final childSegs = [
        for (var i = 0; i < 6; i++)
          _seg(
            idx: i,
            dir: i.isEven ? 1 : -1,
            beginPoleX: i * 2,
            endPoleX: i * 2 + 2,
            beginVal: 10.0 + (i.isEven ? 0 : 2),
            endVal: 12.0 + (i.isEven ? 2 : 0),
            endConfirmX: i * 2 + 2,
          ),
      ];
      final parentSegs = [
        _seg(
          idx: 0,
          dir: 1,
          beginPoleX: 0,
          endPoleX: 6,
          beginVal: 10,
          endVal: 14,
          endConfirmX: 6,
        ),
        _seg(
          idx: 1,
          dir: -1,
          beginPoleX: 6,
          endPoleX: 12,
          beginVal: 14,
          endVal: 10,
          endConfirmX: 12,
        ),
      ];
      final levels = [
        LevelBundle(level: 1, segments: childSegs),
        LevelBundle(level: 2, segments: parentSegs),
      ];
      final groups = calcTrendLineGroupsForLevel(displayKn: 0, levels: levels);
      expect(groups.length, greaterThanOrEqualTo(1));
      final latest = selectFxExtendGroups(groups, focusX: null);
      expect(latest.length, 1);
      expect(latest.first.poleMaxX, groups.last.poleMaxX);
    });
  });

  group('catalog', () {
    test('主图含趋势线：maxKn=1 挂 K0；maxKn=3 挂 K0/K1', () {
      final c1 = buildMainIndicatorCatalog(1);
      final t1 = c1.where((e) => e.kind == MainIndicatorKind.trendLine);
      expect(t1.map((e) => e.kn), [1]);
      expect(t1.first.label, 'K0趋势线');

      final c3 = buildMainIndicatorCatalog(3);
      final t3 = c3.where((e) => e.kind == MainIndicatorKind.trendLine);
      expect(t3.map((e) => e.kn), [1, 2]);

      final d = defaultMainIndicatorsK0();
      expect(d.any((e) => e.kind == MainIndicatorKind.trendLine), isTrue);
      final lv0 = mainIndicatorsForLevel(0, buildMainIndicatorCatalog(1));
      expect(lv0.any((e) => e.kind == MainIndicatorKind.trendLine), isTrue);
    });
  });
}
