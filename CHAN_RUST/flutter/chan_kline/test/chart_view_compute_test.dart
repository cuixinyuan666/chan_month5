import 'package:chan_kline/compute/bi_virtual_bar_view_compute.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
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
  test('as-of 组装：冻结段查表 + 当步快照进行中笔（含半侧衔接）', () {
    final bars = _bars(10);
    // Rust 冻结段：1段#0（K1 极点 → K4 极点，x=5 冻结）
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
    // 当步快照：x=5 新起进行中笔 idx=1（K4 极点 → K5）
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

    final atConfirm = asOfBiVirtualBars(
      bars: bars,
      levels: levels,
      barFeatures: feats,
      defaultBiPolicy: 'purged',
      asOf: 5,
    );
    expect(atConfirm.length, 2, reason: '确认当步应有冻结笔+新进行中笔');
    expect(atConfirm[0].idx, 0);
    expect(atConfirm[0].high, 10.9);
    expect(atConfirm[1].idx, 1);
    expect(atConfirm[1].x1, 4);
    expect(atConfirm[1].x2, 5);

    final views = buildBiVirtualBarViews(atConfirm);
    expect(views[0].endAtLeftHalf, isTrue);
    expect(views[1].startAtRightHalf, isTrue);
    expect(views[0].viewX2, views[1].viewX1);
  });

  test('首笔确认前：pending 给默认笔，purged 为空', () {
    final bars = _bars(4);
    final feats = [
      for (var i = 0; i < 4; i++)
        BarCrosshairFeature(idx: i, weekday: '周一', mergeInnerSeq: 0, levels: const [
          LevelSnap(level: 1),
        ]),
    ];
    final pending = asOfBiVirtualBars(
      bars: bars,
      levels: const [LevelBundle(level: 1)],
      barFeatures: feats,
      defaultBiPolicy: 'pending',
      asOf: 3,
    );
    expect(pending.length, 1);
    expect(pending.first.x1, 0);
    expect(pending.first.x2, 3);

    final purged = asOfBiVirtualBars(
      bars: bars,
      levels: const [LevelBundle(level: 1)],
      barFeatures: feats,
      defaultBiPolicy: 'purged',
      asOf: 3,
    );
    expect(purged, isEmpty);
  });
}
