/// 手续费：这阶段默认 0，以后再接真实模型。
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

/// 滑点：这阶段默认不改价。
abstract class SlippageModel {
  const SlippageModel();
  double apply(double rawPrice);
}

class ZeroSlippage extends SlippageModel {
  const ZeroSlippage();
  @override
  double apply(double rawPrice) => rawPrice;
}
