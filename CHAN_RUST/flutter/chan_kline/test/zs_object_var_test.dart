import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/structure_object.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/backtest/trade_value.dart';
import 'package:chan_kline/backtest/trade_var_diagnose.dart';
import 'package:chan_kline/backtest/zhongshu_object_store.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/zs_frame.dart';
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
      code: 'test',
      period: '1m',
      barCount: asOf + 1,
      asOfX: asOf,
      beginText: '',
      endText: '',
    );

ZSFrame _zs({
  required int x1,
  required int x2,
  required double high,
  required double low,
  bool sure = true,
  int level = 0,
}) {
  return ZSFrame(
    x1: x1,
    x2: x2,
    high: high,
    low: low,
    gg: high,
    dd: low,
    level: level,
    isSure: sure,
  );
}

void main() {
  group('登记与钟门禁', () {
    test('K0..K2 确认中枢高/低/中轴进公式；旧 ZS.HIGH 仍只盘点', () {
      for (final kn in [0, 1, 2]) {
        for (final f in ['HIGH', 'LOW', 'CENTER']) {
          final id = 'STRUCTURE.K$kn.ZS.CURRENT.$f';
          final d = lookupTradeVariable(id, maxKn: 2)!;
          expect(d.expressionReady, isTrue, reason: id);
          expect(d.valueType, TradeValueType.numeric, reason: id);
          expect(d.clockFamily, TradeClockFamily.zsMath, reason: id);
        }
      }
      expect(lookupTradeVariable('STRUCTURE.K0.ZS.CURRENT.HIGH')!.evalClock,
          TradeEvalClock.k0Bar);
      expect(lookupTradeVariable('STRUCTURE.K1.ZS.CURRENT.LOW')!.evalClock,
          TradeEvalClock.knSample);
      expect(
        lookupTradeVariable('STRUCTURE.K2.ZS.HIGH')!.expressionReady,
        isFalse,
      );
    });

    test('同层收盘 vs 确认中枢合法；K0 收盘 vs K1 中枢非法', () {
      expect(
        compileBinaryOp(
          leftId: 'RAW.K1.CLOSE',
          rightId: 'STRUCTURE.K1.ZS.CURRENT.LOW',
          op: TradeBinaryOp.lt,
          maxKn: 2,
        ),
        isA<TradeExprOk>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'RAW.K0.CLOSE',
          rightId: 'STRUCTURE.K1.ZS.CURRENT.HIGH',
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'SUB.K1.ZS_CONFIRM',
          rightId: 'STRUCTURE.K1.ZS.CURRENT.LOW',
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileConditionAst(
          const TradeAndAst(
            TradeEventAst('SUB.K1.ZS_CONFIRM'),
            TradeCmpAst(
              left: TradeVarRef('RAW.K1.CLOSE'),
              right: TradeVarRef('STRUCTURE.K1.ZS.CURRENT.LOW'),
              op: TradeBinaryOp.lt,
            ),
          ),
          maxKn: 2,
        ),
        isA<CondCompileOk>(),
      );
    });
  });

  group('对象身份与生命周期', () {
    test('动态延伸 objectId 不变', () {
      final store = ZhongshuObjectStore();
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 3, x2: 5, high: 10, low: 8, sure: false)],
        asOf: 5,
      );
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 3, x2: 6, high: 10, low: 8)],
        asOf: 7,
      );
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 3, x2: 9, high: 12, low: 8)],
        asOf: 9,
      );
      final a = store.resolveCurrentConfirmedZs(displayKn: 0, asOf: 7)!;
      final b = store.resolveCurrentConfirmedZs(displayKn: 0, asOf: 9)!;
      expect(a.objectId, 'ZS|0|3');
      expect(b.objectId, a.objectId);
      expect(a.confirmX, 7);
      expect(b.endX, 9);
      expect(b.high, 12);
      expect(b.state, StructureObjectState.extended);
    });

    test('K100 当时看见的 HIGH 不跟未来扩大走', () {
      final store = ZhongshuObjectStore();
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 2, x2: 8, high: 10, low: 7)],
        asOf: 100,
      );
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 2, x2: 20, high: 15, low: 7)],
        asOf: 110,
      );
      final bars = [_bar(100, 9), _bar(110, 9)];
      final at100 = lookupTradeNumeric(
        variableId: 'STRUCTURE.K0.ZS.CURRENT.HIGH',
        asOf: 100,
        bars: bars,
        zsObjects: store,
      );
      final at110 = lookupTradeNumeric(
        variableId: 'STRUCTURE.K0.ZS.CURRENT.HIGH',
        asOf: 110,
        bars: bars,
        zsObjects: store,
      );
      expect(at100.value, closeTo(10, 1e-12));
      expect(at110.value, closeTo(15, 1e-12));
      expect(at100.value != at110.value, isTrue);
    });

    test('旧中枢结束后 CURRENT 切到新确认中枢', () {
      final store = ZhongshuObjectStore();
      store.ingestLevel(
        displayKn: 1,
        frames: [_zs(x1: 1, x2: 6, high: 10, low: 8)],
        asOf: 6,
      );
      store.ingestLevel(
        displayKn: 1,
        frames: [
          _zs(x1: 1, x2: 6, high: 10, low: 8),
          _zs(x1: 10, x2: 14, high: 20, low: 16),
        ],
        asOf: 14,
      );
      final oldId = store.resolveCurrentConfirmedZs(displayKn: 1, asOf: 6)!.objectId;
      final neu = store.resolveCurrentConfirmedZs(displayKn: 1, asOf: 14)!;
      expect(oldId, 'ZS|1|1');
      expect(neu.objectId, 'ZS|1|10');
      expect(neu.high, 20);
      final ended = store.snapshotOf(oldId, 14)!;
      expect(ended.state, StructureObjectState.ended);
    });

    test('没有确认中枢是不可用，不是 0', () {
      final store = ZhongshuObjectStore();
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 1, x2: 3, high: 10, low: 8, sure: false)],
        asOf: 3,
      );
      final bars = [_bar(3, 9)];
      final v = lookupTradeNumeric(
        variableId: 'STRUCTURE.K0.ZS.CURRENT.LOW',
        asOf: 3,
        bars: bars,
        zsObjects: store,
      );
      expect(v.isUnavailable, isTrue);
      expect(v.value, isNull);
      expect(store.resolveCurrentConfirmedZs(displayKn: 0, asOf: 3), isNull);
    });

    test('K0 / K1 同一套 CURRENT 规则', () {
      final store = ZhongshuObjectStore();
      store.ingestLevel(
        displayKn: 0,
        frames: [_zs(x1: 2, x2: 4, high: 11, low: 9)],
        asOf: 4,
      );
      store.ingestLevel(
        displayKn: 1,
        frames: [_zs(x1: 2, x2: 4, high: 21, low: 19, level: 0)],
        asOf: 4,
      );
      expect(
        store.resolveCurrentConfirmedZs(displayKn: 0, asOf: 4)!.objectId,
        'ZS|0|2',
      );
      expect(
        store.resolveCurrentConfirmedZs(displayKn: 1, asOf: 4)!.center,
        closeTo(20, 1e-12),
      );
    });
  });

  group('比较 / 穿越 / 综合回测', () {
    test('K0 CLOSE < ZS.LOW 与上穿 HIGH', () {
      final bars = [
        _bar(0, 10),
        _bar(1, 9),
        _bar(2, 8),
        _bar(3, 12),
      ];
      final store = ZhongshuObjectStore();
      for (var i = 0; i <= 3; i++) {
        store.ingestLevel(
          displayKn: 0,
          frames: i == 0
              ? const []
              : [_zs(x1: 0, x2: 1, high: 11, low: 9)],
          asOf: i,
        );
      }
      final lt = compileConditionAst(
        const TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeVarRef('STRUCTURE.K0.ZS.CURRENT.LOW'),
          op: TradeBinaryOp.lt,
        ),
      ) as CondCompileOk;
      final ltSig = evalCompiledCond(
        cond: lt.root,
        side: TradeSide.buy,
        ruleId: 'lt',
        ctx: CondEvalCtx(asOf: 3, bars: bars, zsObjects: store),
      );
      expect(ltSig.map((s) => s.discoveryX).toList(), [2]);

      final cross = compileConditionAst(
        const TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeVarRef('STRUCTURE.K0.ZS.CURRENT.HIGH'),
          op: TradeBinaryOp.crossAbove,
        ),
      ) as CondCompileOk;
      final xSig = evalCompiledCond(
        cond: cross.root,
        side: TradeSide.sell,
        ruleId: 'x',
        ctx: CondEvalCtx(asOf: 3, bars: bars, zsObjects: store),
      );
      expect(xSig.map((s) => s.discoveryX).toList(), [3]);
    });

    test('K1.BUY1 AND CLOSE<ZS.LOW / SELL1 OR CROSS_ABOVE HIGH 完整链路', () {
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
              low: 8,
              close: 9,
            ),
            LevelUnitBar(
              idx: 1,
              dir: -1,
              x1: 6,
              x2: 12,
              open: 9,
              high: 13,
              low: 9,
              close: 12.5,
            ),
          ],
        ),
      ];
      final zs = ZhongshuObjectStore();
      for (var i = 0; i <= 12; i++) {
        zs.ingestLevel(
          displayKn: 1,
          frames: i < 4
              ? [_zs(x1: 1, x2: 3, high: 11, low: 10, sure: false)]
              : [_zs(x1: 1, x2: i >= 8 ? 8 : 5, high: 11, low: 10)],
          asOf: i,
        );
      }
      final events = ChanEventStore(
        buy1ByKn: {
          1: [
            const Buy1Frame(
              x: 6,
              price: 9,
              label: '1Ba',
              segIdx: 3,
              level: 0,
            ),
          ],
        },
        sell1ByKn: {
          1: [
            const Sell1Frame(
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
            buyAst: k1Buy1AndZsLowAst(),
            sellAst: k1Sell1OrZsHighAst(),
          ),
          maxKn: 2,
        ),
        isA<StrategyCompileOk>(),
      );

      final run = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k1Buy1AndZsLowAst(),
          sellAst: k1Sell1OrZsHighAst(),
          initialCapital: 100000,
          quantity: 100,
        ),
        scope: _scope(12),
        bars: bars,
        levels: levels,
        mathFreeze: MathSeriesFreezeStore(),
        chanEvents: events,
        zsObjects: zs,
        maxKn: 2,
      );
      expect(run.ok, isTrue, reason: run.error);
      expect(run.engineVersion, kBacktestEngineVersion);
      final buys =
          run.result!.signals.where((s) => s.side == TradeSide.buy).toList();
      expect(buys.map((s) => s.discoveryX).toList(), [6]);
      expect(buys.first.conditionText, contains('BUY1'));
      expect(buys.first.conditionText, contains('ZS.CURRENT.LOW'));
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

  group('诊断', () {
    test('能看到 objectId、确认/起止时间和 HIGH/LOW/CENTER', () {
      final store = ZhongshuObjectStore();
      store.ingestLevel(
        displayKn: 1,
        frames: [_zs(x1: 4, x2: 8, high: 12, low: 10)],
        asOf: 8,
      );
      final d = diagnoseTradeVariable(
        variableId: 'STRUCTURE.K1.ZS.CURRENT.HIGH',
        asOf: 8,
        bars: [_bar(8, 11)],
        zsObjects: store,
        maxKn: 2,
      );
      expect(d.currentZs, isNotNull);
      expect(d.text, contains('ZS|1|4'));
      expect(d.text, contains('HIGH'));
      expect(d.text, contains('LOW'));
      expect(d.text, contains('CENTER'));
      expect(d.text, contains('K0 #8'));
    });
  });
}
