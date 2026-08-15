import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'backtest_result.dart';
import 'chan_event_store.dart';
import 'divergence_relation_store.dart';
import 'condition_eval.dart';
import 'cost_models.dart';
import 'mini_loop.dart';
import 'signal_event.dart';
import 'strategy_compile.dart';
import 'strategy_config.dart';
import 'zhongshu_object_store.dart';

/// 引擎版本：以后缠论/撮合规则改了，旧报告能对上是哪一版跑的。
const String kBacktestEngineVersion = 'backtest-workbench-v6-divergence-rel';

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

/// 编译 AST → 求值信号 → 现有撮合/净值核心。Flutter 不再重算条件或收益。
BacktestRun executeStrategyBacktest({
  required StrategyConfig config,
  required BacktestDataScope scope,
  required List<KlineBar> bars,
  List<LevelBundle> levels = const [],
  required MathSeriesFreezeStore mathFreeze,
  ChanEventStore chanEvents = ChanEventStore.empty,
  ZhongshuObjectStore? zsObjects,
  DivergenceRelationStore? diverRelations,
  int bollN = 20,
  int maxKn = 8,
  DateTime? now,
  String? runId,
}) {
  final started = now ?? DateTime.now();
  final id = runId ?? 'run_${started.millisecondsSinceEpoch}';
  final compiled = compileStrategyConfig(config, maxKn: maxKn);
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
  final cut = scope.asOfX < 0
      ? (bars.isEmpty ? 0 : bars.last.idx)
      : scope.asOfX;
  final ctx = CondEvalCtx(
    asOf: cut,
    bars: bars,
    levels: levels,
    mathFreeze: mathFreeze,
    chanEvents: chanEvents,
    zsObjects: zsObjects,
    diverRelations: diverRelations,
    bollN: bollN,
    maxKn: maxKn,
  );
  final signals = <SignalEvent>[
    ...evalCompiledCond(
      cond: ok.buy,
      side: TradeSide.buy,
      ruleId: 'ast_buy',
      ctx: ctx,
    ),
    ...evalCompiledCond(
      cond: ok.sell,
      side: TradeSide.sell,
      ruleId: 'ast_sell',
      ctx: ctx,
    ),
  ];
  final result = runMiniLoopFromSignals(
    signals: signals,
    bars: bars,
    quantity: config.quantity,
    initialCash: config.initialCapital,
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
