import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/backtest/trade_var_diagnose.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close, {double vol = 1, double? open}) {
  final o = open ?? close;
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: o,
    high: (close > o ? close : o) + 1,
    low: (close < o ? close : o) - 1,
    close: close,
    volume: vol,
    amount: 1,
  );
}

BacktestDataScope _scope(int asOf, {int barCount = 0}) => BacktestDataScope(
      code: 'test',
      period: '1m',
      barCount: barCount > 0 ? barCount : asOf + 1,
      asOfX: asOf,
      beginText: '',
      endText: '',
    );

void main() {
  group('登记与选择器', () {
    test('MACD/RSI/KDJ 进公式；K1 成交量按铺平层序列进公式', () {
      final g0 = groupedRegisteredVars(0, 2);
      expect(g0.map((e) => e.key).toList(),
          containsAll(['ohlc', 'volume', 'boll', 'macd', 'rsi', 'kdj']));
      final g1 = groupedRegisteredVars(1, 2);
      expect(g1.any((e) => e.key == 'volume'), isTrue);
      expect(
        g1
            .firstWhere((e) => e.key == 'macd')
            .fields
            .map((e) => e.fieldLabel)
            .toList(),
        ['DIF', 'DEA', 'HIST'],
      );
      expect(lookupTradeVariable('SUB.K1.MACD.DIF')!.expressionReady, isTrue);
      expect(lookupTradeVariable('SUB.K1.VOLUME')!.expressionReady, isTrue);
      expect(remapRegisteredVarId('RAW.K0.VOLUME', 1, maxKn: 2), 'SUB.K1.VOLUME');
      expect(remapRegisteredVarId('SUB.K1.VOLUME', 0, maxKn: 2), 'RAW.K0.VOLUME');
      expect(remapRegisteredVarId('SUB.K0.MACD.DIF', 1, maxKn: 2),
          'SUB.K1.MACD.DIF');
    });

    test('同层 MACD DIF vs DEA 合法；K0 × K1 非法', () {
      expect(
        compileBinaryOp(
          leftId: 'SUB.K1.MACD.DIF',
          rightId: 'SUB.K1.MACD.DEA',
          op: TradeBinaryOp.crossAbove,
          maxKn: 2,
        ),
        isA<TradeExprOk>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'SUB.K0.MACD.DIF',
          rightId: 'SUB.K1.RSI.VALUE',
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileConditionAst(const TradeCmpAst(
          left: TradeVarRef('RAW.K0.VOLUME'),
          right: TradeVarRef('SUB.K1.MACD.DIF'),
          op: TradeBinaryOp.gt,
        ), maxKn: 2),
        isA<CondCompileIllegal>(),
      );
    });
  });

  group('金标：图上格子 = 交易变量 = 回测计算钟', () {
    test('K0 MACD/RSI/KDJ 只读冻结仓；空仓不可用、不现算', () {
      final bars = [for (var i = 0; i < 30; i++) _bar(i, 10.0 + i * 0.2)];
      const asOf = 29;
      final live = computeClassicMathForLevel(
        displayKn: 0,
        bars: bars,
        config: const MathIndicatorConfig(),
        asOf: asOf,
      );
      expect(
        lookupTradeNumeric(
          variableId: 'SUB.K0.MACD.DIF',
          asOf: asOf,
          bars: bars,
        ).isUnavailable,
        isTrue,
      );
      expect(
        readEvalClockSeries(
          variableId: 'SUB.K0.RSI.VALUE',
          asOf: asOf,
          bars: bars,
        ),
        isEmpty,
      );
      expect(
        lookupTradeNumeric(
          variableId: 'SUB.K0.KDJ.K',
          asOf: asOf,
          bars: bars,
          mathFreeze: MathSeriesFreezeStore(),
        ).isUnavailable,
        isTrue,
      );

      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(),
        maxDisplayKn: 0,
        asOf: asOf,
      );
      // 图上有冻结仓时画冻结格子，与交易读数同一份
      expect(store.macd(0)!.dif[asOf], closeTo(live.macd.dif[asOf]!, 1e-12));
      for (final id in [
        'SUB.K0.MACD.DIF',
        'SUB.K0.MACD.DEA',
        'SUB.K0.MACD.HIST',
        'SUB.K0.RSI.VALUE',
        'SUB.K0.KDJ.K',
        'SUB.K0.KDJ.D',
        'SUB.K0.KDJ.J',
      ]) {
        final plot = lookupTradeNumeric(
          variableId: id,
          asOf: asOf,
          bars: bars,
          mathFreeze: store,
        );
        final series = readEvalClockSeries(
          variableId: id,
          asOf: asOf,
          bars: bars,
          mathFreeze: store,
        );
        expect(plot.isAvailable, isTrue, reason: id);
        expect(series, isNotEmpty, reason: id);
        expect(series.last.availableAt, asOf, reason: id);
        expect(plot.value, closeTo(series.last.value, 1e-12), reason: id);
      }
      expect(
        lookupTradeNumeric(
          variableId: 'SUB.K0.MACD.HIST',
          asOf: asOf,
          bars: bars,
          mathFreeze: store,
        ).value,
        closeTo(store.macd(0)!.macd[asOf]!, 1e-12),
      );
    });

    test('K1 与更高层：计算钟在虚拟K右端，图上格子是铺平持值', () {
      final bridge = ChanBridge.instance;
      final bars = bridge.loadKlines(
        dataRoot: bridge.defaultDataRoot(),
        code: '002003',
        beginDate: '2004/07/19 10:47:00',
        endDate: '2004/07/20 13:09:00',
        period: 'tick',
      );
      const asOf = 80;
      final prefix = bars.where((b) => b.idx <= asOf).toList();
      final bundle = bridge.buildKlineCombineBundle(prefix);
      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: prefix,
        levels: bundle.levels,
        config: const MathIndicatorConfig(),
        maxDisplayKn: 2,
        asOf: asOf,
      );

      final kns = <int>[1];
      if (store.macd(2) != null) kns.add(2);
      for (final kn in kns) {
        final samples = collectKnOhlcSamples(
          displayKn: kn,
          bars: prefix,
          levels: bundle.levels,
          asOf: asOf,
        );
        expect(samples, isNotEmpty, reason: 'K$kn');
        final id = macdFieldId(kn, 'DIF');
        final plot = lookupTradeNumeric(
          variableId: id,
          asOf: asOf,
          bars: prefix,
          levels: bundle.levels,
          mathFreeze: store,
        );
        expect(plot.isAvailable, isTrue, reason: id);
        expect(plot.value, closeTo(store.macd(kn)!.dif[asOf]!, 1e-12));

        final eval = readEvalClockSeries(
          variableId: id,
          asOf: asOf,
          bars: prefix,
          levels: bundle.levels,
          mathFreeze: store,
        );
        expect(eval.length, samples.length, reason: id);
        expect(eval.last.availableAt, samples.last.endX);
        expect(
          eval.last.value,
          closeTo(store.macd(kn)!.dif[samples.last.endX]!, 1e-12),
        );
        expect(eval.length, lessThanOrEqualTo(prefix.length));

        final rsiEval = readEvalClockSeries(
          variableId: rsiValueId(kn),
          asOf: asOf,
          bars: prefix,
          levels: bundle.levels,
          mathFreeze: store,
        );
        expect(rsiEval.map((e) => e.availableAt).toList(),
            eval.map((e) => e.availableAt).toList());
      }
    });
  });

  group('综合策略链路', () {
    test('K0 注入 MACD+RSI：信号→下一根开盘→净值，UI 不另算', () {
      final bars = [for (var i = 0; i <= 8; i++) _bar(i, 10, open: 10.0 + i)];
      final store = MathSeriesFreezeStore();
      store.macdByKn[0] = MacdK0Series(
        dif: <double?>[0, 0, 0, 2, 2, 2, -1, -1, -1],
        dea: <double?>[1, 1, 1, 1, 1, 1, 0, 0, 0],
        macd: <double?>[0, 0, 0, 2, 2, 2, -2, -2, -2],
      );
      store.rsiByKn[0] = <double?>[
        40, 40, 40, 40, 40, 40, 80, 80, 80,
      ];
      final cfg = const StrategyConfig(
        buyAst: TradeAndAst(
          TradeCmpAst(
            left: TradeVarRef('SUB.K0.MACD.DIF'),
            right: TradeVarRef('SUB.K0.MACD.DEA'),
            op: TradeBinaryOp.crossAbove,
          ),
          TradeCmpAst(
            left: TradeVarRef('SUB.K0.RSI.VALUE'),
            right: TradeConstRef(50),
            op: TradeBinaryOp.lt,
          ),
        ),
        sellAst: TradeOrAst(
          TradeCmpAst(
            left: TradeVarRef('SUB.K0.MACD.DIF'),
            right: TradeVarRef('SUB.K0.MACD.DEA'),
            op: TradeBinaryOp.crossBelow,
          ),
          TradeCmpAst(
            left: TradeVarRef('SUB.K0.RSI.VALUE'),
            right: TradeConstRef(70),
            op: TradeBinaryOp.gt,
          ),
        ),
        initialCapital: 100000,
        quantity: 100,
      );
      expect(compileStrategyConfig(cfg, maxKn: 0), isA<StrategyCompileOk>());
      final run = executeStrategyBacktest(
        config: cfg,
        scope: _scope(8),
        bars: bars,
        mathFreeze: store,
        maxKn: 0,
      );
      expect(run.ok, isTrue);
      expect(run.engineVersion, kBacktestEngineVersion);
      final buys = run.result!.signals.where((s) => s.side == TradeSide.buy);
      expect(buys.map((s) => s.discoveryX).toList(), [3]);
      expect(buys.first.conditionText, contains('MACD.DIF'));
      expect(buys.first.explainBlock, contains('买点'));
      final buyFill =
          run.result!.fills.firstWhere((f) => f.side == TradeSide.buy);
      expect(buyFill.executeX, 3);
      expect(run.result!.equityCurve, isNotEmpty);
      expect(run.result!.metrics.netProfit, isA<double>());
    });

    test('K1 MACD+RSI 综合策略能编过并能跑；成交量只走 K0 常数比较', () {
      expect(
        compileStrategyConfig(
          StrategyConfig(
            buyAst: k1MacdRsiBuyAst(),
            sellAst: k1MacdRsiSellAst(),
          ),
          maxKn: 2,
        ),
        isA<StrategyCompileOk>(),
      );
      final volBars = [
        _bar(0, 10, vol: 100),
        _bar(1, 11, vol: 2000000),
        _bar(2, 12, vol: 2000000),
        _bar(3, 13, vol: 2000000),
      ];
      final volRun = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k0VolumeGtAst(1000000),
          sellAst: const TradeCmpAst(
            left: TradeVarRef('RAW.K0.CLOSE'),
            right: TradeConstRef(0),
            op: TradeBinaryOp.lt,
          ),
        ),
        scope: _scope(3),
        bars: volBars,
        mathFreeze: MathSeriesFreezeStore(),
        maxKn: 0,
      );
      expect(volRun.ok, isTrue);
      expect(
        volRun.result!.signals.where((s) => s.side == TradeSide.buy),
        isNotEmpty,
      );

      final bridge = ChanBridge.instance;
      final bars = bridge.loadKlines(
        dataRoot: bridge.defaultDataRoot(),
        code: '002003',
        beginDate: '2004/07/19 10:47:00',
        endDate: '2004/07/20 13:09:00',
        period: 'tick',
      );
      const asOf = 80;
      final prefix = bars.where((b) => b.idx <= asOf).toList();
      final bundle = bridge.buildKlineCombineBundle(prefix);
      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: prefix,
        levels: bundle.levels,
        config: const MathIndicatorConfig(),
        maxDisplayKn: 2,
        asOf: asOf,
      );
      final run = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k1MacdRsiBuyAst(),
          sellAst: k1MacdRsiSellAst(),
        ),
        scope: _scope(asOf, barCount: prefix.length),
        bars: prefix,
        levels: bundle.levels,
        mathFreeze: store,
        maxKn: 2,
      );
      expect(run.ok, isTrue);
      for (final f in run.result!.fills) {
        final sig =
            run.result!.signals.firstWhere((s) => s.signalId == f.signalId);
        expect(f.executeX, sig.discoveryX);
      }
      expect(run.result!.equityCurve, isNotEmpty);
    });
  });

  group('变量诊断', () {
    test('能看出冻结仓来源、计算钟和 availableAt', () {
      final bars = [for (var i = 0; i < 8; i++) _bar(i, 10.0 + i)];
      final empty = diagnoseTradeVariable(
        variableId: 'SUB.K0.MACD.DIF',
        asOf: 7,
        bars: bars,
      );
      expect(empty.plotValue.isUnavailable, isTrue);
      expect(empty.freezePresent, isFalse);
      expect(empty.text, contains('不会现场重算'));

      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(),
        maxDisplayKn: 0,
        asOf: 7,
      );
      final d = diagnoseTradeVariable(
        variableId: 'SUB.K0.MACD.DIF',
        asOf: 7,
        bars: bars,
        mathFreeze: store,
      );
      expect(d.expressionReady, isTrue);
      expect(d.clockFamily!.name, 'zsMath');
      expect(d.evalPoint, isNotNull);
      expect(d.evalPoint!.availableAt, 7);
      expect(d.plotValue.isAvailable, isTrue);
      expect(d.text, contains('K0 #7'));
      expect(d.freezePresent, isTrue);
      expect(d.source, contains('macd'));
    });
  });
}
