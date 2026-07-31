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
  test('主图 catalog 含 Kn筹码分布 全层同构', () {
    final cat = buildMainIndicatorCatalog(2);
    expect(cat.contains(const MainChartIndicator.chip(0)), isTrue);
    expect(cat.contains(const MainChartIndicator.chip(1)), isTrue);
    expect(cat.contains(const MainChartIndicator.chip(2)), isTrue);
    expect(const MainChartIndicator.chip(0).label, 'K0筹码分布');
    expect(const MainChartIndicator.chip(1).displayLevel, 1);
    final lv0 = mainIndicatorsForLevel(0, cat);
    expect(lv0.contains(const MainChartIndicator.chip(0)), isTrue);
  });

  test('副图 catalog 不再含筹码', () {
    final cat = buildSubIndicatorCatalog(2);
    expect(cat.any((e) => e.label.contains('筹码')), isFalse);
  });

  test('defaultMainIndicatorsK0 含筹码', () {
    final d = defaultMainIndicatorsK0();
    expect(d.contains(const MainChartIndicator.chip(0)), isTrue);
  });

  test('Dart 兜底：cutoff 冻结当下性', () {
    final bars = [
      _bar(
        idx: 0,
        metrics: _bins(p: [10.0], s: [10.0], b: [0.0]),
      ),
      _bar(
        idx: 1,
        metrics: _bins(p: [11.0], s: [0.0], b: [20.0]),
      ),
    ];
    final a = ChipProfileCompute.compute(bars: bars, cutoffX: 0, bucketStep: 1);
    final b = ChipProfileCompute.compute(bars: bars, cutoffX: 1, bucketStep: 1);
    expect(a.isEmpty, isFalse);
    expect(b.maxTotal, greaterThanOrEqualTo(a.maxTotal));
    expect(a.cutoffX, 0);
    expect(b.cutoffX, 1);
  });
}
