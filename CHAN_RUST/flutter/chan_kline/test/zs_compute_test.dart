import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/zs_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/zs_frame.dart';

LevelBundle _levelWithZs({
  required int level,
  required List<ZSFrame> normal,
  List<ZSFrame> overSeg = const [],
}) {
  return LevelBundle(
    level: level,
    zsNormalFrames: normal,
    zsOverSegFrames: overSeg,
  );
}

void main() {
  test('rustZsFramesForKn 读 K0 与 Kn 末态 JSON', () {
    final k0 = [
      const ZSFrame(x1: 3, x2: 5, high: 11.71, low: 11.71, level: 0, count: 1),
    ];
    final k1 = [
      const ZSFrame(x1: 0, x2: 2, high: 20, low: 10, level: 1, count: 2),
    ];
    final levels = [_levelWithZs(level: 1, normal: k1)];
    expect(
      rustZsFramesForKn(
        kn: 0,
        algo: ZSAlgoKind.normal,
        zsK0NormalFrames: k0,
        zsK0OverSegFrames: const [],
        levels: levels,
      ),
      k0,
    );
    expect(
      rustZsFramesForKn(
        kn: 1,
        algo: ZSAlgoKind.normal,
        zsK0NormalFrames: k0,
        zsK0OverSegFrames: const [],
        levels: levels,
      ),
      k1,
    );
  });

  test('zs crosshair tooltip 命中坐标显示 ZG ZD', () {
    final bundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      zsK0NormalFrames: [
        const ZSFrame(
          x1: 0,
          x2: 1,
          high: 11.72,
          low: 11.71,
          level: 0,
          count: 2,
        ),
      ],
    );
    final rows = zsCrosshairTooltipRows(
      asOfIdx: 0,
      mainIndicators: {const MainChartIndicator.zsNormal(0)},
      combineFrames: const [],
      levels: const [],
      barFeatures: const [],
      zsK0NormalFrames: bundle.zsK0NormalFrames,
      asOfBundle: bundle,
      asOf: 0,
    );
    expect(rows.length, 1);
    expect(rows.first.label, contains('ZG/ZD'));
    expect(rows.first.value, 'ZG11.71/ZD11.72');
  });

  test('asOfBundle 与末态帧分离：十字线读 as-of bundle', () {
    final tail = [
      const ZSFrame(x1: 6, x2: 7, high: 11.73, low: 11.72, level: 0, count: 1),
    ];
    final asOfBundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      zsK0NormalFrames: tail,
      levels: const [],
    );
    final tailFrames = rustZsFramesFromBundle(
      bundle: asOfBundle,
      kn: 0,
      algo: ZSAlgoKind.normal,
    );
    expect(tailFrames, tail);
    expect(
      computeZsFramesAtAsOf(
        kn: 0,
        algo: ZSAlgoKind.normal,
        combineFrames: const [],
        levels: const [],
        barFeatures: const [],
        asOf: 7,
        asOfBundle: asOfBundle,
        zsK0NormalFrames: [
          const ZSFrame(x1: 8, x2: 11, high: 11.7, low: 11.7, level: 0),
        ],
      ),
      tail,
    );
  });
}
