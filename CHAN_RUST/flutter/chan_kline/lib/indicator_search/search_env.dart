import 'dart:io';

import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/models/kline_bar.dart';

import 'search_core.dart';

class SearchEnv {
  final List<KlineBar> bars;
  final BacktestStepHarnessResult h;
  final String code;
  final String period;
  final String begin;
  final String end;

  SearchEnv(this.bars, this.h, this.code, this.period, this.begin, this.end);

  int get outSampleEndX => bars.length;

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
    final run = executeStrategyBacktest(
      config: StrategyConfig(buyAst: buy, sellAst: sell),
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
      chipPeaks: h.chipPeaks,
      maxKn: h.maxKn,
      barFeatures: h.barFeatures,
      mathConfig: h.mathConfig,
    );
    if (!run.ok) return null;
    final m = run.result!.metrics;
    return RawScore(
      trades: m.totalTrades,
      winRate: m.winRate.value,
      payoff: m.payoffRatio.value,
      profitFactor: m.profitFactor.value,
      netProfit: m.netProfit,
    );
  }
}

String pctText(double? x) => x == null ? '—' : '${(x * 100).toStringAsFixed(1)}%';
String fxText(double? x) => x == null ? '—' : x.toStringAsFixed(2);

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
    return '${v.passed ? "✔" : "·"} ${v.name}\n'
        '    样本内 ${i.trades}笔 胜率${pctText(i.winRate)} 盈亏比${fxText(i.payoff)} '
        'PF${fxText(i.profitFactor)} 净利${i.netProfit.toStringAsFixed(0)}\n'
        '    样本外 ${o.trades}笔 胜率${pctText(o.winRate)} 盈亏比${fxText(o.payoff)} '
        'PF${fxText(o.profitFactor)} 净利${o.netProfit.toStringAsFixed(0)}';
  }).join('\n');
}

String reportHeader(
  String code,
  String period,
  int bars,
  int splitX,
  int gateTrades,
) =>
    '''
========== 高胜率高盈亏比 指标组合榜（$code $period $bars根K0）==========
口径：单仓只做多 / 发现根收盘成交 / 不计手续费；样本内70%选，样本外30%验
切分：K0#$splitX 之前为样本内，之后为样本外
门槛：样本内外都需 胜率≥60% 且 盈亏比≥1.5 且 ≥$gateTrades笔
（非投资建议；样本量有限时请扩大区间或多标的复验）
''';
