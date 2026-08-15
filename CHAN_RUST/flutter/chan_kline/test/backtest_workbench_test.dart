import 'package:chan_kline/backtest/account.dart';
import 'package:chan_kline/backtest/backtest_link.dart';
import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/backtest_result.dart';
import 'package:chan_kline/backtest/backtest_run.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/equity_build.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/strategy_config_form.dart';
import 'package:chan_kline/backtest/strategy_signal_painter.dart';
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
