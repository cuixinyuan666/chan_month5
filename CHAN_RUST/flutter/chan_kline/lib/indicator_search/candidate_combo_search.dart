import '../backtest/condition_ast.dart';

import 'search_core.dart';
import 'search_scoring.dart';

/// 组合搜索：把单条买卖条件用「并且」拼成组合，而不是全交叉。
///
/// 全交叉是平方级的，绝大多数组合毫无意义。这里用前向贪心：从最好的单条出发，
/// 每次只尝试「再加一条」，留下样本外分数提升最大的若干条（束宽），
/// 直到组合长度到上限或再加不再变好。结果可解释：每条组合都列得出由哪些基元拼成。
///
/// 评分由调用方注入（[scoreOf]），本文件不跑回测。这样单测可以用假分数验证搜索逻辑，
/// 真实寻优时再接上样本外回测。

/// 一条基元条件：买或卖的一侧，带一个稳定的键用于去重。
class ComboAtom {
  final String key;
  final TradeAst ast;

  /// 中文短名，拼进组合名称里让人读得懂。
  final String label;

  const ComboAtom({required this.key, required this.ast, required this.label});
}

/// 搜索产出的一个组合。
class ComboCandidate {
  /// 买侧基元（按加入顺序）。
  final List<ComboAtom> buys;

  /// 卖侧基元（按加入顺序）。
  final List<ComboAtom> sells;

  /// 该组合的样本外分数。
  final double score;

  const ComboCandidate({
    required this.buys,
    required this.sells,
    required this.score,
  });

  /// 组合长度 = 买卖两侧基元数之和。
  int get size => buys.length + sells.length;

  /// 可读名称：`组合｜买A 且 买B｜卖C`。
  String get name {
    String side(List<ComboAtom> atoms) =>
        atoms.map((a) => a.label).join(' 且 ');
    return '组合｜${side(buys)}｜${side(sells)}';
  }

  TradeAst get buyAst => _fold(buys);
  TradeAst get sellAst => _fold(sells);

  /// 转成寻优候选，可直接进现有的编译与回测链路。
  ComboCand toComboCand() => ComboCand(name, buyAst, sellAst);

  static TradeAst _fold(List<ComboAtom> atoms) {
    var ast = atoms.first.ast;
    for (var i = 1; i < atoms.length; i++) {
      ast = TradeAndAst(ast, atoms[i].ast);
    }
    return ast;
  }
}

/// 前向贪心 + 束搜索。
///
/// [scoreOf] 给出一个组合的样本外分数；返回 null 表示该组合不可用（编译失败等），
/// 搜索会跳过它。
///
/// [beamWidth] 每轮保留的组合数，[maxSize] 组合长度上限（买卖两侧基元数之和）。
/// [minGain] 再加一条至少要提升这么多分才算有效，防止为了加而加。
List<ComboCandidate> beamComboSearch({
  required List<ComboAtom> buyAtoms,
  required List<ComboAtom> sellAtoms,
  required double? Function(List<ComboAtom> buys, List<ComboAtom> sells) scoreOf,
  int beamWidth = 8,
  int maxSize = 3,
  double minGain = 0.0,
}) {
  final seeds = <ComboCandidate>[];
  for (final b in buyAtoms) {
    for (final s in sellAtoms) {
      final score = scoreOf([b], [s]);
      if (score == null || score <= 0) continue;
      seeds.add(ComboCandidate(buys: [b], sells: [s], score: score));
    }
  }
  seeds.sort((a, b) => b.score.compareTo(a.score));
  var beam = seeds.take(beamWidth).toList();
  if (beam.isEmpty) return const [];

  final best = <String, ComboCandidate>{
    for (final c in beam) c.name: c,
  };

  while (beam.isNotEmpty && beam.first.size < maxSize) {
    final next = <ComboCandidate>[];
    for (final cur in beam) {
      void tryAdd(List<ComboAtom> buys, List<ComboAtom> sells) {
        if (buys.length + sells.length > maxSize) return;
        final score = scoreOf(buys, sells);
        if (score == null) return;
        if (score - cur.score < minGain) return;
        next.add(ComboCandidate(buys: buys, sells: sells, score: score));
      }

      final haveBuy = cur.buys.map((a) => a.key).toSet();
      for (final b in buyAtoms) {
        if (haveBuy.contains(b.key)) continue;
        tryAdd([...cur.buys, b], cur.sells);
      }
      final haveSell = cur.sells.map((a) => a.key).toSet();
      for (final s in sellAtoms) {
        if (haveSell.contains(s.key)) continue;
        tryAdd(cur.buys, [...cur.sells, s]);
      }
    }
    if (next.isEmpty) break;
    next.sort((a, b) => b.score.compareTo(a.score));
    beam = _dedup(next).take(beamWidth).toList();
    for (final c in beam) {
      final prev = best[c.name];
      if (prev == null || c.score > prev.score) best[c.name] = c;
    }
  }

  final out = best.values.toList()
    ..sort((a, b) {
      final c = b.score.compareTo(a.score);
      if (c != 0) return c;
      return a.name.compareTo(b.name);
    });
  return out;
}

List<ComboCandidate> _dedup(List<ComboCandidate> xs) {
  final seen = <String>{};
  final out = <ComboCandidate>[];
  for (final c in xs) {
    if (seen.add(c.name)) out.add(c);
  }
  return out;
}

/// 粗筛：只留样本内笔数达到门槛、且样本内净利为正的候选。
///
/// 这是寻优提速的第一关。样本内都赚不到钱或成交太少的组合，没有必要再花
/// 完整的样本外回测去验证。返回的是原列表的子集，顺序不变。
List<ComboCand> screenByInSample({
  required List<ComboCand> cands,
  required int? Function(ComboCand) inSampleTrades,
  required double? Function(ComboCand) inSampleNetProfit,
  int minTrades = kMinTradesForScore,
}) {
  final out = <ComboCand>[];
  for (final c in cands) {
    final trades = inSampleTrades(c);
    final net = inSampleNetProfit(c);
    if (trades == null || net == null) continue;
    if (trades < minTrades) continue;
    if (net <= 0) continue;
    out.add(c);
  }
  return out;
}
