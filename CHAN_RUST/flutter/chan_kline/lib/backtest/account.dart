/// 第一版账户：单品种、只做多、单仓。
class AccountState {
  double cash;
  int positionQty;
  double avgCost;
  double realizedPnL;

  AccountState({
    required this.cash,
    this.positionQty = 0,
    this.avgCost = 0,
    this.realizedPnL = 0,
  });

  bool get isFlat => positionQty <= 0;
  bool get isLong => positionQty > 0;

  double marketValue(double lastPrice) =>
      isFlat ? 0 : positionQty * lastPrice;

  double unrealizedPnL(double lastPrice) =>
      isFlat ? 0 : (lastPrice - avgCost) * positionQty;
}
