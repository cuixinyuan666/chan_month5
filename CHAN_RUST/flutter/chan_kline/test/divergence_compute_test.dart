import 'package:chan_kline/compute/divergence_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/divergence_algo.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/models/zs_frame.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int i, {double c = 10, double h = 11, double l = 9, double v = 100}) {
  return KlineBar(
    idx: i,
    timeMs: i * 60000,
    timeText: 't$i',
    open: c,
    high: h,
    low: l,
    close: c,
    volume: v,
    amount: v * c,
  );
}

List<KlineBar> _breakoutBars() {
  return [
    _bar(0, c: 10, h: 10.5, l: 8.0),
    _bar(1, c: 9.5, h: 10.0, l: 9.0),
    _bar(2, c: 9.6, h: 10.1, l: 9.1),
    _bar(3, c: 9.4, h: 9.9, l: 9.0),
    _bar(4, c: 8.0, h: 9.0, l: 7.0),
  ];
}

void main() {
  test('副图 catalog 含 12 背驰算法×层；主图无背驰', () {
    final sub = buildSubIndicatorCatalog(1);
    final divers = sub.where((e) => e.kind == SubIndicatorKind.divergence);
    expect(divers.length, 12 * 2);
    expect(
      divers.any((e) => e.diverAlgo == DivergenceAlgo.peak && e.kn == 0),
      isTrue,
    );
    expect(divers.any((e) => e.label == 'K0背驰_turnrate_avg'), isTrue);
    expect(
      SubIndicatorKind.divergence.categoryLabel,
      '背驰',
    );

    final main = buildMainIndicatorCatalog(1);
    expect(
      main.any((e) => e.label.contains('背驰')),
      isFalse,
    );
  });

  test('默认 K0 副图层全选不含背驰', () {
    final def = defaultSubIndicatorsK0();
    expect(
      def.any((e) => e.kind == SubIndicatorKind.divergence),
      isFalse,
    );
  });

  test('未突破 → diver=0 且 in/out/ratio 清空', () {
    final bars = _breakoutBars();
    final zsBreak = [
      const ZSFrame(
        x1: 1,
        x2: 3,
        high: 10.0,
        low: 9.0,
        level: 0,
        inSegIdx: 0,
        outSegIdx: 4,
      ),
    ];
    final zsNoBreak = [
      const ZSFrame(
        x1: 1,
        x2: 3,
        high: 10.0,
        low: 6.0,
        level: 0,
        inSegIdx: 0,
        outSegIdx: 4,
      ),
    ];

    final pass = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zsBreak,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
    );
    final peakPass = pass[DivergenceAlgo.peak]!;
    expect(peakPass.diverAt[4], 1);
    expect(peakPass.ratioAt[4], isNotNull);
    expect(peakPass.inAt[4], isNotNull);

    // 同 x 未突破事件：diver=0，变量同步清空（不 hold 旧值）
    final fail = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zsNoBreak,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
    );
    final peakFail = fail[DivergenceAlgo.peak]!;
    expect(peakFail.diverAt[4], 0);
    expect(peakFail.ratioAt[4], isNull);
    expect(peakFail.inAt[4], isNull);
    expect(peakFail.outAt[4], isNull);
  });

  test('严格背驰率：力度不弱 → diver=-1', () {
    final bars = _breakoutBars();
    final zs = [
      const ZSFrame(
        x1: 1,
        x2: 3,
        high: 10.0,
        low: 9.0,
        level: 0,
        inSegIdx: 0,
        outSegIdx: 4,
      ),
    ];
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zs,
      config: const MathIndicatorConfig(divergenceRate: 0.0001),
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[4], -1);
    expect(amp.ratioAt[4], isNotNull);
    expect(amp.ratioAt[4]!.isFinite, isTrue);
  });

  test('asOf 截断：事件后不可见', () {
    final bars = _breakoutBars();
    final zs = [
      const ZSFrame(
        x1: 1,
        x2: 3,
        high: 10.0,
        low: 9.0,
        level: 0,
        inSegIdx: 0,
        outSegIdx: 4,
      ),
    ];
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zs,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      asOf: 3,
    );
    final peak = map[DivergenceAlgo.peak]!;
    expect(peak.diverAt[3], 0);
    expect(peak.ratioAt[3], isNull);
  });

  test('12 算法均有序列；缺 turnrate 时 turnrate_avg diver=0', () {
    final bars = _breakoutBars();
    final zs = [
      const ZSFrame(
        x1: 1,
        x2: 3,
        high: 10.0,
        low: 9.0,
        level: 0,
        inSegIdx: 0,
        outSegIdx: 4,
      ),
    ];
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zs,
    );
    expect(map.length, 12);
    for (final a in DivergenceAlgoMeta.all) {
      expect(map[a], isNotNull);
      expect(map[a]!.diverAt.length, bars.length);
    }
    expect(map[DivergenceAlgo.turnrateAvg]!.diverAt[4], 0);
    expect(map[DivergenceAlgo.turnrateAvg]!.ratioAt[4], isNull);
  });
}
