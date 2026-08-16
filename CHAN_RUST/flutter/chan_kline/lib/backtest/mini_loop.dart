import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'account.dart';
import 'backtest_result.dart';
import 'cost_models.dart';
import 'cross_eval.dart';
import 'equity_curve.dart';
import 'order_models.dart';
import 'signal_event.dart';
import 'signal_normalize.dart';

export 'backtest_result.dart';

/// 兼容旧测试名：最小闭环现在直接产出完整回测结果。
typedef MiniLoopResult = BacktestResult;

KlineBar? k0BarAt(List<KlineBar> bars, int idx) {
  for (final b in bars) {
    if (b.idx == idx) return b;
  }
  return null;
}

/// 从已归一化信号跑：订单 → 下一根 K0 开盘成交 → 单仓多头 → 交易记录 → 净值/绩效。
/// displayKn 只留在信号上，成交钟永远是 K0。
BacktestResult runMiniLoopFromSignals({
  required List<SignalEvent> signals,
  required List<KlineBar> bars,
  int quantity = 100,
  double initialCash = 100000000,
  CommissionModel commission = const ZeroCommission(),
  SlippageModel slippage = const ZeroSlippage(),
}) {
  final tradable = [...signals.where((s) => s.isTradable)]
    ..sort((a, b) {
      final c = a.discoveryX.compareTo(b.discoveryX);
      if (c != 0) return c;
      // 同一根：先平后开（对齐金字塔：平仓写在开仓前面）
      final aw = a.side == TradeSide.sell ? 0 : 1;
      final bw = b.side == TradeSide.sell ? 0 : 1;
      return aw.compareTo(bw);
    });

  final orders = <Order>[];
  final fills = <Fill>[];
  final trades = <TradeRecord>[];
  final acc = AccountState(cash: initialCash);
  var oid = 0;
  var fid = 0;
  var tid = 0;
  SignalEvent? entrySig;
  Fill? entryFill;

  for (final sig in tradable) {
    final executeAt = sig.discoveryX + 1;
    var order = Order(
      orderId: 'O${++oid}',
      signalId: sig.signalId,
      side: sig.side!,
      quantity: quantity,
      createdAt: sig.discoveryX,
      executeAt: executeAt,
      status: OrderStatus.pending,
    );

    final next = k0BarAt(bars, executeAt);
    if (next == null) {
      orders.add(order.copyWith(
        status: OrderStatus.expired,
        rejectReason: '无未来K0',
      ));
      continue;
    }

    if (sig.side == TradeSide.buy) {
      if (acc.isLong) {
        orders.add(order.copyWith(
          status: OrderStatus.rejected,
          rejectReason: '已有仓位再次BUY',
        ));
        continue;
      }
      final raw = next.open;
      final price = slippage.apply(raw, side: TradeSide.buy);
      final fee = commission.fee(price: price, quantity: quantity);
      final cost = price * quantity + fee;
      if (cost > acc.cash) {
        orders.add(order.copyWith(
          status: OrderStatus.rejected,
          rejectReason: '现金不足',
        ));
        continue;
      }
      acc.cash -= cost;
      acc.positionQty = quantity;
      acc.avgCost = price;
      acc.realizedPnL -= fee; // 进场费当时已付
      final fill = Fill(
        fillId: 'F${++fid}',
        orderId: order.orderId,
        signalId: sig.signalId,
        side: TradeSide.buy,
        quantity: quantity,
        price: price,
        executeX: executeAt,
        commission: fee,
        slippage: price - raw, // 买滑点：成交价相对开盘的差
      );
      fills.add(fill);
      entrySig = sig;
      entryFill = fill;
      orders.add(order.copyWith(status: OrderStatus.filled));
      continue;
    }

    // SELL
    if (acc.isFlat) {
      orders.add(order.copyWith(
        status: OrderStatus.rejected,
        rejectReason: '没有仓位SELL',
      ));
      continue;
    }
    final raw = next.open;
    final price = slippage.apply(raw, side: TradeSide.sell);
    final fee = commission.fee(price: price, quantity: acc.positionQty);
    final qty = acc.positionQty;
    acc.cash += price * qty - fee;
    final gross = (price - acc.avgCost) * qty;
    acc.realizedPnL += gross - fee;
    final fill = Fill(
      fillId: 'F${++fid}',
      orderId: order.orderId,
      signalId: sig.signalId,
      side: TradeSide.sell,
      quantity: qty,
      price: price,
      executeX: executeAt,
      commission: fee,
      slippage: price - raw, // 卖滑点：成交价相对开盘的差（通常为负）
    );
    fills.add(fill);
    if (entrySig != null && entryFill != null) {
      final slipCash =
          entryFill.slippage * qty + (raw - price) * qty; // 两边滑点的现金成本
      trades.add(TradeRecord(
        tradeId: 'T${++tid}',
        entrySignalId: entrySig.signalId,
        exitSignalId: sig.signalId,
        entryX: entryFill.executeX,
        exitX: executeAt,
        entryPrice: entryFill.price,
        exitPrice: price,
        quantity: qty,
        grossPnL: gross,
        commission: entryFill.commission + fee,
        slippage: slipCash,
      ));
    }
    acc.positionQty = 0;
    acc.avgCost = 0;
    entrySig = null;
    entryFill = null;
    orders.add(order.copyWith(status: OrderStatus.filled));
  }

  final lastPrice = bars.isEmpty ? 0.0 : bars.last.close;
  OpenPosition? open;
  if (acc.isLong && entrySig != null && entryFill != null) {
    open = OpenPosition(
      entrySignalId: entrySig.signalId,
      entryX: entryFill.executeX,
      avgCost: acc.avgCost,
      quantity: acc.positionQty,
      marketValue: acc.marketValue(lastPrice),
      unrealizedPnL: acc.unrealizedPnL(lastPrice),
    );
  }

  return buildBacktestResult(
    signals: tradable,
    orders: orders,
    fills: fills,
    trades: trades,
    account: acc,
    bars: bars,
    initialCapital: initialCash,
    openPosition: open,
  );
}

/// CROSS → 归一化 → 最小闭环。布林必须读冻结仓，禁止现算第二套。
BacktestResult runMiniLongOnlyLoop({
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  required MathSeriesFreezeStore mathFreeze,
  required CrossRule buyRule,
  required CrossRule sellRule,
  int asOf = -1,
  int quantity = 100,
  double initialCash = 100000000,
  int bollN = 20,
  CommissionModel commission = const ZeroCommission(),
  SlippageModel slippage = const ZeroSlippage(),
}) {
  final cut = asOf < 0
      ? (bars.isEmpty ? 0 : bars.last.idx)
      : asOf;
  final buyRaw = evalCross(
    leftId: buyRule.leftId,
    rightId: buyRule.rightId,
    op: buyRule.op,
    asOf: cut,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    bollN: bollN,
  );
  final sellRaw = evalCross(
    leftId: sellRule.leftId,
    rightId: sellRule.rightId,
    op: sellRule.op,
    asOf: cut,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    bollN: bollN,
  );
  final signals = <SignalEvent>[
    if (buyRaw is CrossEvalOk)
      ...normalizeCrossSignals(hits: buyRaw.events, rule: buyRule),
    if (sellRaw is CrossEvalOk)
      ...normalizeCrossSignals(hits: sellRaw.events, rule: sellRule),
  ];
  return runMiniLoopFromSignals(
    signals: signals,
    bars: bars,
    quantity: quantity,
    initialCash: initialCash,
    commission: commission,
    slippage: slippage,
  );
}
