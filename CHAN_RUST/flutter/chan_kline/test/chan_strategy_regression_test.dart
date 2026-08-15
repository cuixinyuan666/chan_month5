import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/backtest_run_context.dart';
import 'package:chan_kline/backtest/buy_n_var.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/buy_n_frame.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close, {double? open}) {
  final o = open ?? close;
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: o,
    high: (close > o ? close : o) + 1,
    low: (close < o ? close : o) - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

BacktestDataScope _scope(int asOf) => BacktestDataScope(
      code: '002003',
      period: '1min',
      barCount: asOf + 1,
      asOfX: asOf,
      beginText: '',
      endText: '',
    );

void main() {
  group('标准策略都能编译', () {
    test('6+1 条标准策略走同一套 AST 编译门禁', () {
      final specs = <String, TradeAst>{
        'macd+rsi': k1MacdRsiBuyAst(),
        'boll+rsi': k0BollDownAndRsiAst(),
        'buy1+rsi': k1Buy1AndRsiAst(),
        'buy1+zs': k1Buy1AndZsLowAst(),
        'buy1+diver': k1Buy1AndDiverAst(),
        'diver.ratio+rsi': k1DiverRatioAndRsiAst(),
        'buy_n3 or buy1': k1BuyN3OrBuy1Ast(),
      };
      for (final e in specs.entries) {
        expect(
          compileConditionAst(e.value, maxKn: 2),
          isA<CondCompileOk>(),
          reason: e.key,
        );
      }
    });
  });

  group('TypeError / ClockError / Unavailable', () {
    test('Event > Number 是 TypeError', () {
      final r = compileConditionAst(
        const TradeCmpAst(
          left: TradeVarRef('STRUCTURE.K1.BUY1'),
          right: TradeConstRef(0),
          op: TradeBinaryOp.gt,
        ),
        maxKn: 2,
      );
      expect(r, isA<CondCompileIllegal>());
      expect((r as CondCompileIllegal).kind, TradeCompileErrorKind.type);
    });

    test('Event CROSS Number 是 TypeError', () {
      final r = compileConditionAst(
        const TradeCmpAst(
          left: TradeVarRef('STRUCTURE.K1.BUY_N.3'),
          right: TradeVarRef('SUB.K1.RSI.VALUE'),
          op: TradeBinaryOp.crossAbove,
        ),
        maxKn: 2,
      );
      expect((r as CondCompileIllegal).kind, TradeCompileErrorKind.type);
    });

    test('K0 AND K1 是 ClockError', () {
      final r = compileConditionAst(
        const TradeAndAst(
          TradeCmpAst(
            left: TradeVarRef('RAW.K0.CLOSE'),
            right: TradeConstRef(10),
            op: TradeBinaryOp.gt,
          ),
          TradeCmpAst(
            left: TradeVarRef('RAW.K1.CLOSE'),
            right: TradeConstRef(10),
            op: TradeBinaryOp.gt,
          ),
        ),
        maxKn: 2,
      );
      expect((r as CondCompileIllegal).kind, TradeCompileErrorKind.clock);
    });

    test('整个背驰对象比大小是 Unavailable', () {
      final r = compileConditionAst(
        const TradeCmpAst(
          left: TradeVarRef('STRUCTURE.K1.DIVERGENCE'),
          right: TradeConstRef(0.8),
          op: TradeBinaryOp.lt,
        ),
        maxKn: 2,
      );
      expect((r as CondCompileIllegal).kind, TradeCompileErrorKind.unavailable);
    });

    test('合法：RATIO < 0.8、ZS.LOW < CLOSE、BUY1 AND RSI、DIRECTION == UP', () {
      expect(
        compileConditionAst(k1DiverRatioAndRsiAst(), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(
          const TradeCmpAst(
            left: TradeVarRef('STRUCTURE.K1.ZS.CURRENT.LOW'),
            right: TradeVarRef('RAW.K1.CLOSE'),
            op: TradeBinaryOp.lt,
          ),
          maxKn: 2,
        ),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(k1Buy1AndRsiAst(), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(k1Buy1AndDiverAst(), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(
          const TradeCmpAst(
            left: TradeVarRef('STRUCTURE.K1.DIVERGENCE.DIRECTION'),
            right: TradeEnumRef('UP'),
            op: TradeBinaryOp.eq,
          ),
          maxKn: 2,
        ),
        isA<CondCompileOk>(),
      );
    });
  });

  group('统一链路 AST → Signal → Order → Fill', () {
    test('纯指标 MACD+RSI：发现当根、下一根开盘、归因、运行上下文', () {
      final bars = [for (var i = 0; i <= 8; i++) _bar(i, 10, open: 10.0 + i)];
      final store = MathSeriesFreezeStore();
      store.macdByKn[0] = MacdK0Series(
        dif: <double?>[0, 0, 0, 2, 2, 2, -1, -1, -1],
        dea: <double?>[1, 1, 1, 1, 1, 1, 0, 0, 0],
        macd: <double?>[0, 0, 0, 2, 2, 2, -2, -2, -2],
      );
      store.rsiByKn[0] = <double?>[40, 40, 40, 40, 40, 40, 80, 80, 80];
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
        sellAst: kDefaultBollSellAst,
        quantity: 100,
        initialCapital: 100000,
      );
      final run = executeStrategyBacktest(
        config: cfg,
        scope: _scope(8),
        bars: bars,
        mathFreeze: store,
        maxKn: 0,
        runId: 'reg-macd-rsi',
      );
      expect(run.ok, isTrue);
      expect(run.engineVersion, kBacktestEngineVersion);
      expect(run.context!.strategyVersion, kStrategyAstVersion);
      expect(run.context!.dataContractVersion, kDataContractVersion);
      expect(run.context!.structureSemanticVersion, kStructureSemanticVersion);
      expect(run.context!.symbol, '002003');
      final buys = run.result!.signals.where((s) => s.side == TradeSide.buy);
      expect(buys, isNotEmpty);
      expect(buys.first.trace, isNotNull);
      expect(buys.first.trace!.text.contains('AND'), isTrue);
      expect(run.result!.fills, isNotEmpty);
      expect(run.result!.fills.first.executeX, buys.first.discoveryX + 1);
      expect(run.result!.rulePerformances.any((p) => p.ruleId == 'ast_buy'), isTrue);
    });

    test('BUY1 AND RSI：事件与数值混合；ConditionTrace 含 TRUE', () {
      final bars = [for (var i = 0; i <= 8; i++) _bar(i, 10, open: 10.0 + i)];
      final store = MathSeriesFreezeStore();
      store.rsiByKn[0] = <double?>[40, 40, 40, 40, 40, 40, 40, 40, 40];
      final events = ChanEventStore(
        buy1ByKn: {
          0: [
            const Buy1Frame(
              x: 3,
              price: 13,
              label: '1Ba',
              segIdx: 1,
              level: 0,
            ),
          ],
        },
        sell1ByKn: {
          0: [
            const Sell1Frame(
              x: 6,
              price: 16,
              label: '1Sa',
              segIdx: 1,
              level: 0,
            ),
          ],
        },
      );
      final cfg = const StrategyConfig(
        buyAst: TradeAndAst(
          TradeEventAst('STRUCTURE.K0.BUY1'),
          TradeCmpAst(
            left: TradeVarRef('SUB.K0.RSI.VALUE'),
            right: TradeConstRef(50),
            op: TradeBinaryOp.lt,
          ),
        ),
        sellAst: TradeEventAst('STRUCTURE.K0.SELL1'),
        quantity: 100,
      );
      final run = executeStrategyBacktest(
        config: cfg,
        scope: _scope(8),
        bars: bars,
        mathFreeze: store,
        chanEvents: events,
        maxKn: 0,
      );
      expect(run.ok, isTrue);
      final buy = run.result!.signals.firstWhere((s) => s.side == TradeSide.buy);
      expect(buy.discoveryX, 3);
      expect(buy.trace!.text.contains('TRUE'), isTrue);
      expect(run.result!.fills.first.executeX, 4);
    });

    test('BUY_N(3) OR BUY1 与四类分层互不串', () {
      expect(
        compileConditionAst(TradeEventAst(buyNVarId(2, 4)), maxKn: 2),
        isA<CondCompileOk>(),
      );
      final listed = listTradeChanEvents(
        variableId: buyNVarId(2, 4),
        asOf: 50,
        store: ChanEventStore(
          buyNByKn: {
            1: [
              const BuyNFrame(
                cls: 4,
                x: 10,
                price: 1,
                label: '4Ba',
                segIdx: 1,
                level: 0,
              ),
            ],
            2: [
              const BuyNFrame(
                cls: 4,
                x: 20,
                price: 2,
                label: '4Ba',
                segIdx: 1,
                level: 1,
              ),
            ],
          },
        ),
        maxKn: 2,
      );
      expect(listed.single.discoveryX, 20);
      expect(listed.single.displayKn, 2);
    });
  });
}
