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

    final before = lookup.crosshairBiLines(0);
    expect(before.first, contains('首笔确认前'));

    final atConfirm = lookup.crosshairBiLines(1);
    expect(atConfirm.any((l) => l.startsWith('笔K线[序号]：#1')), isTrue);
    expect(atConfirm.any((l) => l.contains('笔确认当步')), isTrue);
    expect(atConfirm.any((l) => l.startsWith('笔K线[合并内序]：')), isTrue);
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
