/// 交易条件取值：有数 / 不可用。
/// 没有数据是「不可用」，不能当成「条件不成立」。
enum TradeTriState {
  /// 这一格当时已经能读到数
  available,
  /// 越界、尚未有第一个样本、变量未登记进公式
  unavailable,
}

/// 数值型条件变量在某一根 K0 上的读数。
class TradeScalar {
  final TradeTriState state;
  final double? value;

  const TradeScalar.unavailable()
      : state = TradeTriState.unavailable,
        value = null;

  const TradeScalar.num(double v)
      : state = TradeTriState.available,
        value = v;

  bool get isUnavailable => state == TradeTriState.unavailable;

  bool get isAvailable => state == TradeTriState.available && value != null;
}

/// 结构事件（discovery edge）：一次发现一笔，不是持续 true。
/// 身份走稳定键；discoveryX 是首次被系统知道的那根 K0。
class TradeChanEvent {
  final String eventId;
  final int displayKn;
  final int discoveryX;
  final int availableAt;
  final String label;
  final double price;
  final String source;

  const TradeChanEvent({
    required this.eventId,
    required this.displayKn,
    required this.discoveryX,
    required this.availableAt,
    required this.label,
    required this.price,
    required this.source,
  });
}
