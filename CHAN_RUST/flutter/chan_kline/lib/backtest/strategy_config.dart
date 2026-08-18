import 'condition_ast.dart';
import 'trade_clock.dart';

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

/// 策略配置：买/卖各一棵 AST。界面只搭树，真假由引擎求值。
class StrategyConfig {
  final TradeAst buyAst;
  final TradeAst sellAst;
  final int quantity;
  final double initialCapital;
  /// 成交额费率；0=免手续费
  final double commissionRate;
  /// 买加价/卖减价的固定价差；0=无滑点
  final double slippageAmount;
  /// 买点/卖点共用：本周期收盘或次周期开盘（K0 轴）
  final TradeFillPriceMode fillPriceMode;
  final BacktestDataScope? dataScope;

  const StrategyConfig({
    this.buyAst = kDefaultBollBuyAst,
    this.sellAst = kDefaultBollSellAst,
    this.quantity = 100,
    this.initialCapital = 100000,
    this.commissionRate = 0,
    this.slippageAmount = 0,
    this.fillPriceMode = kDefaultTradeFillPriceMode,
    this.dataScope,
  });

  /// 旧口径：每边只选一层，收盘穿布林。
  factory StrategyConfig.bollLayers({
    int buyKn = 0,
    int sellKn = 0,
    int quantity = 100,
    double initialCapital = 100000,
    double commissionRate = 0,
    double slippageAmount = 0,
    TradeFillPriceMode fillPriceMode = kDefaultTradeFillPriceMode,
    BacktestDataScope? dataScope,
  }) {
    return StrategyConfig(
      buyAst: bollBuyAst(buyKn),
      sellAst: bollSellAst(sellKn),
      quantity: quantity,
      initialCapital: initialCapital,
      commissionRate: commissionRate,
      slippageAmount: slippageAmount,
      fillPriceMode: fillPriceMode,
      dataScope: dataScope,
    );
  }

  String get buyLabel => astConditionText(buyAst);
  String get sellLabel => astConditionText(sellAst);

  StrategyConfig copyWith({
    TradeAst? buyAst,
    TradeAst? sellAst,
    int? quantity,
    double? initialCapital,
    double? commissionRate,
    double? slippageAmount,
    TradeFillPriceMode? fillPriceMode,
    BacktestDataScope? dataScope,
  }) {
    return StrategyConfig(
      buyAst: buyAst ?? this.buyAst,
      sellAst: sellAst ?? this.sellAst,
      quantity: quantity ?? this.quantity,
      initialCapital: initialCapital ?? this.initialCapital,
      commissionRate: commissionRate ?? this.commissionRate,
      slippageAmount: slippageAmount ?? this.slippageAmount,
      fillPriceMode: fillPriceMode ?? this.fillPriceMode,
      dataScope: dataScope ?? this.dataScope,
    );
  }
}
