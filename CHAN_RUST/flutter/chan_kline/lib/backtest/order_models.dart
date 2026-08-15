import 'signal_event.dart';

enum OrderType { market }

enum OrderStatus {
  pending,
  filled,
  /// 显式拒绝：已有仓再买 / 无仓再卖 / 现金不足
  rejected,
  /// 没有下一根 K0，不能拿最后收盘价虚构
  expired,
}

/// 市价单（第一版只有这一种）。
class Order {
  final String orderId;
  final String signalId;
  final TradeSide side;
  final OrderType type;
  final int quantity;
  /// 信号被知道的 K0
  final int createdAt;
  /// 计划成交的 K0（discoveryX+1）
  final int executeAt;
  final OrderStatus status;
  final String? rejectReason;

  const Order({
    required this.orderId,
    required this.signalId,
    required this.side,
    this.type = OrderType.market,
    required this.quantity,
    required this.createdAt,
    required this.executeAt,
    required this.status,
    this.rejectReason,
  });

  Order copyWith({OrderStatus? status, String? rejectReason}) {
    return Order(
      orderId: orderId,
      signalId: signalId,
      side: side,
      type: type,
      quantity: quantity,
      createdAt: createdAt,
      executeAt: executeAt,
      status: status ?? this.status,
      rejectReason: rejectReason ?? this.rejectReason,
    );
  }
}

/// 成交。手续费/滑点接口预留，这阶段默认 0。
class Fill {
  final String fillId;
  final String orderId;
  final String signalId;
  final TradeSide side;
  final int quantity;
  final double price;
  final int executeX;
  final double commission;
  final double slippage;

  const Fill({
    required this.fillId,
    required this.orderId,
    required this.signalId,
    required this.side,
    required this.quantity,
    required this.price,
    required this.executeX,
    this.commission = 0,
    this.slippage = 0,
  });
}

class TradeRecord {
  final String tradeId;
  final String entrySignalId;
  final String exitSignalId;
  final int entryX;
  final int exitX;
  final double entryPrice;
  final double exitPrice;
  final int quantity;
  final double grossPnL;
  final double commission;
  final double slippage;

  const TradeRecord({
    required this.tradeId,
    required this.entrySignalId,
    required this.exitSignalId,
    required this.entryX,
    required this.exitX,
    required this.entryPrice,
    required this.exitPrice,
    required this.quantity,
    required this.grossPnL,
    this.commission = 0,
    this.slippage = 0,
  });

  /// 闭合交易净盈亏（毛利减买卖两边手续费）。未平仓没有这笔。
  double get netPnL => grossPnL - commission;
}
