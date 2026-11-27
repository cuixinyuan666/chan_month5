import 'package:chan_kline/compute/kline_period_aggregate.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(
  int i, {
  required double open,
  required double high,
  required double low,
  required double close,
}) {
  return KlineBar(
    idx: i,
    timeMs: 1000 * 60 * i,
    timeText: '2026/07/10 09:${i.toString().padLeft(2, '0')}:00',
    open: open,
    high: high,
    low: low,
    close: close,
    volume: 1,
    amount: 10,
  );
}

void main() {
  group('周期 → 1 分钟根数映射', () {
    test('默认周期与更大周期都有一一根数', () {
      expect(oneMinuteCountForPeriod('1m'), 1);
      expect(oneMinuteCountForPeriod('5m'), 5);
      expect(oneMinuteCountForPeriod('15m'), 15);
      expect(oneMinuteCountForPeriod('30m'), 30);
      expect(oneMinuteCountForPeriod('60m'), 60);
      expect(oneMinuteCountForPeriod('2h'), 120);
      expect(oneMinuteCountForPeriod('4h'), 240);
      expect(oneMinuteCountForPeriod('1d'), 240);
      expect(oneMinuteCountForPeriod('1w'), 1200);
      expect(oneMinuteCountForPeriod('1mon'), 4800);
    });

    test('未知周期按 1 分钟处理', () {
      expect(oneMinuteCountForPeriod('unknown'), 1);
    });
  });

  group('1 分钟聚合为高周期', () {
    final bars = <KlineBar>[
      _bar(0, open: 10, high: 12, low: 9, close: 11),
      _bar(1, open: 11, high: 15, low: 10, close: 14),
      _bar(2, open: 14, high: 16, low: 13, close: 15),
      _bar(3, open: 15, high: 17, low: 14, close: 16),
      _bar(4, open: 16, high: 18, low: 15, close: 17),
    ];

    test('5 根 1m 聚成 1 根 5m，OHLC 取首开/终收/组内高低', () {
      final out = aggregateKlineBarsByPeriod(bars, '5m');
      expect(out, hasLength(1));
      expect(out.single.open, 10, reason: '开 = 组内第一根开');
      expect(out.single.close, 17, reason: '收 = 组内最后一根收');
      expect(out.single.high, 18, reason: '高 = 组内最高');
      expect(out.single.low, 9, reason: '低 = 组内最低');
      expect(out.single.volume, 5, reason: '成交量累加');
      expect(out.single.amount, 50, reason: '成交额累加');
    });

    test('15 根 1m 聚成 1 根 15m', () {
      final many = [
        for (var i = 0; i < 15; i++)
          _bar(i,
              open: 10.0 + i,
              high: 11.0 + i,
              low: 9.0 + i,
              close: 10.5 + i),
      ];
      final out = aggregateKlineBarsByPeriod(many, '15m');
      expect(out, hasLength(1));
      expect(out.single.open, 10);
      expect(out.single.close, 24.5);
      expect(out.single.high, 25);
      expect(out.single.low, 9);
    });

    test('末尾不足一组也出一根（构建中），不丢数据', () {
      final twelve = [
        for (var i = 0; i < 12; i++)
          _bar(i, open: 10, high: 11, low: 9, close: 10),
      ];
      final out = aggregateKlineBarsByPeriod(twelve, '5m');
      expect(out, hasLength(3));
      expect(out.last.volume, 2, reason: '末组只有 2 根');
    });

    test('1m 原样返回，不复制列表', () {
      expect(aggregateKlineBarsByPeriod(bars, '1m'), same(bars));
    });

    test('空列表原样返回', () {
      expect(aggregateKlineBarsByPeriod(const <KlineBar>[], '5m'), isEmpty);
    });
  });
}
