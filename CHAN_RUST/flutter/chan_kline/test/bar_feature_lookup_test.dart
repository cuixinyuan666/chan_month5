import 'package:chan_kline/compute/bar_feature_compute.dart';
import 'package:chan_kline/compute/bi_crosshair_compute.dart';
import 'package:chan_kline/compute/bi_confirm_compute.dart';
import 'package:chan_kline/compute/default_bi_compute.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/bi_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
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
  test('purged：首笔确认前 tooltip 占位，确认当步有笔K字段', () {
    final bars = _bars(8);
    final confirms = [
      const BiConfirmSignal(
        x: 1,
        fx: 'BOTTOM',
        value: 1,
        fractalX1: 0,
        fractalX2: 1,
      ),
    ];
    final segments = computeBiSegments(bars, confirms);
    var features = computeBarCrosshairFeatures(bars, const []);
    features = enrichBiCrosshairFields(
      bars,
      features,
      segments,
      confirms,
      'purged',
    );

    expect(features[0].biIdx, isNull);
    expect(features[1].biIdx, 0);
    expect(features[1].biHigh, greaterThan(0));

    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      biConfirms: confirms,
      barFeatures: features,
      biSegments: segments,
    );

    final before = lookup.crosshairTooltipLines(0, timePart: '2024/01/01 09:00');
    expect(before.any((l) => l.contains('首笔确认前')), isTrue);
    expect(before.any((l) => l.startsWith('K线合并K线序:')), isTrue);
    expect(before.any((l) => l.startsWith('K线合并分型确认:')), isTrue);
    expect(BarFeatureLookup.weekdayToW('周五'), 'w5');
    expect(BarFeatureLookup.weekdayToW('周日'), 'w7');
    expect(before.first, '日期时间:2024/01/01 09:00 w1');

    final atConfirm = lookup.crosshairTooltipLines(1, timePart: '2024/01/01 09:01');
    final biSeqIdx = atConfirm.indexWhere((l) => l.startsWith('笔K线[序号]:'));
    final biOhlcvIdx = atConfirm.indexWhere((l) => l.startsWith('笔K线:O'));
    final biMergeSeqIdx = atConfirm.indexWhere((l) => l.startsWith('笔K线合并笔K线序:'));
    expect(biSeqIdx, lessThan(biOhlcvIdx));
    expect(biOhlcvIdx, lessThan(biMergeSeqIdx));
    expect(atConfirm.any((l) => l.startsWith('笔K线[序号]:0')), isTrue);
    expect(atConfirm.any((l) => l.startsWith('K线合并分型确认:1')), isTrue);
    expect(atConfirm.any((l) => l.startsWith('K线合并:H')), isTrue);
    expect(atConfirm.any((l) => l.startsWith('笔K线合并:H')), isTrue);
  });

  test('第二笔 K线合并分型确认当步展示新起 provisional 笔K字段', () {
    final bars = _bars(10);
    final confirms = [
      const BiConfirmSignal(
        x: 2,
        fx: 'BOTTOM',
        value: 1,
        fractalX1: 1,
        fractalX2: 1,
      ),
      const BiConfirmSignal(
        x: 5,
        fx: 'TOP',
        value: -1,
        fractalX1: 4,
        fractalX2: 4,
      ),
    ];
    final segments = computeBiSegments(bars, confirms);
    var features = computeBarCrosshairFeatures(bars, const []);
    features = enrichBiCrosshairFields(
      bars,
      features,
      segments,
      confirms,
      'purged',
    );
    expect(features[5].biIdx, 1);
    expect(features[5].biHigh, greaterThan(0));
    expect(features[5].biCombineHigh, greaterThan(0));

    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      biConfirms: confirms,
      barFeatures: features,
      biSegments: segments,
    );
    final atSecond = lookup.crosshairTooltipLines(5, timePart: '2024/01/01 09:05');
    expect(atSecond.any((l) => l.startsWith('K线合并分型确认:-1')), isTrue);
    expect(atSecond.any((l) => l.startsWith('笔K线[序号]:1')), isTrue);
    expect(atSecond.any((l) => l.startsWith('笔K线:O')), isTrue);
    expect(atSecond.any((l) => l.startsWith('笔K线合并笔K线序:')), isTrue);
    expect(atSecond.any((l) => l.startsWith('笔K线合并:H')), isTrue);
  });

  test('pending 展示策略不影响 purged 十字线笔K字段', () {
    final bars = _bars(5);
    final confirms = computeBiConfirmSignals(bars);
    final segments = computeBiSegments(bars, confirms);
    var features = computeBarCrosshairFeatures(bars, const []);
    // 模拟 bridge：十字线固定 purged
    features = enrichBiCrosshairFields(
      bars,
      features,
      segments,
      confirms,
      'purged',
    );
    if (confirms.isEmpty) {
      expect(features.every((f) => f.biIdx == null), isTrue);
    } else {
      final firstX = confirms.first.x;
      for (var i = 0; i < firstX; i++) {
        expect(features[i].biIdx, isNull, reason: 'idx=$i');
      }
    }
  });
}
