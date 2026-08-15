import 'signal_event.dart';

/// 手续费：默认 0；非 0 模型用于回测结果验收。
abstract class CommissionModel {
  const CommissionModel();
  double fee({
    required double price,
    required int quantity,
  });
}

class ZeroCommission extends CommissionModel {
  const ZeroCommission();
  @override
  double fee({required double price, required int quantity}) => 0;
}

/// 成交额比例手续费（买、卖各自按成交价×量×费率）。
class RateCommission extends CommissionModel {
  final double rate;
  const RateCommission(this.rate);
  @override
  double fee({required double price, required int quantity}) =>
      price * quantity * rate;
}

/// 滑点：默认不改价。买往上加、卖往下减，禁止无方向乱改。
abstract class SlippageModel {
  const SlippageModel();
  double apply(double rawPrice, {required TradeSide side});
}

class ZeroSlippage extends SlippageModel {
  const ZeroSlippage();
  @override
  double apply(double rawPrice, {required TradeSide side}) => rawPrice;
}

/// 固定价差滑点：买成交价 = 开盘 + amount，卖 = 开盘 − amount。
class AbsoluteSlippage extends SlippageModel {
  final double amount;
  const AbsoluteSlippage(this.amount);
  @override
  double apply(double rawPrice, {required TradeSide side}) {
    if (side == TradeSide.buy) return rawPrice + amount;
    return rawPrice - amount;
  }
}
