import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/step_freeze/audit_probe_assertions.dart';
import 'package:chan_kline/step_freeze/step_freeze_parity_driver.dart';

import 'robot_verify_data.dart';
import 'robot_verify_model.dart';

/// 连续单步冻结对拍 + 探针场景（与主图 `StepFreezeMerger` 同源）。
Future<RobotVerifyPhase> runContinuousStepFreezePhase({String? klineRoot}) async {
  const phaseId = 'continuous_step_freeze';
  if (!hasOffline002003Data(klineRoot: klineRoot)) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: true,
      skipped: true,
      skipReason: 'no_offline_002003',
    );
  }

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

  final driver = StepFreezeParityDriver(truncationCheck: true);
  final cases = <Map<String, Object?>>[];
  var allOk = true;

  for (final spec in _periodSpecs) {
    final bars = _loadBars(period: spec.period);
    if (bars.length < spec.minBars) {
      allOk = false;
      cases.add({
        'period': spec.period,
        'ok': false,
        'error': 'insufficient_bars',
        'bars': bars.length,
        'minBars': spec.minBars,
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

List<KlineBar> _loadBars({required String period}) {
  final bridge = ChanBridge.instance;
  return bridge.loadKlines(
    dataRoot: bridge.defaultDataRoot(),
    code: '002003',
    beginDate: '2004/07/19 10:47:00',
    endDate: '2004/07/20 13:09:00',
    period: period,
  );
}
