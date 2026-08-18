import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close, {double vol = 1}) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: close,
    high: close + 1,
    low: close - 1,
    close: close,
    volume: vol,
    amount: 1,
  );
}

void main() {
  group('目录登记', () {
    test('K0 开高低收量 + 各层布林已登记；一类买点是事件', () {
      final regs = buildRegisteredTradeVariables(1);
      expect(regs.any((e) => e.variableId == 'RAW.K0.CLOSE'), isTrue);
      expect(regs.any((e) => e.variableId == 'RAW.K0.VOLUME'), isTrue);
      expect(regs.any((e) => e.variableId == 'RAW.K1.CLOSE'), isTrue);
      expect(regs.any((e) => e.variableId == 'MAIN.K0.BOLL.DOWN'), isTrue);
      expect(regs.any((e) => e.variableId == 'MAIN.K1.BOLL.UP'), isTrue);
      expect(regs.any((e) => e.variableId == 'SUB.K0.MACD.DIF'), isTrue);
      expect(regs.any((e) => e.variableId == 'SUB.K1.MACD.HIST'), isTrue);
      expect(regs.any((e) => e.variableId == 'SUB.K1.RSI.VALUE'), isTrue);
      expect(regs.any((e) => e.variableId == 'SUB.K1.KDJ.K'), isTrue);
      // 成交量只登记 K0
      expect(regs.any((e) => e.variableId == 'RAW.K1.VOLUME'), isFalse);

      // 一类买点已进公式（事件，不能拿去比较）
      final buy1 = lookupTradeVariable('STRUCTURE.K0.BUY1');
      expect(buy1, isNotNull);
      expect(buy1!.expressionReady, isTrue);
      expect(buy1.valueType, TradeValueType.event);

      final zsHigh = lookupTradeVariable('STRUCTURE.K2.ZS.HIGH');
      expect(zsHigh, isNotNull);
      expect(zsHigh!.expressionReady, isFalse);

      final zsCur = lookupTradeVariable('STRUCTURE.K1.ZS.CURRENT.HIGH');
      expect(zsCur, isNotNull);
      expect(zsCur!.expressionReady, isTrue);
      expect(zsCur.valueType, TradeValueType.objectProjection);
      expect(zsCur.clockFamily, TradeClockFamily.zsMath);
      expect(zsCur.evalClock, TradeEvalClock.knSample);

      final exists = lookupTradeVariable('STRUCTURE.K1.DIVERGENCE.EXISTS');
      expect(exists, isNotNull);
      expect(exists!.expressionReady, isTrue);
      expect(exists.valueType, TradeValueType.event);
      expect(exists.evalClock, TradeEvalClock.k0Bar);

      final ratio = lookupTradeVariable('STRUCTURE.K1.DIVERGENCE.RATIO');
      expect(ratio, isNotNull);
      expect(ratio!.expressionReady, isTrue);
      expect(ratio.valueType, TradeValueType.relationProjection);
      expect(ratio.evalClock, TradeEvalClock.knSample);

      final dir = lookupTradeVariable('STRUCTURE.K1.DIVERGENCE.DIRECTION');
      expect(dir, isNotNull);
      expect(dir!.expressionReady, isTrue);
      expect(dir.valueType, TradeValueType.enumeration);

      final buyN = lookupTradeVariable('STRUCTURE.K1.BUY_N.3');
      expect(buyN, isNotNull);
      expect(buyN!.expressionReady, isTrue);
      expect(buyN.valueType, TradeValueType.event);
      expect(
        lookupTradeVariable('CHAN.K1.BUY_N.3')!.variableId,
        'STRUCTURE.K1.BUY_N.3',
      );
    });

    test('同层同钟才能编译成比较/穿越；混层在编译阶段就是非法表达式', () {
      final ok = compileBinaryOp(
        leftId: 'RAW.K1.CLOSE',
        rightId: 'MAIN.K1.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
      );
      expect(ok, isA<TradeExprOk>());
      final pair = (ok as TradeExprOk).pair;
      expect(pair.left.displayKn, 1);
      expect(pair.right.displayKn, 1);
      expect(pair.left.clockFamily, TradeClockFamily.zsMath);
      expect(pair.right.clockFamily, TradeClockFamily.zsMath);
      expect(pair.left.evalClock, TradeEvalClock.knSample);

      final mixed = compileBinaryOp(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'MAIN.K1.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
      );
      expect(mixed, isA<TradeExprIllegal>());
      final mixedErr = mixed as TradeExprIllegal;
      expect(mixedErr.reason.contains('不是同一层同一套钟'), isTrue);
      expect(mixedErr.kind, TradeCompileErrorKind.clock);

      final eventCmp = compileBinaryOp(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'STRUCTURE.K0.BUY1',
        op: TradeBinaryOp.gt,
      );
      expect(eventCmp, isA<TradeExprIllegal>());
      expect((eventCmp as TradeExprIllegal).kind, TradeCompileErrorKind.type);

      expect(
        canCombineInExpression('RAW.K0.CLOSE', 'MAIN.K0.BOLL.DOWN'),
        isTrue,
      );
      expect(
        canCombineInExpression('RAW.K0.CLOSE', 'MAIN.K1.BOLL.DOWN'),
        isFalse,
      );
    });

    test('K1 收盘 evalClock=虚拟K样本，plotClock=K0格子；成交钟固定 K0', () {
      final close1 = lookupTradeVariable('RAW.K1.CLOSE')!;
      expect(close1.evalClock, TradeEvalClock.knSample);
      expect(close1.plotClock, TradePlotClock.k0Bar);
      final close0 = lookupTradeVariable('RAW.K0.CLOSE')!;
      expect(close0.evalClock, TradeEvalClock.k0Bar);
      expect(kTradeExecutionClock, TradeExecutionClock.k0NextOpen);
      expect(kDefaultTradeFillPriceMode, TradeFillPriceMode.sameBarClose);
    });
  });

  group('取值', () {
    test('K0 收盘 / 成交量按当根读；越界不可用', () {
      final bars = [_bar(0, 10, vol: 3), _bar(1, 12, vol: 5)];
      final c0 = lookupTradeNumeric(
        variableId: 'RAW.K0.CLOSE',
        asOf: 0,
        bars: bars,
      );
      expect(c0.isAvailable, isTrue);
      expect(c0.value, closeTo(10, 1e-12));

      final v1 = lookupTradeNumeric(
        variableId: 'RAW.K0.VOLUME',
        asOf: 1,
        bars: bars,
      );
      expect(v1.value, closeTo(5, 1e-12));

      final miss = lookupTradeNumeric(
        variableId: 'RAW.K0.CLOSE',
        asOf: 9,
        bars: bars,
      );
      expect(miss.isUnavailable, isTrue);

      final unreg = lookupTradeNumeric(
        variableId: 'STRUCTURE.K0.BUY1',
        asOf: 0,
        bars: bars,
      );
      expect(unreg.isUnavailable, isTrue);
    });

    test('布林第一根就有数，不把热身当成不可用', () {
      final bars = [_bar(0, 10)];
      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(bollN: 20),
        maxDisplayKn: 0,
        asOf: 0,
      );
      final got = lookupTradeNumeric(
        variableId: 'MAIN.K0.BOLL.MID',
        asOf: 0,
        bars: bars,
        mathFreeze: store,
        bollN: 20,
      );
      expect(got.isAvailable, isTrue);
      expect(got.value, closeTo(10, 1e-9));
    });

    test('K0 布林只读冻结仓；没有仓则不可用，禁止现算第二套', () {
      final bars = [
        for (var i = 0; i < 5; i++) _bar(i, (i + 1).toDouble()),
      ];
      final live = computeBollForLevel(displayKn: 0, bars: bars, n: 3, asOf: 2);
      final noFreeze = lookupTradeNumeric(
        variableId: 'MAIN.K0.BOLL.MID',
        asOf: 2,
        bars: bars.where((b) => b.idx <= 2).toList(),
        bollN: 3,
      );
      expect(noFreeze.isUnavailable, isTrue);

      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(bollN: 3),
        maxDisplayKn: 0,
        asOf: 4,
      );
      final frozen = lookupTradeNumeric(
        variableId: 'MAIN.K0.BOLL.DOWN',
        asOf: 4,
        bars: bars,
        mathFreeze: store,
        bollN: 3,
      );
      expect(frozen.value, closeTo(store.boll(0)!.down[4]!, 1e-12));
      expect(
        lookupTradeNumeric(
          variableId: 'MAIN.K0.BOLL.MID',
          asOf: 2,
          bars: bars,
          mathFreeze: store,
          bollN: 3,
        ).value,
        closeTo(live.mid[2]!, 1e-12),
      );

      final emptyStore = MathSeriesFreezeStore();
      final noCell = lookupTradeNumeric(
        variableId: 'MAIN.K0.BOLL.UP',
        asOf: 0,
        bars: bars,
        mathFreeze: emptyStore,
      );
      expect(noCell.isUnavailable, isTrue);
    });

    test('K1 收盘走虚拟K取样铺平，不拿原生K0收盘冒充', () {
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
      final samples = collectKnOhlcSamples(
        displayKn: 1,
        bars: prefix,
        levels: bundle.levels,
        asOf: asOf,
      );
      expect(samples, isNotEmpty);

      final pts = [for (final s in samples) (x: s.endX, v: s.close)];
      final expanded = expandPointsToK0(pts, prefix.length, asOf: asOf);
      final expectClose = expanded[asOf];
      expect(expectClose, isNotNull);

      final got = lookupTradeNumeric(
        variableId: 'RAW.K1.CLOSE',
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
      );
      expect(got.isAvailable, isTrue);
      expect(got.value, closeTo(expectClose!, 1e-12));

      final k0 = lookupTradeNumeric(
        variableId: 'RAW.K0.CLOSE',
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
      );
      expect(k0.isAvailable, isTrue);
      // 动态段收盘偶尔会等于当根 K0 收盘，不强制不相等；只锁「K1 必须等于取样铺平」

      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: prefix,
        levels: bundle.levels,
        config: const MathIndicatorConfig(),
        maxDisplayKn: 1,
        asOf: asOf,
      );
      final boll1 = lookupTradeNumeric(
        variableId: 'MAIN.K1.BOLL.MID',
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
        mathFreeze: store,
      );
      expect(boll1.isAvailable, isTrue);
      expect(boll1.value, closeTo(store.boll(1)!.mid[asOf]!, 1e-12));

      final evalClose = readEvalClockSeries(
        variableId: 'RAW.K1.CLOSE',
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
      );
      expect(evalClose.length, samples.length);
      expect(evalClose.last.availableAt, samples.last.endX);
      expect(evalClose.last.value, closeTo(samples.last.close, 1e-12));
      // 计算钟样本数应少于（或至多等于）K0 根数，不能拿铺平格子冒充
      expect(evalClose.length, lessThanOrEqualTo(prefix.length));

      final evalBoll = readEvalClockSeries(
        variableId: 'MAIN.K1.BOLL.MID',
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
        mathFreeze: store,
      );
      expect(evalBoll, isNotEmpty);
      expect(evalBoll.map((e) => e.availableAt).toList(),
          evalClose.map((e) => e.availableAt).toList());
    });
  });
}
