/// 这次回测用的数据范围（当时走到哪根 K0），不是另算一套行情。
class BacktestDataScope {
  final String code;
  final String period;
  final int barCount;
  /// 运行时已走到的最后一根 K0
  final int asOfX;
  final String beginText;
  final String endText;

  const BacktestDataScope({
    required this.code,
    required this.period,
    required this.barCount,
    required this.asOfX,
    required this.beginText,
    required this.endText,
  });
}

/// 第一版策略：每条腿只选一层 Kn，CLOSE 与布林轨锁死同层同钟。
/// 买：K{n}.CLOSE 下穿 K{n}.BOLL.DOWN；卖：K{m}.CLOSE 上穿 K{m}.BOLL.UP。
/// 界面没有「左腿一层、右腿另一层」的独立选择，所以拼不出 K0收盘×K1布林。
class StrategyConfig {
  final int buyKn;
  final int sellKn;
  final int quantity;
  final double initialCapital;
  /// 成交额费率；0=免手续费
  final double commissionRate;
  /// 买加价/卖减价的固定价差；0=无滑点
  final double slippageAmount;
  final BacktestDataScope? dataScope;

  const StrategyConfig({
    this.buyKn = 0,
    this.sellKn = 0,
    this.quantity = 100,
    this.initialCapital = 100000,
    this.commissionRate = 0,
    this.slippageAmount = 0,
    this.dataScope,
  });

  String get buyCloseId => 'RAW.K$buyKn.CLOSE';
  String get buyBollId => 'MAIN.K$buyKn.BOLL.DOWN';
  String get sellCloseId => 'RAW.K$sellKn.CLOSE';
  String get sellBollId => 'MAIN.K$sellKn.BOLL.UP';

  String get buyLabel => 'K$buyKn 收盘 下穿 K$buyKn 布林下轨';
  String get sellLabel => 'K$sellKn 收盘 上穿 K$sellKn 布林上轨';

  StrategyConfig copyWith({
    int? buyKn,
    int? sellKn,
    int? quantity,
    double? initialCapital,
    double? commissionRate,
    double? slippageAmount,
    BacktestDataScope? dataScope,
  }) {
    return StrategyConfig(
      buyKn: buyKn ?? this.buyKn,
      sellKn: sellKn ?? this.sellKn,
      quantity: quantity ?? this.quantity,
      initialCapital: initialCapital ?? this.initialCapital,
      commissionRate: commissionRate ?? this.commissionRate,
      slippageAmount: slippageAmount ?? this.slippageAmount,
      dataScope: dataScope ?? this.dataScope,
    );
  }
}
