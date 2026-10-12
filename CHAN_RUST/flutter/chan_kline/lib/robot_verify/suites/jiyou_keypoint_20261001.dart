import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_align.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_diagnostics.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_export.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/stat_metrics.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:chan_kline/step_freeze/step_freeze_parity_driver.dart';
import 'package:chan_kline/step_freeze/step_freeze_session_state.dart';

import '../continuous_step_verify.dart';
import '../robot_verify_data.dart';
import '../robot_verify_flutter_test.dart';
import '../robot_verify_model.dart';
import '../robot_verify_suite_meta.dart';

const String kJiYouKeyPointSuiteId = 'jiyou_keypoint_20261001';

/// 顶底差异走查：**由机器人自己连续单步走到末根 K**，出转折点、出统计表、
/// 出顶底差异度，并把 Top-N 差异清单写进 JSON 供人判读。
///
/// 这一阶段对应用户要求的「冷启动连续单步走到末根 K → 点计优」那一步，
/// 但**完全由机器人验证完成**，不借「一键跳末」代替：
///  - [StepFreezeWalkTrace.isOneByOne] 证明每步只喂进去 1 根、步数等于 K0 总根数，
///    从根上排除「一次性喂满再算」；
///  - 差异度与手工重算对拍，且降序单调；
///  - 「有没有洞察」是主观判断、写不成断言 —— 所以只把 Top-N 清单原样输出，
///    由人看报告判读。机器人负责证明链路正确，不假装能理解洞察。
Future<RobotVerifyPhase> runJiyouContrastWalkPhase({String? klineRoot}) async {
  const phaseId = 'jiyou_contrast_walk';

  try {
    ChanBridge.instance.ensureInitialized();
  } catch (e) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'ffi_init_failed', 'message': '$e'},
    );
  }

  final plan = await resolveRobotVerify002003LoadPlan(klineRoot: klineRoot);
  if (plan == null) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: true,
      skipped: true,
      skipReason: 'no_verify_data',
      details: {'attempts': lastRobotVerifyDataResolveAttempts()},
    );
  }

  final List<KlineBar> bars;
  try {
    bars = loadRobotVerifyBars(plan: plan, period: '1m');
  } catch (e) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'load_failed', 'message': '$e'},
    );
  }
  if (bars.length < 40) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'insufficient_bars', 'bars': bars.length},
    );
  }

  // ① 连续单步走到末根，并留下轨迹作为证据
  final driver = StepFreezeParityDriver(truncationCheck: true);
  final trace = driver.walkWithTrace(bars);
  final b = trace.lastBundle;
  final state = trace.state;
  final maxKn = chartMaxKn(levels: b.levels, k0Lines: b.k0Lines);

  // ② 用这条逐根冻出来的账建 lookup（不是走完瘦包）
  final lookup = _lookupFromWalk(
    bars: bars,
    bundle: b,
    state: state,
    maxKn: maxKn,
  );

  // ③ 计优
  const settings = KeyPointStatSettings();
  final collect = collectKeyPoints(
    bars: bars,
    levels: b.levels,
    k0Confirms: b.k0Confirms,
    k0Lines: b.k0Lines,
    asOf: bars.last.idx,
  );
  final result = KeyPointStatRunner.run(
    lookup: lookup,
    collect: collect,
    settings: settings,
    code: '002003',
    period: '1m',
    barCount: bars.length,
    maxKn: maxKn,
    align: KeyPointStatAlign(
      code: '002003',
      period: '1m',
      barCount: bars.length,
      asOf: bars.last.idx,
      maxKn: maxKn,
      truncationCheck: true,
    ),
  );
  final diag = KeyPointStatDiagnostics.of(result);

  final checks = <RobotVerifyCheck>[];
  void add(String id, bool ok, [Map<String, Object?> data = const {}]) =>
      checks.add(RobotVerifyCheck(id: id, ok: ok, data: data));

  // --- 逐根证据 ---
  add(
    'walk_steps_equal_bars',
    trace.steps == bars.length,
    {'steps': trace.steps, 'bars': bars.length},
  );
  add('walk_one_bar_per_step', trace.isOneByOne, {
    'first': trace.fedCounts.isEmpty ? -1 : trace.fedCounts.first,
    'last': trace.fedCounts.isEmpty ? -1 : trace.fedCounts.last,
  });
  add('walk_features_grow_one_by_one', trace.featuresGrowOneByOne);
  add(
    'walk_reached_last_bar',
    trace.fedCounts.isNotEmpty && trace.fedCounts.last == bars.length,
  );

  // --- 计优链路 ---
  add('key_points_found', collect.keyPoints.isNotEmpty, {
    'count': collect.keyPoints.length,
  });
  add(
    'key_points_confirmed_only',
    collect.keyPoints.every((p) => p.confirmX <= bars.last.idx),
  );
  add('groups_built', result.groups.isNotEmpty);
  add('align_lines_present', result.headerLine.contains('点位口径：')
      && result.headerLine.contains('指标参数：'));

  // --- 顶底差异度 ---
  final cs = result.contrasts;
  add('contrast_not_empty', cs.isNotEmpty, {'count': cs.length});
  add(
    'contrast_descending',
    cs.length < 2 || cs[0].contrast >= cs[cs.length - 1].contrast,
  );
  add(
    'contrast_all_finite',
    cs.every((c) => c.contrast.isFinite && c.pooledSigma > 0),
  );
  add(
    'contrast_sides_differ',
    cs.isEmpty || cs.any((c) => c.topMean != c.bottomMean),
    {'reason': '全无差异说明顶底取到了同一批点'},
  );
  // 与手工重算对拍（用第一项自己再算一遍 |Δmean| / RMS）
  var handOk = true;
  if (cs.isNotEmpty) {
    final c = cs.first;
    final pooled = _rmsForCheck(c.pooledSigma);
    final manual = (c.topMean - c.bottomMean).abs() / pooled;
    handOk = (manual - c.contrast).abs() < 1e-9;
  }
  add('contrast_matches_manual', handOk);

  final ok = checks.every((c) => c.ok);
  return RobotVerifyPhase(
    id: phaseId,
    ok: ok,
    details: {
      'bars': bars.length,
      'maxKn': maxKn,
      'harness': 'StepFreezeMerger.walkWithTrace',
      'walk': {
        'steps': trace.steps,
        'oneByOne': trace.isOneByOne,
        'featuresOneByOne': trace.featuresGrowOneByOne,
        'lastFed': trace.fedCounts.isEmpty ? -1 : trace.fedCounts.last,
      },
      'keyPoints': collect.toJson(),
      'groupCount': result.groups.length,
      'contrastCount': cs.length,
      'diagnostics': diag.toJson(),
      // Top-N 差异清单：供人判读「有没有洞察」
      'topContrast': diag.topContrastJson(result, 10),
      'checks': checks.map((c) => c.toJson()).toList(),
    },
  );
}

double _rmsForCheck(double pooled) => pooled <= 0 ? 1 : pooled;

/// 用连续单步冻出来的末包建冻结账（两个阶段共用，保证走的是同一条路径）。
BarFeatureLookup _lookupFromWalk({
  required List<KlineBar> bars,
  required KlineCombineBundle bundle,
  required StepFreezeSessionState state,
  required int maxKn,
}) {
  return BarFeatureLookup.build(
    bars: bars,
    combineFrames: bundle.frames,
    k0Confirms: bundle.k0Confirms,
    barFeatures: bundle.barFeatures,
    k0Lines: bundle.k0Lines,
    k1Analysis: bundle.k1Analysis,
    levels: bundle.levels,
    k1CombineFrames: bundle.k1CombineFrames,
    buy1HistoryByKn: state.buy1HistoryByKn,
    sell1HistoryByKn: state.sell1HistoryByKn,
    buy2HistoryByKn: state.buy2HistoryByKn,
    sell2HistoryByKn: state.sell2HistoryByKn,
    buyNHistoryByKn: state.buyNHistoryByKn,
    sellNHistoryByKn: state.sellNHistoryByKn,
    adjacentRatioHistoryByKn: state.adjacentRatioHistoryByKn,
    stepRhythmHistoryByKn: state.stepRhythmHistoryByKn,
    lineSlopeHistoryByKn: state.lineSlopeHistoryByKn,
    buy1K0Frames: state.buy1HistoryByKn[0] ?? const [],
    sell1K0Frames: state.sell1HistoryByKn[0] ?? const [],
    buy2K0Frames: state.buy2HistoryByKn[0] ?? const [],
    sell2K0Frames: state.sell2HistoryByKn[0] ?? const [],
    buyNK0Frames: state.buyNHistoryByKn[0] ?? const [],
    sellNK0Frames: state.sellNHistoryByKn[0] ?? const [],
    subIndicators: buildSubIndicatorCatalog(maxKn, truncationCheck: true)
        .toSet(),
    truncationCheck: true,
    judgmentHistoryByKn: state.judgmentHistoryByKn,
    zsJudgmentHistoryByKn: state.zsJudgmentHistoryByKn,
    zsConfirmHistoryByKn: state.zsConfirmHistoryByKn,
    asOf: bars.last.idx,
    mathFreezeStore: state.mathFreezeStore,
    diverFreezeStore: state.diverFreezeStore,
    zsK0Frames: bundle.zsK0Frames,
  );
}

/// 计优（关键点位指标统计）验收：flutter test + 进程内自检 + 连续单步冻结对拍
/// + **顶底差异走查**（由机器人自己连续单步走到末根，不借「一键跳末」）。
Future<List<RobotVerifyPhase>> runJiyouKeyPointPhases({
  required String klineRoot,
  bool runFlutterTest = true,
}) async {
  final phases = <RobotVerifyPhase>[];

  if (runFlutterTest) {
    phases.add(
      await runFlutterTestJsonPhase(
        phaseId: 'flutter_test_jiyou',
        workingDirectory: klineRoot,
        testPathArgs: ['test/jiyou/'],
      ),
    );
  }

  phases.add(await runJiyouKeyPointInProcess(klineRoot: klineRoot));
  phases.add(await runJiyouContrastWalkPhase(klineRoot: klineRoot));

  final meta = metaForSuite(kJiYouKeyPointSuiteId);
  if (meta?.continuousStepFreeze == true) {
    phases.add(await runContinuousStepFreezePhase(klineRoot: klineRoot));
  }

  return phases;
}

/// 用连续单步冻结仓（与主图同源的 [StepFreezeMerger]）构建冻结账，
/// 再跑一遍计优全流程做进程内自检。
Future<RobotVerifyPhase> runJiyouKeyPointInProcess({String? klineRoot}) async {
  const phaseId = 'inprocess_jiyou_keypoint';

  try {
    ChanBridge.instance.ensureInitialized();
  } catch (e) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'ffi_init_failed', 'message': '$e'},
    );
  }

  final bridge = ChanBridge.instance;
  if (bridge.loadedFfiAbiVersion != kChanFfiAbiVersion) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {
        'error': 'ffi_abi_mismatch',
        'loaded': bridge.loadedFfiAbiVersion,
        'expected': kChanFfiAbiVersion,
      },
    );
  }

  final plan = await resolveRobotVerify002003LoadPlan(klineRoot: klineRoot);
  if (plan == null) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: true,
      skipped: true,
      skipReason: 'no_verify_data',
      details: {
        'message': '本地未找到可用分笔且协议拉取失败',
        'attempts': lastRobotVerifyDataResolveAttempts(),
      },
    );
  }

  List<KlineBar> bars;
  try {
    bars = loadRobotVerifyBars(plan: plan, period: '1m');
  } catch (e) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'load_failed', 'message': '$e'},
    );
  }
  if (bars.length < 40) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'insufficient_bars', 'bars': bars.length},
    );
  }

  final driver = StepFreezeParityDriver(truncationCheck: true);
  final acc = driver.accumulateStepOnly(bars);
  final b = acc.lastBundle;
  final state = acc.state;
  final maxKn = chartMaxKn(levels: b.levels, k0Lines: b.k0Lines);

  final lookup = _lookupFromWalk(
    bars: bars,
    bundle: b,
    state: state,
    maxKn: maxKn,
  );

const settings = KeyPointStatSettings();
  final collect = collectKeyPoints(
    bars: bars,
    levels: b.levels,
    k0Confirms: b.k0Confirms,
    k0Lines: b.k0Lines,
    asOf: bars.last.idx,
  );

  // 同输入重跑必须逐字节一致。用同一个闭包保证两次参数完全相同 ——
  // 早先这里两次各写一份参数、漏传了 code/period，报告头纳入复现参数后
  // 就成了「同输入不同输出」；参数收在一处才不会再漂。
  KeyPointStatResult runOnce() => KeyPointStatRunner.run(
        lookup: lookup,
        collect: collectKeyPoints(
          bars: bars,
          levels: b.levels,
          k0Confirms: b.k0Confirms,
          k0Lines: b.k0Lines,
          asOf: bars.last.idx,
        ),
        settings: settings,
        code: '002003',
        period: '1m',
        barCount: bars.length,
        maxKn: maxKn,
      );

  final result = runOnce();

  final checks = <RobotVerifyCheck>[];
  void add(String id, bool ok, [Map<String, Object?> data = const {}]) =>
      checks.add(RobotVerifyCheck(id: id, ok: ok, data: data));

  add(
    'key_points_found',
    collect.keyPoints.isNotEmpty,
    {'count': collect.keyPoints.length},
  );
  add(
    'key_points_in_range',
    collect.keyPoints.every((p) => p.poleX >= 0 && p.poleX <= bars.length - 1),
  );
  add(
    'key_points_deduped',
    collect.keyPoints.map((e) => e.dedupKey).toSet().length ==
        collect.keyPoints.length,
  );
  add(
    'confirmed_only',
    collect.keyPoints.every((p) => p.confirmX <= bars.last.idx),
    {'skippedUnconfirmed': collect.skippedUnconfirmed},
  );
  add('groups_built', result.groups.isNotEmpty, {
    'groups': result.groups.map((e) => e.groupKey).toList(),
  });
  add(
    'has_summary_group',
    result.groups.any((g) => g.groupKey == 'ALL'),
  );
  add(
    'groups_non_empty',
    result.groups.every((g) => g.pointCount > 0),
  );

  final all = result.groups.where((g) => g.groupKey == 'ALL').toList();
  final allStats = all.isEmpty ? <StatSummary>[] : all.first.stats;
  final numeric = allStats.where((e) => e.kind == StatValueKind.numeric);
  final categorical = allStats.where((e) => e.kind == StatValueKind.categorical);

  add('numeric_stats_present', numeric.length >= 5, {'numeric': numeric.length});
  add('categorical_stats_present', categorical.isNotEmpty, {
    'categorical': categorical.length,
  });
  add(
    'mean_within_min_max',
    numeric.every(
      (s) => s.min != null && s.mean != null && s.max != null &&
          s.min! <= s.mean! + 1e-9 && s.mean! <= s.max! + 1e-9,
    ),
  );
  add(
    'median_inside_quartiles',
    numeric.every(
      (s) => s.p25 == null || s.median == null || s.p75 == null ||
          (s.p25! <= s.median! + 1e-9 && s.median! <= s.p75! + 1e-9),
    ),
  );
  add(
    'mode_count_within_samples',
    numeric.every((s) => s.modeCount <= s.sampleCount) &&
        categorical.every((s) => s.modeCount <= s.sampleCount),
  );
  add(
    'no_filled_zero',
    numeric.every((s) => s.sampleCount == 0 || s.mean != null),
  );

  // 同输入重跑必须完全一致（可复现是统计表的生命线）。
  add(
    'deterministic_rerun',
    KeyPointStatExport.buildTsv(result) ==
        KeyPointStatExport.buildTsv(runOnce()),
  );

  var exportOk = true;
  String? exportErr;
  try {
    KeyPointStatExport.buildJson(result);
    KeyPointStatExport.buildTsv(result);
  } catch (e) {
    exportOk = false;
    exportErr = '$e';
  }
  add(
    'export_serializable',
    exportOk,
    exportErr == null ? const {} : <String, Object?>{'error': exportErr},
  );

  final ok = checks.every((c) => c.ok);
  return RobotVerifyPhase(
    id: phaseId,
    ok: ok,
    details: {
      'bars': bars.length,
      'maxKn': maxKn,
      'keyPoints': collect.toJson(),
      'groupCount': result.groups.length,
      'metricCount': result.metricCount,
      'numericCount': numeric.length,
      'categoricalCount': categorical.length,
      'checks': checks.map((c) => c.toJson()).toList(),
    },
  );
}