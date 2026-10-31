import '../backtest/backtest_metrics.dart';
import '../backtest/condition_ast.dart';
import '../backtest/trade_operand.dart';

import 'candidate_combo_search.dart';
import 'indicator_search_runner.dart';
import 'search_core.dart';
import 'search_env.dart';
import 'search_ranking.dart';
import 'search_scoring.dart';

/// 智能寻优的编排：粗筛 → 组合搜索 → 按样本外稳健分排名。
///
/// 与旧的全量列出互不干扰：只有设置里打开「智能寻优」才走这里。
/// 它不改回测口径，只决定「跑哪些候选、结果怎么排」。

/// 智能寻优的结果。
class SmartSearchOutcome {
  /// 粗筛前的候选数。
  final int beforeScreen;

  /// 粗筛后存活的候选数。
  final int afterScreen;

  /// 组合搜索新生成的组合数。
  final int combosBuilt;

  /// 按稳健分降序排好的结果（分数已写进每个候选）。
  final List<ComboVerdict> ranked;

  const SmartSearchOutcome({
    required this.beforeScreen,
    required this.afterScreen,
    required this.combosBuilt,
    required this.ranked,
  });
}

/// 把一条候选的买侧或卖侧拆成基元。
///
/// 只拆最外层的「并且」链；「或者」和叶子都当成一个整体基元，
/// 因为再拆开会改变原意。
List<ComboAtom> atomsOf(TradeAst ast, String prefix) {
  if (ast is TradeAndAst) {
    return [
      ...atomsOf(ast.left, prefix),
      ...atomsOf(ast.right, prefix),
    ];
  }
  return [
    ComboAtom(
      key: '$prefix:${astConditionCacheKey(ast)}',
      ast: ast,
      label: astConditionTextCn(ast),
      variableKey: _variableOf(ast),
    ),
  ];
}

/// 提取基元实际读的变量，供「同一变量只加一次」去重。
/// 组合式或提取不出单一变量时返回 null，退化为按基元键去重。
String? _variableOf(TradeAst ast) {
  if (ast is TradeEventAst) return ast.variableId;
  if (ast is TradeCmpAst) {
    final left = ast.left;
    if (left is TradeVarRef) return left.variableId;
  }
  return null;
}

/// 执行一次智能寻优。
///
/// [maxComboSize] 组合长度上限，[beamWidth] 每轮保留的组合数。
/// 进度通过 [onProgress] 回传，文案直接给人看。
Future<SmartSearchOutcome> runSmartSearch({
  required IndicatorSearchRunner runner,
  required SearchEnv env,
  required List<ComboCand> cands,
  required int splitX,
  required int maxKn,
  int maxComboSize = 3,
  int beamWidth = 8,
  int atomPoolPerSide = 8,
  void Function(String detail)? onProgress,
}) async {
  onProgress?.call('粗筛：先看样本内，去掉成交太少或亏钱的');

  final inSample = <ComboCand, SegmentMetrics>{};
  for (final c in cands) {
    final m = runner.evaluateInSample(
      c: c,
      env: env,
      splitX: splitX,
      maxKn: maxKn,
    );
    if (m != null) inSample[c] = m;
  }

  final survivors = screenByInSample(
    cands: cands,
    inSampleTrades: (c) => inSample[c]?.trades,
    inSampleNetProfit: (c) => inSample[c]?.netProfit,
  );
  onProgress?.call('粗筛后剩 ${survivors.length} / ${cands.length} 条');

  // 基元池按「所在存活候选的样本内得分」排序后截断。全量基元两两配对会产生
  // 几千个种子对，每个都跑回测比旧方法还贵；只留每侧最好的若干个即可。
  final buyAtoms = <String, _AtomRank>{};
  final sellAtoms = <String, _AtomRank>{};
  for (final c in survivors) {
    final score = scoreSegment(inSample[c]!);
    for (final a in atomsOf(c.buyAst, '买')) {
      final prev = buyAtoms[a.key];
      if (prev == null || score > prev.score) {
        buyAtoms[a.key] = _AtomRank(a, score);
      }
    }
    for (final a in atomsOf(c.sellAst, '卖')) {
      final prev = sellAtoms[a.key];
      if (prev == null || score > prev.score) {
        sellAtoms[a.key] = _AtomRank(a, score);
      }
    }
  }
  List<ComboAtom> topAtoms(Map<String, _AtomRank> pool) {
    final list = pool.values.toList()
      ..sort((a, b) => b.score.compareTo(a.score));
    return [for (final r in list.take(atomPoolPerSide)) r.atom];
  }

  onProgress?.call('组合搜索：把单条条件拼成并且组合');
  final combos = beamComboSearch(
    buyAtoms: topAtoms(buyAtoms),
    sellAtoms: topAtoms(sellAtoms),
    beamWidth: beamWidth,
    maxSize: maxComboSize,
    minGain: 0.0,
    // 搜索阶段只跑样本内：组合只是候选生成器，最终排名仍以样本外为准。
    // 若搜索阶段就按样本外打分，每个种子对都要跑两段回测，比旧方法更慢。
    scoreOf: (buys, sells) {
      final cand = ComboCandidate(buys: buys, sells: sells, score: 0).toComboCand();
      final m = runner.evaluateInSample(
        c: cand,
        env: env,
        splitX: splitX,
        maxKn: maxKn,
      );
      if (m == null) return null;
      return scoreSegment(m);
    },
  );

  final comboCands = [for (final c in combos) c.toComboCand()];
  onProgress?.call('生成 ${comboCands.length} 个组合，开始按样本外打分');

  // 记录每个候选由几个基元拼成，去重时优先保留更简单的规则。
  final atomCount = <String, int>{
    for (final c in survivors) c.name: 1,
    for (final combo in combos) combo.toComboCand().name: combo.size,
  };

  final verdicts = <ComboVerdict>[];
  final realCost = <ComboVerdict, double>{};
  final seen = <String>{};

  /// 统一的「评估」：存活者复用粗筛的样本内结果，组合跑完整两段。
  void evaluate(ComboCand c) {
    if (!seen.add(c.name)) return;
    final precomputed = inSample[c];
    final ComboVerdict? v;
    if (precomputed != null) {
      // 样本内已经跑过，只补样本外。
      v = runner.evaluateCandidateWithInSample(
        c: c,
        env: env,
        splitX: splitX,
        maxKn: maxKn,
        inSample: precomputed,
      );
    } else {
      v = runner.evaluateCandidate(
        c: c,
        env: env,
        splitX: splitX,
        maxKn: maxKn,
      );
    }
    if (v != null) verdicts.add(v);
  }

  for (final c in survivors) {
    evaluate(c);
  }
  for (final c in comboCands) {
    evaluate(c);
  }

  final ranked = rankVerdicts(verdicts);

  // 行为去重：两个组合如果在内段和外段的成交结果完全一样，它们在真实数据上
  // 就是同一条策略，只是写法不同。只留规则最简单的那条（基元最少），
  // 免得前几名被同一行为的多种写法占满，看起来像「找到了很多组合」。
  final byBehavior = <String, RankedVerdict>{};
  for (final r in ranked) {
    final key = _behaviorKey(r.verdict);
    final prev = byBehavior[key];
    if (prev == null ||
        (atomCount[r.verdict.name] ?? 99) < (atomCount[prev.verdict.name] ?? 99)) {
      byBehavior[key] = r;
    }
  }
  final deduped = byBehavior.values.toList()
    ..sort((a, b) {
      final c = b.rankScore.compareTo(a.rankScore);
      if (c != 0) return c;
      return a.verdict.name.compareTo(b.verdict.name);
    });

  // 真实成本只算排名前 [kRealCostTopN] 名：换撮合参数必须重跑两段，
  // 全部候选都算会让扫描时间翻倍，而用户真正会看的就是前几名。
  const kRealCostTopN = 30;
  onProgress?.call('给前 $kRealCostTopN 名另算真实成本分（万 3 + 0.01 滑点）');
  final rankedTop = deduped.take(kRealCostTopN);
  for (final r in rankedTop) {
    final v = r.verdict;
    if (v.buyAst == null || v.sellAst == null) continue;
    final compiled = runner.compileOk(
      ComboCand(v.name, v.buyAst!, v.sellAst!),
      maxKn,
    );
    if (compiled == null) continue;
    final costSeg = env.runInOutWithRealCost(
      compiled,
      v.buyAst!,
      v.sellAst!,
      splitX,
    );
    if (costSeg != null) {
      realCost[v] = robustRankScore(costSeg.inSample, costSeg.outSample);
    }
  }

  final withScore = [
    for (final r in deduped)
      ComboVerdict(
        name: r.verdict.name,
        buyText: r.verdict.buyText,
        sellText: r.verdict.sellText,
        inSample: r.verdict.inSample,
        outSample: r.verdict.outSample,
        buyAst: r.verdict.buyAst,
        sellAst: r.verdict.sellAst,
        splitX: r.verdict.splitX,
        rankScore: r.rankScore,
        realCostScore: realCost[r.verdict],
      ),
  ];

  return SmartSearchOutcome(
    beforeScreen: cands.length,
    afterScreen: survivors.length,
    combosBuilt: comboCands.length,
    ranked: withScore,
  );
}

/// 基元及其「所在候选的样本内得分」，用于基元池排序截断。
class _AtomRank {
  final ComboAtom atom;
  final double score;
  const _AtomRank(this.atom, this.score);
}

/// 行为指纹：内外两段的成交结果完全一样，就认为在真实数据上是同一条策略。
///
/// 用笔数、盈亏与回撤这类离散结果做指纹，不用浮点分数 —— 分数相同不代表
/// 成交相同，但成交相同必然导致分数相同。
String _behaviorKey(ComboVerdict v) {
  String seg(SegmentMetrics s) => [
        s.trades,
        s.winning,
        s.losing,
        s.flat,
        s.netProfit.toStringAsFixed(4),
        s.grossProfit.toStringAsFixed(4),
        s.grossLoss.toStringAsFixed(4),
        s.maxDrawdown.toStringAsFixed(4),
        s.maxDrawdownPct.toStringAsFixed(8),
        s.maxConsecutiveLosses,
      ].join(',');
  return '${seg(v.inSample)}|${seg(v.outSample)}';
}
