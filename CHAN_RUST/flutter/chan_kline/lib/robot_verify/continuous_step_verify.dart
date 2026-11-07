import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/step_freeze/audit_probe_assertions.dart';
import 'package:chan_kline/step_freeze/step_freeze_parity_driver.dart';

import 'robot_verify_data.dart';
import 'robot_verify_model.dart';

/// 连续单步冻结对拍 + 探针场景（与主图 `StepFreezeMerger` 同源）。
Future<RobotVerifyPhase> runContinuousStepFreezePhase({String? klineRoot}) async {
  const phaseId = 'continuous_step_freeze';

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
  if (!bridge.supportsAppendDelta) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'missing_chan_pipeline_append_delta'},
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
        'localBackup': hasLocal002003TickBackup(klineRoot: klineRoot),
        'attempts': lastRobotVerifyDataResolveAttempts(),
      },
    );
  }

  final driver = StepFreezeParityDriver(truncationCheck: true);
  final cases = <Map<String, Object?>>[];
  var allOk = true;

  for (final spec in _periodSpecs) {
    List<KlineBar> bars;
    try {
      bars = loadRobotVerifyBars(plan: plan, period: spec.period);
    } catch (e) {
      allOk = false;
      cases.add({
        'period': spec.period,
        'ok': false,
        'error': 'load_failed',
        'message': '$e',
        'dataRoot': plan.dataRoot,
        'tickSource': plan.tickSource,
        'via': plan.via,
      });
      continue;
    }
    if (bars.length < spec.minBars) {
      allOk = false;
      cases.add({
        'period': spec.period,
        'ok': false,
        'error': 'insufficient_bars',
        'bars': bars.length,
        'minBars': spec.minBars,
        'dataRoot': plan.dataRoot,
        'tickSource': plan.tickSource,
        'via': plan.via,
      });
      continue;
    }
    final result = driver.run(bars);
    final caseMap = <String, Object?>{
      'period': spec.period,
      'ok': result.ok,
      'bars': bars.length,
      'steps': bars.length,
      'lastSegN': result.lastSegN,
      'midSnapSegN': result.midSnapSegN,
      'dataRoot': plan.dataRoot,
      'tickSource': plan.tickSource,
      'via': plan.via,
      if (!result.ok) 'mismatches': result.mismatches,
    };
    if (spec.period == 'tick' && result.ok) {
      final acc = driver.accumulateStepOnly(bars);
      final probe = AuditProbeAssertions.evaluate(
        bars: acc.bars,
        stepIdx: bars.length - 1,
        sessionLevels: acc.lastBundle.levels,
        barFeatures: acc.lastBundle.barFeatures,
        stepRhythmHistoryByKn: acc.state.stepRhythmHistoryByKn,
      );
      caseMap['auditProbe'] = probe;
      if (probe['ok'] != true) {
        caseMap['ok'] = false;
        allOk = false;
      }
    }
    if (caseMap['ok'] != true) allOk = false;
    cases.add(caseMap);
  }

  return RobotVerifyPhase(
    id: phaseId,
    ok: allOk,
    details: {'cases': cases, 'harness': 'StepFreezeMerger'},
  );
}

class _PeriodSpec {
  const _PeriodSpec(this.period, this.minBars);
  final String period;
  final int minBars;
}

const _periodSpecs = [
  _PeriodSpec('1m', 40),
  _PeriodSpec('tick', 80),
];
