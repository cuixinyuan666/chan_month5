import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'backtest_result.dart';
import 'cost_models.dart';
import 'mini_loop.dart';
import 'strategy_compile.dart';
import 'strategy_config.dart';

/// 引擎版本：以后缠论/撮合规则改了，旧报告能对上是哪一版跑的。
const String kBacktestEngineVersion = 'backtest-workbench-v1';

/// 一次回测运行：策略 + 当时数据范围 + 引擎版本 + 结果。
/// UI 不直接塞一堆散参数进引擎。
class BacktestRun {
  final String runId;
  final String engineVersion;
  final DateTime startedAt;
  final StrategyConfig strategyConfig;
  final BacktestDataScope sourceRange;
  final BacktestResult? result;
  final String? error;

  const BacktestRun({
    required this.runId,
    required this.engineVersion,
    required this.startedAt,
    required this.strategyConfig,
    required this.sourceRange,
    this.result,
    this.error,
  });

  bool get ok => error == null && result != null;
}

/// 编译 → 现有 CROSS/撮合/净值核心。Flutter 不再重算条件或收益。
BacktestRun executeStrategyBacktest({
  required StrategyConfig config,
  required BacktestDataScope scope,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  required MathSeriesFreezeStore mathFreeze,
  int bollN = 20,
  int maxKn = 8,
  DateTime? now,
  String? runId,
}) {
  final started = now ?? DateTime.now();
  final id = runId ?? 'run_${started.millisecondsSinceEpoch}';
  final compiled = compileBollCrossStrategy(config, maxKn: maxKn);
  if (compiled is StrategyCompileIllegal) {
    return BacktestRun(
      runId: id,
      engineVersion: kBacktestEngineVersion,
      startedAt: started,
      strategyConfig: config,
      sourceRange: scope,
      error: compiled.reason,
    );
  }
  final ok = compiled as StrategyCompileOk;
  if (bars.isEmpty) {
    return BacktestRun(
      runId: id,
      engineVersion: kBacktestEngineVersion,
      startedAt: started,
      strategyConfig: config,
      sourceRange: scope,
      error: '还没有可回测的 K 线，请先加载并走到至少一根',
    );
  }
  final result = runMiniLongOnlyLoop(
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    buyRule: ok.buyRule,
    sellRule: ok.sellRule,
    asOf: scope.asOfX,
    quantity: config.quantity,
    initialCash: config.initialCapital,
    bollN: bollN,
    commission: config.commissionRate <= 0
        ? const ZeroCommission()
        : RateCommission(config.commissionRate),
    slippage: config.slippageAmount <= 0
        ? const ZeroSlippage()
        : AbsoluteSlippage(config.slippageAmount),
  );
  return BacktestRun(
    runId: id,
    engineVersion: kBacktestEngineVersion,
    startedAt: started,
    strategyConfig: config.copyWith(dataScope: scope),
    sourceRange: scope,
    result: result,
  );
}
