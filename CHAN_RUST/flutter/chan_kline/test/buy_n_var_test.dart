import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/buy_n_var.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/buy_n_frame.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/sell_n_frame.dart';
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

BuyNFrame _bn({
  required int x,
  required int cls,
  required String label,
  int seg = 3,
  int level = 0,
  double price = 10,
}) {
  return BuyNFrame(
    cls: cls,
    x: x,
    price: price,
    label: label,
    segIdx: seg,
    level: level,
  );
}

void main() {
  group('登记', () {
    test('BUY_N/SELL_N 按 class 登记，不硬编码 BUY3', () {
      for (final kn in [0, 1, 2]) {
        for (final cls in [3, 4, 5, 6]) {
          final buy = lookupTradeVariable(buyNVarId(kn, cls), maxKn: 2)!;
          expect(buy.expressionReady, isTrue, reason: buy.variableId);
          expect(buy.valueType, TradeValueType.event);
          expect(buy.evalClock, TradeEvalClock.k0Bar);
          final sell = lookupTradeVariable(sellNVarId(kn, cls), maxKn: 2)!;
          expect(sell.valueType, TradeValueType.event);
        }
      }
      expect(lookupTradeVariable('STRUCTURE.K1.BUY3'), isNull);
      expect(lookupTradeVariable('STRUCTURE.K1.BUY_N.7')!.expressionReady, isTrue);
      expect(lookupTradeVariable('STRUCTURE.K1.BUY_N.21'), isNull);
      expect(
        lookupTradeVariable('CHAN.K0.SELL_N.3')!.variableId,
        sellNVarId(0, 3),
      );
    });

    test('BUY_N 不能比较/穿越；可与同层 RSI AND', () {
      expect(
        compileValuePair(
          left: const TradeVarRef('STRUCTURE.K1.BUY_N.3'),
          right: const TradeConstRef(0),
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        (compileValuePair(
          left: const TradeVarRef('STRUCTURE.K1.BUY_N.3'),
          right: const TradeConstRef(0),
          op: TradeBinaryOp.gt,
          maxKn: 2,
        ) as TradeExprIllegal)
            .kind,
        TradeCompileErrorKind.type,
      );
      expect(compileConditionAst(k1BuyN3AndRsiAst(), maxKn: 2), isA<CondCompileOk>());
      expect(compileConditionAst(k1BuyN3OrBuy1Ast(), maxKn: 2), isA<CondCompileOk>());
      expect(compileConditionAst(k0Buy1OrK1BuyN3Ast(), maxKn: 2), isA<CondCompileOk>());
      expect(isChanClassBsEventVarId('STRUCTURE.K0.BUY1'), isTrue);
      expect(isChanClassBsEventVarId('STRUCTURE.K1.BUY_N.4'), isTrue);
      expect(isChanClassBsEventVarId('SUB.K1.FRACTAL_CONFIRM'), isFalse);
    });
  });

  group('发现边沿 / 动态延伸 / 未来不可见', () {
    test('同一稳定身份多次 x 只出一次信号', () {
      final bars = _bars(110);
      final store = ChanEventStore(
        buyNByKn: {
          1: [
            _bn(x: 100, cls: 3, label: '3Ba', price: 12.5),
            _bn(x: 101, cls: 3, label: '3Ba', price: 12.4),
            _bn(x: 102, cls: 3, label: '3Ba', price: 12.3),
          ],
        },
      );
      final listed = listTradeChanEvents(
        variableId: 'CHAN.K1.BUY_N.3',
        asOf: 103,
        store: store,
        maxKn: 2,
      );
      expect(listed.length, 1);
      expect(listed.single.discoveryX, 100);

      final compiled =
          compileConditionAst(TradeEventAst(buyNVarId(1, 3)), maxKn: 2)
              as CondCompileOk;
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

    test('不同类号互不干扰；K0/K1 分层', () {
      final store = ChanEventStore(
        buyNByKn: {
          0: [_bn(x: 10, cls: 3, label: '3Ba', level: 0)],
          1: [
            _bn(x: 20, cls: 3, label: '3Ba', level: 0),
            _bn(x: 21, cls: 4, label: '4Ba', seg: 4, level: 0),
          ],
        },
        sellNByKn: {
          1: [
            SellNFrame(
              cls: 3,
              x: 30,
              price: 11,
              label: '3Sa',
              segIdx: 5,
              level: 0,
            ),
          ],
        },
      );
      expect(
        listTradeChanEvents(
          variableId: buyNVarId(1, 3),
          asOf: 40,
          store: store,
          maxKn: 2,
        ).single.discoveryX,
        20,
      );
      expect(
        listTradeChanEvents(
          variableId: buyNVarId(1, 4),
          asOf: 40,
          store: store,
          maxKn: 2,
        ).single.discoveryX,
        21,
      );
      expect(
        listTradeChanEvents(
          variableId: buyNVarId(0, 3),
          asOf: 40,
          store: store,
          maxKn: 2,
        ).single.discoveryX,
        10,
      );
      expect(
        listTradeChanEvents(
          variableId: sellNVarId(1, 3),
          asOf: 40,
          store: store,
          maxKn: 2,
        ).single.discoveryX,
        30,
      );
    });

    test('未来才出现的 N 类不能进入过去的回测', () {
      final store = ChanEventStore(
        buyNByKn: {
          1: [
            _bn(x: 100, cls: 3, label: '3Ba'),
            _bn(x: 150, cls: 3, label: '3Bb', seg: 4),
          ],
        },
      );
      final listed = listTradeChanEvents(
        variableId: buyNVarId(1, 3),
        asOf: 120,
        store: store,
        maxKn: 2,
      );
      expect(listed.map((e) => e.discoveryX).toList(), [100]);
    });
  });

  group('与一类/RSI 混合 + 成交钟', () {
    test('BUY_N(3) OR BUY1：两处发现各出一次；下一根开盘成交', () {
      final bars = [
        for (var i = 0; i <= 12; i++) _bar(i, 10.0 + i, open: 10.0 + i),
      ];
      final store = ChanEventStore(
        buy1ByKn: {
          1: [
            const Buy1Frame(
              x: 4,
              price: 14,
              label: '1Ba',
              segIdx: 2,
              level: 0,
            ),
          ],
        },
        sell1ByKn: {
          1: [
            const Sell1Frame(
              x: 6,
              price: 16,
              label: '1Sa',
              segIdx: 2,
              level: 0,
            ),
          ],
        },
        buyNByKn: {
          1: [_bn(x: 8, cls: 3, label: '3Ba', price: 18, seg: 3)],
        },
      );
      final cfg = StrategyConfig(
        buyAst: k1BuyN3OrBuy1Ast(),
        sellAst: k1Sell1EventAst,
        quantity: 100,
        initialCapital: 100000,
        fillPriceMode: TradeFillPriceMode.nextBarOpen,
      );
      expect(compileStrategyConfig(cfg, maxKn: 2), isA<StrategyCompileOk>());
      final run = executeStrategyBacktest(
        config: cfg,
        scope: _scope(12),
        bars: bars,
        mathFreeze: MathSeriesFreezeStore(),
        chanEvents: store,
        maxKn: 2,
      );
      expect(run.ok, isTrue);
      final buys = run.result!.signals.where((s) => s.side == TradeSide.buy);
      expect(buys.map((s) => s.discoveryX).toList(), [4, 8]);
      expect(buys.first.trace, isNotNull);
      expect(buys.first.trace!.text.contains('OR'), isTrue);
      final fills = run.result!.fills.where((f) => f.side == TradeSide.buy);
      expect(fills.map((f) => f.executeX).toList(), [5, 9]);
      expect(run.result!.rulePerformances, isNotEmpty);
      expect(run.context, isNotNull);
      expect(run.context!.engineVersion, kBacktestEngineVersion);
      expect(run.context!.dataContractVersion, 'catalog-v4-chip-peaks');
    });
  });
}
