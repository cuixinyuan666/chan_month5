import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/robot_verify/continuous_step_verify.dart';
import 'package:flutter_test/flutter_test.dart';

import 'offline_tick_files.dart';

/// 后台对拍：连续单步冻结 vs 一次性走完瘦包（实现见 continuous_step_verify.dart）。
void main() {
  setUpAll(() {
    ChanBridge.instance.ensureInitialized();
    expect(
      ChanBridge.instance.loadedFfiAbiVersion,
      kChanFfiAbiVersion,
      reason: '库版本须与界面一致；请覆盖 windows/native/chan_ffi.dll',
    );
    expect(
      ChanBridge.instance.supportsAppendDelta,
      isTrue,
      reason: '须有 chan_pipeline_append_delta',
    );
  });

  test(
    '002003 连续单步冻结对拍（1m + tick）',
    () async {
      final phase = await runContinuousStepFreezePhase();
      expect(phase.skipped, isFalse, reason: phase.skipReason);
      expect(phase.ok, isTrue, reason: '${phase.details}');
      final cases = phase.details['cases'] as List<dynamic>?;
      expect(cases, isNotNull);
      expect(cases!.length, 2);
      for (final c in cases!) {
        final m = c as Map<String, dynamic>;
        expect(m['ok'], isTrue, reason: '$m');
      }
    },
    timeout: const Timeout(Duration(minutes: 15)),
    skip: hasOffline002003TickFiles() ? false : kNoOffline002003Skip,
  );
}
