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

  /// 反解回回测工作台对齐参数（用于恢复/快照界面重建 SearchEnv 做预览）。
  SearchWorkbenchAlign toAlign() => SearchWorkbenchAlign(
        strategyTemplate: StrategyConfig(
          quantity: quantity,
          initialCapital: initialCapital,
          commissionRate: commissionRate,
          slippageAmount: slippageAmount,
          fillPriceMode: fillPriceModeEnum,
        ),
        bucketStep: bucketStep,
        bollN: bollN,
        donchianN: donchianN,
        regressK: regressK,
      );
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

SegmentMetrics segmentMetricsFromRun(BacktestRun run, {int? cutX}) {
  final r = run.result;
  if (r == null) return SegmentMetrics.empty;
  return computeSegmentMetrics(
    r.trades,
    r.equityCurve,
    r.initialCapital,
    cutX: cutX,
  );
}

/// 样本内：进场与平仓均在切点及之前（闭合在 splitX 内）。
List<TradeRecord> inSampleClosedTrades(List<TradeRecord> all, int splitX) =>
    all.where((t) => t.entryX <= splitX && t.exitX <= splitX).toList();

/// 样本外：进场严格晚于切点。
List<TradeRecord> outSampleClosedTradesList(
  List<TradeRecord> all,
  int splitX,
) => all.where((t) => t.entryX > splitX).toList();

/// 切点两侧都不计入的跨界闭合单（进场≤split、平仓>split）。
List<TradeRecord> crossSplitClosedTrades(List<TradeRecord> all, int splitX) =>
    all.where((t) => t.entryX <= splitX && t.exitX > splitX).toList();

class InOutSegmentScores {
  final SegmentMetrics inSample;
  final SegmentMetrics outSample;

  const InOutSegmentScores({required this.inSample, required this.outSample});
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

  BacktestRun? runAt(TradeAst buy, TradeAst sell, int endX) {
    return runAtCompiled(null, buy, sell, endX);
  }

  /// [compiled] 非空时跳过 AST 重编（与 [runAt] 求值结果一致）。
  BacktestRun? runAtCompiled(
    StrategyCompileOk? compiled,
    TradeAst buy,
    TradeAst sell,
    int endX,
  ) {
    final run = _executeBacktest(compiled, buy, sell, endX);
    if (run == null || !run.ok || run.result == null) return null;
    return run;
  }

  /// 样本内/外各独立重跑：内段 asOf=切点；外段全区间求信号但仅撮合 executeX>切点。
  /// 外段净值曲线裁剪到切点之后再算年化（去掉前段平台期），避免污染波动率/Sharpe。
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
    return InOutSegmentScores(
      inSample: segmentMetricsFromRun(rIn),
      outSample: segmentMetricsFromRun(rOut, cutX: splitX + 1),
    );
  }

  BacktestRun? _runOutSampleCompiled(
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
    return run;
  }

  /// 眼睛按钮用：以整组买卖条件替换当前策略，跑全区间（asOf 至最后一根）回测。
  BacktestRun? runFull(TradeAst buy, TradeAst sell, int endX) {
    final run = _executeBacktest(null, buy, sell, endX);
    if (run == null || !run.ok || run.result == null) return null;
    return run;
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
  SegmentMetrics? runOutSampleFromFull(
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
      knClock: h.knClock,
    );
  }
}

String pctText(double? x) =>
    x == null ? '—' : '${(x * 100).toStringAsFixed(1)}%';

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

String _mnTxt(MetricNum m) =>
    m.isUnavailable ? '—' : (m.isInfinity ? '∞' : m.value!.toStringAsFixed(2));

String fmtList(Iterable<ComboVerdict> rows) {
  if (rows.isEmpty) return '（无）';
  return rows
      .map((v) {
        final i = v.inSample, o = v.outSample;
        return '${v.name}\n'
            '    样本内 ${i.trades}笔 胜率${pctText(i.winRate.isFinite ? i.winRate.value : null)} '
            '盈亏比${_mnTxt(i.payoffRatio)} PF${_mnTxt(i.profitFactor)} '
            '净利${i.netProfit.toStringAsFixed(0)} Sharpe${_mnTxt(i.sharpe)} Calmar${_mnTxt(i.calmar)}\n'
            '    样本外 ${o.trades}笔 胜率${pctText(o.winRate.isFinite ? o.winRate.value : null)} '
            '盈亏比${_mnTxt(o.payoffRatio)} PF${_mnTxt(o.profitFactor)} '
            '净利${o.netProfit.toStringAsFixed(0)} Sharpe${_mnTxt(o.sharpe)} Calmar${_mnTxt(o.calmar)}';
      })
      .join('\n');
}

String reportHeader({
  required String code,
  required String period,
  required int bars,
  required int splitX,
  IndicatorSearchAlignSnapshot? align,
}) {
  final fillLabel = align != null
      ? tradeFillPriceModeLabel(align.fillPriceModeEnum)
      : '（快照未记录，默认本周期收盘）';
  final replayLine = align?.replayParamLine ?? '复现参数：未写入快照（旧版）；当时以主界面策略回测参数为准';
  return '''
========== 指标组合全量寻优（$code $period $bars根K0）==========
口径：单仓只做多 / 成交价：$fillLabel / 与回测工作台同撮合与数学指标参数
$replayLine
方法：样本内、样本外各独立重跑（本金重置、单仓只做多）—— 内段 asOf 至 K0#$splitX；外段仅撮合成交根 > K0#$splitX 的信号
跨界：不再「全跑再切单」；内外段成交路径互不影响
口径：外段条件求值 asOf 至最后一根，每根只用该根及之前信息，逐根因果；K1+ 穿越按「动态段逐根在场」判（每根 K 都是采样点），K0 变量按原生 K0 逐根判；内段 asOf 截断至 K0#$splitX 更保守
展示：所有可编译候选均列出（含 0 成交），不做达标/排名筛选；不可计算值显示「—」
指标：年化按 252 交易日、无风险利率 0（仅展示，不参与筛选）；回撤/年化均基于真实净值曲线，不合成
警示：内外段 K 根数不同，净利绝对值勿横向对比强弱
（非投资建议；样本量有限时请扩大区间或多标的复验）
''';
}
