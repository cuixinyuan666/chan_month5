import 'dart:io';

import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/kline_bar.dart';

import 'search_core.dart';

/// 寻优快照/报告头用的撮合与数学指标参数（与 [SearchWorkbenchAlign] 对齐）。
class IndicatorSearchAlignSnapshot {
  final int quantity;
  final double initialCapital;
  final double commissionRate;
  final double slippageAmount;
  final String fillPriceMode;
  final double bucketStep;
  final int bollN;
  final int donchianN;
  final double regressK;

  const IndicatorSearchAlignSnapshot({
    this.quantity = 100,
    this.initialCapital = 100000,
    this.commissionRate = 0,
    this.slippageAmount = 0,
    this.fillPriceMode = 'sameBarClose',
    this.bucketStep = 0.1,
    this.bollN = 20,
    this.donchianN = 20,
    this.regressK = 2.0,
  });

  TradeFillPriceMode get fillPriceModeEnum {
    for (final v in TradeFillPriceMode.values) {
      if (v.name == fillPriceMode) return v;
    }
    return kDefaultTradeFillPriceMode;
  }

  factory IndicatorSearchAlignSnapshot.fromAlign(SearchWorkbenchAlign align) {
    final t = align.strategyTemplate;
    return IndicatorSearchAlignSnapshot(
      quantity: t.quantity,
      initialCapital: t.initialCapital,
      commissionRate: t.commissionRate,
      slippageAmount: t.slippageAmount,
      fillPriceMode: t.fillPriceMode.name,
      bucketStep: align.bucketStep,
      bollN: align.bollN,
      donchianN: align.donchianN,
      regressK: align.regressK,
    );
  }

  Map<String, dynamic> toJson() => {
        'quantity': quantity,
        'initialCapital': initialCapital,
        'commissionRate': commissionRate,
        'slippageAmount': slippageAmount,
        'fillPriceMode': fillPriceMode,
        'bucketStep': bucketStep,
        'bollN': bollN,
        'donchianN': donchianN,
        'regressK': regressK,
      };

  static IndicatorSearchAlignSnapshot? fromJsonMap(Map<String, dynamic>? m) {
    if (m == null || m.isEmpty) return null;
    return IndicatorSearchAlignSnapshot(
      quantity: (m['quantity'] as num?)?.toInt() ?? 100,
      initialCapital: (m['initialCapital'] as num?)?.toDouble() ?? 100000,
      commissionRate: (m['commissionRate'] as num?)?.toDouble() ?? 0,
      slippageAmount: (m['slippageAmount'] as num?)?.toDouble() ?? 0,
      fillPriceMode: m['fillPriceMode'] as String? ?? 'sameBarClose',
      bucketStep: (m['bucketStep'] as num?)?.toDouble() ?? 0.1,
      bollN: (m['bollN'] as num?)?.toInt() ?? 20,
      donchianN: (m['donchianN'] as num?)?.toInt() ?? 20,
      regressK: (m['regressK'] as num?)?.toDouble() ?? 2.0,
    );
  }

  String get replayParamLine =>
      '复现参数：数量 $quantity · 本金 ${initialCapital.toStringAsFixed(0)} · '
      '费率 $commissionRate · 滑点 $slippageAmount · '
      '布林N $bollN · 唐奇安N $donchianN · 回归K $regressK · 筹码步长 $bucketStep';
}

/// 与回测工作台对齐的撮合/指标参数（买卖 AST 仍由候选决定）。
class SearchWorkbenchAlign {
  final StrategyConfig strategyTemplate;
  final BarFeatureLookup? features;
  final double bucketStep;
  final int bollN;
  final int donchianN;
  final double regressK;

  const SearchWorkbenchAlign({
    this.strategyTemplate = const StrategyConfig(),
    this.features,
    this.bucketStep = 0.1,
    this.bollN = 20,
    this.donchianN = 20,
    this.regressK = 2.0,
  });

  factory SearchWorkbenchAlign.fromHarness(BacktestStepHarnessResult h) {
    final mc = h.mathConfig;
    return SearchWorkbenchAlign(
      bucketStep: h.chipBucketStep,
      bollN: mc.bollN,
      donchianN: mc.donchianN,
      regressK: mc.regressK,
    );
  }
}

double? _metricToDouble(MetricNum m) {
  if (m.isInfinity) return double.infinity;
  if (m.isFinite) return m.value;
  return null;
}

RawScore rawScoreFromMetrics(BacktestMetrics m) {
  return RawScore(
    trades: m.totalTrades,
    winRate: m.winRate.isFinite ? m.winRate.value : null,
    payoff: _metricToDouble(m.payoffRatio),
    profitFactor: _metricToDouble(m.profitFactor),
    netProfit: m.netProfit,
  );
}

/// 按闭合交易列表汇总（不依赖净值曲线；用于样本外 entry 切片）。
RawScore rawScoreFromClosedTrades(
  List<TradeRecord> trades, {
  double initialCapital = 100000,
}) {
  if (trades.isEmpty) {
    return const RawScore(
      trades: 0,
      winRate: null,
      payoff: null,
      profitFactor: null,
      netProfit: 0,
    );
  }
  final net = trades.fold(0.0, (a, t) => a + t.netPnL);
  final endX = trades.last.exitX;
  final m = computeBacktestMetrics(
    initialCapital: initialCapital,
    equityCurve: [
      EquityPoint(
        x: trades.first.entryX,
        cash: initialCapital,
        positionQty: 0,
        positionValue: 0,
        equity: initialCapital,
        realizedPnL: 0,
        unrealizedPnL: 0,
      ),
      EquityPoint(
        x: endX,
        cash: initialCapital + net,
        positionQty: 0,
        positionValue: 0,
        equity: initialCapital + net,
        realizedPnL: net,
        unrealizedPnL: 0,
      ),
    ],
    closedTrades: trades,
  );
  return RawScore(
    trades: m.totalTrades,
    winRate: m.winRate.isFinite ? m.winRate.value : null,
    payoff: _metricToDouble(m.payoffRatio),
    profitFactor: _metricToDouble(m.profitFactor),
    netProfit: net,
  );
}

/// 样本内：进场与平仓均在切点及之前（闭合在 splitX 内）。
List<TradeRecord> inSampleClosedTrades(
  List<TradeRecord> all,
  int splitX,
) =>
    all.where((t) => t.entryX <= splitX && t.exitX <= splitX).toList();

/// 样本外：进场严格晚于切点。
List<TradeRecord> outSampleClosedTradesList(
  List<TradeRecord> all,
  int splitX,
) =>
    all.where((t) => t.entryX > splitX).toList();

/// 切点两侧都不计入的跨界闭合单（进场≤split、平仓>split）。
List<TradeRecord> crossSplitClosedTrades(
  List<TradeRecord> all,
  int splitX,
) =>
    all
        .where((t) => t.entryX <= splitX && t.exitX > splitX)
        .toList();

class InOutSegmentScores {
  final RawScore inSample;
  final RawScore outSample;

  const InOutSegmentScores({
    required this.inSample,
    required this.outSample,
  });
}

class SearchEnv {
  final List<KlineBar> bars;
  final BacktestStepHarnessResult h;
  final String code;
  final String period;
  final String begin;
  final String end;
  final SearchWorkbenchAlign align;

  SearchEnv(
    this.bars,
    this.h,
    this.code,
    this.period,
    this.begin,
    this.end, {
    SearchWorkbenchAlign? align,
  }) : align = align ?? SearchWorkbenchAlign.fromHarness(h);

  int get outSampleEndX => bars.isEmpty ? 0 : bars.last.idx;

  RawScore? runAt(TradeAst buy, TradeAst sell, int endX) {
    return runAtCompiled(null, buy, sell, endX);
  }

  /// [compiled] 非空时跳过 AST 重编（与 [runAt] 求值结果一致）。
  RawScore? runAtCompiled(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int endX,
  ) {
    final run = _executeBacktest(compiled, buy, sell, endX);
    if (run == null || !run.ok || run.result == null) return null;
    return rawScoreFromMetrics(run.result!.metrics);
  }

  /// 样本内/外各独立重跑：内段 asOf=切点；外段全区间求信号但仅撮合 executeX>切点。
  InOutSegmentScores? runInOutFromSingleFull(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int splitX,
  ) {
    final rIn = runAtCompiled(compiled, buy, sell, splitX);
    if (rIn == null) return null;
    final rOut = _runOutSampleCompiled(compiled, buy, sell, splitX);
    if (rOut == null) return null;
    return InOutSegmentScores(inSample: rIn, outSample: rOut);
  }

  RawScore? _runOutSampleCompiled(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int splitX,
  ) {
    final run = _executeBacktest(
      compiled,
      buy,
      sell,
      outSampleEndX,
      minExecuteXExclusive: splitX,
    );
    if (run == null || !run.ok || run.result == null) return null;
    return rawScoreFromMetrics(run.result!.metrics);
  }

  List<TradeRecord>? allClosedTradesFromFull(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
  ) {
    final run = _executeBacktest(compiled, buy, sell, outSampleEndX);
    if (run == null || !run.ok || run.result == null) return null;
    return run.result!.closedTrades;
  }

  /// 全区间回测后，仅统计进场 K0# > [splitX] 的闭合交易。
  RawScore? runOutSampleFromFull(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int splitX,
  ) {
    final seg = runInOutFromSingleFull(compiled, buy, sell, splitX);
    return seg?.outSample;
  }

  /// 外段闭合交易（进场严格晚于 [splitX]）；供对拍与口径断言。
  List<TradeRecord>? outSampleClosedTrades(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int splitX,
  ) {
    final all = allClosedTradesFromFull(compiled, buy, sell);
    if (all == null) return null;
    return outSampleClosedTradesList(all, splitX);
  }

  /// 样本内闭合交易（进场与平仓均 ≤ [splitX]）。
  List<TradeRecord>? inSampleClosedTradesFromFull(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int splitX,
  ) {
    final all = allClosedTradesFromFull(compiled, buy, sell);
    if (all == null) return null;
    return inSampleClosedTrades(all, splitX);
  }

  BacktestRun? _executeBacktest(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int endX, {
    int? minExecuteXExclusive,
  }) {
    final tpl = align.strategyTemplate;
    return executeStrategyBacktest(
      config: StrategyConfig(
        buyAst: buy,
        sellAst: sell,
        quantity: tpl.quantity,
        initialCapital: tpl.initialCapital,
        commissionRate: tpl.commissionRate,
        slippageAmount: tpl.slippageAmount,
        fillPriceMode: tpl.fillPriceMode,
      ),
      precompiled: compiled,
      scope: BacktestDataScope(
        code: code,
        period: period,
        barCount: endX + 1,
        asOfX: endX,
        beginText: begin,
        endText: end,
      ),
      bars: bars,
      levels: h.levels,
      mathFreeze: h.mathFreeze,
      chanEvents: h.chanEvents,
      zsObjects: h.zsObjects,
      diverRelations: h.diverRelations,
      lineSeries: h.lineSeries,
      features: align.features,
      chipPeaks: h.chipPeaks,
      bucketStep: align.bucketStep,
      bollN: align.bollN,
      donchianN: align.donchianN,
      maxKn: h.maxKn,
      regressK: align.regressK,
      barFeatures: h.barFeatures,
      mathConfig: h.mathConfig,
      minExecuteXExclusive: minExecuteXExclusive,
    );
  }
}

String pctText(double? x) => x == null ? '—' : '${(x * 100).toStringAsFixed(1)}%';

String fxText(double? x) {
  if (x == null) return '—';
  if (x.isInfinite) return '∞';
  return x.toStringAsFixed(2);
}

void logProgress(String text, {String? logFilePath}) {
  if (logFilePath == null) return;
  try {
    File(logFilePath).writeAsStringSync(
      '[${DateTime.now().toIso8601String()}] $text\n',
      mode: FileMode.append,
      flush: true,
    );
  } catch (_) {}
}

String fmtList(Iterable<ComboVerdict> rows) {
  if (rows.isEmpty) return '（无）';
  return rows.map((v) {
    final i = v.inSample, o = v.outSample;
    final outNote = v.outSampleSkipped ? '（外段未测）' : '';
    return '${v.passed ? "✔" : "·"} ${v.name}\n'
        '    样本内 ${i.trades}笔 胜率${pctText(i.winRate)} 盈亏比${fxText(i.payoff)} '
        'PF${fxText(i.profitFactor)} 净利${i.netProfit.toStringAsFixed(0)}\n'
        '    样本外${outNote} ${o.trades}笔 胜率${pctText(o.winRate)} 盈亏比${fxText(o.payoff)} '
        'PF${fxText(o.profitFactor)} 净利${o.netProfit.toStringAsFixed(0)}';
  }).join('\n');
}

String reportHeader({
  required String code,
  required String period,
  required int bars,
  required int splitX,
  required int gateTrades,
  IndicatorSearchAlignSnapshot? align,
}) {
  final fillLabel = align != null
      ? tradeFillPriceModeLabel(align.fillPriceModeEnum)
      : '（快照未记录，默认本周期收盘）';
  final replayLine = align?.replayParamLine ??
      '复现参数：未写入快照（旧版）；当时以主界面策略回测参数为准';
  return '''
========== 高胜率高盈亏比 指标组合榜（$code $period $bars根K0）==========
口径：单仓只做多 / 成交价：$fillLabel / 与回测工作台同撮合与数学指标参数
$replayLine
方法：样本内、样本外各独立重跑（本金重置、单仓只做多）—— 内段 asOf 至 K0#$splitX；外段仅撮合成交根 > K0#$splitX 的信号
跨界：不再「全跑再切单」；内外段成交路径互不影响
门槛：样本内外都需 胜率≥60% 且 盈亏比≥1.5（∞ 计达标） 且 ≥$gateTrades笔
净利：内外均为所计闭合交易的 netPnL 合计（统计口径相同）
警示：内外段 K 根数不同，净利绝对值勿横向对比强弱
提示：全胜小样本时盈亏比可能为 ∞，请结合笔数审慎看待双达标
（非投资建议；样本量有限时请扩大区间或多标的复验）
''';
}
