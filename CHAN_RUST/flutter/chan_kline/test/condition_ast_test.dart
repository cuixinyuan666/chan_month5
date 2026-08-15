import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/condition_eval.dart';
import 'package:chan_kline/backtest/mini_loop.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/signal_normalize.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
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

CondEvalCtx _ctx(List<KlineBar> bars) => CondEvalCtx(
      asOf: bars.last.idx,
      bars: bars,
      mathFreeze: MathSeriesFreezeStore(),
    );

void main() {
  group('AST 编译门禁', () {
    test('单条件变量比较：同层 CLOSE > OPEN 合法', () {
      const ast = TradeCmpAst(
        left: TradeVarRef('RAW.K0.CLOSE'),
        right: TradeVarRef('RAW.K0.OPEN'),
        op: TradeBinaryOp.gt,
      );
      expect(compileConditionAst(ast, maxKn: 2), isA<CondCompileOk>());
    });

    test('变量 vs 常数：K0.CLOSE > 10 合法', () {
      const ast = TradeCmpAst(
        left: TradeVarRef('RAW.K0.CLOSE'),
        right: TradeConstRef(10),
        op: TradeBinaryOp.gt,
      );
      expect(compileConditionAst(ast), isA<CondCompileOk>());
    });

    test('常数 vs 常数非法', () {
      const ast = TradeCmpAst(
        left: TradeConstRef(1),
        right: TradeConstRef(2),
        op: TradeBinaryOp.gt,
      );
      expect(compileConditionAst(ast), isA<CondCompileIllegal>());
    });

    test('CROSS 同层合法；K0 × K1 非法', () {
      expect(
        compileConditionAst(bollBuyAst(0)),
        isA<CondCompileOk>(),
      );
      expect(
        compileConditionAst(bollBuyAst(1), maxKn: 2),
        isA<CondCompileOk>(),
      );
      const mixed = TradeCmpAst(
        left: TradeVarRef('RAW.K0.CLOSE'),
        right: TradeVarRef('MAIN.K1.BOLL.DOWN'),
        op: TradeBinaryOp.crossBelow,
      );
      expect(compileConditionAst(mixed, maxKn: 2), isA<CondCompileIllegal>());
    });

    test('AND/OR 同层合法；K0 AND K1 非法', () {
      final same = TradeAndAst(
        bollBuyAst(1),
        const TradeCmpAst(
          left: TradeVarRef('RAW.K1.CLOSE'),
          right: TradeVarRef('MAIN.K1.BOLL.MID'),
          op: TradeBinaryOp.lt,
        ),
      );
      expect(compileConditionAst(same, maxKn: 2), isA<CondCompileOk>());
      final mixed = TradeAndAst(
        const TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(10),
          op: TradeBinaryOp.gt,
        ),
        const TradeCmpAst(
          left: TradeVarRef('RAW.K1.CLOSE'),
          right: TradeConstRef(10),
          op: TradeBinaryOp.gt,
        ),
      );
      expect(compileConditionAst(mixed, maxKn: 2), isA<CondCompileIllegal>());
    });

    test('K1 综合买卖策略能编过；买卖各自独立', () {
      final cfg = StrategyConfig(
        buyAst: k1CompositeBuyAst(),
        sellAst: k1CompositeSellAst(),
      );
      expect(compileStrategyConfig(cfg, maxKn: 2), isA<StrategyCompileOk>());
      final buyOnly = compileConditionAst(cfg.buyAst, maxKn: 2);
      final sellOnly = compileConditionAst(cfg.sellAst, maxKn: 2);
      expect(buyOnly, isA<CondCompileOk>());
      expect(sellOnly, isA<CondCompileOk>());
    });
  });

  group('AST 求值（计算钟，假变真才出信号）', () {
    test('变量 vs 常数：CLOSE > 10 只在假变真时打一次', () {
      final bars = [
        _bar(0, 8),
        _bar(1, 9),
        _bar(2, 12),
        _bar(3, 13),
        _bar(4, 7),
        _bar(5, 11),
      ];
      final compiled = compileConditionAst(const TradeCmpAst(
        left: TradeVarRef('RAW.K0.CLOSE'),
        right: TradeConstRef(10),
        op: TradeBinaryOp.gt,
      )) as CondCompileOk;
      final ev = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: _ctx(bars),
      );
      expect(ev.map((e) => e.discoveryX).toList(), [2, 5]);
      expect(ev.first.conditionText, contains('K0.CLOSE > 10'));
      expect(ev.first.snapshots, isNotEmpty);
      expect(ev.first.explainBlock, contains('买点'));
      expect(ev.first.explainBlock, contains('K0 #2'));
    });

    test('CROSS_ABOVE 与旧边沿同一根；持续在上侧不重复', () {
      final bars = [
        _bar(0, 8),
        _bar(1, 9),
        _bar(2, 12),
        _bar(3, 13),
      ];
      final compiled = compileConditionAst(const TradeCmpAst(
        left: TradeVarRef('RAW.K0.CLOSE'),
        right: TradeConstRef(10),
        op: TradeBinaryOp.crossAbove,
      )) as CondCompileOk;
      final ev = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: _ctx(bars),
      );
      expect(ev.map((e) => e.discoveryX).toList(), [2]);
    });

    test('AND：穿越当根同时满足比较才出信号', () {
      // 8,9,12,13：上穿 10 在 #2；CLOSE < 12.5 在 #2 仍真、#3 假
      final bars = [
        _bar(0, 8),
        _bar(1, 9),
        _bar(2, 12),
        _bar(3, 13),
      ];
      final ast = const TradeAndAst(
        TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(10),
          op: TradeBinaryOp.crossAbove,
        ),
        TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(12.5),
          op: TradeBinaryOp.lt,
        ),
      );
      final compiled = compileConditionAst(ast) as CondCompileOk;
      final ev = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.buy,
        ruleId: 'ast_buy',
        ctx: _ctx(bars),
      );
      expect(ev.map((e) => e.discoveryX).toList(), [2]);
      expect(ev.single.conditionText, contains('AND'));
    });

    test('OR：比较先真时在比较那根出信号，不要求再等穿越', () {
      // CLOSE > 4 从 #0 就真 → 上升沿在 #0；后面上穿 10 不再重复
      final bars = [
        _bar(0, 8),
        _bar(1, 9),
        _bar(2, 12),
      ];
      final ast = const TradeOrAst(
        TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(10),
          op: TradeBinaryOp.crossAbove,
        ),
        TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(4),
          op: TradeBinaryOp.gt,
        ),
      );
      final compiled = compileConditionAst(ast) as CondCompileOk;
      final ev = evalCompiledCond(
        cond: compiled.root,
        side: TradeSide.sell,
        ruleId: 'ast_sell',
        ctx: _ctx(bars),
      );
      expect(ev.map((e) => e.discoveryX).toList(), [0]);
      expect(ev.single.side, TradeSide.sell);
    });

    test('买卖条件独立：买 CLOSE>10，卖 CLOSE<0（永不）只出买点', () {
      final bars = [_bar(0, 8), _bar(1, 12), _bar(2, 13), _bar(3, 14)];
      final cfg = const StrategyConfig(
        buyAst: TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(10),
          op: TradeBinaryOp.gt,
        ),
        sellAst: TradeCmpAst(
          left: TradeVarRef('RAW.K0.CLOSE'),
          right: TradeConstRef(0),
          op: TradeBinaryOp.lt,
        ),
      );
      final run = executeStrategyBacktest(
        config: cfg,
        scope: _scope(3),
        bars: bars,
        mathFreeze: MathSeriesFreezeStore(),
      );
      expect(run.ok, isTrue);
      expect(run.result!.signals.every((s) => s.side == TradeSide.buy), isTrue);
      expect(run.result!.signals, isNotEmpty);
    });
  });

  group('同一套 AST → 现有回测核心', () {
    test('默认布林穿越 AST 与旧 CROSS 路径发现点一致', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 24; i++) _bar(i, 100, open: 100),
        for (var i = 24; i < 40; i++) _bar(i, 40, open: 41),
        for (var i = 40; i < 56; i++) _bar(i, 180, open: 179),
      ];
      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(bollN: 20),
        maxDisplayKn: 0,
        asOf: bars.last.idx,
      );
      final old = runMiniLongOnlyLoop(
        bars: bars,
        mathFreeze: store,
        buyRule: CrossRule.bollBuy(),
        sellRule: CrossRule.bollSell(),
        quantity: 100,
        initialCash: 1000000,
        bollN: 20,
      );
      final run = executeStrategyBacktest(
        config: const StrategyConfig(),
        scope: _scope(bars.last.idx),
        bars: bars,
        mathFreeze: store,
        bollN: 20,
        maxKn: 0,
      );
      expect(run.ok, isTrue);
      final astBuy = run.result!.signals
          .where((s) => s.side == TradeSide.buy)
          .map((s) => s.discoveryX)
          .toList();
      final oldBuy = old.signals
          .where((s) => s.side == TradeSide.buy)
          .map((s) => s.discoveryX)
          .toList();
      expect(astBuy, oldBuy);
      final astSell = run.result!.signals
          .where((s) => s.side == TradeSide.sell)
          .map((s) => s.discoveryX)
          .toList();
      final oldSell = old.signals
          .where((s) => s.side == TradeSide.sell)
          .map((s) => s.discoveryX)
          .toList();
      expect(astSell, oldSell);
      expect(run.result!.trades.length, old.trades.length);
      expect(run.engineVersion, kBacktestEngineVersion);
    });

    test('K1 综合策略能跑通（无第二套 UI 计算）', () {
      final bars = [_bar(0, 10), _bar(1, 11), _bar(2, 12)];
      final run = executeStrategyBacktest(
        config: StrategyConfig(
          buyAst: k1CompositeBuyAst(),
          sellAst: k1CompositeSellAst(),
        ),
        scope: _scope(2),
        bars: bars,
        mathFreeze: MathSeriesFreezeStore(),
        maxKn: 2,
      );
      expect(compileStrategyConfig(run.strategyConfig, maxKn: 2),
          isA<StrategyCompileOk>());
      expect(run.ok, isTrue);
      expect(run.error, isNull);
    });
  });
}
