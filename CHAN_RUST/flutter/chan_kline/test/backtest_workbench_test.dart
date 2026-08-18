import 'package:chan_kline/backtest/account.dart';
import 'package:chan_kline/backtest/backtest_link.dart';
import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/backtest_result.dart';
import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/equity_build.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/strategy_config_form.dart';
import 'package:chan_kline/backtest/strategy_signal_painter.dart';
import 'package:chan_kline/backtest/strategy_trade_round.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

SignalEvent _sig(String id, TradeSide side, int x) {
  return SignalEvent(
    signalId: id,
    ruleId: side == TradeSide.buy ? 'boll_cross_buy' : 'boll_cross_sell',
    side: side,
    op: side == TradeSide.buy
        ? TradeBinaryOp.crossBelow
        : TradeBinaryOp.crossAbove,
    displayKn: 0,
    clockFamily: TradeClockFamily.zsMath,
    evalIndex: 0,
    discoveryX: x,
    availableAt: x,
    signalPrice: 10,
    source: 'test',
    leftValue: 10,
    rightValue: 10,
    leftId: 'RAW.K0.CLOSE',
    rightId: side == TradeSide.buy ? 'MAIN.K0.BOLL.DOWN' : 'MAIN.K0.BOLL.UP',
  );
}

void main() {
  group('策略配置编译门禁', () {
    test('同一层 CLOSE 与布林轨能编过；层号写在 AST 上锁死', () {
      final cfg = StrategyConfig.bollLayers(buyKn: 1, sellKn: 1);
      expect(astConditionText(cfg.buyAst), contains('K1.CLOSE'));
      expect(astConditionText(cfg.buyAst), contains('K1.BOLL.DOWN'));
      expect(astConditionText(cfg.sellAst), contains('K1.BOLL.UP'));
      expect(compileBollCrossStrategy(cfg, maxKn: 2), isA<StrategyCompileOk>());
    });

    test('买 K0、卖 K2 仍合法：两条腿各自同层，不是一条表达式混层', () {
      final cfg = StrategyConfig.bollLayers(buyKn: 0, sellKn: 2);
      expect(compileBollCrossStrategy(cfg, maxKn: 2), isA<StrategyCompileOk>());
    });

    test('层号超出当前图上最大层 → 非法，不进 CROSS', () {
      final cfg = StrategyConfig.bollLayers(buyKn: 5, sellKn: 0);
      final r = compileBollCrossStrategy(cfg, maxKn: 1);
      expect(r, isA<StrategyCompileIllegal>());
    });

    test('混层比较仍然只能走 compileBinaryOp，配不出来', () {
      final mixed = compileBinaryOp(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'MAIN.K1.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
      );
      expect(mixed, isA<TradeExprIllegal>());
    });
  });

  group('BacktestRun / 链路', () {
    test('空 K 线给出明确错误，不虚构结果', () {
      final run = executeStrategyBacktest(
        config: const StrategyConfig(),
        scope: const BacktestDataScope(
          code: 'test',
          period: '1m',
          barCount: 0,
          asOfX: 0,
          beginText: '',
          endText: '',
        ),
        bars: const [],
        mathFreeze: MathSeriesFreezeStore(),
      );
      expect(run.ok, isFalse);
      expect(run.engineVersion, kBacktestEngineVersion);
      expect(run.error, contains('K 线'));
    });

    test('第 n 笔交易能追到入场/出场信号，不另算', () {
      final buy = _sig('b1', TradeSide.buy, 2);
      final sell = _sig('s1', TradeSide.sell, 6);
      final trade = TradeRecord(
        tradeId: 'T1',
        entrySignalId: 'b1',
        exitSignalId: 's1',
        entryX: 3,
        exitX: 7,
        entryPrice: 10,
        exitPrice: 12,
        quantity: 100,
        grossPnL: 200,
      );
      final bars = [
        for (var i = 0; i <= 8; i++)
          KlineBar(
            idx: i,
            timeMs: i * 60000,
            timeText: 't$i',
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 1,
            amount: 1,
          ),
      ];
      final fills = [
        Fill(
          fillId: 'F1',
          orderId: 'O1',
          signalId: 'b1',
          side: TradeSide.buy,
          quantity: 100,
          price: 10,
          executeX: 3,
        ),
        Fill(
          fillId: 'F2',
          orderId: 'O2',
          signalId: 's1',
          side: TradeSide.sell,
          quantity: 100,
          price: 12,
          executeX: 7,
        ),
      ];
      final curve = buildEquityCurve(
        bars: bars,
        fills: fills,
        initialCash: 100000,
      );
      final result = BacktestResult(
        signals: [buy, sell],
        orders: [
          Order(
            orderId: 'O1',
            signalId: 'b1',
            side: TradeSide.buy,
            quantity: 100,
            createdAt: 2,
            executeAt: 3,
            status: OrderStatus.filled,
          ),
          Order(
            orderId: 'O2',
            signalId: 's1',
            side: TradeSide.sell,
            quantity: 100,
            createdAt: 6,
            executeAt: 7,
            status: OrderStatus.filled,
          ),
        ],
        fills: fills,
        trades: [trade],
        equityCurve: curve,
        metrics: computeBacktestMetrics(
          initialCapital: 100000,
          equityCurve: curve,
          closedTrades: [trade],
        ),
        openPosition: null,
        account: AccountState(cash: 100200),
        lastPrice: 10,
        initialCapital: 100000,
      );
      final link = BacktestLinkIndex(result);
      expect(link.entrySignalOf(result.trades.first)?.signalId, 'b1');
      expect(link.exitSignalOf(result.trades.first)?.signalId, 's1');
      expect(link.tradeForSignal('b1')?.tradeId, 'T1');
      expect(link.fillForSignal('b1')?.executeX, 3);
      expect(link.orderForSignal('s1')?.status, OrderStatus.filled);
      expect(result.metrics.netProfit, closeTo(curve.last.equity - 100000, 1e-6));
    });
  });

  group('策略点命中', () {
    test('买点落在对应 discoveryX 柱心附近', () {
      final bars = [
        for (var i = 0; i < 5; i++)
          KlineBar(
            idx: i,
            timeMs: i,
            timeText: '$i',
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 1,
            amount: 1,
          ),
      ];
      final vp = KlineViewport()..resetForBarCount(5);
      final pr = vp.priceRangeFor(bars);
      final sig = _sig('b1', TradeSide.buy, 2);
      final c = strategyMarkerCenter(
        signal: sig,
        bars: bars,
        viewport: vp,
        priceRange: pr,
        canvasW: 500,
        plotTop: 28,
        plotH: 200,
      );
      expect(c, isNotNull);
      expect(c!.dx, closeTo(vp.barCenterX(2, 500), 0.5));
      final hit = hitTestStrategySignal(
        local: c,
        signals: [sig],
        bars: bars,
        viewport: vp,
        priceRange: pr,
        canvasW: 500,
        plotTop: 28,
        plotH: 200,
      );
      expect(hit?.signal.signalId, 'b1');
    });

    test('有成交时画在发现根，被拒不画', () {
      final bars = [
        for (var i = 0; i < 5; i++)
          KlineBar(
            idx: i,
            timeMs: i,
            timeText: '$i',
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 1,
            amount: 1,
          ),
      ];
      final vp = KlineViewport()..resetForBarCount(5);
      final pr = vp.priceRangeFor(bars);
      final buy = _sig('b1', TradeSide.buy, 2);
      final sell = _sig('s1', TradeSide.sell, 2);
      const fills = [
        Fill(
          fillId: 'F1',
          orderId: 'O1',
          signalId: 'b1',
          side: TradeSide.buy,
          quantity: 1,
          price: 10,
          executeX: 3,
        ),
      ];
      expect(strategyMarkerPlotX(signal: buy, fills: fills), 2);
      expect(strategyMarkerPlotX(signal: sell, fills: fills), isNull);
      final c = strategyMarkerCenter(
        signal: buy,
        bars: bars,
        viewport: vp,
        priceRange: pr,
        canvasW: 500,
        plotTop: 28,
        plotH: 200,
        fills: fills,
      );
      expect(c, isNotNull);
      expect(c!.dx, closeTo(vp.barCenterX(2, 500), 0.5));
      final rejected = strategyMarkerCenter(
        signal: sell,
        bars: bars,
        viewport: vp,
        priceRange: pr,
        canvasW: 500,
        plotTop: 28,
        plotH: 200,
        fills: fills,
      );
      expect(rejected, isNull);
      final hit = hitTestStrategySignal(
        local: c,
        signals: [buy, sell],
        bars: bars,
        viewport: vp,
        priceRange: pr,
        canvasW: 500,
        plotTop: 28,
        plotH: 200,
        fills: fills,
      );
      expect(hit?.signal.signalId, 'b1');
    });

    test('平移视口后策略点应重绘（窗已拷贝，不跟共享对象比）', () {
      final bars = [
        for (var i = 0; i < 5; i++)
          KlineBar(
            idx: i,
            timeMs: i,
            timeText: '$i',
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 1,
            amount: 1,
          ),
      ];
      final vp = KlineViewport()..resetForBarCount(5);
      final pr = vp.priceRangeFor(bars);
      StrategySignalPainter make() => StrategySignalPainter(
            bars: bars,
            signals: [_sig('b1', TradeSide.buy, 2)],
            highlightedIds: const {},
            viewport: vp,
            priceRange: pr,
            mainH: 200,
          );
      final a = make();
      vp.viewXMin += 1.2;
      vp.viewXMax += 1.2;
      final b = make();
      expect(b.shouldRepaint(a), isTrue);
    });
  });

  group('策略买卖组号', () {
    test('闭合交易按顺序编号买1卖1买2卖2', () {
      final buy1 = _sig('b1', TradeSide.buy, 2);
      final sell1 = _sig('s1', TradeSide.sell, 6);
      final buy2 = _sig('b2', TradeSide.buy, 8);
      final sell2 = _sig('s2', TradeSide.sell, 10);
      final trades = [
        TradeRecord(
          tradeId: 'T1',
          entrySignalId: 'b1',
          exitSignalId: 's1',
          entryX: 2,
          exitX: 6,
          entryPrice: 10,
          exitPrice: 12,
          quantity: 100,
          grossPnL: 200,
        ),
        TradeRecord(
          tradeId: 'T2',
          entrySignalId: 'b2',
          exitSignalId: 's2',
          entryX: 8,
          exitX: 10,
          entryPrice: 11,
          exitPrice: 13,
          quantity: 100,
          grossPnL: 200,
        ),
      ];
      final result = BacktestResult(
        signals: [buy1, sell1, buy2, sell2],
        orders: const [],
        fills: const [],
        trades: trades,
        equityCurve: const [],
        metrics: computeBacktestMetrics(
          initialCapital: 100000,
          equityCurve: const [],
          closedTrades: trades,
        ),
        openPosition: null,
        account: AccountState(cash: 100000),
        lastPrice: 10,
        initialCapital: 100000,
      );
      final rounds = buildStrategyRoundIndex(result);
      expect(rounds.sideLabel(buy1), '买1');
      expect(rounds.sideLabel(sell1), '卖1');
      expect(rounds.sideLabel(buy2), '买2');
      expect(rounds.sideLabel(sell2), '卖2');
      expect(rounds.tradeGroupLabel(result.trades.first), '买1→卖1');
      expect(rounds.tradeGroupShort(result.trades.last), '组2');
    });

    test('期末持仓只有买N', () {
      final buy = _sig('bOpen', TradeSide.buy, 5);
      final result = BacktestResult(
        signals: [buy],
        orders: const [],
        fills: const [],
        trades: const [],
        equityCurve: const [],
        metrics: computeBacktestMetrics(
          initialCapital: 100000,
          equityCurve: const [],
          closedTrades: const [],
        ),
        openPosition: OpenPosition(
          entrySignalId: 'bOpen',
          entryX: 5,
          avgCost: 10,
          quantity: 100,
          marketValue: 1100,
          unrealizedPnL: 100,
        ),
        account: AccountState(cash: 90000, positionQty: 100, avgCost: 10),
        lastPrice: 11,
        initialCapital: 100000,
      );
      final rounds = buildStrategyRoundIndex(result);
      expect(rounds.sideLabel(buy), '买1');
    });
  });

  group('配置 UI 条件构建器', () {
    testWidgets('买卖可搭比较/穿越/AND，不再写死收盘下穿布林', (tester) async {
      var cfg = const StrategyConfig();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: StrategyConfigForm(
                config: cfg,
                maxKn: 3,
                onChanged: (c) => cfg = c,
              ),
            ),
          ),
        ),
      );
      expect(find.text('收盘  下穿  布林下轨'), findsNothing);
      expect(find.textContaining('变量诊断'), findsOneWidget);
      expect(find.text('买入条件（同层同钟，真假由回测引擎算）'), findsOneWidget);
      expect(find.text('下穿'), findsWidgets);
      expect(find.text('上穿'), findsWidgets);
      expect(find.text('添加条件'), findsNWidgets(2));
      await tester.tap(find.text('添加条件').first);
      await tester.pumpAndSettle();
      expect(find.text('AND'), findsWidgets);
      expect(find.text('OR'), findsWidgets);
      expect(find.text('K0收盘穿K1布林'), findsNothing);
    });
  });
}
