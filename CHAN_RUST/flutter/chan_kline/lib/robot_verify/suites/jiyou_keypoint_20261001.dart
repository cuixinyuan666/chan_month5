import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_export.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/key_point_stats/stat_metrics.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:chan_kline/step_freeze/step_freeze_parity_driver.dart';

import '../continuous_step_verify.dart';
import '../robot_verify_data.dart';
import '../robot_verify_flutter_test.dart';
import '../robot_verify_model.dart';
import '../robot_verify_suite_meta.dart';

const String kJiYouKeyPointSuiteId = 'jiyou_keypoint_20261001';

/// 计优（关键点位指标统计）验收：flutter test + 进程内自检 + 连续单步冻结对拍。
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

  final lookup = BarFeatureLookup.build(
    bars: bars,
    combineFrames: b.frames,
    k0Confirms: b.k0Confirms,
    barFeatures: b.barFeatures,
    k0Lines: b.k0Lines,
    k1Analysis: b.k1Analysis,
    levels: b.levels,
    k1CombineFrames: b.k1CombineFrames,
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
    zsK0Frames: b.zsK0Frames,
  );
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
  );

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
  final again = KeyPointStatRunner.run(
    lookup: lookup,
    collect: collectKeyPoints(
      bars: bars,
      levels: b.levels,
      k0Confirms: b.k0Confirms,
      k0Lines: b.k0Lines,
      asOf: bars.last.idx,
    ),
    settings: settings,
    barCount: bars.length,
    maxKn: maxKn,
  );
  add(
    'deterministic_rerun',
    KeyPointStatExport.buildTsv(result) == KeyPointStatExport.buildTsv(again),
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