import 'package:chan_kline/compute/chip_profile_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar({
  required int idx,
  required Map<String, dynamic> metrics,
  int? timeMs,
  String? timeText,
}) {
  return KlineBar(
    idx: idx,
    timeMs: timeMs ?? idx * 60000,
    timeText: timeText ?? '2024/01/0${idx + 1} 10:00',
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
  List<double>? w,
}) {
  return {
    'chip_tick_bins': {'p': p, 's': s, 'b': b, 'w': w ?? const <double>[]},
  };
}

void main() {
  test('主图 catalog 不再含筹码分布（已迁设置·仅K0）', () {
    final cat = buildMainIndicatorCatalog(2);
    expect(cat.any((e) => e.label.contains('筹码')), isFalse);
    final lv0 = mainIndicatorsForLevel(0, cat);
    expect(lv0.any((e) => e.label.contains('筹码')), isFalse);
  });

  test('副图 catalog 不再含筹码', () {
    final cat = buildSubIndicatorCatalog(2);
    expect(cat.any((e) => e.label.contains('筹码')), isFalse);
  });

  test('defaultMainIndicatorsK0 不再含筹码', () {
    final d = defaultMainIndicatorsK0();
    expect(d.any((e) => e.label.contains('筹码')), isFalse);
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

  test('灰度 w 独立分量：total=s+b+w', () {
    final bars = [
      _bar(
        idx: 0,
        timeMs: 1000,
        timeText: '2024/01/02 10:00',
        metrics: _bins(p: [10.0], s: [10.0], b: [5.0], w: [3.0]),
      ),
    ];
    final p = ChipProfileCompute.compute(bars: bars, cutoffX: 0, bucketStep: 1);
    expect(p.w, [3.0]);
    expect(p.total, [18.0]);
    expect(p.s, [10.0]);
    expect(p.b, [5.0]);
  });

  test('旧「b 空用 w 当买」已删除：w 只进灰度', () {
    final bars = [
      _bar(
        idx: 0,
        timeMs: 2000,
        timeText: '2024/01/03 10:00',
        metrics: _bins(p: [10.0], s: const [], b: const [], w: [7.0]),
      ),
    ];
    final p = ChipProfileCompute.compute(bars: bars, cutoffX: 0, bucketStep: 1);
    expect(p.b, [0.0]);
    expect(p.w, [7.0]);
    expect(p.total, [7.0]);
  });
}
