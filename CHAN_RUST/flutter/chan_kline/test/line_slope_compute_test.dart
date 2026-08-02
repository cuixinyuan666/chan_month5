import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/line_slope_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/level_models.dart';

LevelSegmentN _seg({
  required int idx,
  required int dir,
  required int beginPoleX,
  required int endConfirmX,
  required double begin,
  required double end,
}) {
  final lo = begin < end ? begin : end;
  final hi = begin < end ? end : begin;
  return LevelSegmentN(
    idx: idx,
    dir: dir,
    beginConfirmX: beginPoleX,
    endConfirmX: endConfirmX,
    beginPoleX: beginPoleX,
    endPoleX: endConfirmX,
    open: begin,
    high: hi,
    low: lo,
    close: end,
    beginFractalHigh: dir < 0 ? begin : hi,
    beginFractalLow: dir > 0 ? begin : lo,
    endFractalHigh: dir > 0 ? end : hi,
    endFractalLow: dir < 0 ? end : lo,
  );
}

LevelBundle _lv(int level, List<LevelSegmentN> segs, {LevelUnitBar? active}) {
  return LevelBundle(
    level: level,
    segments: segs,
    activeUnit: active,
  );
}

void main() {
  group('line_slope_compute', () {
    test('水平线 slope≈0', () {
      final levels = [
        _lv(1, [
          _seg(
            idx: 0,
            dir: 1,
            beginPoleX: 0,
            endConfirmX: 4,
            begin: 10,
            end: 10,
          ),
        ]),
      ];
      final p = calcLineSlopeForStep(
        levels: levels,
        displayKn: 0,
        displayX: 4,
      );
      expect(p, isNotNull);
      expect(p!.slope, closeTo(0, 1e-12));
      expect(p.dir, 'up');
    });

    test('上升 dx=2 → 正斜率', () {
      // begin=10 end=14，dx=2 → slope=2
      final levels = [
        _lv(1, [
          _seg(
            idx: 0,
            dir: 1,
            beginPoleX: 3,
            endConfirmX: 5,
            begin: 10,
            end: 14,
          ),
        ]),
      ];
      final p = calcLineSlopeForStep(
        levels: levels,
        displayKn: 0,
        displayX: 5,
      );
      expect(p, isNotNull);
      expect(p!.slope, closeTo(2, 1e-9));
      expect(p.x, 5);
    });

    test('虚线/进行中子线可算', () {
      final levels = [
        _lv(
          1,
          const [],
          active: const LevelUnitBar(
            idx: 0,
            dir: -1,
            x1: 2,
            x2: 6,
            open: 12,
            high: 12,
            low: 8,
            close: 8,
          ),
        ),
      ];
      final p = calcLineSlopeForStep(
        levels: levels,
        displayKn: 0,
        displayX: 6,
      );
      expect(p, isNotNull);
      // (8-12)/(6-2) = -1
      expect(p!.slope, closeTo(-1, 1e-9));
      expect(p.dir, 'down');
    });

    test('|dx|<1 → null', () {
      final levels = [
        _lv(1, [
          _seg(
            idx: 0,
            dir: 1,
            beginPoleX: 5,
            endConfirmX: 5,
            begin: 10,
            end: 12,
          ),
        ]),
      ];
      expect(
        calcLineSlopeForStep(
          levels: levels,
          displayKn: 0,
          displayX: 5,
        ),
        isNull,
      );
    });

    test('同 x 覆盖 + asOf 截断', () {
      final hist = <LineSlopePoint>[];
      mergeLineSlopePoint(
        hist,
        const LineSlopePoint(
          x: 3,
          displayKn: 0,
          slope: 1.0,
          dir: 'up',
          childIdx: 0,
        ),
      );
      mergeLineSlopePoint(
        hist,
        const LineSlopePoint(
          x: 3,
          displayKn: 0,
          slope: 2.5,
          dir: 'up',
          childIdx: 0,
        ),
      );
      mergeLineSlopePoint(
        hist,
        const LineSlopePoint(
          x: 5,
          displayKn: 0,
          slope: -0.5,
          dir: 'down',
          childIdx: 1,
        ),
      );
      expect(hist.length, 2);
      expect(hist.firstWhere((e) => e.x == 3).slope, 2.5);

      final series = expandLineSlopeToSeries(hist, 8, maxX: 3);
      expect(series[3], 2.5);
      expect(series[5], isNull);
    });
  });

  group('catalog', () {
    test('含 lineSlope 且默认 K0 / 层全选纳入', () {
      final cat = buildSubIndicatorCatalog(2);
      final slopes = cat.where((e) => e.kind == SubIndicatorKind.lineSlope);
      expect(slopes.map((e) => e.kn), [0, 1]);
      expect(slopes.every((e) => e.label.contains('连线斜率')), isTrue);
      expect(slopes.every((e) => e.displayLevel == e.kn), isTrue);

      final d = defaultSubIndicatorsK0();
      expect(d.any((e) => e.kind == SubIndicatorKind.lineSlope), isTrue);
      final lv0 = subIndicatorsForLevel(0, buildSubIndicatorCatalog(1));
      expect(lv0.any((e) => e.kind == SubIndicatorKind.lineSlope), isTrue);
    });
  });
}
