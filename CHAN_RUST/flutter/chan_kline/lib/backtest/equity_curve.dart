/// 指标三态：有限数 / 正无穷 / 不可用。禁止 NaN。
enum MetricKind { finite, infinity, unavailable }

class MetricNum {
  final MetricKind kind;
  final double? value;

  const MetricNum.finite(double v)
      : kind = MetricKind.finite,
        value = v;

  /// 正无穷（例如只有盈利没有亏损时的盈亏因子）
  const MetricNum.infinity()
      : kind = MetricKind.infinity,
        value = null;

  const MetricNum.unavailable()
      : kind = MetricKind.unavailable,
        value = null;

  bool get isFinite => kind == MetricKind.finite;
  bool get isInfinity => kind == MetricKind.infinity;
  bool get isUnavailable => kind == MetricKind.unavailable;

  /// UI 不得对 NaN 猜意图：∞ / 不可用 / 有限数。
  String get display {
    switch (kind) {
      case MetricKind.infinity:
        return '∞';
      case MetricKind.unavailable:
        return '不可用';
      case MetricKind.finite:
        return '$value';
    }
  }

  @override
  bool operator ==(Object other) =>
      other is MetricNum && other.kind == kind && other.value == value;

  @override
  int get hashCode => Object.hash(kind, value);
}

/// 一根 K0 收盘时的账户快照。equity = cash + positionQty × close。
class EquityPoint {
  final int x;
  final double cash;
  final int positionQty;
  final double positionValue;
  final double equity;
  final double realizedPnL;
  final double unrealizedPnL;

  const EquityPoint({
    required this.x,
    required this.cash,
    required this.positionQty,
    required this.positionValue,
    required this.equity,
    required this.realizedPnL,
    required this.unrealizedPnL,
  });
}

/// 期末仍持仓：没有闭合 TradeRecord，但净值里有浮盈浮亏。
class OpenPosition {
  final String entrySignalId;
  final int entryX;
  final double avgCost;
  final int quantity;
  final double marketValue;
  final double unrealizedPnL;

  const OpenPosition({
    required this.entrySignalId,
    required this.entryX,
    required this.avgCost,
    required this.quantity,
    required this.marketValue,
    required this.unrealizedPnL,
  });
}
