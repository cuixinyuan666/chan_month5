import 'package:chan_kline/backtest/backtest_result.dart';
import 'package:chan_kline/backtest/cost_models.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/backtest/mini_loop.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

/// 旧净值/绩效用例按次周期开盘成交编写。
const _nextOpenFill = TradeFillPriceMode.nextBarOpen;

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

List<KlineBar> _bars(int n, {double open = 10, double close = 10}) =>
    [for (var i = 0; i < n; i++) _bar(i, close, open: open)];

SignalEvent _sig({
  required String id,
  required TradeSide side,
  required int discoveryX,
}) {
  return SignalEvent(
    signalId: id,
    ruleId: side == TradeSide.buy ? 'test_buy' : 'test_sell',
    side: side,
    op: side == TradeSide.buy
        ? TradeBinaryOp.crossBelow
        : TradeBinaryOp.crossAbove,
    displayKn: 0,
    clockFamily: TradeClockFamily.zsMath,
    evalIndex: 0,
    discoveryX: discoveryX,
    availableAt: discoveryX,
    signalPrice: 10,
    source: 'test',
    leftValue: 10,
    rightValue: 10,
    leftId: 'RAW.K0.CLOSE',
    rightId: side == TradeSide.buy ? 'MAIN.K0.BOLL.DOWN' : 'MAIN.K0.BOLL.UP',
  );
}

EquityPoint _eqAt(BacktestResult r, int x) =>
    r.equityCurve.firstWhere((p) => p.x == x);

void _expectCurveIdentity(BacktestResult r, List<KlineBar> bars) {
  expect(r.equityCurve.length, bars.length);
  for (final p in r.equityCurve) {
    final bar = bars.firstWhere((b) => b.idx == p.x);
    expect(p.positionValue, closeTo(p.positionQty * bar.close, 1e-9));
    expect(p.equity, closeTo(p.cash + p.positionQty * bar.close, 1e-9),
        reason: 'x=${p.x} 净值必须含浮盈');
  }
  expect(r.metrics.finalEquity, closeTo(r.equityCurve.last.equity, 1e-9));
  expect(
    r.metrics.netProfit,
    closeTo(r.metrics.finalEquity - r.metrics.initialCapital, 1e-9),
  );
}

void main() {
  group('Phase3 回测结果引擎', () {
    test('一笔盈利交易：TradeRecord 与期末净值一致', () {
      final bars = [
        _bar(0, 10, open: 10),
        _bar(1, 10, open: 10), // BUY 成交
        _bar(2, 11, open: 11),
        _bar(3, 12, open: 12), // SELL 成交
        _bar(4, 12, open: 12),
      ];
      const cash = 100000.0;
      const qty = 100;
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's', side: TradeSide.sell, discoveryX: 2),
        ],
        bars: bars,
        quantity: qty,
        initialCash: cash,
        fillPriceMode: _nextOpenFill,
      );
      _expectCurveIdentity(r, bars);
      expect(r.closedTrades.length, 1);
      expect(r.openPosition, isNull);
      expect(r.trades.single.netPnL, closeTo((12 - 10) * qty, 1e-9));
      expect(r.metrics.winningTrades, 1);
      expect(r.metrics.losingTrades, 0);
      expect(r.metrics.netProfit, closeTo(200, 1e-9));
      expect(r.metrics.returnPct.isFinite, isTrue);
      expect(r.metrics.returnPct.value, closeTo(200 / cash, 1e-12));
      expect(_eqAt(r, 1).positionQty, 100);
      expect(_eqAt(r, 2).unrealizedPnL, closeTo(100, 1e-9)); // 持仓看到 11
      expect(_eqAt(r, 3).positionQty, 0);
      expect(_eqAt(r, 3).unrealizedPnL, 0);
    });

    test('一笔亏损交易', () {
      final bars = [
        _bar(0, 12, open: 12),
        _bar(1, 12, open: 12),
        _bar(2, 11, open: 11),
        _bar(3, 10, open: 10),
        _bar(4, 10, open: 10),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's', side: TradeSide.sell, discoveryX: 2),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: _nextOpenFill,
      );
      expect(r.trades.single.netPnL, closeTo(-200, 1e-9));
      expect(r.metrics.winningTrades, 0);
      expect(r.metrics.losingTrades, 1);
      expect(r.metrics.netProfit, closeTo(-200, 1e-9));
      expect(r.metrics.profitFactor.isFinite, isTrue);
      expect(r.metrics.profitFactor.value, closeTo(0, 1e-12));
      expect(r.metrics.payoffRatio.isUnavailable, isTrue);
      expect(r.metrics.averageWin.isUnavailable, isTrue);
    });

    test('多笔交易 + 连续盈亏 + 最大盈亏', () {
      // 赢、赢、亏、亏：开盘价走 10→12→15→14→12
      final opens = <double>[10, 10, 12, 12, 15, 15, 14, 14, 12, 12, 12];
      final bars = [for (var i = 0; i < opens.length; i++) _bar(i, opens[i], open: opens[i])];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 1), // 10→12 +200
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 2),
          _sig(id: 's2', side: TradeSide.sell, discoveryX: 3), // 12→15 +300
          _sig(id: 'b3', side: TradeSide.buy, discoveryX: 4),
          _sig(id: 's3', side: TradeSide.sell, discoveryX: 5), // 15→14 -100
          _sig(id: 'b4', side: TradeSide.buy, discoveryX: 6),
          _sig(id: 's4', side: TradeSide.sell, discoveryX: 7), // 14→12 -200
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: _nextOpenFill,
      );
      expect(r.trades.length, 4);
      expect(r.metrics.maxConsecutiveWins, 2);
      expect(r.metrics.maxConsecutiveLosses, 2);
      expect(r.metrics.largestWin.value, closeTo(300, 1e-9));
      expect(r.metrics.largestLoss.value, closeTo(-200, 1e-9));
      expect(r.metrics.winRate.value, closeTo(0.5, 1e-12));
      expect(r.metrics.grossProfit, closeTo(500, 1e-9));
      expect(r.metrics.grossLoss, closeTo(-300, 1e-9));
      expect(r.metrics.profitFactor.value, closeTo(500 / 300, 1e-12));
      expect(r.metrics.payoffRatio.value, closeTo((250) / 150, 1e-12));
      expect(r.metrics.expectancy.value, closeTo(200 / 4, 1e-12));
      expect(r.metrics.netProfit, closeTo(200, 1e-9));
    });

    test('中途持仓到最后：无闭合交易，净值含浮盈', () {
      final bars = [
        _bar(0, 10, open: 10),
        _bar(1, 10, open: 10), // BUY
        _bar(2, 11, open: 11),
        _bar(3, 13, open: 13),
      ];
      final r = runMiniLoopFromSignals(
        signals: [_sig(id: 'b', side: TradeSide.buy, discoveryX: 0)],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: _nextOpenFill,
      );
      _expectCurveIdentity(r, bars);
      expect(r.trades, isEmpty);
      expect(r.closedTrades, isEmpty);
      expect(r.openPosition, isNotNull);
      expect(r.openPosition!.entryX, 1);
      expect(r.openPosition!.unrealizedPnL, closeTo(300, 1e-9));
      expect(r.metrics.totalTrades, 0);
      expect(r.metrics.netProfit, closeTo(300, 1e-9)); // 浮盈进期末净值
      expect(r.metrics.winRate.isUnavailable, isTrue);
      expect(_eqAt(r, 3).unrealizedPnL, closeTo(300, 1e-9));
      expect(_eqAt(r, 3).positionQty, 100);
    });

    test('最后一根信号无法成交：净值不变', () {
      final bars = [_bar(0, 10, open: 10), _bar(1, 11, open: 11)];
      final r = runMiniLoopFromSignals(
        signals: [_sig(id: 'bLast', side: TradeSide.buy, discoveryX: 1)],
        bars: bars,
        initialCash: 50000,
        fillPriceMode: _nextOpenFill,
      );
      expect(r.fills, isEmpty);
      expect(r.trades, isEmpty);
      expect(r.openPosition, isNull);
      expect(r.orders.single.status, OrderStatus.expired);
      expect(r.metrics.netProfit, closeTo(0, 1e-9));
      expect(r.metrics.finalEquity, closeTo(50000, 1e-9));
      for (final p in r.equityCurve) {
        expect(p.positionQty, 0);
        expect(p.equity, closeTo(50000, 1e-9));
      }
    });

    test('无交易', () {
      final bars = _bars(5);
      final r = runMiniLoopFromSignals(
        signals: const [],
        bars: bars,
        initialCash: 80000,
      );
      expect(r.metrics.totalTrades, 0);
      expect(r.metrics.netProfit, 0);
      expect(r.metrics.profitFactor.isUnavailable, isTrue);
      expect(r.metrics.payoffRatio.isUnavailable, isTrue);
      expect(r.metrics.expectancy.isUnavailable, isTrue);
      expect(r.metrics.largestWin.isUnavailable, isTrue);
      expect(r.metrics.largestLoss.isUnavailable, isTrue);
      expect(r.metrics.maxDrawdown, 0);
      expect(r.openPosition, isNull);
    });

    test('只有盈利无亏损：盈亏因子/盈亏比 = ∞，不是 NaN', () {
      final bars = [
        for (var i = 0; i <= 8; i++) _bar(i, 10.0 + i, open: 10.0 + i),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 2),
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 4),
          _sig(id: 's2', side: TradeSide.sell, discoveryX: 6),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: _nextOpenFill,
      );
      expect(r.metrics.losingTrades, 0);
      expect(r.metrics.winningTrades, 2);
      expect(r.metrics.profitFactor.isInfinity, isTrue);
      expect(r.metrics.profitFactor.display, '∞');
      expect(r.metrics.payoffRatio.isInfinity, isTrue);
      expect(r.metrics.averageLoss.isUnavailable, isTrue);
      expect(r.metrics.averageLoss.display, '不可用');
      expect(r.metrics.largestLoss.isUnavailable, isTrue);
    });

    test('只有亏损无盈利：盈亏因子=0，盈亏比不可用', () {
      final bars = [
        for (var i = 0; i <= 8; i++) _bar(i, 20.0 - i, open: 20.0 - i),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 2),
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 4),
          _sig(id: 's2', side: TradeSide.sell, discoveryX: 6),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: _nextOpenFill,
      );
      expect(r.metrics.winningTrades, 0);
      expect(r.metrics.losingTrades, 2);
      expect(r.metrics.profitFactor.isFinite, isTrue);
      expect(r.metrics.profitFactor.value, closeTo(0, 1e-12));
      expect(r.metrics.payoffRatio.isUnavailable, isTrue);
      expect(r.metrics.averageWin.isUnavailable, isTrue);
    });

    test('手续费非 0：净利扣两边费用，净值对得上', () {
      final bars = [
        _bar(0, 100, open: 100),
        _bar(1, 100, open: 100),
        _bar(2, 120, open: 120),
        _bar(3, 120, open: 120),
      ];
      const qty = 100;
      const rate = 0.001;
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's', side: TradeSide.sell, discoveryX: 2),
        ],
        bars: bars,
        quantity: qty,
        initialCash: 100000,
        commission: const RateCommission(rate),
        fillPriceMode: _nextOpenFill,
      );
      final buyFee = 100 * qty * rate;
      final sellFee = 120 * qty * rate;
      final gross = (120 - 100) * qty;
      expect(r.trades.single.grossPnL, closeTo(gross, 1e-9));
      expect(r.trades.single.commission, closeTo(buyFee + sellFee, 1e-9));
      expect(r.trades.single.netPnL, closeTo(gross - buyFee - sellFee, 1e-9));
      expect(r.metrics.netProfit, closeTo(r.trades.single.netPnL, 1e-9));
      expect(_eqAt(r, 1).realizedPnL, closeTo(-buyFee, 1e-9));
      _expectCurveIdentity(r, bars);
    });

    test('滑点非 0：买加价卖减价，Fill.slippage 有符号', () {
      final bars = [
        _bar(0, 10, open: 10),
        _bar(1, 10, open: 10),
        _bar(2, 12, open: 12),
        _bar(3, 12, open: 12),
      ];
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's', side: TradeSide.sell, discoveryX: 2),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        slippage: const AbsoluteSlippage(0.5),
        fillPriceMode: _nextOpenFill,
      );
      expect(r.fills[0].price, closeTo(10.5, 1e-12));
      expect(r.fills[0].slippage, closeTo(0.5, 1e-12));
      expect(r.fills[1].price, closeTo(11.5, 1e-12));
      expect(r.fills[1].slippage, closeTo(-0.5, 1e-12));
      expect(r.trades.single.grossPnL, closeTo((11.5 - 10.5) * 100, 1e-9));
      expect(r.trades.single.slippage, closeTo(0.5 * 100 + 0.5 * 100, 1e-9));
    });

    test('TradeRecord 盈亏 ≠ EquityCurve 回撤：中途深亏后卖出仍盈利', () {
      // 100 买入，收到 50（净值大回撤），最后 120 卖出（闭合交易仍是赢）
      final bars = [
        _bar(0, 100, open: 100),
        _bar(1, 100, open: 100), // BUY @100
        _bar(2, 50, open: 90), // 收盘腰斩 → 浮亏回撤
        _bar(3, 50, open: 50),
        _bar(4, 50, open: 50),
        _bar(5, 120, open: 120), // SELL @120
        _bar(6, 120, open: 120),
      ];
      const qty = 100;
      const cash = 100000.0;
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b', side: TradeSide.buy, discoveryX: 0),
          _sig(id: 's', side: TradeSide.sell, discoveryX: 4),
        ],
        bars: bars,
        quantity: qty,
        initialCash: cash,
        fillPriceMode: _nextOpenFill,
      );
      _expectCurveIdentity(r, bars);
      expect(r.trades.single.netPnL, closeTo(2000, 1e-9)); // 交易赢
      expect(r.metrics.winningTrades, 1);
      final trough = _eqAt(r, 2);
      expect(trough.equity, closeTo(cash + (50 - 100) * qty, 1e-9));
      expect(r.metrics.maxDrawdown, closeTo(5000, 1e-9)); // 回撤 5000
      expect(r.metrics.peakEquity, closeTo(cash, 1e-9));
      expect(r.metrics.troughEquity, closeTo(95000, 1e-9));
      expect(r.metrics.maxDrawdownStartX, 1);
      expect(r.metrics.maxDrawdownEndX, 2);
      expect(r.metrics.recoveryX, 5); // 卖出后净值回到峰上
      expect(r.metrics.maxDrawdownPct, closeTo(5000 / cash, 1e-12));
      expect(r.metrics.drawdown, closeTo(r.metrics.maxDrawdown, 1e-12));
      // 两者各自正确、互不相等
      expect(r.trades.single.netPnL, isNot(closeTo(r.metrics.maxDrawdown, 1e-6)));
      expect(r.metrics.netProfit, closeTo(2000, 1e-9));
    });

    test('持仓未回本：recoveryX 为空，浮亏仍在净值里', () {
      final bars = [
        _bar(0, 100, open: 100),
        _bar(1, 100, open: 100),
        _bar(2, 80, open: 80),
        _bar(3, 70, open: 70),
      ];
      final r = runMiniLoopFromSignals(
        signals: [_sig(id: 'b', side: TradeSide.buy, discoveryX: 0)],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: _nextOpenFill,
      );
      expect(r.trades, isEmpty);
      expect(r.openPosition, isNotNull);
      expect(r.metrics.netProfit, closeTo(-3000, 1e-9));
      expect(r.metrics.maxDrawdown, closeTo(3000, 1e-9));
      expect(r.metrics.recoveryX, isNull);
    });
  });
}
