import 'package:chan_kline/backtest/mini_loop.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/signal_normalize.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close, {double? open}) {
  final o = open ?? close;
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: o,
    high: (close > o ? close : o) + 1,
    low: (close < o ? close : o) - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

SignalEvent _sig({
  required String id,
  required TradeSide side,
  required int discoveryX,
  int displayKn = 0,
  double price = 10,
}) {
  return SignalEvent(
    signalId: id,
    ruleId: side == TradeSide.buy ? 'test_buy' : 'test_sell',
    side: side,
    op: side == TradeSide.buy
        ? TradeBinaryOp.crossBelow
        : TradeBinaryOp.crossAbove,
    displayKn: displayKn,
    clockFamily: TradeClockFamily.zsMath,
    evalIndex: 0,
    discoveryX: discoveryX,
    availableAt: discoveryX,
    signalPrice: price,
    source: 'test',
    leftValue: price,
    rightValue: price,
    leftId: 'RAW.K$displayKn.CLOSE',
    rightId: side == TradeSide.buy
        ? 'MAIN.K$displayKn.BOLL.DOWN'
        : 'MAIN.K$displayKn.BOLL.UP',
  );
}

void main() {
  group('最小闭环：信号→订单→次周期K0开盘→持仓→交易记录', () {
    test('BUY X → X+1 开盘成交 → SELL Y → Y+1 开盘成交 → 一笔 TradeRecord', () {
      final bars = [
        for (var i = 0; i <= 10; i++)
          _bar(i, 10.0 + i, open: 100.0 + i),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 2, price: 12),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 6, price: 16),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(r.fills.length, 2);
      expect(r.fills[0].side, TradeSide.buy);
      expect(r.fills[0].executeX, 3);
      expect(r.fills[0].price, closeTo(103, 1e-12)); // K0[3].open
      expect(r.fills[1].side, TradeSide.sell);
      expect(r.fills[1].executeX, 7);
      expect(r.fills[1].price, closeTo(107, 1e-12));
      expect(r.trades.length, 1);
      final t = r.trades.single;
      expect(t.entrySignalId, 'b1');
      expect(t.exitSignalId, 's1');
      expect(t.entryX, 3);
      expect(t.exitX, 7);
      expect(t.quantity, 100);
      expect(t.grossPnL, closeTo((107 - 103) * 100, 1e-9));
      expect(t.commission, 0);
      expect(r.account.isFlat, isTrue);
      expect(r.account.realizedPnL, closeTo(t.grossPnL, 1e-9));
    });

    test('最后一根 K0 产生 BUY + 次周期开盘 → 不得虚构成交', () {
      final bars = [_bar(0, 10, open: 10), _bar(1, 11, open: 11)];
      final r = runMiniLoopFromSignals(
        signals: [_sig(id: 'bLast', side: TradeSide.buy, discoveryX: 1)],
        bars: bars,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(r.fills, isEmpty);
      expect(r.trades, isEmpty);
      expect(r.orders.single.status, OrderStatus.expired);
      expect(r.orders.single.rejectReason, '无未来K0');
      expect(r.account.isFlat, isTrue);
    });

    test('没有仓位 SELL → 不成交', () {
      final bars = [_bar(0, 10, open: 10), _bar(1, 11, open: 11), _bar(2, 12, open: 12)];
      final r = runMiniLoopFromSignals(
        signals: [_sig(id: 's0', side: TradeSide.sell, discoveryX: 0)],
        bars: bars,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(r.fills, isEmpty);
      expect(r.trades, isEmpty);
      expect(r.orders.single.status, OrderStatus.rejected);
      expect(r.orders.single.rejectReason, '没有仓位SELL');
    });

    test('已有仓位再次 BUY → 第一版拒绝', () {
      final bars = [
        for (var i = 0; i <= 6; i++) _bar(i, 10, open: 10.0 + i),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 1),
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 3),
        ],
        bars: bars,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(r.fills.length, 1);
      expect(r.fills.single.executeX, 2);
      expect(r.orders.where((o) => o.status == OrderStatus.rejected).length, 1);
      expect(
        r.orders.firstWhere((o) => o.status == OrderStatus.rejected).rejectReason,
        '已有仓位再次BUY',
      );
      expect(r.account.isLong, isTrue);
      expect(r.trades, isEmpty);
    });

    test('同一根既买又卖：先平后开（空仓只开，有仓先平再开）', () {
      final bars = [
        for (var i = 0; i <= 12; i++) _bar(i, 10, open: 10.0 + i),
      ];
      // 7 空仓：卖拒绝、买成交在 8；8 有仓：先卖平再买开，都在 9 成交
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b7', side: TradeSide.buy, discoveryX: 7),
          _sig(id: 's7', side: TradeSide.sell, discoveryX: 7),
          _sig(id: 'b8', side: TradeSide.buy, discoveryX: 8),
          _sig(id: 's8', side: TradeSide.sell, discoveryX: 8),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(
        r.orders
            .firstWhere((o) => o.signalId == 's7')
            .status,
        OrderStatus.rejected,
      );
      expect(
        r.orders.firstWhere((o) => o.signalId == 's7').rejectReason,
        '没有仓位SELL',
      );
      expect(r.fills.length, 3);
      expect(r.fills[0].signalId, 'b7');
      expect(r.fills[0].side, TradeSide.buy);
      expect(r.fills[0].executeX, 8);
      expect(r.fills[1].signalId, 's8');
      expect(r.fills[1].side, TradeSide.sell);
      expect(r.fills[1].executeX, 9);
      expect(r.fills[2].signalId, 'b8');
      expect(r.fills[2].side, TradeSide.buy);
      expect(r.fills[2].executeX, 9);
      expect(r.trades.length, 1);
      expect(r.trades.single.entryX, 8);
      expect(r.trades.single.exitX, 9);
      expect(r.account.isLong, isTrue);
    });

    test('K1 CROSS 仍映射到真实 K0 executionX；displayKn 不改变成交钟', () {
      final bars = [
        for (var i = 0; i <= 20; i++) _bar(i, 10, open: 50.0 + i),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(
            id: 'k1b',
            side: TradeSide.buy,
            discoveryX: 10,
            displayKn: 1,
            price: 8,
          ),
          _sig(
            id: 'k1s',
            side: TradeSide.sell,
            discoveryX: 14,
            displayKn: 1,
            price: 12,
          ),
        ],
        bars: bars,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(r.signals.singleWhere((s) => s.signalId == 'k1b').displayKn, 1);
      expect(r.fills[0].executeX, 11); // 10+1，K0 不是 K1
      expect(r.fills[0].price, closeTo(61, 1e-12));
      expect(r.fills[1].executeX, 15);
      expect(r.trades.single.entryX, 11);
      expect(r.trades.single.exitX, 15);
    });
  });

  group('默认：本周期收盘价成交', () {
    test('BUY X → X 收盘成交；最后一根也能成交', () {
      final bars = [_bar(0, 10, open: 10), _bar(1, 11, open: 11)];
      final r = runMiniLoopFromSignals(
        signals: [_sig(id: 'bLast', side: TradeSide.buy, discoveryX: 1)],
        bars: bars,
      );
      expect(r.fills.single.executeX, 1);
      expect(r.fills.single.price, closeTo(11, 1e-12));
      expect(r.account.isLong, isTrue);
    });

    test('BUY X → X 收盘 → SELL Y → Y 收盘', () {
      final bars = [
        for (var i = 0; i <= 6; i++) _bar(i, 10.0 + i, open: 100.0 + i),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 2, price: 12),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 5, price: 15),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
      );
      expect(r.fills[0].executeX, 2);
      expect(r.fills[0].price, closeTo(12, 1e-12));
      expect(r.fills[1].executeX, 5);
      expect(r.fills[1].price, closeTo(15, 1e-12));
      expect(r.trades.single.grossPnL, closeTo((15 - 12) * 100, 1e-9));
    });
  });

  group('BOLL CROSS 真实闭环', () {
    test('K0 收下穿下轨再上穿上轨：下一根开盘成交并合成 TradeRecord', () {
      // 先走一段高位让布林跟上，再砸下去穿下轨，再拉上去穿上轨
      final bars = <KlineBar>[
        for (var i = 0; i < 24; i++) _bar(i, 100, open: 100),
        for (var i = 24; i < 40; i++) _bar(i, 40, open: 41),
        for (var i = 40; i < 56; i++) _bar(i, 180, open: 179),
      ];
      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(bollN: 20),
        maxDisplayKn: 0,
        asOf: bars.last.idx,
      );
      final r = runMiniLongOnlyLoop(
        bars: bars,
        mathFreeze: store,
        buyRule: CrossRule.bollBuy(),
        sellRule: CrossRule.bollSell(),
        quantity: 100,
        initialCash: 1000000,
        bollN: 20,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(r.signals.where((s) => s.side == TradeSide.buy), isNotEmpty);
      expect(r.fills.where((f) => f.side == TradeSide.buy), isNotEmpty);
      final buyFill = r.fills.firstWhere((f) => f.side == TradeSide.buy);
      final buySig = r.signals.firstWhere((s) => s.signalId == buyFill.signalId);
      expect(buyFill.executeX, buySig.discoveryX + 1);
      expect(buyFill.price, k0BarAt(bars, buyFill.executeX)!.open);
      expect(buySig.availableAt, buySig.discoveryX);
      expect(r.trades, isNotEmpty);
      final t = r.trades.first;
      expect(t.exitX, t.entryX + (t.exitX - t.entryX));
      expect(t.exitX > t.entryX, isTrue);
      expect(t.commission, 0);
    });
  });
}
