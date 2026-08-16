import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/backtest/trade_var_diagnose.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/buy2_frame.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/zs_signal_event.dart';
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

List<KlineBar> _bars(int n) => [for (var i = 0; i < n; i++) _bar(i, 10.0 + i)];

BacktestDataScope _scope(int asOf) => BacktestDataScope(
      code: 'test',
      period: '1m',
      barCount: asOf + 1,
      asOfX: asOf,
      beginText: '',
      endText: '',
    );

Buy1Frame _b1({
  required int x,
  required String label,
  int seg = 3,
  int level = 0,
  double price = 10,
}) {
  return Buy1Frame(
    x: x,
    price: price,
    label: label,
    segIdx: seg,
    level: level,
  );
}

void main() {
  group('登记与类型门禁', () {
    test('K0/K1/K2 一类二类、分型确认、中枢确认进公式', () {
      for (final kn in [0, 1, 2]) {
        for (final id in [
          'STRUCTURE.K$kn.BUY1',
          'STRUCTURE.K$kn.SELL1',
          'STRUCTURE.K$kn.BUY2',
          'STRUCTURE.K$kn.SELL2',
          'SUB.K$kn.FRACTAL_CONFIRM',
          'SUB.K$kn.ZS_CONFIRM',
        ]) {
          final d = lookupTradeVariable(id, maxKn: 2)!;
          expect(d.expressionReady, isTrue, reason: id);
          expect(d.valueType, TradeValueType.event, reason: id);
          expect(d.evalClock, TradeEvalClock.k0Bar, reason: id);
        }
      }
      expect(
        lookupTradeVariable('STRUCTURE.K1.BUY1', maxKn: 2)!.clockFamily,
        TradeClockFamily.zsMath,
      );
      expect(
        lookupTradeVariable('SUB.K1.FRACTAL_CONFIRM', maxKn: 2)!.clockFamily,
        TradeClockFamily.line,
      );
      expect(lookupTradeVariable('STRUCTURE.K2.ZS.HIGH')!.expressionReady, isFalse);
      expect(
        lookupTradeVariable('STRUCTURE.K1.ZS.CURRENT.HIGH', maxKn: 2)!
            .expressionReady,
        isTrue,
      );
      expect(
        lookupTradeVariable('STRUCTURE.K1.ZS.CURRENT.LOW', maxKn: 2)!.valueType,
        TradeValueType.objectProjection,
      );
    });

    test('事件不能比较或穿越；EVENT_EXISTS 能编过', () {
      expect(
        compileBinaryOp(
          leftId: 'STRUCTURE.K1.BUY1',
          rightId: 'RAW.K1.CLOSE',
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'STRUCTURE.K1.BUY1',
          rightId: 'SUB.K1.RSI.VALUE',
          op: TradeBinaryOp.crossAbove,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileConditionAst(const TradeEventAst('STRUCTURE.K1.BUY1'), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(
          const TradeCmpAst(
            left: TradeVarRef('STRUCTURE.K1.BUY1'),
            right: TradeConstRef(0),
            op: TradeBinaryOp.gt,
          ),
          maxKn: 2,
        ),
        isA<CondCompileIllegal>(),
      );
    });

    test('BUY1 AND RSI 同层合法；分型确认 AND RSI 非法；BUY1 OR BUY2 合法', () {
      expect(
        compileConditionAst(k1Buy1AndRsiAst(), maxKn: 2),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(
          const TradeAndAst(
            TradeEventAst('STRUCTURE.K1.BUY1'),
            TradeEventAst('STRUCTURE.K1.BUY2'),
          ),
          maxKn: 2,
        ),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(
          const TradeAndAst(
            TradeEventAst('SUB.K1.FRACTAL_CONFIRM'),
            TradeCmpAst(
              left: TradeVarRef('SUB.K1.RSI.VALUE'),
              right: TradeConstRef(50),
              op: TradeBinaryOp.lt,
            ),
          ),
          maxKn: 2,
        ),
        isA<CondCompileIllegal>(),
      );
      expect(
        compileConditionAst(
          const TradeAndAst(
            TradeEventAst('STRUCTURE.K0.BUY1'),
            TradeEventAst('STRUCTURE.K1.BUY1'),
          ),
          maxKn: 2,
        ),
        isA<CondCompileIllegal>(),
      );
    });
  });

  group('当下性：首次发现 vs 动态后续 x', () {
    test('K1.BUY1 在 #100 首次发现只出一次；#101-103 动态仍在不重复', () {
      final bars = _bars(110);
      final store = ChanEventStore(
        buy1ByKn: {
          1: [
            _b1(x: 100, label: '1Ba', price: 12.5),
            _b1(x: 101, label: '1Ba', price: 12.4),
            _b1(x: 102, label: '1Ba', price: 12.3),
            _b1(x: 103, label: '1Ba', price: 12.2),
          ],
        },
      );
      final listed = listTradeChanEvents(
        variableId: 'STRUCTURE.K1.BUY1',
        asOf: 103,
        store: store,
        maxKn: 2,
      );
      expect(listed.length, 1);
      expect(listed.single.discoveryX, 100);
      expect(listed.single.eventId, contains('1Ba'));

      final compiled =
          compileConditionAst(k1Buy1EventAst, maxKn: 2) as CondCompileOk;
      final ev = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: CondEvalCtx(
          asOf: 103,
          bars: bars,
          chanEvents: store,
          maxKn: 2,
        ),
      );
      expect(ev.map((e) => e.discoveryX).toList(), [100]);
    });

    test('未来才确认的 BUY1 不能进入过去的回测', () {
      final bars = _bars(110);
      final store = ChanEventStore(
        buy1ByKn: {
          1: [
            _b1(x: 100, label: '1Ba'),
            _b1(x: 150, label: '1Bb', seg: 4),
          ],
        },
      );
      final listed = listTradeChanEvents(
        variableId: 'STRUCTURE.K1.BUY1',
        asOf: 99,
        store: store,
        maxKn: 2,
      );
      expect(listed, isEmpty);

      final compiled =
          compileConditionAst(k1Buy1EventAst, maxKn: 2) as CondCompileOk;
      final past = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: CondEvalCtx(
          asOf: 99,
          bars: bars,
          chanEvents: store,
          maxKn: 2,
        ),
      );
      expect(past, isEmpty);

      final now = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: CondEvalCtx(
          asOf: 103,
          bars: bars,
          chanEvents: store,
          maxKn: 2,
        ),
      );
      expect(now.map((e) => e.discoveryX).toList(), [100]);
      expect(now.every((e) => e.discoveryX <= 103), isTrue);
    });

    test('K0 / 更高层各自读自己的会话历史', () {
      final store = ChanEventStore(
        buy1ByKn: {
          0: [_b1(x: 7, label: '1Ba', level: 0)],
          2: [_b1(x: 20, label: '1Ba', level: 1, seg: 1)],
        },
      );
      expect(
        listTradeChanEvents(
          variableId: 'STRUCTURE.K0.BUY1',
          asOf: 30,
          store: store,
          maxKn: 2,
        ).single.discoveryX,
        7,
      );
      expect(
        listTradeChanEvents(
          variableId: 'STRUCTURE.K2.BUY1',
          asOf: 30,
          store: store,
          maxKn: 2,
        ).single.discoveryX,
        20,
      );
    });
  });

  group('二类 / 分型确认 / 中枢确认', () {
    test('二类只消费发现边沿，不把持续存在铺成 true', () {
      final store = ChanEventStore(
        buy2ByKn: {
          0: [
            Buy2Frame(x: 8, price: 9, label: '2Ba', segIdx: 1, level: 0),
            Buy2Frame(x: 9, price: 9.1, label: '2Ba', segIdx: 1, level: 0),
          ],
        },
      );
      final ev = listTradeChanEvents(
        variableId: 'STRUCTURE.K0.BUY2',
        asOf: 12,
        store: store,
      );
      expect(ev.length, 1);
      expect(ev.single.discoveryX, 8);
      expect(ev.single.label, '2Ba');
    });

    test('分型确认是首次确认事件，不是当前已确认清单', () {
      final k0 = [
        const K0ConfirmSignal(
          x: 4,
          fx: 'BOTTOM',
          value: 1,
          fractalX1: 1,
          fractalX2: 3,
        ),
        const K0ConfirmSignal(
          x: 4,
          fx: 'BOTTOM',
          value: 1,
          fractalX1: 1,
          fractalX2: 3,
        ),
      ];
      final knLv = LevelBundle(
        level: 1,
        confirms: const [
          LevelConfirm(
            x: 11,
            fx: 'TOP',
            value: -1,
            fractalX1: 8,
            fractalX2: 10,
          ),
          LevelConfirm(
            x: 18,
            fx: 'TOP',
            value: -1,
            fractalX1: 8,
            fractalX2: 10,
          ),
        ],
      );
      expect(
        listTradeChanEvents(
          variableId: 'SUB.K0.FRACTAL_CONFIRM',
          asOf: 20,
          store: ChanEventStore(k0FractalConfirms: k0),
        ).single.discoveryX,
        4,
      );
      final knEv = listTradeChanEvents(
        variableId: 'SUB.K1.FRACTAL_CONFIRM',
        asOf: 20,
        levels: [knLv],
        maxKn: 2,
      );
      expect(knEv.length, 1);
      expect(knEv.single.discoveryX, 11);
    });

    test('中枢确认只暴露首次确认事件', () {
      final store = ChanEventStore(
        zsConfirmByKn: {
          1: [
            const ZsSignalEvent(
              x: 15,
              kn: 1,
              seq: 1,
              x1: 6,
              dir: 1,
              value: 1,
            ),
            const ZsSignalEvent(
              x: 16,
              kn: 1,
              seq: 1,
              x1: 6,
              dir: 1,
              value: 1,
            ),
          ],
        },
      );
      final ev = listTradeChanEvents(
        variableId: 'SUB.K1.ZS_CONFIRM',
        asOf: 20,
        store: store,
        maxKn: 2,
      );
      expect(ev.length, 1);
      expect(ev.single.discoveryX, 15);
      expect(ev.single.eventId, contains('6'));
    });
  });

  group('事件脉冲（对齐金字塔 CROSS）', () {
    test('连着两颗不同分型确认都出信号，不像收盘大于均线那样只打第一次', () {
      final bars = _bars(12);
      final store = ChanEventStore(
        k0FractalConfirms: const [
          K0ConfirmSignal(
            x: 7,
            fx: 'BOTTOM',
            value: 1,
            fractalX1: 5,
            fractalX2: 6,
          ),
          K0ConfirmSignal(
            x: 8,
            fx: 'TOP',
            value: -1,
            fractalX1: 6,
            fractalX2: 7,
          ),
        ],
      );
      final compiled = compileConditionAst(
        const TradeEventAst('SUB.K0.FRACTAL_CONFIRM'),
      ) as CondCompileOk;
      final ev = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: CondEvalCtx(
          asOf: 11,
          bars: bars,
          chanEvents: store,
        ),
      );
      expect(ev.map((e) => e.discoveryX).toList(), [7, 8]);
    });

    test('买卖都用分型确认：7 开仓，8 先平再开；成交在下一根开盘', () {
      final bars = _bars(12);
      final store = ChanEventStore(
        k0FractalConfirms: const [
          K0ConfirmSignal(
            x: 7,
            fx: 'BOTTOM',
            value: 1,
            fractalX1: 5,
            fractalX2: 6,
          ),
          K0ConfirmSignal(
            x: 8,
            fx: 'TOP',
            value: -1,
            fractalX1: 6,
            fractalX2: 7,
          ),
        ],
      );
      final run = executeStrategyBacktest(
        config: const StrategyConfig(
          buyAst: TradeEventAst('SUB.K0.FRACTAL_CONFIRM'),
          sellAst: TradeEventAst('SUB.K0.FRACTAL_CONFIRM'),
          quantity: 100,
          initialCapital: 100000,
        ),
        scope: _scope(11),
        bars: bars,
        mathFreeze: MathSeriesFreezeStore(),
        chanEvents: store,
      );
      expect(run.ok, isTrue, reason: run.error);
      final buys = run.result!.signals
          .where((s) => s.side == TradeSide.buy)
          .map((s) => s.discoveryX)
          .toList();
      final sells = run.result!.signals
          .where((s) => s.side == TradeSide.sell)
          .map((s) => s.discoveryX)
          .toList();
      expect(buys, [7, 8]);
      expect(sells, [7, 8]);
      expect(run.result!.fills.length, 3);
      expect(run.result!.fills[0].side, TradeSide.buy);
      expect(run.result!.fills[0].executeX, 8);
      expect(run.result!.fills[1].side, TradeSide.sell);
      expect(run.result!.fills[1].executeX, 9);
      expect(run.result!.fills[2].side, TradeSide.buy);
      expect(run.result!.fills[2].executeX, 9);
      expect(run.result!.trades.length, 1);
      expect(run.result!.trades.single.entryX, 8);
      expect(run.result!.trades.single.exitX, 9);
      expect(run.result!.openPosition, isNotNull);
    });
  });

  group('综合策略：一类买 + RSI / 一类卖 OR MACD', () {
    test('K1.BUY1 AND RSI<50 → 下一根开盘成交；动态后续不重复买', () {
      final bars = [
        for (var i = 0; i <= 12; i++) _bar(i, 10.0, open: 10.0 + i * 0.1),
      ];
      final levels = [
        LevelBundle(
          level: 0,
          unitBars: const [
            LevelUnitBar(
              idx: 0,
              dir: 1,
              x1: 0,
              x2: 6,
              open: 10,
              high: 11,
              low: 9,
              close: 10,
            ),
            LevelUnitBar(
              idx: 1,
              dir: -1,
              x1: 6,
              x2: 12,
              open: 10,
              high: 11,
              low: 9,
              close: 10,
            ),
          ],
        ),
      ];
      final freeze = MathSeriesFreezeStore();
      freeze.rsiByKn[1] = [
        for (var i = 0; i <= 12; i++) 40.0,
      ];
      freeze.macdByKn[1] = MacdK0Series(
        dif: [for (var i = 0; i <= 12; i++) i < 10 ? 1.0 : -1.0],
        dea: [for (var i = 0; i <= 12; i++) 0.0],
        macd: [for (var i = 0; i <= 12; i++) 0.0],
      );
      final store = ChanEventStore(
        buy1ByKn: {
          1: [
            _b1(x: 6, label: '1Ba', price: 10.5),
            _b1(x: 7, label: '1Ba', price: 10.4),
            _b1(x: 8, label: '1Ba', price: 10.3),
          ],
        },
        sell1ByKn: {
          1: [
            Sell1Frame(
              x: 10,
              price: 11,
              label: '1Sa',
              segIdx: 4,
              level: 0,
            ),
          ],
        },
      );

      expect(
        compileStrategyConfig(
          StrategyConfig(
            buyAst: k1Buy1AndRsiAst(),
            sellAst: k1Sell1OrMacdAst(),
          ),
          maxKn: 2,
        ),
        isA<StrategyCompileOk>(),
      );

      final run = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k1Buy1AndRsiAst(),
          sellAst: k1Sell1OrMacdAst(),
          initialCapital: 100000,
          quantity: 100,
        ),
        scope: _scope(12),
        bars: bars,
        levels: levels,
        mathFreeze: freeze,
        chanEvents: store,
        maxKn: 2,
      );
      expect(run.ok, isTrue, reason: run.error);
      expect(run.engineVersion, kBacktestEngineVersion);
      final buys =
          run.result!.signals.where((s) => s.side == TradeSide.buy).toList();
      expect(buys.map((s) => s.discoveryX).toList(), [6]);
      expect(buys.first.conditionText, contains('BUY1'));
      expect(buys.first.conditionText, contains('RSI'));
      final buyFill =
          run.result!.fills.firstWhere((f) => f.side == TradeSide.buy);
      expect(buyFill.executeX, 7);
      expect(run.result!.equityCurve, isNotEmpty);
      expect(run.result!.metrics.netProfit, isA<double>());
      for (final f in run.result!.fills) {
        final sig =
            run.result!.signals.firstWhere((s) => s.signalId == f.signalId);
        expect(f.executeX, sig.discoveryX + 1);
      }
    });
  });

  group('变量诊断', () {
    test('能看出事件来源、首次发现 K0 和 eventId', () {
      final bars = _bars(12);
      final store = ChanEventStore(
        buy1ByKn: {
          1: [_b1(x: 6, label: '1Ba', price: 12.5)],
        },
      );
      final d = diagnoseTradeVariable(
        variableId: 'STRUCTURE.K1.BUY1',
        asOf: 10,
        bars: bars,
        chanEvents: store,
        maxKn: 2,
      );
      expect(d.lastEvent, isNotNull);
      expect(d.lastEvent!.discoveryX, 6);
      expect(d.text, contains('1Ba'));
      expect(d.text, contains('K0 #6'));
      expect(d.note, contains('首次发现'));
    });
  });
}
