import 'dart:isolate';

import '../backtest/backtest_metrics.dart';
import '../backtest/backtest_step_harness.dart';
import '../backtest/strategy_config.dart';
import '../models/bar_feature_lookup.dart';
import '../models/kline_bar.dart';

import 'indicator_search_runner.dart';
import 'search_core.dart';
import 'search_env.dart';

/// 寻优并行：把候选切片丢进多个隔离区同时回测。
///
/// 回测是纯 Dart 计算，不碰 FFI，也没有可变全局状态，所以可以安全地按候选分片。
/// 冻结仓（[BacktestStepHarnessResult]）作为普通对象随请求复制进隔离区，
/// 每个 worker 拿到的是一份独立副本，互不影响，也不需要各自重新冻结。
///
/// 口径保证：worker 内走的是与主线程完全相同的 [IndicatorSearchRunner] 与
/// [SearchEnv]，并行只改变「谁在哪个线程算」，不改变任何计算。

/// 一个分片要算什么。
enum SearchBatchMode {
  /// 只跑样本内（粗筛用，最便宜）。
  inSampleOnly,

  /// 只补跑样本外（样本内已在粗筛算过）。
  outSampleOnly,

  /// 内外两段都跑（完整评估）。
  full,

  /// 内外两段都跑，但按真实成本口径（万 3 + 0.01 滑点）。
  fullRealCost,
}

/// 一个分片的请求。所有字段都是可跨隔离区传递的普通对象。
class SearchBatchRequest {
  final List<KlineBar> bars;
  final BacktestStepHarnessResult harness;
  final String code;
  final String period;
  final String begin;
  final String end;
  final StrategyConfig strategyTemplate;
  final BarFeatureLookup? features;
  final double bucketStep;
  final int bollN;
  final int donchianN;
  final double regressK;
  final int maxKn;
  final int splitX;
  final List<ComboCand> candidates;
  final SearchBatchMode mode;

  /// 只补样本外时，按候选名提供粗筛已经算好的样本内结果。
  final Map<String, SegmentMetrics> knownInSample;

  const SearchBatchRequest({
    required this.bars,
    required this.harness,
    required this.code,
    required this.period,
    required this.begin,
    required this.end,
    required this.strategyTemplate,
    required this.features,
    required this.bucketStep,
    required this.bollN,
    required this.donchianN,
    required this.regressK,
    required this.maxKn,
    required this.splitX,
    required this.candidates,
    required this.mode,
    this.knownInSample = const {},
  });
}

/// 一个候选在本分片里的结果。
///
/// [inSample] 只在 [SearchBatchMode.inSampleOnly] 时有值；
/// [verdict] 在其余模式下有值。编译或回测失败时两者都为 null。
class SearchBatchItemResult {
  final SegmentMetrics? inSample;
  final ComboVerdict? verdict;

  const SearchBatchItemResult({this.inSample, this.verdict});
}

/// 隔离区入口：按请求建环境，逐个候选算，按原顺序回传。
///
/// 必须是顶层函数：`Isolate.run` 发送的是闭包，闭包只能捕获请求对象，
/// 不能捕获主线程的 runner / env（它们带有缓存状态，传过去也没有意义）。
List<SearchBatchItemResult> runSearchBatch(SearchBatchRequest req) {
  final env = SearchEnv(
    req.bars,
    req.harness,
    req.code,
    req.period,
    req.begin,
    req.end,
    align: SearchWorkbenchAlign(
      strategyTemplate: req.strategyTemplate,
      features: req.features,
      bucketStep: req.bucketStep,
      bollN: req.bollN,
      donchianN: req.donchianN,
      regressK: req.regressK,
    ),
  );
  final runner = IndicatorSearchRunner();
  return [for (final c in req.candidates) _evaluateOne(runner, env, req, c)];
}

SearchBatchItemResult _evaluateOne(
  IndicatorSearchRunner runner,
  SearchEnv env,
  SearchBatchRequest req,
  ComboCand c,
) {
  switch (req.mode) {
    case SearchBatchMode.inSampleOnly:
      final m = runner.evaluateInSample(
        c: c,
        env: env,
        splitX: req.splitX,
        maxKn: req.maxKn,
      );
      return SearchBatchItemResult(inSample: m);
    case SearchBatchMode.outSampleOnly:
      final known = req.knownInSample[c.name];
      if (known == null) return const SearchBatchItemResult();
      final v = runner.evaluateCandidateWithInSample(
        c: c,
        env: env,
        splitX: req.splitX,
        maxKn: req.maxKn,
        inSample: known,
      );
      return SearchBatchItemResult(verdict: v);
    case SearchBatchMode.full:
      final v = runner.evaluateCandidate(
        c: c,
        env: env,
        splitX: req.splitX,
        maxKn: req.maxKn,
      );
      return SearchBatchItemResult(verdict: v);
    case SearchBatchMode.fullRealCost:
      final v = runner.evaluateCandidateWithRealCost(
        c: c,
        env: env,
        splitX: req.splitX,
        maxKn: req.maxKn,
      );
      return SearchBatchItemResult(verdict: v);
  }
}

/// 并行执行一个批次，按输入顺序回传结果。
///
/// [workers] 为 1 时直接在主线程算（测试与单核环境用），保证结果与并行完全一致。
/// 分片用轮转法：候选成本差异大时，轮转比连续切片更均衡。
Future<List<SearchBatchItemResult>> runBatchInParallel({
  required SearchEnv env,
  required List<ComboCand> candidates,
  required int splitX,
  required int maxKn,
  SearchBatchMode mode = SearchBatchMode.full,
  Map<String, SegmentMetrics> knownInSample = const {},
  int workers = 1,
}) async {
  if (candidates.isEmpty) return const [];
  final n = workers.clamp(1, candidates.length);
  if (n <= 1) {
    final req = _requestOf(
      env: env,
      candidates: candidates,
      splitX: splitX,
      maxKn: maxKn,
      mode: mode,
      knownInSample: knownInSample,
    );
    return runSearchBatch(req);
  }

  final chunks = List.generate(n, (_) => <ComboCand>[]);
  for (var i = 0; i < candidates.length; i++) {
    chunks[i % n].add(candidates[i]);
  }

  final requests = [
    for (final chunk in chunks)
      _requestOf(
        env: env,
        candidates: chunk,
        splitX: splitX,
        maxKn: maxKn,
        mode: mode,
        knownInSample: knownInSample,
      ),
  ];
  final parts = await Future.wait([for (final req in requests) _runChunk(req)]);
  // 兜底：某个隔离区失败（内存不足等）时，这一片退回主线程算，
  // 不让整次寻优因为一个分片崩掉。结果口径完全一样。
  for (var k = 0; k < parts.length; k++) {
    parts[k] ??= runSearchBatch(requests[k]);
  }
  final done = [for (final p in parts) p!];

  // 轮转分片：第 i 个候选落在第 i % n 片、片内第 i ~/ n 个。
  final out = List<SearchBatchItemResult?>.filled(candidates.length, null);
  for (var i = 0; i < candidates.length; i++) {
    final part = done[i % n];
    final local = i ~/ n;
    if (local < part.length) out[i] = part[local];
  }
  return [
    for (final r in out) r ?? const SearchBatchItemResult(),
  ];
}

/// 跑一个分片；隔离区失败时返回 null，由调用方退回主线程。
Future<List<SearchBatchItemResult>?> _runChunk(
  SearchBatchRequest req,
) async {
  try {
    return await Isolate.run(() => runSearchBatch(req));
  } catch (_) {
    return null;
  }
}

SearchBatchRequest _requestOf({
  required SearchEnv env,
  required List<ComboCand> candidates,
  required int splitX,
  required int maxKn,
  required SearchBatchMode mode,
  required Map<String, SegmentMetrics> knownInSample,
}) {
  final align = env.align;
  return SearchBatchRequest(
    bars: env.bars,
    harness: env.h,
    code: env.code,
    period: env.period,
    begin: env.begin,
    end: env.end,
    strategyTemplate: align.strategyTemplate,
    features: align.features,
    bucketStep: align.bucketStep,
    bollN: align.bollN,
    donchianN: align.donchianN,
    regressK: align.regressK,
    maxKn: maxKn,
    splitX: splitX,
    candidates: candidates,
    mode: mode,
    knownInSample: knownInSample,
  );
}
