import 'cost_models.dart';
import 'strategy_config.dart';

/// 回测运行上下文（Phase 14）：以后对比两次回测，能分清是策略、契约、结构语义还是引擎变了。
class BacktestRunContext {
  final String runId;
  final String engineVersion;
  final String strategyVersion;
  final String dataContractVersion;
  final String structureSemanticVersion;
  final String symbol;
  final String timeframe;
  final int startX;
  final int endX;
  final double initialCapital;
  final String costModel;
  final StrategyConfig strategyConfig;

  const BacktestRunContext({
    required this.runId,
    required this.engineVersion,
    required this.strategyVersion,
    required this.dataContractVersion,
    required this.structureSemanticVersion,
    required this.symbol,
    required this.timeframe,
    required this.startX,
    required this.endX,
    required this.initialCapital,
    required this.costModel,
    required this.strategyConfig,
  });
}

const String kStrategyAstVersion = 'ast-v2';
const String kDataContractVersion = 'catalog-v2-buy-n';
const String kStructureSemanticVersion = 'structure-v2';

String describeCostModel({
  required double commissionRate,
  required double slippageAmount,
}) {
  final fee = commissionRate <= 0 ? '免手续费' : '费率$commissionRate';
  final slip = slippageAmount <= 0 ? '无滑点' : '固定滑点$slippageAmount';
  return '$fee；$slip';
}

BacktestRunContext buildRunContext({
  required String runId,
  required String engineVersion,
  required StrategyConfig config,
  required BacktestDataScope scope,
  int startX = 0,
}) {
  return BacktestRunContext(
    runId: runId,
    engineVersion: engineVersion,
    strategyVersion: kStrategyAstVersion,
    dataContractVersion: kDataContractVersion,
    structureSemanticVersion: kStructureSemanticVersion,
    symbol: scope.code,
    timeframe: scope.period,
    startX: startX,
    endX: scope.asOfX,
    initialCapital: config.initialCapital,
    costModel: describeCostModel(
      commissionRate: config.commissionRate,
      slippageAmount: config.slippageAmount,
    ),
    strategyConfig: config,
  );
}

/// 给描述用，不参与撮合。
String costModelLabel(CommissionModel c, SlippageModel s) =>
    '${c.runtimeType}/${s.runtimeType}';
