import '../backtest/backtest_metrics.dart';
import '../backtest/condition_ast.dart';

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
    ),
  ];
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

  final buyAtoms = <String, ComboAtom>{};
  final sellAtoms = <String, ComboAtom>{};
  for (final c in survivors) {
    for (final a in atomsOf(c.buyAst, '买')) {
      buyAtoms.putIfAbsent(a.key, () => a);
    }
    for (final a in atomsOf(c.sellAst, '卖')) {
      sellAtoms.putIfAbsent(a.key, () => a);
    }
  }

  onProgress?.call('组合搜索：把单条条件拼成并且组合');
  final combos = beamComboSearch(
    buyAtoms: buyAtoms.values.toList(),
    sellAtoms: sellAtoms.values.toList(),
    beamWidth: beamWidth,
    maxSize: maxComboSize,
    minGain: 0.0,
    scoreOf: (buys, sells) {
      final cand = ComboCandidate(buys: buys, sells: sells, score: 0).toComboCand();
      final v = runner.evaluateCandidate(
        c: cand,
        env: env,
        splitX: splitX,
        maxKn: maxKn,
      );
      if (v == null) return null;
      return robustRankScore(v.inSample, v.outSample);
    },
  );

  final comboCands = [for (final c in combos) c.toComboCand()];
  onProgress?.call('生成 ${comboCands.length} 个组合，开始按样本外打分');

  final verdicts = <ComboVerdict>[];
  final realCost = <ComboVerdict, double>{};
  final seen = <String>{};
  for (final c in [...survivors, ...comboCands]) {
    if (!seen.add(c.name)) continue;
    final compiled = runner.compileOk(c, maxKn);
    if (compiled == null) continue;
    final seg = env.runInOutFromSingleFull(
      compiled,
      c.buyAst,
      c.sellAst,
      splitX,
    );
    if (seg == null) continue;
    final v = ComboVerdict(
      name: c.name,
      buyText: astConditionTextCn(c.buyAst, maxKn: maxKn),
      sellText: astConditionTextCn(c.sellAst, maxKn: maxKn),
      inSample: seg.inSample,
      outSample: seg.outSample,
      buyAst: c.buyAst,
      sellAst: c.sellAst,
      splitX: splitX,
    );
    verdicts.add(v);
    // 真实成本另算一列，不改默认撮合参数。
    final costSeg = env.runInOutWithRealCost(
      compiled,
      c.buyAst,
      c.sellAst,
      splitX,
    );
    if (costSeg != null) {
      realCost[v] = robustRankScore(costSeg.inSample, costSeg.outSample);
    }
  }

  final ranked = rankVerdicts(verdicts);
  final withScore = [
    for (final r in ranked)
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
