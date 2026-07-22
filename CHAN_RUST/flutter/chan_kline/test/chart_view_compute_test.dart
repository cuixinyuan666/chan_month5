import 'package:chan_kline/compute/k1_bar_view_compute.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/models/fractal_judgment_event.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/k1_bar.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

List<KlineBar> _bars(int n) => List.generate(
      n,
      (i) => KlineBar(
        idx: i,
        timeMs: i,
        timeText: '2024/01/01 09:${i.toString().padLeft(2, '0')}',
        open: 10.0 + i * 0.1,
        high: 10.5 + i * 0.1,
        low: 9.5 + i * 0.1,
        close: 10.2 + i * 0.1,
        volume: 100.0 + i,
        amount: 1.0,
        metrics: const {},
      ),
    );

void main() {
  test('as-of 组装：冻结段查表 + 当步快照进行中K0连线（含半侧衔接）', () {
    final bars = _bars(10);
    // Rust 冻结段：K1#0（极点 → 极点，x=5 冻结）
    const levels = [
      LevelBundle(
        level: 1,
        segments: [
          LevelSegmentN(
            idx: 0,
            dir: 1,
            beginConfirmX: 2,
            endConfirmX: 5,
            beginPoleX: 1,
            endPoleX: 4,
            open: 10.1,
            high: 10.9,
            low: 9.6,
            close: 10.6,
            volume: 400,
          ),
        ],
      ),
    ];
    // 当步快照：x=5 新起进行中K0连线 idx=1（K4 极点 → K5）
    final feats = List.generate(10, (i) {
      final active = i >= 5;
      return BarCrosshairFeature(
        idx: i,
        weekday: '周一',
        mergeInnerSeq: 0,
        levels: [
          LevelSnap(
            level: 1,
            unitIdx: active ? 1 : (i >= 2 ? 0 : null),
            unitDir: active ? -1 : 1,
            unitX1: active ? 4 : (i >= 2 ? 1 : -1),
            unitX2: active ? i : (i >= 2 ? i : -1),
            unitOpen: 10.4,
            unitHigh: 11.0,
            unitLow: 9.9,
            unitClose: 10.7,
            unitVolume: 210,
          ),
        ],
      );
    });

    final atConfirm = asOfK1Bars(
      bars: bars,
      levels: levels,
      barFeatures: feats,
      defaultK0Policy: 'purged',
      asOf: 5,
    );
    expect(atConfirm.length, 2, reason: '确认当步应有冻结K0连线+新进行中K0连线');
    expect(atConfirm[0].idx, 0);
    expect(atConfirm[0].high, 10.9);
    expect(atConfirm[1].idx, 1);
    expect(atConfirm[1].x1, 4);
    expect(atConfirm[1].x2, 5);

    final views = buildK1BarViews(atConfirm);
    expect(views[0].endAtLeftHalf, isTrue);
    expect(views[1].startAtRightHalf, isTrue);
    expect(views[0].viewX2, views[1].viewX1);
  });

  test('fractalExtremeBarIdxRaw 与 K0ConfirmSignal 包装同口径', () {
    final bars = _bars(6);
    bars[2] = KlineBar(
      idx: 2,
      timeMs: 2,
      timeText: 't2',
      open: 12,
      high: 15,
      low: 11,
      close: 14,
      volume: 100,
      amount: 1,
      metrics: const {},
    );
    const conf = K0ConfirmSignal(
      x: 4,
      fx: 'TOP',
      value: -1,
      fractalX1: 1,
      fractalX2: 3,
    );
    expect(
      fractalExtremeBarIdxRaw(bars, fx: 'TOP', fractalX1: 1, fractalX2: 3),
      2,
    );
    expect(fractalExtremeBarIdx(bars, conf), 2);
  });

  test('levelSegmentEndpoint 优先 Rust poleX', () {
    final bars = _bars(8);
    const seg = LevelSegmentN(
      idx: 0,
      dir: 1,
      beginConfirmX: 2,
      endConfirmX: 5,
      beginPoleX: 1,
      endPoleX: 4,
      open: 10,
      high: 11,
      low: 9,
      close: 10.5,
      volume: 100,
      beginFractalX1: 1,
      beginFractalX2: 1,
      endFractalX1: 3,
      endFractalX2: 4,
    );
    const confirms = [
      LevelConfirm(
        x: 2,
        fx: 'BOTTOM',
        value: 1,
        fractalX1: 1,
        fractalX2: 1,
        poleX: 1,
      ),
      LevelConfirm(
        x: 5,
        fx: 'TOP',
        value: -1,
        fractalX1: 3,
        fractalX2: 4,
        poleX: 4,
      ),
    ];
    final begin = levelSegmentEndpoint(
      bars: bars,
      seg: seg,
      confirms: confirms,
      isBegin: true,
    );
    final end = levelSegmentEndpoint(
      bars: bars,
      seg: seg,
      confirms: confirms,
      isBegin: false,
    );
    expect(begin?.barIdx, 1);
    expect(begin?.price, bars[1].low);
    expect(end?.barIdx, 4);
    expect(end?.price, bars[4].high);
  });

  test('asOfLevelSegments 仅含 endConfirmX<=asOf 的冻结段', () {
    const levels = [
      LevelBundle(level: 1),
      LevelBundle(
        level: 2,
        segments: [
          LevelSegmentN(
            idx: 0,
            dir: 1,
            beginConfirmX: 2,
            endConfirmX: 5,
            beginPoleX: 1,
            endPoleX: 4,
            open: 10,
            high: 11,
            low: 9,
            close: 10.5,
            volume: 100,
          ),
          LevelSegmentN(
            idx: 1,
            dir: -1,
            beginConfirmX: 5,
            endConfirmX: 8,
            beginPoleX: 4,
            endPoleX: 7,
            open: 10.5,
            high: 11,
            low: 9,
            close: 9.5,
            volume: 120,
          ),
        ],
      ),
    ];
    final at5 = asOfLevelSegments(levels: levels, level: 2, asOf: 5);
    expect(at5.length, 1);
    expect(at5.first.idx, 0);
    final at8 = asOfLevelSegments(levels: levels, level: 2, asOf: 8);
    expect(at8.length, 2);
  });

  test('首K0连线确认前：pending 给默认K1 bar，purged 为空', () {
    final bars = _bars(4);
    final feats = [
      for (var i = 0; i < 4; i++)
        BarCrosshairFeature(idx: i, weekday: '周一', mergeInnerSeq: 0, levels: const [
          LevelSnap(level: 1),
        ]),
    ];
    final pending = asOfK1Bars(
      bars: bars,
      levels: const [LevelBundle(level: 1)],
      barFeatures: feats,
      defaultK0Policy: 'pending',
      asOf: 3,
    );
    expect(pending.length, 1);
    expect(pending.first.x1, 0);
    expect(pending.first.x2, 3);

    final purged = asOfK1Bars(
      bars: bars,
      levels: const [LevelBundle(level: 1)],
      barFeatures: feats,
      defaultK0Policy: 'purged',
      asOf: 3,
    );
    expect(purged, isEmpty);
  });

  test('构建中虚线尾端：取区间内首次方向极值所在 K0（非 as-of 末根）', () {
    // 确认在 0；区间 (0,4]：K2 先创 high=20，K4 high=19 更低 → 尾端应落 K2
    final bars = <KlineBar>[
      for (var i = 0; i <= 4; i++)
        KlineBar(
          idx: i,
          timeMs: i,
          timeText: 't$i',
          open: 10,
          high: i == 2 ? 20 : (i == 4 ? 19 : 11 + i * 0.1),
          low: 9,
          close: 10,
          volume: 1,
          amount: 1,
          metrics: const {},
        ),
    ];
    final up = buildingTailEndpoint(
      bars: bars,
      afterConfirmX: 0,
      asOfX: 4,
      buildingDir: 1,
    );
    expect(up, isNotNull);
    expect(up!.barIdx, 2);
    expect(up.price, 20);

    // 降：K1 先创 low=5，K4 low=5.5 → 尾端落 K1
    final downBars = <KlineBar>[
      for (var i = 0; i <= 4; i++)
        KlineBar(
          idx: i,
          timeMs: i,
          timeText: 't$i',
          open: 10,
          high: 12,
          low: i == 1 ? 5 : (i == 4 ? 5.5 : 8),
          close: 10,
          volume: 1,
          amount: 1,
          metrics: const {},
        ),
    ];
    final down = buildingTailEndpoint(
      bars: downBars,
      afterConfirmX: 0,
      asOfX: 4,
      buildingDir: -1,
    );
    expect(down, isNotNull);
    expect(down!.barIdx, 1);
    expect(down.price, 5);

    // 空区间：确认==asOf → 退化为 asOf 本根
    final empty = buildingTailEndpoint(
      bars: bars,
      afterConfirmX: 4,
      asOfX: 4,
      buildingDir: 1,
    );
    expect(empty, isNotNull);
    expect(empty!.barIdx, 4);
    expect(empty.price, 19);
  });

  test('展示轨虚拟单元：levelBundle 含 active；asOf 含进行中', () {
    const bundle = LevelBundle(
      level: 2,
      unitBars: [
        LevelUnitBar(
          idx: 0,
          dir: 1,
          x1: 1,
          x2: 4,
          open: 10,
          high: 11,
          low: 9,
          close: 10.5,
          confirmX: 5,
        ),
      ],
      activeUnit: LevelUnitBar(
        idx: 1,
        dir: -1,
        x1: 4,
        x2: 7,
        open: 10.5,
        high: 11,
        low: 9.5,
        close: 9.8,
        confirmX: 7,
      ),
      segments: [
        LevelSegmentN(
          idx: 0,
          dir: 1,
          beginConfirmX: 2,
          endConfirmX: 5,
          beginPoleX: 1,
          endPoleX: 4,
          open: 10,
          high: 11,
          low: 9,
          close: 10.5,
        ),
      ],
    );
    final v = levelBundleVirtualK1Bars(bundle);
    expect(v.length, 2);
    expect(v.last.idx, 1);
    expect(v.last.x2, 7);

    final levels = [
      const LevelBundle(level: 1),
      bundle,
    ];
    final feats = [
      for (var i = 0; i <= 7; i++)
        BarCrosshairFeature(
          idx: i,
          weekday: '周一',
          mergeInnerSeq: 0,
          levels: [
            if (i >= 5)
              LevelSnap(
                level: 2,
                unitIdx: 1,
                unitDir: -1,
                unitX1: 4,
                unitX2: i,
                unitOpen: 10.5,
                unitHigh: 11,
                unitLow: 9.5,
                unitClose: 9.8,
              ),
          ],
        ),
    ];
    final at7 = asOfLevelVirtualK1Bars(
      levels: levels,
      barFeatures: feats,
      level: 2,
      asOf: 7,
      includeBuilding: true,
    );
    expect(at7.length, 2);
    expect(at7.last.idx, 1);
    expect(at7.last.x2, 7);

    final frozenOnly = asOfLevelVirtualK1Bars(
      levels: levels,
      barFeatures: feats,
      level: 2,
      asOf: 7,
      includeBuilding: false,
    );
    expect(frozenOnly.length, 1);
    expect(frozenOnly.first.idx, 0);
  });

  test('computeDisplayBuildingLines：无确认时画未冻动态单元', () {
    final bars = _bars(10);
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: 9,
      virtualUnits: const [
        K1Bar(
          idx: 0,
          dir: 1,
          x1: 1,
          x2: 5,
          open: 9.6,
          high: 10.9,
          low: 9.6,
          close: 10.9,
          confirmX: 5,
        ),
      ],
      frozenIdx: const {},
      liveJudgments: const [],
    );
    expect(lines.length, 1);
    expect(lines.first.begin.barIdx, 1);
    expect(lines.first.end.barIdx, 5);
    expect(lines.first.asSolid, isFalse);
  });

  test('computeDisplayBuildingLines：判断钉死端点不随 asOf 拉长；确认↔判断虚线', () {
    final bars = _bars(20);
    bars[5] = KlineBar(
      idx: 5,
      timeMs: 5,
      timeText: 't5',
      open: 10,
      high: 14,
      low: 9.5,
      close: 13,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    bars[8] = KlineBar(
      idx: 8,
      timeMs: 8,
      timeText: 't8',
      open: 10,
      high: 11,
      low: 8,
      close: 9,
      volume: 1,
      amount: 1,
      metrics: const {},
    );

    const bottomConfirm = LevelConfirm(
      x: 3,
      fx: 'BOTTOM',
      value: 1,
      fractalX1: 1,
      fractalX2: 3,
      poleX: 2,
    );
    // 判断成立于 x=8：钉死扫价区间 (2,8]，首高在 5；右组=[8,8]
    const topJudgment = FractalJudgmentEvent(
      x: 8,
      fx: 'TOP',
      fractalX1: 6,
      fractalX2: 7,
      rightX1: 8,
      rightX2: 8,
    );

    final at8 = computeDisplayBuildingLines(
      bars: bars,
      asOf: 8,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [topJudgment],
    );
    expect(at8, isNotEmpty);
    // 确认→判断虚线；开口 tip（triggerX==asOf）→ 右组首根 8
    final closed = at8.where((l) => !l.isOpenTip).toList();
    expect(closed.length, 1);
    expect(closed.first.beginSrc, 'confirm');
    expect(closed.first.endSrc, 'judgment');
    expect(closed.first.asSolid, isFalse);
    expect(closed.first.end.barIdx, 5); // 钉在扫价首极值 5，不是 8
    final open = at8.where((l) => l.isOpenTip).toList();
    expect(open.length, 1);
    expect(open.first.begin.barIdx, 5);
    expect(open.first.end.barIdx, 8);

    // asOf 前进到 15，判断仍在 live → 端点仍钉 5，无开口
    final at15 = computeDisplayBuildingLines(
      bars: bars,
      asOf: 15,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [topJudgment],
    );
    final closed15 = at15.where((l) => !l.isOpenTip).toList();
    expect(closed15.length, 1);
    expect(closed15.first.end.barIdx, 5);
    expect(at15.any((l) => l.isOpenTip), isFalse);
  });

  test('判断开口：极点→右组[55,58]内首极值（例 44→55）', () {
    final bars = _bars(60);
    for (var i = 33; i <= 58; i++) {
      bars[i] = KlineBar(
        idx: i,
        timeMs: i,
        timeText: 't$i',
        open: 10,
        high: 11.0,
        low: 9.0,
        close: 10,
        volume: 1,
        amount: 1,
        metrics: const {},
      );
    }
    bars[44] = KlineBar(
      idx: 44,
      timeMs: 44,
      timeText: 't44',
      open: 10,
      high: 14.0,
      low: 9.0,
      close: 10,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    bars[47] = KlineBar(
      idx: 47,
      timeMs: 47,
      timeText: 't47',
      open: 10,
      high: 11.0,
      low: 7.0,
      close: 10,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    // 右组内 55 为方向首低（openDir 在 TOP 后向下）
    bars[55] = KlineBar(
      idx: 55,
      timeMs: 55,
      timeText: 't55',
      open: 10,
      high: 11.0,
      low: 6.0,
      close: 10,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    const bottomConfirm = LevelConfirm(
      x: 30,
      fx: 'BOTTOM',
      value: 1,
      fractalX1: 28,
      fractalX2: 30,
      poleX: 32,
    );
    const topJudgment = FractalJudgmentEvent(
      x: 58,
      fx: 'TOP',
      fractalX1: 32,
      fractalX2: 55,
      rightX1: 55,
      rightX2: 58,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: 58,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [topJudgment],
    );
    final open = lines.where((l) => l.isOpenTip).toList();
    expect(open, isNotEmpty);
    expect(open.first.begin.barIdx, 44);
    expect(open.first.end.barIdx, 55);
    expect(
      open.any((l) => l.begin.barIdx == 44 && l.end.barIdx == 47),
      isFalse,
    );
  });

  test('确认刚成立开口：K0 右组=[confirm.x,confirm.x]（例 @8 → 终点 8）', () {
    final bars = _bars(12);
    bars[6] = KlineBar(
      idx: 6,
      timeMs: 6,
      timeText: 't6',
      open: 10,
      high: 11,
      low: 8.0,
      close: 9,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    bars[7] = KlineBar(
      idx: 7,
      timeMs: 7,
      timeText: 't7',
      open: 10,
      high: 12,
      low: 9.0,
      close: 11,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    const bottomConfirm = LevelConfirm(
      x: 8,
      fx: 'BOTTOM',
      value: 1,
      fractalX1: 6,
      fractalX2: 7,
      poleX: 6,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: 8,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [],
    );
    final open = lines.where((l) => l.isOpenTip).toList();
    expect(open, isNotEmpty);
    // 刚确认：右组=[8,8]，开口终点钉 8（不再扫 (6,8] 落在 7）
    expect(open.first.end.barIdx, 8);
  });

  test('判断开口：K0 右组不共用中组（right=[8,8]）', () {
    final bars = _bars(20);
    bars[5] = KlineBar(
      idx: 5,
      timeMs: 5,
      timeText: 't5',
      open: 10,
      high: 14,
      low: 9.5,
      close: 13,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    const bottomConfirm = LevelConfirm(
      x: 3,
      fx: 'BOTTOM',
      value: 1,
      fractalX1: 1,
      fractalX2: 3,
      poleX: 2,
    );
    const topJudgment = FractalJudgmentEvent(
      x: 8,
      fx: 'TOP',
      fractalX1: 6,
      fractalX2: 7,
      rightX1: 8,
      rightX2: 8,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: 8,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [topJudgment],
    );
    final open = lines.where((l) => l.isOpenTip).toList();
    expect(open.single.begin.barIdx, 5);
    expect(open.single.end.barIdx, 8);
  });

  test('computeDisplayBuildingLines：判断失效回退；开口从确认→asOf', () {
    final bars = _bars(12);
    bars[5] = KlineBar(
      idx: 5,
      timeMs: 5,
      timeText: 't5',
      open: 10,
      high: 14,
      low: 9.5,
      close: 13,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    const bottomConfirm = LevelConfirm(
      x: 3,
      fx: 'BOTTOM',
      value: 1,
      fractalX1: 1,
      fractalX2: 3,
      poleX: 2,
    );

    // 判断已从 live 消失 → 仅开口 confirm→asOf
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: 10,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [],
    );
    expect(lines.length, 1);
    expect(lines.first.isOpenTip, isTrue);
    expect(lines.first.beginSrc, 'confirm');
    expect(lines.first.endSrc, 'open');
    expect(lines.first.asSolid, isFalse);
  });

  test('computeDisplayBuildingLines：判断↔判断定格为实线', () {
    final bars = _bars(20);
    bars[5] = KlineBar(
      idx: 5,
      timeMs: 5,
      timeText: 't5',
      open: 10,
      high: 14,
      low: 9.5,
      close: 13,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    bars[10] = KlineBar(
      idx: 10,
      timeMs: 10,
      timeText: 't10',
      open: 10,
      high: 11,
      low: 7,
      close: 8,
      volume: 1,
      amount: 1,
      metrics: const {},
    );
    const bottomConfirm = LevelConfirm(
      x: 2,
      fx: 'BOTTOM',
      value: 1,
      fractalX1: 0,
      fractalX2: 2,
      poleX: 1,
    );
    final lines = computeDisplayBuildingLines(
      bars: bars,
      asOf: 15,
      virtualUnits: const [],
      frozenIdx: const {},
      levelConfirms: const [bottomConfirm],
      liveJudgments: const [
        FractalJudgmentEvent(x: 8, fx: 'TOP', fractalX1: 5, fractalX2: 5),
        FractalJudgmentEvent(x: 12, fx: 'BOTTOM', fractalX1: 10, fractalX2: 10),
      ],
    );
    final jj = lines.where(
      (l) => l.beginSrc == 'judgment' && l.endSrc == 'judgment',
    );
    expect(jj.isNotEmpty, isTrue);
    expect(jj.every((l) => l.asSolid), isTrue);
  });
}
