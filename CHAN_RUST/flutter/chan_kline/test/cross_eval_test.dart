import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/cross_eval.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
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
    high: close > o ? close + 1 : o + 1,
    low: close < o ? close - 1 : o - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

TradeOperand _op(String id) => TradeOperand.tryBind(id)!;

void main() {
  group('边沿检测（evalClock 样本）', () {
    test('下穿只在边沿触发一次；持续在下侧不重复', () {
      const leftId = 'RAW.K0.CLOSE';
      const rightId = 'MAIN.K0.BOLL.DOWN';
      final left = [
        const EvalClockPoint(evalIndex: 0, availableAt: 0, value: 10),
        const EvalClockPoint(evalIndex: 1, availableAt: 1, value: 10),
        const EvalClockPoint(evalIndex: 2, availableAt: 2, value: 8),
        const EvalClockPoint(evalIndex: 3, availableAt: 3, value: 7),
        const EvalClockPoint(evalIndex: 4, availableAt: 4, value: 6),
      ];
      final right = [
        const EvalClockPoint(evalIndex: 0, availableAt: 0, value: 9),
        const EvalClockPoint(evalIndex: 1, availableAt: 1, value: 9),
        const EvalClockPoint(evalIndex: 2, availableAt: 2, value: 9),
        const EvalClockPoint(evalIndex: 3, availableAt: 3, value: 9),
        const EvalClockPoint(evalIndex: 4, availableAt: 4, value: 9),
      ];
      final ev = detectCrossOnEvalSeries(
        left: left,
        right: right,
        op: TradeBinaryOp.crossBelow,
        leftOp: _op(leftId),
        rightOp: _op(rightId),
      );
      expect(ev.length, 1);
      expect(ev.single.availableAt, 2);
      expect(ev.single.evalIndex, 2);
      expect(ev.single.op, TradeBinaryOp.crossBelow);
    });

    test('上穿只在边沿触发一次；持续在上侧不重复', () {
      final left = [
        const EvalClockPoint(evalIndex: 0, availableAt: 0, value: 8),
        const EvalClockPoint(evalIndex: 1, availableAt: 10, value: 8),
        const EvalClockPoint(evalIndex: 2, availableAt: 20, value: 12),
        const EvalClockPoint(evalIndex: 3, availableAt: 30, value: 13),
      ];
      final right = [
        const EvalClockPoint(evalIndex: 0, availableAt: 0, value: 9),
        const EvalClockPoint(evalIndex: 1, availableAt: 10, value: 9),
        const EvalClockPoint(evalIndex: 2, availableAt: 20, value: 9),
        const EvalClockPoint(evalIndex: 3, availableAt: 30, value: 9),
      ];
      final ev = detectCrossOnEvalSeries(
        left: left,
        right: right,
        op: TradeBinaryOp.crossAbove,
        leftOp: _op('RAW.K1.CLOSE'),
        rightOp: _op('MAIN.K1.BOLL.UP'),
      );
      expect(ev.length, 1);
      expect(ev.single.availableAt, 20);
      expect(ev.single.evalIndex, 2);
    });

    test('K1 样本稀疏：穿越落在样本 availableAt，不会在中间 K0 格子打点', () {
      // 只有 3 根 K1 样本；若误用 K0 阶梯，1..9 也可能被扫到
      final left = [
        const EvalClockPoint(evalIndex: 0, availableAt: 0, value: 10),
        const EvalClockPoint(evalIndex: 1, availableAt: 10, value: 8),
        const EvalClockPoint(evalIndex: 2, availableAt: 20, value: 7),
      ];
      final right = [
        const EvalClockPoint(evalIndex: 0, availableAt: 0, value: 9),
        const EvalClockPoint(evalIndex: 1, availableAt: 10, value: 9),
        const EvalClockPoint(evalIndex: 2, availableAt: 20, value: 9),
      ];
      final ev = detectCrossOnEvalSeries(
        left: left,
        right: right,
        op: TradeBinaryOp.crossBelow,
        leftOp: _op('RAW.K1.CLOSE'),
        rightOp: _op('MAIN.K1.BOLL.DOWN'),
      );
      expect(ev.length, 1);
      expect(ev.single.availableAt, 10);
      expect(const {0, 10, 20}.contains(ev.single.availableAt), isTrue);
      expect(ev.single.evalIndex, 1);
    });
  });

  group('evalCross 门禁与 asOf', () {
    test('K0.CLOSE vs K1.BOLL.DOWN 非法，不产出事件', () {
      final bars = [_bar(0, 10), _bar(1, 8)];
      final r = evalCross(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'MAIN.K1.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
        asOf: 1,
        bars: bars,
      );
      expect(r, isA<CrossEvalIllegal>());
      expect((r as CrossEvalIllegal).reason.contains('不是同一层同一套钟'), isTrue);
    });

    test('K1.CLOSE vs K1.BOLL.DOWN / UP 可编译；gt 不求值', () {
      expect(
        compileBinaryOp(
          leftId: 'RAW.K1.CLOSE',
          rightId: 'MAIN.K1.BOLL.DOWN',
          op: TradeBinaryOp.crossBelow,
        ),
        isA<TradeExprOk>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'RAW.K1.CLOSE',
          rightId: 'MAIN.K1.BOLL.UP',
          op: TradeBinaryOp.crossAbove,
        ),
        isA<TradeExprOk>(),
      );
      final r = evalCross(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'MAIN.K0.BOLL.DOWN',
        op: TradeBinaryOp.gt,
        asOf: 0,
        bars: [_bar(0, 10)],
      );
      expect(r, isA<CrossEvalIllegal>());
    });

    test('K0 收盘下穿开盘后待在外侧，只出一次下穿', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 5; i++) _bar(i, 12, open: 10),
        for (var i = 5; i < 20; i++) _bar(i, 8, open: 10),
      ];
      final r = evalCross(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'RAW.K0.OPEN',
        op: TradeBinaryOp.crossBelow,
        asOf: 19,
        bars: bars,
      );
      expect(r, isA<CrossEvalOk>());
      final ev = (r as CrossEvalOk).events;
      expect(ev.length, 1);
      expect(ev.single.op, TradeBinaryOp.crossBelow);
      expect(ev.single.availableAt, 5);
      expect(ev.where((e) => e.availableAt >= 6), isEmpty);
    });

    test('availableAt 不超过 asOf；截断后看不到未来样本', () {
      final bars = <KlineBar>[
        for (var i = 0; i < 5; i++) _bar(i, 12, open: 10),
        for (var i = 5; i < 20; i++) _bar(i, 8, open: 10),
      ];
      final early = evalCross(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'RAW.K0.OPEN',
        op: TradeBinaryOp.crossBelow,
        asOf: 4,
        bars: bars.where((b) => b.idx <= 4).toList(),
      );
      expect(early, isA<CrossEvalOk>());
      expect((early as CrossEvalOk).events, isEmpty);

      final late = evalCross(
        leftId: 'RAW.K0.CLOSE',
        rightId: 'RAW.K0.OPEN',
        op: TradeBinaryOp.crossBelow,
        asOf: 19,
        bars: bars,
      ) as CrossEvalOk;
      expect(late.events, isNotEmpty);
      expect(late.events.every((e) => e.availableAt <= 19), isTrue);
      expect(late.events.single.availableAt, 5);
    });

    test('K1 穿越按虚拟K样本；事件 availableAt 落在样本右端，且不超过 asOf', () {
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
        maxDisplayKn: 1,
        asOf: asOf,
      );
      final samples = collectKnOhlcSamples(
        displayKn: 1,
        bars: prefix,
        levels: bundle.levels,
        asOf: asOf,
      );
      final sampleAts = samples.map((s) => s.endX).toSet();
      expect(samples.length, lessThan(prefix.length));

      final down = evalCross(
        leftId: 'RAW.K1.CLOSE',
        rightId: 'MAIN.K1.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
        mathFreeze: store,
      );
      expect(down, isA<CrossEvalOk>());
      final up = evalCross(
        leftId: 'RAW.K1.CLOSE',
        rightId: 'MAIN.K1.BOLL.UP',
        op: TradeBinaryOp.crossAbove,
        asOf: asOf,
        bars: prefix,
        levels: bundle.levels,
        mathFreeze: store,
      );
      expect(up, isA<CrossEvalOk>());
      final downOk = down as CrossEvalOk;
      final upOk = up as CrossEvalOk;

      for (final ev in [...downOk.events, ...upOk.events]) {
        expect(ev.availableAt <= asOf, isTrue);
        expect(sampleAts.contains(ev.availableAt), isTrue);
        expect(ev.evalIndex, lessThan(samples.length));
        expect(ev.displayKn, 1);
        expect(ev.clockFamily, TradeClockFamily.zsMath);
      }

      const cut = 40;
      final prefixCut = bars.where((b) => b.idx <= cut).toList();
      final bundleCut = bridge.buildKlineCombineBundle(prefixCut);
      final storeCut = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: storeCut,
        bars: prefixCut,
        levels: bundleCut.levels,
        config: const MathIndicatorConfig(),
        maxDisplayKn: 1,
        asOf: cut,
      );
      final cutR = evalCross(
        leftId: 'RAW.K1.CLOSE',
        rightId: 'MAIN.K1.BOLL.DOWN',
        op: TradeBinaryOp.crossBelow,
        asOf: cut,
        bars: prefixCut,
        levels: bundleCut.levels,
        mathFreeze: storeCut,
      ) as CrossEvalOk;
      expect(cutR.events.every((e) => e.availableAt <= cut), isTrue);
      final lateAts =
          downOk.events.map((e) => e.availableAt).where((x) => x > cut);
      for (final x in lateAts) {
        expect(cutR.events.any((e) => e.availableAt == x), isFalse);
      }
    });
  });
}
