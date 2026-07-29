import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/zs_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/zs_frame.dart';

LevelBundle _levelWithZs({
  required int level,
  required List<ZSFrame> frames,
}) {
  return LevelBundle(
    level: level,
    zsFrames: frames,
  );
}

void main() {
  test('rustZsFramesForKn 读 K0 与 Kn 末态 JSON', () {
    final k0 = [
      const ZSFrame(x1: 3, x2: 5, high: 11.71, low: 11.71, gg: 11.71, dd: 11.71, level: 0, count: 1),
    ];
    final k1 = [
      const ZSFrame(x1: 0, x2: 2, high: 20, low: 10, gg: 22, dd: 8, level: 1, count: 2),
    ];
    final levels = [_levelWithZs(level: 1, frames: k1)];
    expect(
      rustZsFramesForKn(
        kn: 0,
        zsK0Frames: k0,
        levels: levels,
      ),
      k0,
    );
    expect(
      rustZsFramesForKn(
        kn: 1,
        zsK0Frames: k0,
        levels: levels,
      ),
      k1,
    );
  });

  test('zs crosshair tooltip 命中坐标显示连续中枢4行', () {
    final bundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      zsK0Frames: [
        const ZSFrame(
          x1: 0,
          x2: 1,
          high: 11.72,
          low: 11.71,
          gg: 11.73,
          dd: 11.70,
          level: 0,
          count: 2,
          seq: 0,
          isSure: true,
        ),
      ],
    );
    final rows = zsCrosshairTooltipRows(
      asOfIdx: 0,
      mainIndicators: {const MainChartIndicator.zs(0)},
      combineFrames: const [],
      levels: const [],
      barFeatures: const [],
      zsK0Frames: bundle.zsK0Frames,
      asOfBundle: bundle,
      asOf: 0,
    );
    expect(rows.length, 4);
    expect(rows[0].label, 'K0连续中枢价格');
    expect(rows[0].value, 'GG【11.73】/DD【11.70】/ZG【11.72】/ZD【11.71】');
    expect(rows[1].label, 'K0连续中枢Kn序');
    expect(rows[1].value, '【2】');
    expect(rows[2].label, 'K0连续中枢组No.');
    expect(rows[2].value, '【0】');
    expect(rows[3].label, 'K0连续中枢确认');
    expect(rows[3].value, '【0】');
  });

  test('连续中枢确认：仅首根K检测上一中枢isSure', () {
    final bundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      zsK0Frames: [
        const ZSFrame(
          x1: 0, x2: 3, high: 20, low: 10, gg: 22, dd: 8,
          level: 0, count: 3, seq: 0, isSure: true,
        ),
        const ZSFrame(
          x1: 4, x2: 7, high: 30, low: 20, gg: 32, dd: 18,
          level: 0, count: 2, seq: 1, isSure: false,
        ),
      ],
    );
    // ZS[1].x1=4 → 首根K，检测 ZS[0].isSure=true → 确认=1
    final rowsFirst = zsCrosshairTooltipRows(
      asOfIdx: 4,
      mainIndicators: {const MainChartIndicator.zs(0)},
      combineFrames: const [],
      levels: const [],
      barFeatures: const [],
      zsK0Frames: bundle.zsK0Frames,
      asOfBundle: bundle,
      asOf: 4,
    );
    expect(rowsFirst.length, 4);
    expect(rowsFirst[3].label, 'K0连续中枢确认');
    expect(rowsFirst[3].value, '【1】');

    // ZS[1] 非首根K（x1+1=5）→ 确认=0
    final rowsMid = zsCrosshairTooltipRows(
      asOfIdx: 5,
      mainIndicators: {const MainChartIndicator.zs(0)},
      combineFrames: const [],
      levels: const [],
      barFeatures: const [],
      zsK0Frames: bundle.zsK0Frames,
      asOfBundle: bundle,
      asOf: 5,
    );
    expect(rowsMid.length, 4);
    expect(rowsMid[3].value, '【0】');
  });

  test('连续中枢确认：上一中枢未确认时显示0', () {
    final bundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      zsK0Frames: [
        const ZSFrame(
          x1: 0, x2: 3, high: 20, low: 10, gg: 22, dd: 8,
          level: 0, count: 3, seq: 0, isSure: false,
        ),
        const ZSFrame(
          x1: 4, x2: 7, high: 30, low: 20, gg: 32, dd: 18,
          level: 0, count: 2, seq: 1, isSure: false,
        ),
      ],
    );
    // ZS[1].x1=4 → 首根K，检测 ZS[0].isSure=false → 确认=0
    final rows = zsCrosshairTooltipRows(
      asOfIdx: 4,
      mainIndicators: {const MainChartIndicator.zs(0)},
      combineFrames: const [],
      levels: const [],
      barFeatures: const [],
      zsK0Frames: bundle.zsK0Frames,
      asOfBundle: bundle,
      asOf: 4,
    );
    expect(rows.length, 4);
    expect(rows[3].value, '【0】');
  });

  test('asOfBundle 与末态帧分离：十字线读 as-of bundle', () {
    final tail = [
      const ZSFrame(x1: 6, x2: 7, high: 11.73, low: 11.72, gg: 11.74, dd: 11.71, level: 0, count: 1),
    ];
    final asOfBundle = KlineCombineBundle(
      frames: const [],
      k0Confirms: const [],
      zsK0Frames: tail,
      levels: const [],
    );
    final tailFrames = rustZsFramesFromBundle(
      bundle: asOfBundle,
      kn: 0,
    );
    expect(tailFrames, tail);
    expect(
      computeZsFramesAtAsOf(
        kn: 0,
        combineFrames: const [],
        levels: const [],
        barFeatures: const [],
        asOf: 7,
        asOfBundle: asOfBundle,
        zsK0Frames: [
          const ZSFrame(x1: 8, x2: 11, high: 11.7, low: 11.7, gg: 11.7, dd: 11.7, level: 0),
        ],
      ),
      tail,
    );
  });
}
