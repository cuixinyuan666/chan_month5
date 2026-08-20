import 'package:chan_kline/backtest/catalog_lookup.dart';
import 'package:chan_kline/backtest/chan_event_store.dart';
import 'package:chan_kline/backtest/chart_line_store.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/compute/line_slope_compute.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/fractal_judgment_event.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/models/zs_signal_event.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: close,
    high: close + 1,
    low: close - 1,
    close: close,
    volume: idx + 1,
    amount: 1,
  );
}

void main() {
  group('目录补全', () {
    test('均线/通道/未确认中枢/判断/斜率/节奏已登记', () {
      expect(lookupTradeVariable('MAIN.K0.MA.5')!.expressionReady, isTrue);
      expect(lookupTradeVariable('MAIN.K1.CHANNEL.20.MAX')!.expressionReady, isTrue);
      expect(
        lookupTradeVariable('STRUCTURE.K0.ZS.ACTIVE.HIGH')!.expressionReady,
        isTrue,
      );
      expect(lookupTradeVariable('SUB.K0.FRACTAL_JUDGMENT')!.clockFamily,
          TradeClockFamily.line);
      expect(lookupTradeVariable('SUB.K1.ZS_JUDGMENT')!.clockFamily,
          TradeClockFamily.zsMath);
      expect(lookupTradeVariable('SUB.K0.LINE_SLOPE')!.clockFamily,
          TradeClockFamily.line);
      expect(lookupTradeVariable('MAIN.K0.STEP_RHYTHM')!.expressionReady, isTrue);
      expect(lookupTradeVariable('MAIN.K0.DEMARK.COMPLETE_BUY')!.valueType,
          TradeValueType.event);
      expect(lookupTradeVariable('MAIN.K0.TREND_LINE.SUPPORT')!.clockFamily,
          TradeClockFamily.zsMath);
      expect(lookupTradeVariable('SUB.K0.CHIP.PEAK')!.expressionReady, isTrue);
      expect(lookupTradeVariable('SUB.K1.CHIP.PEAK')!.expressionReady, isFalse);
    });

    test('斜率不能和布林比；收盘可以和趋势支撑比', () {
      expect(
        compileBinaryOp(
          leftId: 'SUB.K0.LINE_SLOPE',
          rightId: 'MAIN.K0.BOLL.DOWN',
          op: TradeBinaryOp.gt,
        ),
        isA<TradeExprIllegal>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'RAW.K0.CLOSE',
          rightId: 'MAIN.K0.TREND_LINE.SUPPORT',
          op: TradeBinaryOp.crossBelow,
        ),
        isA<TradeExprOk>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'RAW.K0.CLOSE',
          rightId: 'SUB.K0.CHIP.PEAK.M1',
          op: TradeBinaryOp.lt,
        ),
        isA<TradeExprOk>(),
      );
      expect(
        compileBinaryOp(
          leftId: 'RAW.K0.CLOSE',
          rightId: 'MAIN.K0.MA.5',
          op: TradeBinaryOp.gt,
        ),
        isA<TradeExprOk>(),
      );
    });
  });

  group('取值', () {
    test('均线读冻结仓，不另算', () {
      final bars = [for (var i = 0; i < 8; i++) _bar(i, 10.0 + i)];
      final store = MathSeriesFreezeStore();
      mergeMathSeriesForStep(
        store: store,
        bars: bars,
        levels: const [],
        config: const MathIndicatorConfig(),
        maxDisplayKn: 0,
        asOf: 7,
      );
      final v = lookupTradeNumeric(
        variableId: 'MAIN.K0.MA.5',
        asOf: 7,
        bars: bars,
        mathFreeze: store,
      );
      expect(v.isAvailable, isTrue);
      expect(v.value, isNotNull);
    });

    test('分型判断/中枢判断首次发现；斜率读会话历史', () {
      final bars = [_bar(0, 10), _bar(1, 11), _bar(2, 12)];
      final events = ChanEventStore(
        fractalJudgmentByKn: {
          0: const [
            FractalJudgmentEvent(
              x: 1,
              fx: 'BOTTOM',
              fractalX1: 0,
              fractalX2: 0,
            ),
            FractalJudgmentEvent(
              x: 2,
              fx: 'BOTTOM',
              fractalX1: 0,
              fractalX2: 0,
            ),
          ],
        },
        zsJudgmentByKn: {
          0: const [
            ZsSignalEvent(x: 1, kn: 0, seq: 0, x1: 3, dir: 1, value: 1),
            ZsSignalEvent(x: 2, kn: 0, seq: 0, x1: 3, dir: 1, value: 1),
          ],
        },
      );
      final fx = listTradeChanEvents(
        variableId: 'SUB.K0.FRACTAL_JUDGMENT',
        asOf: 2,
        store: events,
      );
      expect(fx.map((e) => e.availableAt).toList(), [1]);
      final zs = listTradeChanEvents(
        variableId: 'SUB.K0.ZS_JUDGMENT',
        asOf: 2,
        store: events,
      );
      expect(zs.map((e) => e.availableAt).toList(), [1]);

      final slope = lookupTradeNumeric(
        variableId: 'SUB.K0.LINE_SLOPE',
        asOf: 1,
        bars: bars,
        lineSeries: ChartLineStore(
          lineSlopeByKn: {
            0: const [
              LineSlopePoint(
                x: 1,
                displayKn: 0,
                slope: 0.5,
                dir: 'up',
                childIdx: 0,
              ),
            ],
          },
        ),
      );
      expect(slope.value, closeTo(0.5, 1e-12));
    });
  });
}
