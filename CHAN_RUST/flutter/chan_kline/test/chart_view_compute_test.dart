import 'package:chan_kline/compute/k1_bar_view_compute.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
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
}
