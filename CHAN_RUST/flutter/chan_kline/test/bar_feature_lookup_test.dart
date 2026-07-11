import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/bi_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
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

/// 模拟 Rust 逐K快照：首段确认前 unitIdx=null（purged 口径）
BarCrosshairFeature _feat(int idx, {int? unitIdx, int level2Unit = -1}) {
  return BarCrosshairFeature(
    idx: idx,
    weekday: '周一',
    mergeInnerSeq: 0,
    levels: [
      LevelSnap(
        level: 1,
        unitIdx: unitIdx,
        unitDir: 1,
        unitX1: unitIdx == null ? -1 : 0,
        unitX2: unitIdx == null ? -1 : idx,
        unitOpen: 10.0,
        unitHigh: 11.0,
        unitLow: 9.5,
        unitClose: 10.5,
        unitVolume: 300,
        mergeInnerSeq: 0,
        mergeCount: 1,
        combineHigh: 11.0,
        combineLow: 9.5,
      ),
      if (level2Unit >= 0)
        LevelSnap(
          level: 2,
          unitIdx: level2Unit,
          unitDir: -1,
          unitX1: 0,
          unitX2: idx,
          unitOpen: 10.0,
          unitHigh: 12.0,
          unitLow: 9.0,
          unitClose: 9.5,
          unitVolume: 900,
          mergeInnerSeq: 1,
          mergeCount: 2,
          combineHigh: 12.0,
          combineLow: 9.0,
        ),
    ],
  );
}

void main() {
  test('首段确认前：全部 N 段块输出占位行', () {
    final bars = _bars(3);
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      biConfirms: const [],
      barFeatures: [for (var i = 0; i < 3; i++) _feat(i)],
      levels: const [LevelBundle(level: 1), LevelBundle(level: 2)],
    );
    final lines = lookup.crosshairTooltipLines(0, timePart: '2024/01/01 09:00');
    expect(lines.first, '日期时间:2024/01/01 09:00 w1');
    expect(lines.any((l) => l == 'K1[序号]:首K1确认前'), isTrue);
    expect(lines.any((l) => l == 'K2[序号]:首K2确认前'), isTrue);
    expect(lines.any((l) => l.startsWith('K0合并分型确认:')), isTrue);
  });

  test('K1/K2 快照齐全时：Kn 块按模板输出序号/OHLCV/合并/确认', () {
    final bars = _bars(6);
    final feats = [for (var i = 0; i < 6; i++) _feat(i, unitIdx: i >= 2 ? 0 : null, level2Unit: i >= 4 ? 0 : -1)];
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      biConfirms: const [
        BiConfirmSignal(x: 2, fx: 'BOTTOM', value: 1, fractalX1: 1, fractalX2: 1),
      ],
      barFeatures: feats,
      levels: [
        const LevelBundle(level: 1, confirms: [
          LevelConfirm(x: 2, fx: 'BOTTOM', value: 1),
        ]),
        const LevelBundle(level: 2, confirms: [
          LevelConfirm(x: 4, fx: 'TOP', value: -1),
        ]),
      ],
    );

    final atConfirm = lookup.crosshairTooltipLines(2, timePart: '2024/01/01 09:02');
    // K0合并分型确认 = K1 端点确认（旧口径 bi_confirm）
    expect(atConfirm.any((l) => l == 'K0合并分型确认:1'), isTrue);
    // K1 块顺序：序号 → OHLCV → 合并序 → 合并H/L → 合并分型确认
    final seqIdx = atConfirm.indexWhere((l) => l.startsWith('K1[序号]:0'));
    final ohlcvIdx = atConfirm.indexWhere((l) => l.startsWith('K1:O'));
    final mergeSeqIdx = atConfirm.indexWhere((l) => l.startsWith('K1合并K1序:'));
    final mergeHlIdx = atConfirm.indexWhere((l) => l.startsWith('K1合并:H'));
    expect(seqIdx, greaterThanOrEqualTo(0));
    expect(seqIdx, lessThan(ohlcvIdx));
    expect(ohlcvIdx, lessThan(mergeSeqIdx));
    expect(mergeSeqIdx, lessThan(mergeHlIdx));

    // x=4 当步：K1 块「合并分型确认」= K2 确认值 -1
    final at2 = lookup.crosshairTooltipLines(4, timePart: '2024/01/01 09:04');
    expect(at2.any((l) => l == 'K1合并分型确认:-1'), isTrue);
    expect(at2.any((l) => l.startsWith('K2[序号]:0')), isTrue);
    expect(at2.any((l) => l.startsWith('K2合并K2序:1')), isTrue);
  });
}
