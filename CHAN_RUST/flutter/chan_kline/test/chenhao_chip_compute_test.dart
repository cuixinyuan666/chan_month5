import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/compute/chenhao_chip_compute.dart';
import 'package:chan_kline/ml/ml_feature_label.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(
  int idx,
  double close, {
  double? high,
  double? low,
  double volume = 100,
  double? amount,
}) {
  final h = high ?? close;
  final l = low ?? close;
  return KlineBar(
    idx: idx,
    timeMs: DateTime(2024, 1, 2, 9, 30).millisecondsSinceEpoch + idx * 60000,
    timeText: 't$idx',
    open: close,
    high: h,
    low: l,
    close: close,
    volume: volume,
    amount: amount ?? close * volume,
  );
}

void main() {
  setUp(ChenhaoSeriesCache.clear);

  test('获利盘和套牢盘加起来是 1', () {
    final series = computeChenhaoSeries([
      _bar(0, 10, high: 10.2, low: 9.8),
      _bar(1, 12, high: 12.2, low: 11.8),
    ]);
    final snap = series.atIdx(1)!;
    expect(snap.winner, isNotNull);
    expect(snap.trapped, isNotNull);
    expect(snap.winner! + snap.trapped!, closeTo(1, 1e-9));
    expect(snap.winner!, greaterThan(0.5));
  });

  test('无穷成本均线按换手替身递推，不用后面的 K', () {
    final first = computeChenhaoSeries([
      _bar(0, 10),
      _bar(1, 20),
    ]);
    final longer = computeChenhaoSeries([
      _bar(0, 10),
      _bar(1, 20),
      _bar(2, 40),
    ]);
    expect(first.atIdx(0)!.cycInf, closeTo(10, 1e-9));
    expect(first.atIdx(1)!.cycInf, closeTo(15, 1e-9));
    expect(longer.atIdx(1)!.cycInf, closeTo(15, 1e-9));
    expect(longer.atIdx(1)!.cysInf, closeTo((20 - 15) / 15, 1e-9));
  });

  test('价抬上去且量很安静时，90比3 为 1', () {
    final series = computeChenhaoSeries([
      _bar(0, 10, high: 10.2, low: 9.8, volume: 1000),
      _bar(1, 12, high: 12.2, low: 11.8, volume: 10),
    ]);
    final snap = series.atIdx(1)!;
    expect(snap.winner!, greaterThan(0.9));
    expect(snap.ninety3, 1);
  });

  test('回测能读到 K0 成本均线，读不到 K1', () {
    expect(lookupTradeVariable('MAIN.K0.CYC.5')!.expressionReady, isTrue);
    expect(lookupTradeVariable('SUB.K0.WINNER')!.displayName, 'K0获利盘');
    expect(lookupTradeVariable('SUB.K0.MYP')!.description, contains('近似'));
    expect(lookupTradeVariable('SUB.K1.WINNER'), isNull);
    final bars = [_bar(0, 10), _bar(1, 12)];
    final v = lookupTradeNumeric(
      variableId: 'MAIN.K0.CYC.5',
      asOf: 0,
      bars: bars,
    );
    expect(v.isAvailable, isTrue);
    expect(v.value, closeTo(10, 1e-9));
  });

  test('机器学习中文名能对上筹码字段', () {
    expect(MlFeatureLabel.toChinese('sub.chip_winner'), '获利盘');
    expect(MlFeatureLabel.toChinese('sub.cyc_inf'), '成本均线无穷');
    expect(MlFeatureLabel.toChinese('sub.chip_ninety3'), '90比3');
  });
}
