import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';

import '../continuous_step_verify.dart';
import '../robot_verify_flutter_test.dart';
import '../robot_verify_model.dart';
import '../robot_verify_suite_meta.dart';

/// 2026-09-30 寻优 + 连续单步冻结验收（结构化阶段，无人类可读长文）。
Future<List<RobotVerifyPhase>> runIndicatorSearchOpt20260930Phases({
  required String klineRoot,
  bool runFlutterTest = true,
}) async {
  final phases = <RobotVerifyPhase>[];

  if (runFlutterTest) {
    phases.add(
      await runFlutterTestJsonPhase(
        phaseId: 'flutter_test_indicator_search',
        workingDirectory: klineRoot,
        testPathArgs: ['test/indicator_search/'],
      ),
    );
  }

  phases.add(await runIndicatorSearchOpt20260930InProcess());

  final meta = metaForSuite('indicator_search_opt_20260930');
  if (meta?.continuousStepFreeze == true) {
    phases.add(await runContinuousStepFreezePhase(klineRoot: klineRoot));
  }

  return phases;
}

Future<RobotVerifyPhase> runIndicatorSearchOpt20260930InProcess() async {
  const phaseId = 'inprocess_indicator_search_opt';
  final checks = <RobotVerifyCheck>[];

  final pool16 = VariablePool(16);
  final cap2k = buildCandidates(
    pool16,
    const CandidateBuildOptions.optimized(maxCandidates: 2000),
  );
  checks.add(RobotVerifyCheck(
    id: 'cap2000_length',
    ok: cap2k.length <= 2000,
    data: {'actual': cap2k.length, 'cap': 2000},
  ));
  final s2k = summarizeCandidates(cap2k);
  checks.add(RobotVerifyCheck(
    id: 'cap2000_mix',
    ok: s2k.crosses > 0 && s2k.thresholds > 0,
    data: {
      'crosses': s2k.crosses,
      'thresholds': s2k.thresholds,
      'events': s2k.events,
    },
  ));

  final cap12k = buildCandidates(
    pool16,
    const CandidateBuildOptions.optimized(maxCandidates: 12000),
  );
  checks.add(RobotVerifyCheck(
    id: 'cap12000_length',
    ok: cap12k.length <= 12000,
    data: {'actual': cap12k.length, 'cap': 12000},
  ));
  final s12 = summarizeCandidates(cap12k);
  checks.add(RobotVerifyCheck(
    id: 'cap12000_mix',
    ok: s12.crosses > 0 && s12.thresholds > 0,
    data: {'crosses': s12.crosses, 'thresholds': s12.thresholds},
  ));

  final pool8 = VariablePool(8);
  final orphans = pool8.events.where(
    (d) => !VariablePool.isBuyEvent(d) && !VariablePool.isSellEvent(d),
  );
  checks.add(RobotVerifyCheck(
    id: 'event_pool_no_orphans',
    ok: orphans.isEmpty,
    data: {'orphans': orphans.length},
  ));
  final buyIds = pool8.buyEvents().map((e) => e.variableId).toSet();
  checks.add(RobotVerifyCheck(
    id: 'buy_pool_divergence_fractal',
    ok: buyIds.any((id) => id.contains('DIVERGENCE.EXISTS')) &&
        buyIds.any((id) => id.contains('FRACTAL_CONFIRM')),
  ));

  final pairs = pool16.sameClockNumericPairs();
  var crossUnit = 0;
  for (final p in pairs) {
    if (p.$1.unit != p.$2.unit) crossUnit++;
  }
  checks.add(RobotVerifyCheck(
    id: 'cross_same_unit',
    ok: crossUnit == 0,
    data: {'crossUnitPairs': crossUnit, 'totalPairs': pairs.length},
  ));

  final adjList = pool8.numeric
      .where((d) => d.variableId.contains('ADJACENT_RATIO'))
      .toList();
  if (adjList.isNotEmpty) {
    final c = VariablePool.constantsFor(adjList.first);
    checks.add(RobotVerifyCheck(
      id: 'adjacent_ratio_threshold',
      ok: c.length == 1 && c.first == 0,
      data: {'constants': c},
    ));
  }

  final withCloseTh = cap12k
      .where((c) => c.name.startsWith('阈值｜') && c.name.contains('收盘'))
      .length;
  checks.add(RobotVerifyCheck(
    id: 'threshold_vs_close',
    ok: withCloseTh > 0,
    data: {'count': withCloseTh},
  ));

  final ok = checks.every((c) => c.ok);
  return RobotVerifyPhase(
    id: phaseId,
    ok: ok,
    details: {
      'checks': checks.map((c) => c.toJson()).toList(),
    },
  );
}
