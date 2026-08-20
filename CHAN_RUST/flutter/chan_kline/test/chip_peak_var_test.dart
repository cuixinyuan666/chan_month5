import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/chip_peak_store.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/profile_peak_classify.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: close,
    high: close + 1,
    low: close - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

void main() {
  test('K0筹码峰/笔数峰已登记；可与收盘比；K1仍只盘点', () {
    expect(lookupTradeVariable('SUB.K0.CHIP.PEAK.M1')!.expressionReady, isTrue);
    expect(lookupTradeVariable('SUB.K0.TICK.PEAK.P1')!.expressionReady, isTrue);
    expect(lookupTradeVariable('SUB.K0.CHIP.PEAK')!.clockFamily,
        lookupTradeVariable('RAW.K0.CLOSE')!.clockFamily);
    expect(lookupTradeVariable('SUB.K1.CHIP.PEAK')!.expressionReady, isFalse);
    expect(
      compileBinaryOp(
        leftId: 'RAW.K0.LOW',
        rightId: 'SUB.K0.TICK.PEAK.M1',
        op: TradeBinaryOp.gt,
      ),
      isA<TradeExprOk>(),
    );
  });

  test('框内多峰取离收盘更近；没有对应编号就是空', () {
    const rows = [
      ProfilePeakRow(nameSuffix: '-1', price: 9, b: 0, s: 0, g: 0),
      ProfilePeakRow(nameSuffix: '', price: 10.2, b: 0, s: 0, g: 0),
      ProfilePeakRow(nameSuffix: '', price: 11.8, b: 0, s: 0, g: 0),
      ProfilePeakRow(nameSuffix: '+1', price: 13, b: 0, s: 0, g: 0),
    ];
    expect(pickProfilePeakPrice(rows: rows, suffix: '-1', close: 11), 9);
    expect(pickProfilePeakPrice(rows: rows, suffix: '', close: 11), closeTo(10.2, 1e-12));
    expect(pickProfilePeakPrice(rows: rows, suffix: '+2', close: 11), isNull);
  });

  test('冻结后不沿用、不回写', () {
    final store = ChipPeakFreezeStore();
    store.ingestClassified(
      asOf: 4,
      kind: 'chip',
      rows: const [
        ProfilePeakRow(nameSuffix: '-1', price: 9.5, b: 0, s: 0, g: 0),
      ],
      close: 10,
    );
    store.ingestClassified(
      asOf: 5,
      kind: 'chip',
      rows: const [],
      close: 10,
    );
    final bars = [_bar(4, 10), _bar(5, 10)];
    final at4 = lookupTradeNumeric(
      variableId: 'SUB.K0.CHIP.PEAK.M1',
      asOf: 4,
      bars: bars,
      chipPeaks: store,
    );
    final at5 = lookupTradeNumeric(
      variableId: 'SUB.K0.CHIP.PEAK.M1',
      asOf: 5,
      bars: bars,
      chipPeaks: store,
    );
    expect(at4.value, closeTo(9.5, 1e-12));
    expect(at5.isUnavailable, isTrue);
    store.ingestClassified(
      asOf: 4,
      kind: 'chip',
      rows: const [
        ProfilePeakRow(nameSuffix: '-1', price: 1, b: 0, s: 0, g: 0),
      ],
      close: 10,
    );
    final at4again = lookupTradeNumeric(
      variableId: 'SUB.K0.CHIP.PEAK.M1',
      asOf: 4,
      bars: bars,
      chipPeaks: store,
    );
    expect(at4again.value, closeTo(9.5, 1e-12));
  });
}
