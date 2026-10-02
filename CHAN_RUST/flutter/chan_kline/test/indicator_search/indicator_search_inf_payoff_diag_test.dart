import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 全胜小样本体检（P2 诊断）：`payoff=∞` 在小样本下会压过稳健大样本组合。
///
/// 锁定两件事：
/// 1. 诊断统计本身算得对（∞ 计数、前 N 名、最小笔数、双达标子集）；
/// 2. 该隐患**真实存在**（5 笔全胜 vs 50 笔稳健），
///    防止有人以「不存在问题」为由把诊断删掉。
void main() {
  RawScore score({
    required int trades,
    required double winRate,
    double? payoff,
    double netProfit = 0,
  }) => RawScore(
    trades: trades,
    winRate: winRate,
    payoff: payoff,
    profitFactor: payoff,
    netProfit: netProfit,
  );

  ComboVerdict verdict(
    String name, {
    required RawScore inSample,
    RawScore? outSample,
    bool passed = false,
    double? rank,
  }) => ComboVerdict(
    name: name,
    buyText: '买：收盘上穿 X',
    sellText: '卖：收盘下穿 X',
    inSample: inSample,
    outSample: outSample ?? inSample,
    inRankScore: rank ?? rankScoreOf(inSample, minTrades: 5),
    passed: passed,
    splitX: 100,
  );
  group('全胜小样本隐患确实存在（P2 立项依据）', () {
    test('5 笔全胜的保守分压过 50 笔稳健组合', () {
      final smallInf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final bigSteady = score(trades: 50, winRate: 0.6, payoff: 2.0);

      final rSmall = rankScoreOf(smallInf, minTrades: 5);
      final rBig = rankScoreOf(bigSteady, minTrades: 5);

      // 该隐患是本次审查唯一实质问题，用例锁死这个事实。
      expect(
        rSmall,
        greaterThan(rBig),
        reason: '5 笔全胜应压过 50 笔胜率60%/盈亏比2.0（P2 要解决的排序虚高）',
      );
      expect(rSmall, closeTo(3.13, 0.05));
      expect(rBig, closeTo(1.18, 0.05));
    });

    test('∞ 直接过门槛（∞ 会污染双达标的前提）', () {
      const gate = PassGate();
      final inf5 = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      expect(gate.okSegment(inf5), isTrue, reason: '5 笔全胜即视为达标，payoff=∞ 直接过线');
    });
  });

  group('SearchInfPayoffDiagnostics 统计正确性', () {
    test('空输入返回 empty 且展示行为 null', () {
      final d = SearchInfPayoffDiagnostics.of(const []);
      expect(d.total, 0);
      expect(d.infCount, 0);
      expect(d.toDisplayLine(), isNull);
    });

    test('统计 ∞ 总数、前 N 名命中数与最小笔数', () {
      final inf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final inf2 = score(trades: 6, winRate: 1.0, payoff: double.infinity);
      final normal = score(trades: 50, winRate: 0.6, payoff: 2.0);

      final d = SearchInfPayoffDiagnostics.of([
        verdict('infA', inSample: inf),
        verdict('infB', inSample: inf2),
        verdict('steady', inSample: normal),
      ]);
      expect(d.total, 3);
      expect(d.infCount, 2, reason: '两条样本内为 ∞');
      expect(d.infInTop, 2);
      expect(d.topMinTrades, 5, reason: '前 2 名最小样本内笔数为 5');
      expect(d.passedCount, 0);
    });

    test('topN 越大，命中数按保守分取前 N（含稳健组合）', () {
      final inf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final normal = score(trades: 50, winRate: 0.6, payoff: 2.0);
      final list = [
        verdict('inf', inSample: inf),
        verdict('steady', inSample: normal),
      ];
      expect(SearchInfPayoffDiagnostics.of(list, topN: 1).infInTop, 1);
      expect(SearchInfPayoffDiagnostics.of(list, topN: 2).infInTop, 1);
    });

    test('只统计样本内的 ∞（样本外 ∞ 不计入）', () {
      final inNormal = score(trades: 50, winRate: 0.6, payoff: 2.0);
      final outInf = score(trades: 8, winRate: 1.0, payoff: double.infinity);
      final d = SearchInfPayoffDiagnostics.of([
        verdict('x', inSample: inNormal, outSample: outInf),
      ]);
      expect(d.infCount, 0, reason: '样本内非 ∞，不应计入');
      expect(d.infInTop, 0);
    });

    test('双达标子集的最小笔数与 ∞ 计数独立统计', () {
      final inf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final steady = score(trades: 60, winRate: 0.7, payoff: 2.2);
      final d = SearchInfPayoffDiagnostics.of([
        verdict('infPass', inSample: inf, passed: true),
        verdict('steadyPass', inSample: steady, passed: true),
        verdict(
          'notPass',
          inSample: score(trades: 40, winRate: 0.4, payoff: 0.9),
        ),
      ]);
      expect(d.passedCount, 2);
      expect(d.passedMinTrades, 5, reason: '双达标里最小笔数为 5（隐患形态）');
      expect(d.passedInfCount, 1);
    });
  });
  group('展示行的告警措辞', () {
    test('榜首含 ∞ 小样本时给告警', () {
      final inf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final d = SearchInfPayoffDiagnostics.of([verdict('inf', inSample: inf)]);
      final line = d.toDisplayLine()!;
      expect(line, contains('全胜体检'));
      expect(line, contains('⚠'), reason: '榜首被小样本 ∞ 占据时必须告警');
    });

    test('榜首全是稳健大样本时不告警', () {
      final steady = score(trades: 80, winRate: 0.65, payoff: 2.0);
      final d = SearchInfPayoffDiagnostics.of([
        verdict('a', inSample: steady),
        verdict('b', inSample: score(trades: 90, winRate: 0.7, payoff: 2.5)),
      ]);
      final line = d.toDisplayLine()!;
      expect(line, isNot(contains('⚠')));
      expect(line, contains('双达标 0 个'));
    });

    test('无 ∞ 时不告警', () {
      final steady = score(trades: 30, winRate: 0.66, payoff: 1.9);
      final d = SearchInfPayoffDiagnostics.of([verdict('a', inSample: steady)]);
      expect(d.infInTop, 0);
      expect(d.toDisplayLine()!, isNot(contains('⚠')));
    });
  });

  /// 面板渲染门控：只有「榜首含 ∞ 小样本」才占一行，避免常态下挤压 TabBar。
  group('面板渲染门控条件', () {
    bool shouldShow(SearchInfPayoffDiagnostics d) =>
        d.infInTop > 0 && d.topMinTrades < 10;

    test('榜首含 ∞ 小样本时应显示', () {
      final inf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final d = SearchInfPayoffDiagnostics.of([verdict('inf', inSample: inf)]);
      expect(shouldShow(d), isTrue);
      expect(d.toDisplayLine(), isNotNull);
    });

    test('稳健大样本榜首不显示（不给常态加行）', () {
      final d = SearchInfPayoffDiagnostics.of([
        verdict('a', inSample: score(trades: 80, winRate: 0.65, payoff: 2.0)),
        verdict('b', inSample: score(trades: 90, winRate: 0.7, payoff: 2.5)),
      ]);
      expect(shouldShow(d), isFalse);
    });

    test('∞ 在榜但笔数够多时不显示（不误报）', () {
      final infBig = score(trades: 40, winRate: 1.0, payoff: double.infinity);
      final d = SearchInfPayoffDiagnostics.of([
        verdict('infBig', inSample: infBig),
      ]);
      expect(d.infInTop, 1, reason: '∞ 确实在前列');
      expect(d.topMinTrades, 40);
      expect(shouldShow(d), isFalse, reason: '40 笔全胜不算小样本，不该误报');
    });

    test('空数据不显示', () {
      final d = SearchInfPayoffDiagnostics.of(const []);
      expect(shouldShow(d), isFalse);
    });
  });

  group('诊断是只读的：不改变任何判定', () {
    test('调用诊断前后 passed 与保守分完全不变', () {
      final inf = score(trades: 5, winRate: 1.0, payoff: double.infinity);
      final steady = score(trades: 60, winRate: 0.7, payoff: 2.2);
      const gate = PassGate();
      final list = [
        verdict('infPass', inSample: inf, passed: gate.okSegment(inf)),
        verdict('steadyPass', inSample: steady, passed: gate.okSegment(steady)),
      ];
      final before = [
        (list[0].name, list[0].passed, list[0].inRankScore),
        (list[1].name, list[1].passed, list[1].inRankScore),
      ];
      SearchInfPayoffDiagnostics.of(list);
      final after = [
        (list[0].name, list[0].passed, list[0].inRankScore),
        (list[1].name, list[1].passed, list[1].inRankScore),
      ];
      expect(after, equals(before), reason: '诊断必须是无副作用的旁路统计');
    });
  });
}
