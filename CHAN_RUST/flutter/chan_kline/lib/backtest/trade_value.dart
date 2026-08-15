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
