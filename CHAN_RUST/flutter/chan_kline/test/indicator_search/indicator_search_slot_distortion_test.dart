import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/mini_loop.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/backtest/signal_event.dart';
import 'package:chan_kline/backtest/strategy_compile.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_clock.dart';
import 'package:chan_kline/backtest/trade_operand.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int idx, double close) => KlineBar(
  idx: idx,
  timeMs: idx * 60000,
  timeText: 't$idx',
  open: close,
  high: close + 1,
  low: close - 1,
  close: close,
  volume: 1,
  amount: 1,
);

SignalEvent _sig({
  required String id,
  required TradeSide side,
  required int discoveryX,
}) => SignalEvent(
  signalId: id,
  ruleId: side == TradeSide.buy ? 'r_buy' : 'r_sell',
  side: side,
  op: side == TradeSide.buy
      ? TradeBinaryOp.crossBelow
      : TradeBinaryOp.crossAbove,
  displayKn: 0,
  clockFamily: TradeClockFamily.zsMath,
  evalIndex: 0,
  discoveryX: discoveryX,
  availableAt: discoveryX,
  signalPrice: 10.0 + discoveryX,
  source: 'test',
  leftValue: 10.0 + discoveryX,
  rightValue: 10.0 + discoveryX,
  leftId: 'RAW.K0.CLOSE',
  rightId: 'RAW.K0.OPEN',
);

void main() {
  group('单仓占仓语义：内外独立重跑 vs 全跑再切单', () {
    // 切点 K0#10：买@2 进场后无卖信号 → 一直持仓到切点之后。
    // 切点后 买@14 想进场：全跑口径被拒（已有仓位再次BUY），
    // 独立重跑口径（先滤 executeX<=10、空仓起算）应能成交。
    const splitX = 10;
    final bars = [for (var i = 0; i <= 20; i++) _bar(i, 10.0 + i)];

    test('全跑口径：切点前未平仓占位，拒绝切点后的买点', () {
      final r = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 2),
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 14),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 18),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: TradeFillPriceMode.sameBarClose,
      );
      final rejected = r.orders
          .where((o) => o.status == OrderStatus.rejected)
          .toList();
      expect(rejected, isNotEmpty);
      expect(rejected.first.rejectReason, contains('已有仓位'));
      // 闭合交易只有一笔，且是切点前进场的那笔
      expect(r.trades.length, 1);
      expect(r.trades.single.entryX, lessThanOrEqualTo(splitX));
    });

    test('内外独立重跑：先滤 executeX>切点，空仓起算，买点不再被拒', () {
      // 与 backtest_run 的 minExecuteXExclusive 同一手法：先滤信号再撮合
      final filtered = [
        _sig(id: 'b2', side: TradeSide.buy, discoveryX: 14),
        _sig(id: 's1', side: TradeSide.sell, discoveryX: 18),
      ].where((s) => s.discoveryX > splitX).toList();

      final r = runMiniLoopFromSignals(
        signals: filtered,
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: TradeFillPriceMode.sameBarClose,
      );
      expect(r.orders.where((o) => o.status == OrderStatus.rejected), isEmpty);
      // 外段自成闭环一笔，且成交根全部在切点之后
      expect(r.trades.length, 1);
      final t = r.trades.single;
      expect(t.entryX, greaterThan(splitX));
      expect(t.exitX, greaterThan(splitX));
      // 本金重置口径：外段结束时不留仓
      expect(r.account.isFlat, isTrue);
    });

    test('两口径在同一场景外段笔数不同（证明占仓扭曲确实存在）', () {
      final full = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b1', side: TradeSide.buy, discoveryX: 2),
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 14),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 18),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: TradeFillPriceMode.sameBarClose,
      );
      final indep = runMiniLoopFromSignals(
        signals: [
          _sig(id: 'b2', side: TradeSide.buy, discoveryX: 14),
          _sig(id: 's1', side: TradeSide.sell, discoveryX: 18),
        ],
        bars: bars,
        quantity: 100,
        initialCash: 100000,
        fillPriceMode: TradeFillPriceMode.sameBarClose,
      );
      // 全跑切单：0 笔「进场在切点后」的闭合单；独立重跑：1 笔
      expect(full.trades.where((t) => t.entryX > splitX).length, 0);
      expect(indep.trades.where((t) => t.entryX > splitX).length, 1);
    });
  });

  group('真实数据回归：外段笔数不再被切点前占仓压低', () {
    const code = '002003';
    const period = '1m';
    const begin = '2004/07/19 09:30:00';
    const end = '2004/07/20 15:00:00';

    test('外段独立重跑成交根全 > 切点，且笔数 ≥ 全跑切单口径', () async {
      final bridge = ChanBridge.instance;
      bridge.ensureInitialized();
      final bars = bridge
          .loadKlinesEx(
            dataRoot: bridge.defaultDataRoot(),
            code: code,
            beginDate: begin,
            endDate: end,
            period: period,
            tickSource: 'protocol',
          )
          .bars;
      expect(bars.length, greaterThan(100));
      final h = await driveStepHarness(bars);
      final env = SearchEnv(bars, h, code, period, begin, end);
      final splitX = splitBarIdx(bars);
      final cands = buildCandidates(
        VariablePool(h.maxKn),
        const CandidateBuildOptions.legacyFull(),
      );

      var checked = 0;
      var distorted = 0;
      for (final c in cands) {
        if (checked >= 60) break;
        final comp = compileStrategyConfig(
          StrategyConfig(buyAst: c.buyAst, sellAst: c.sellAst),
          maxKn: h.maxKn,
        );
        if (comp is! StrategyCompileOk) continue;

        final seg = env.runInOutFromSingleFull(
          comp,
          c.buyAst,
          c.sellAst,
          splitX,
        );
        if (seg == null) continue;
        // 旧口径：全区间跑完再按 entryX>切点 切单
        final oosSliced = env.outSampleClosedTrades(
          comp,
          c.buyAst,
          c.sellAst,
          splitX,
        );
        if (oosSliced == null) continue;

        for (final t in oosSliced) {
          expect(t.entryX, greaterThan(splitX));
        }
        // 独立重跑不丢信号：外段笔数不会少于旧切单口径
        expect(
          seg.outSample.trades,
          greaterThanOrEqualTo(oosSliced.length),
          reason:
              '候选 ${c.name}：外段独立重跑 ${seg.outSample.trades} 笔，'
              '不应少于全跑切单 ${oosSliced.length} 笔',
        );
        if (seg.outSample.trades > oosSliced.length) distorted++;
        checked++;
      }
      expect(checked, greaterThan(10));
      // 不变量已逐候选断言；此处仅记录该数据集上是否真出现口径差异（不强制）。
      // ignore: avoid_print
      print('[占仓扭曲回归] checked=$checked 内外独立多出外段笔数的候选=$distorted');
    }, timeout: const Timeout(Duration(minutes: 10)));
  });
}
