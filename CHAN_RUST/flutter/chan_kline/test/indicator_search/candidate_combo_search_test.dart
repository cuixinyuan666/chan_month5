import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/indicator_search/candidate_combo_search.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:flutter_test/flutter_test.dart';

/// 组合搜索的回归。
///
/// 用注入的假分数验证搜索逻辑本身：它该找到分数最高的组合、不超长度上限、
/// 加一条不再变好时停下，并且产出的组合能转成可进现有链路的候选。
void main() {
  ComboAtom atom(String key) => ComboAtom(
        key: key,
        label: key,
        ast: TradeEventAst(key),
      );

  test('选出分数最高的组合，且不超过长度上限', () {
    // 分数规则：买卖两侧各含 'A' 加 1 分，含 'X' 加 3 分，其余 0.5。
    double score(List<ComboAtom> buys, List<ComboAtom> sells) {
      double s = 0;
      for (final a in [...buys, ...sells]) {
        if (a.key == 'X') {
          s += 3;
        } else if (a.key == 'A') {
          s += 1;
        } else {
          s += 0.5;
        }
      }
      return s;
    }

    final found = beamComboSearch(
      buyAtoms: [atom('A'), atom('B'), atom('X')],
      sellAtoms: [atom('S1'), atom('S2')],
      scoreOf: score,
      beamWidth: 4,
      maxSize: 3,
    );

    expect(found, isNotEmpty);
    expect(found.first.score, found.map((c) => c.score).reduce((a, b) => a > b ? a : b));
    for (final c in found) {
      expect(c.size, lessThanOrEqualTo(3));
      expect(c.buys, isNotEmpty);
      expect(c.sells, isNotEmpty);
    }
    // 含 X 的组合应当排在最前
    expect(
      [...found.first.buys, ...found.first.sells].any((a) => a.key == 'X'),
      isTrue,
    );
  });

  test('再加一条不再变好时停止扩展', () {
    // 只有单条组合有分，任何加长都变差。
    double? score(List<ComboAtom> buys, List<ComboAtom> sells) {
      if (buys.length + sells.length > 2) return 0;
      return 1;
    }

    final found = beamComboSearch(
      buyAtoms: [atom('A'), atom('B')],
      sellAtoms: [atom('S')],
      scoreOf: score,
      maxSize: 4,
      minGain: 0.01,
    );
    expect(found.every((c) => c.size == 2), isTrue);
  });

  test('产出的组合能转成寻优候选，名称可读', () {
    final found = beamComboSearch(
      buyAtoms: [atom('RSI低于30')],
      sellAtoms: [atom('RSI高于70')],
      scoreOf: (_, __) => 1,
    );
    expect(found, hasLength(1));
    final cand = found.single.toComboCand();
    expect(cand.name, '组合｜RSI低于30｜RSI高于70');
    expect(cand.buyAst, isA<TradeEventAst>());
    expect(cand.sellAst, isA<TradeEventAst>());
  });

  test('两个买条件拼出并且节点', () {
    double score(List<ComboAtom> buys, List<ComboAtom> sells) =>
        (buys.length + sells.length).toDouble();

    final found = beamComboSearch(
      buyAtoms: [atom('买1'), atom('买2')],
      sellAtoms: [atom('卖1')],
      scoreOf: score,
      beamWidth: 4,
      maxSize: 3,
      minGain: 0.5,
    );
    final wide = found.firstWhere((c) => c.buys.length == 2);
    expect(wide.buyAst, isA<TradeAndAst>());
    expect(wide.size, 3);
  });

  test('同一变量不会被加进同一侧两次（阈值宽的被窄的覆盖）', () {
    // 两个基元读同一个变量，只是阈值不同。
    final wide = ComboAtom(
      key: '买:kdj>20',
      ast: const TradeEventAst('SUB.K0.KDJ.D'),
      label: 'KDJ.D > 20',
      variableKey: 'SUB.K0.KDJ.D',
    );
    final narrow = ComboAtom(
      key: '买:kdj>50',
      ast: const TradeEventAst('SUB.K0.KDJ.D'),
      label: 'KDJ.D > 50',
      variableKey: 'SUB.K0.KDJ.D',
    );
    double score(List<ComboAtom> buys, List<ComboAtom> sells) =>
        (buys.length + sells.length).toDouble();

    final found = beamComboSearch(
      buyAtoms: [wide, narrow],
      sellAtoms: [atom('卖')],
      scoreOf: score,
      beamWidth: 8,
      maxSize: 3,
      minGain: 0.5,
    );
    for (final c in found) {
      final vars = c.buys.map((a) => a.variableKey).toList();
      expect(vars.toSet().length, vars.length,
          reason: '组合 ${c.name} 里同一个变量出现了两次');
    }
  });

  test('粗筛只留样本内成交够多且净利为正的候选', () {
    ComboCand cand(String name) =>
        ComboCand(name, const TradeEventAst('b'), const TradeEventAst('s'));
    final all = [cand('好'), cand('少'), cand('亏'), cand('无')];
    final trades = {'好': 10, '少': 2, '亏': 12};
    final net = {'好': 500.0, '少': 100.0, '亏': -200.0};

    final kept = screenByInSample(
      cands: all,
      inSampleTrades: (c) => trades[c.name],
      inSampleNetProfit: (c) => net[c.name],
    );
    expect(kept.map((c) => c.name).toList(), ['好']);
  });
}
