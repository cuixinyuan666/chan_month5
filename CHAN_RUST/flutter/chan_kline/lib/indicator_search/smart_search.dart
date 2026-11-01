import 'dart:io';

import '../backtest/backtest_metrics.dart';
import '../backtest/condition_ast.dart';
import '../backtest/trade_operand.dart';

import 'candidate_combo_search.dart';
import 'indicator_search_runner.dart';
import 'search_core.dart';
import 'search_env.dart';
import 'search_isolate.dart';
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
  int? workers,
  void Function(String detail)? onProgress,
}) async {
  // 候选少时开隔离区反而更慢（每个 worker 要复制一份冻结仓）。
  // 默认按核数，上限 8；候选不足 64 条时退回串行。
  final workerCount = workers ??
      (cands.length < 64 ? 1 : Platform.numberOfProcessors.clamp(2, 8));

  onProgress?.call(
    workerCount > 1
        ? '粗筛：先看样本内，去掉成交太少或亏钱的（$workerCount 个分片并行）'
        : '粗筛：先看样本内，去掉成交太少或亏钱的',
  );

  final screenResults = await runBatchInParallel(
    env: env,
    candidates: cands,
    splitX: splitX,
    maxKn: maxKn,
    mode: SearchBatchMode.inSampleOnly,
    workers: workerCount,
  );
  final inSample = <ComboCand, SegmentMetrics>{};
  for (var i = 0; i < cands.length; i++) {
    final m = screenResults[i].inSample;
    if (m != null) inSample[cands[i]] = m;
  }
  final survivors = screenByInSample(
    cands: cands,
    inSampleTrades: (c) => inSample[c]?.trades,
    inSampleNetProfit: (c) => inSample[c]?.netProfit,
  );
  onProgress?.call('粗筛后剩 ${survivors.length} / ${cands.length} 条');
  if (runner.cancelRequested) {
    return SmartSearchOutcome(
      beforeScreen: cands.length,
      afterScreen: survivors.length,
      combosBuilt: 0,
      ranked: const [],
    );
  }

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

  final verdicts = <ComboVerdict>[];
  final seen = <String>{};

  // 取消只在批与批之间检查：隔离区里的回测无法中途打断，但一批最多几秒，
  // 足够让「取消扫描」有响应。检查到取消就抛出去，用已算出的部分继续排名。
  void checkCancel() {
    if (runner.cancelRequested) throw const _SmartSearchCancelled();
  }

  // 存活者先补样本外：这批单条候选已经付过样本内的成本，先算完意味着
  // 即使后面组合搜索跑到一半被取消，也有可用的排名结果可落盘。
  final survivorBatch = [
    for (final c in survivors)
      if (seen.add(c.name)) c,
  ];
  final knownInSample = <String, SegmentMetrics>{
    for (final c in survivorBatch)
      if (inSample[c] != null) c.name: inSample[c]!,
  };

  var comboCands = const <ComboCand>[];
  final atomCount = <String, int>{
    for (final c in survivors) c.name: 1,
  };

  try {
    checkCancel();
    onProgress?.call('按样本外打分：存活候选 ${survivorBatch.length} 条');
    final outResults = await runBatchInParallel(
      env: env,
      candidates: survivorBatch,
      splitX: splitX,
      maxKn: maxKn,
      mode: SearchBatchMode.outSampleOnly,
      knownInSample: knownInSample,
      workers: workerCount,
    );
    for (final r in outResults) {
      final v = r.verdict;
      if (v != null) verdicts.add(v);
    }

    checkCancel();
    onProgress?.call('组合搜索：把单条条件拼成并且组合');
    final combos = await beamComboSearchAsync(
      buyAtoms: topAtoms(buyAtoms),
      sellAtoms: topAtoms(sellAtoms),
      beamWidth: beamWidth,
      maxSize: maxComboSize,
      minGain: 0.0,
      // 搜索阶段只跑样本内：组合只是候选生成器，最终排名仍以样本外为准。
      // 若搜索阶段就按样本外打分，每个种子对都要跑两段回测，比旧方法更慢。
      scoreBatch: (batch) async {
        checkCancel();
        final batchCands = [for (final c in batch) c.toComboCand()];
        final results = await runBatchInParallel(
          env: env,
          candidates: batchCands,
          splitX: splitX,
          maxKn: maxKn,
          mode: SearchBatchMode.inSampleOnly,
          workers: workerCount,
        );
        return [
          for (final r in results)
            r.inSample == null ? null : scoreSegment(r.inSample!),
        ];
      },
    );

    comboCands = [for (final c in combos) c.toComboCand()];
    onProgress?.call('生成 ${comboCands.length} 个组合，按样本外打分');
    // 记录每个候选由几个基元拼成，去重时优先保留更简单的规则。
    for (final combo in combos) {
      atomCount[combo.toComboCand().name] = combo.size;
    }

    // 组合：内外两段都跑。
    final comboBatch = [
      for (final c in comboCands)
        if (seen.add(c.name)) c,
    ];
    checkCancel();
    final comboResults = await runBatchInParallel(
      env: env,
      candidates: comboBatch,
      splitX: splitX,
      maxKn: maxKn,
      mode: SearchBatchMode.full,
      workers: workerCount,
    );
    for (final r in comboResults) {
      final v = r.verdict;
      if (v != null) verdicts.add(v);
    }
  } on _SmartSearchCancelled {
    onProgress?.call('已取消：用已算出的 ${verdicts.length} 条结果排名');
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
  final realCost = <String, double>{};
  try {
    checkCancel();
    onProgress?.call('给前 $kRealCostTopN 名另算真实成本分（万 3 + 0.01 滑点）');
    final costCands = [
      for (final r in deduped.take(kRealCostTopN))
        if (r.verdict.buyAst != null && r.verdict.sellAst != null)
          ComboCand(r.verdict.name, r.verdict.buyAst!, r.verdict.sellAst!),
    ];
    final costResults = await runBatchInParallel(
      env: env,
      candidates: costCands,
      splitX: splitX,
      maxKn: maxKn,
      mode: SearchBatchMode.fullRealCost,
      workers: workerCount,
    );
    for (final r in costResults) {
      final v = r.verdict;
      if (v != null) {
        realCost[v.name] = robustRankScore(v.inSample, v.outSample);
      }
    }
  } on _SmartSearchCancelled {
    // 取消：真实成本分留空即可，不阻塞已有结果落盘。
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
        realCostScore: realCost[r.verdict.name],
      ),
  ];

  return SmartSearchOutcome(
    beforeScreen: cands.length,
    afterScreen: survivors.length,
    combosBuilt: comboCands.length,
    ranked: withScore,
  );
}

/// 内部信号：扫描已被取消，提前结束剩余阶段。
///
/// 只在智能寻优内部流转，不外抛：取消后仍要把已经算出的结果排名落盘，
/// 让用户看到「保留部分 TSV」而不是一个空结果。
class _SmartSearchCancelled implements Exception {
  const _SmartSearchCancelled();
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
