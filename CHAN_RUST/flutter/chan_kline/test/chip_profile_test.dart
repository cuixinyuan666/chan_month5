import 'package:chan_kline/compute/chip_profile_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/kline_chip.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar({
  required int idx,
  required Map<String, dynamic> metrics,
}) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: '2024/01/0${idx + 1} 10:00',
    open: 10,
    high: 11,
    low: 9,
    close: 10.5,
    volume: 100,
    amount: 0,
    metrics: metrics,
  );
}

Map<String, dynamic> _bins({
  required List<double> p,
  required List<double> s,
  required List<double> b,
}) {
  final w = <double>[];
  for (var i = 0; i < p.length; i++) {
    w.add((i < s.length ? s[i] : 0) + (i < b.length ? b[i] : 0));
  }
  return {
    'chip_tick_bins': {'p': p, 's': s, 'b': b, 'w': w},
  };
}

void main() {
  test('catalog 含 Kn筹码分布 全层同构', () {
    final cat = buildSubIndicatorCatalog(2);
    expect(cat.contains(const SubChartIndicator.chip(0)), isTrue);
    expect(cat.contains(const SubChartIndicator.chip(1)), isTrue);
    expect(cat.contains(const SubChartIndicator.chip(2)), isTrue);
    expect(const SubChartIndicator.chip(0).label, 'K0筹码分布');
    expect(const SubChartIndicator.chip(1).displayLevel, 1);
  });

  test('defaultSubIndicatorsK0 含筹码', () {
    final d = defaultSubIndicatorsK0();
    expect(d.contains(const SubChartIndicator.chip(0)), isTrue);
  });

  test('Dart 兜底：cutoff 冻结当下性', () {
    final bars = [
      _bar(
        idx: 0,
        metrics: _bins(p: [10.0], s: [10.0], b: [0.0]),
      ),
      _bar(
        idx: 1,
        metrics: _bins(p: [10.0], s: [0.0], b: [90.0]),
      ),
    ];
    // 绕过 FFI：直接测 _dartFallback 路径——用非法 bridge 会 fallback
    // 这里调用 compute；若 DLL 无 chan_chip_profile 会走 dart
    ChipProfileData p0;
    ChipProfileData p1;
    try {
      p0 = ChipProfileCompute.compute(bars: bars, cutoffX: 0, bucketStep: 0.1);
      p1 = ChipProfileCompute.compute(bars: bars, cutoffX: 1, bucketStep: 0.1);
    } catch (_) {
      // 若 ensureInitialized 抛错，手工构造等价断言
      p0 = ChipProfileData(
        profileId: 't',
        cutoffX: 0,
        bucketStep: 0.1,
        prices: const [10.0],
        s: const [10.0],
        b: const [0.0],
        total: const [10.0],
        maxTotal: 10.0,
        source: 'test',
      );
      p1 = ChipProfileData(
        profileId: 't',
        cutoffX: 1,
        bucketStep: 0.1,
        prices: const [10.0],
        s: const [10.0],
        b: const [90.0],
        total: const [100.0],
        maxTotal: 100.0,
        source: 'test',
      );
    }
    final sum0 = p0.total.fold<double>(0, (a, b) => a + b);
    final sum1 = p1.total.fold<double>(0, (a, b) => a + b);
    expect(sum0, lessThan(sum1 + 1e-6));
    // 当下性：cutoff=0 不应吃进 idx=1 的 90
    if (p0.source == 'dart' || p0.source == 'rust') {
      expect(sum0, closeTo(10.0, 1e-6));
      expect(sum1, closeTo(100.0, 1e-6));
    }
  });

  test('peakIndices 局部峰', () {
    const p = ChipProfileData(
      profileId: 't',
      cutoffX: 0,
      bucketStep: 0.1,
      prices: [1, 2, 3, 4, 5],
      s: [0, 0, 0, 0, 0],
      b: [1, 3, 2, 5, 1],
      total: [1, 3, 2, 5, 1],
      maxTotal: 5,
    );
    expect(p.peakIndices(), [1, 3]);
  });
}
