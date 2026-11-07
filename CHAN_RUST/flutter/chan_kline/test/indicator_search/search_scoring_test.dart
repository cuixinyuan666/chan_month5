import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/equity_curve.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_ranking.dart';
import 'package:chan_kline/indicator_search/search_scoring.dart';
import 'package:flutter_test/flutter_test.dart';

/// 寻优评分与排名的回归。
///
/// 钉死三件事：笔数太少的好看数字不得分；样本外亏钱的沉底；
/// 样本内好、样本外崩的过拟合组合被压到样本内外一致的组合之下。
void main() {
  SegmentMetrics seg({
    int trades = 20,
    double winRate = 0.55,
    double netProfit = 1000,
    double profitFactor = 1.6,
    double sharpe = 1.0,
    double calmar = 1.5,
    double expectancy = 50,
    double grossProfit = 2000,
    double dd = 0.08,
    int streak = 2,
  }) =>
      SegmentMetrics(
        trades: trades,
        winning: (trades * winRate).round(),
        losing: trades - (trades * winRate).round(),
        flat: 0,
        winRate: MetricNum.finite(winRate),
        grossProfit: grossProfit,
        grossLoss: grossProfit - netProfit,
        netProfit: netProfit,
        returnPct: MetricNum.finite(0.1),
        payoffRatio: MetricNum.finite(1.4),
        profitFactor: MetricNum.finite(profitFactor),
        expectancy: MetricNum.finite(expectancy),
        averageWin: MetricNum.finite(100),
        averageLoss: MetricNum.finite(-60),
        largestWin: MetricNum.finite(200),
        largestLoss: MetricNum.finite(-120),
        maxConsecutiveWins: 4,
        maxConsecutiveLosses: streak,
        maxDrawdown: 800,
        maxDrawdownPct: dd,
        maxDrawdownStartX: null,
        maxDrawdownEndX: null,
        recoveryX: null,
        avgHoldBars: MetricNum.finite(3),
        medianHoldBars: MetricNum.finite(3),
        maxHoldBars: MetricNum.finite(8),
        holdTimeRatio: MetricNum.finite(0.3),
        annualReturn: MetricNum.finite(0.2),
        annualVol: MetricNum.finite(0.15),
        sharpe: MetricNum.finite(sharpe),
        sortino: MetricNum.finite(1.2),
        calmar: MetricNum.finite(calmar),
      );

  ComboVerdict verdict(String name, SegmentMetrics inS, SegmentMetrics outS) =>
      ComboVerdict(
        name: name,
        buyText: '',
        sellText: '',
        inSample: inS,
        outSample: outS,
        splitX: 0,
      );

  test('笔数不足的段不得分', () {
    expect(scoreSegment(seg(trades: 5, winRate: 1.0, profitFactor: 9)), 0);
    expect(scoreSegment(seg(trades: 0)), 0);
  });

  test('好组合得分高于差组合', () {
    final good = scoreSegment(seg());
    final bad = scoreSegment(seg(
      winRate: 0.36,
      profitFactor: 0.7,
      sharpe: 0.1,
      calmar: 0.1,
      dd: 0.28,
      streak: 7,
    ));
    expect(good, greaterThan(bad));
    expect(good, greaterThan(0));
    expect(good, lessThanOrEqualTo(1));
  });

  test('样本外亏钱或盈利因子低于 1 时稳健分为 0', () {
    final ok = seg();
    expect(robustRankScore(ok, seg(netProfit: -100)), 0);
    expect(robustRankScore(ok, seg(profitFactor: 0.8)), 0);
    expect(robustRankScore(ok, seg(trades: 3)), 0);
    expect(robustRankScore(ok, ok), greaterThan(0));
  });

  test('过拟合组合排名低于样本内外一致的组合', () {
    final steady = verdict('稳态', seg(), seg());
    final overfit = verdict(
      '过拟合',
      seg(winRate: 0.9, profitFactor: 4, sharpe: 2, calmar: 3),
      seg(winRate: 0.4, profitFactor: 1.05, sharpe: 0.1, calmar: 0.1, dd: 0.25),
    );
    final ranked = rankVerdicts([overfit, steady]);
    expect(ranked.first.verdict.name, '稳态');
    expect(ranked.last.rankScore, lessThan(ranked.first.rankScore));
  });

  test('排名同分时按名称升序，结果可复现', () {
    final a = verdict('B', seg(), seg());
    final b = verdict('A', seg(), seg());
    final ranked = rankVerdicts([a, b]);
    expect(ranked.map((r) => r.verdict.name).toList(), ['A', 'B']);
  });

  test('稳健分随候选落盘并可回读', () {
    final v = ComboVerdict(
      name: '阈值｜A',
      buyText: '',
      sellText: '',
      inSample: seg(),
      outSample: seg(),
      splitX: 10,
      rankScore: 0.42,
    );
    final back = ComboVerdict.fromJson(v.toJson());
    expect(back.rankScore, 0.42);

    final old = ComboVerdict.fromJson({
      'name': '旧快照',
      'buyText': '',
      'sellText': '',
      'splitX': 0,
    });
    expect(old.rankScore, isNull);
  });
}
