import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/search_verdict_views.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全量指标模型（移除门槛/排名后）的核心口径与快照兼容。
void main() {
  group('ComboVerdict AST 快照往返', () {
    test('含 AST 的 verdict 往返保留买卖条件', () {
      final v = ComboVerdict(
        name: '事件｜双买',
        buyText: 'K0买1出现',
        sellText: 'K1卖1出现',
        inSample: SegmentMetrics.empty,
        outSample: SegmentMetrics.empty,
        buyAst: k0Buy1EventAst,
        sellAst: k1Sell1EventAst,
        splitX: 123,
      );
      expect(v.hasAst, isTrue);

      final json = v.toJson();
      final back = ComboVerdict.fromJson(json);

      expect(back.hasAst, isTrue);
      // 结构相等（sealed AST 未重载 ==，用 JSON 比对最稳）
      expect(back.buyAst!.toJson(), k0Buy1EventAst.toJson());
      expect(back.sellAst!.toJson(), k1Sell1EventAst.toJson());
      expect(back.name, '事件｜双买');
      expect(back.splitX, 123);
      expect(back.categoryLabel, '事件');
    });

    test('旧快照无 AST → hasAst 为假（眼睛按钮禁用）', () {
      final json = {
        'name': '事件｜双买',
        'buyText': 'K0买1出现',
        'sellText': 'K1卖1出现',
        'inSample': _segmentToJson(SegmentMetrics.empty),
        'outSample': _segmentToJson(SegmentMetrics.empty),
        'splitX': 5,
      };
      final back = ComboVerdict.fromJson(json);
      expect(back.hasAst, isFalse);
      expect(back.buyAst, isNull);
      expect(back.sellAst, isNull);
    });
  });

  group('computeSegmentMetrics 边界', () {
    test('零成交：不崩、无 NaN、不可用项用 unavailable', () {
      final curve = [
        const EquityPoint(
          x: 0,
          cash: 100000,
          positionQty: 0,
          positionValue: 0,
          equity: 100000,
          realizedPnL: 0,
          unrealizedPnL: 0,
        ),
      ];
      final seg = computeSegmentMetrics(const [], curve, 100000);
      expect(seg.trades, 0);
      expect(seg.winRate.isUnavailable, isTrue);
      // 曲线不足 2 点 → 年化不可用
      expect(seg.annualReturn.isUnavailable, isTrue);
      expect(seg.sharpe.isUnavailable, isTrue);
      expect(seg.calmar.isUnavailable, isTrue);
      // 任何参与数值都不应是 NaN
      expect(seg.netProfit.isNaN, isFalse);
      expect(seg.maxDrawdownPct.isNaN, isFalse);
    });

    test('单笔盈利：交易数/胜率/净利有限且正确', () {
      final curve = [
        const EquityPoint(
          x: 0,
          cash: 100000,
          positionQty: 0,
          positionValue: 0,
          equity: 100000,
          realizedPnL: 0,
          unrealizedPnL: 0,
        ),
        const EquityPoint(
          x: 10,
          cash: 101000,
          positionQty: 0,
          positionValue: 0,
          equity: 101000,
          realizedPnL: 1000,
          unrealizedPnL: 0,
        ),
      ];
      final trades = [
        const TradeRecord(
          tradeId: 'T1',
          entrySignalId: 'e',
          exitSignalId: 'x',
          entryX: 0,
          exitX: 5,
          entryPrice: 10,
          exitPrice: 11,
          quantity: 100,
          grossPnL: 1000,
        ),
      ];
      final seg = computeSegmentMetrics(trades, curve, 100000);
      expect(seg.trades, 1);
      expect(seg.winning, 1);
      expect(seg.winRate.isFinite, isTrue);
      expect(seg.winRate.value, closeTo(1.0, 1e-9));
      expect(seg.netProfit, closeTo(1000, 1e-6));
      // 两点的净值曲线可算年化（有限，非 NaN）
      expect(seg.annualReturn.isFinite, isTrue);
      expect(seg.annualReturn.value!.isNaN, isFalse);
    });
  });

  group('sortVerdicts 排序', () {
    SegmentMetrics _seg(
      int trades, {
      MetricNum winRate = const MetricNum.unavailable(),
      MetricNum profitFactor = const MetricNum.unavailable(),
    }) =>
        SegmentMetrics(
          trades: trades,
          winning: 0,
          losing: 0,
          flat: 0,
          winRate: winRate,
          grossProfit: 0,
          grossLoss: 0,
          netProfit: 0,
          returnPct: const MetricNum.unavailable(),
          payoffRatio: const MetricNum.unavailable(),
          profitFactor: profitFactor,
          expectancy: const MetricNum.unavailable(),
          averageWin: const MetricNum.unavailable(),
          averageLoss: const MetricNum.unavailable(),
          largestWin: const MetricNum.unavailable(),
          largestLoss: const MetricNum.unavailable(),
          maxConsecutiveWins: 0,
          maxConsecutiveLosses: 0,
          maxDrawdown: 0,
          maxDrawdownPct: 0,
          maxDrawdownStartX: null,
          maxDrawdownEndX: null,
          recoveryX: null,
          avgHoldBars: const MetricNum.unavailable(),
          medianHoldBars: const MetricNum.unavailable(),
          maxHoldBars: const MetricNum.unavailable(),
          holdTimeRatio: const MetricNum.unavailable(),
          annualReturn: const MetricNum.unavailable(),
          annualVol: const MetricNum.unavailable(),
          sharpe: const MetricNum.unavailable(),
          sortino: const MetricNum.unavailable(),
          calmar: const MetricNum.unavailable(),
        );

    ComboVerdict _v(String name, SegmentMetrics inS) => ComboVerdict(
          name: name,
          buyText: 'b',
          sellText: 's',
          inSample: inS,
          outSample: SegmentMetrics.empty,
          splitX: 1,
        );

    test('默认（无列）保持候选生成顺序', () {
      final rows = [_v('a', _seg(3)), _v('b', _seg(1)), _v('c', _seg(2))];
      final sorted = sortVerdicts(rows, const VerdictSortState());
      expect(sorted.map((e) => e.name), ['a', 'b', 'c']);
    });

    test('按内笔排序：首点降序、再点升序', () {
      final rows = [_v('a', _seg(3)), _v('b', _seg(1)), _v('c', _seg(2))];
      // 默认（未置 ascending）为降序
      final desc = sortVerdicts(
        rows,
        const VerdictSortState(
          keys: [SortKey(VerdictSortColumn.inTrades, false)],
        ),
      );
      expect(desc.map((e) => e.inSample.trades), [3, 2, 1]);
      final asc = sortVerdicts(
        rows,
        const VerdictSortState(
          keys: [SortKey(VerdictSortColumn.inTrades, true)],
        ),
      );
      expect(asc.map((e) => e.inSample.trades), [1, 2, 3]);
    });

    test('不可用胜率沉底', () {
      final rows = [
        _v('na', _seg(0, winRate: const MetricNum.unavailable())),
        _v('ok', _seg(0, winRate: const MetricNum.finite(0.5))),
      ];
      final sorted = sortVerdicts(
        rows,
        const VerdictSortState(
          keys: [SortKey(VerdictSortColumn.inWinRate, false)],
        ),
      );
      expect(sorted.last.inSample.winRate.isUnavailable, isTrue);
    });

    test('多列累积排序：同列 tie-break 按优先级链', () {
      // 三行胜率相同（0.5），盈利因子不同 → 先按胜率，再按盈利因子稳定 tie-break。
      final mk = (String n, double pf) => _v(
            n,
            _seg(
              1,
              winRate: const MetricNum.finite(0.5),
              profitFactor: MetricNum.finite(pf),
            ),
          );
      final rows = [mk('a', 3), mk('b', 1), mk('c', 2)];
      // 优先级：① 内胜率(降) ② 内盈利因子(降) → 盈利因子降序 3,2,1
      final sorted = sortVerdicts(
        rows,
        const VerdictSortState(
          keys: [
            SortKey(VerdictSortColumn.inWinRate, false),
            SortKey(VerdictSortColumn.inPf, false),
          ],
        ),
      );
      expect(sorted.map((e) => e.name), ['a', 'c', 'b']);
      // 切换内盈利因子为升序（② 升）：1,2,3
      final asc = sortVerdicts(
        rows,
        const VerdictSortState(
          keys: [
            SortKey(VerdictSortColumn.inWinRate, false),
            SortKey(VerdictSortColumn.inPf, true),
          ],
        ),
      );
      expect(asc.map((e) => e.name), ['b', 'c', 'a']);
    });
  });

  group('reportHeader', () {
    test('含标的/周期且非空', () {
      final h = reportHeader(
        code: '000001',
        period: '日线',
        bars: 500,
        splitX: 350,
      );
      expect(h, isNotEmpty);
      expect(h, contains('000001'));
      expect(h, contains('日线'));
      expect(h, contains('不做达标/排名筛选'));
    });
  });
}

Map<String, dynamic> _segmentToJson(SegmentMetrics s) => {
      'trades': s.trades,
      'winning': s.winning,
      'losing': s.losing,
      'flat': s.flat,
      'winRate': null,
      'grossProfit': s.grossProfit,
      'grossLoss': s.grossLoss,
      'netProfit': s.netProfit,
      'returnPct': null,
      'payoffRatio': null,
      'profitFactor': null,
      'expectancy': null,
      'averageWin': null,
      'averageLoss': null,
      'largestWin': null,
      'largestLoss': null,
      'maxConsecutiveWins': s.maxConsecutiveWins,
      'maxConsecutiveLosses': s.maxConsecutiveLosses,
      'maxDrawdown': s.maxDrawdown,
      'maxDrawdownPct': s.maxDrawdownPct,
      'maxDrawdownStartX': s.maxDrawdownStartX,
      'maxDrawdownEndX': s.maxDrawdownEndX,
      'recoveryX': s.recoveryX,
      'avgHoldBars': null,
      'medianHoldBars': null,
      'maxHoldBars': null,
      'holdTimeRatio': null,
      'annualReturn': null,
      'annualVol': null,
      'sharpe': null,
      'sortino': null,
      'calmar': null,
    };
