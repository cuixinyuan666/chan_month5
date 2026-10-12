import 'dart:convert';
import 'dart:io';

import 'robot_verify_model.dart';
import 'robot_verify_paths.dart';
import 'robot_verify_registry.dart';

typedef RobotVerifyProgress = void Function(String stepLabel, double? fraction);

/// 编排完整机器人验证（JSON 报告，剪贴板/落盘同 payload）。
Future<RobotVerifyReport> runFullRobotVerify({
  required String suiteId,
  required String klineRoot,
  RobotVerifyProgress? onProgress,
}) async {
  final started = DateTime.now().toIso8601String();
  final phases = <RobotVerifyPhase>[];

  final extLog = Platform.environment['CHAN_ROBOT_TEST_LOG'];
  final presetLog = extLog != null && extLog.isNotEmpty && File(extLog).existsSync();

  onProgress?.call('suite_start', 0.08);
  final suitePhases = await runRobotVerifySuitePhases(
    suiteId: suiteId,
    klineRoot: klineRoot,
    skipFlutterTest: presetLog,
  );

  if (presetLog) {
    phases.add(
      RobotVerifyPhase(
        id: 'flutter_test_indicator_search',
        ok: true,
        skipped: true,
        skipReason: 'preset_log',
        details: {'path': extLog},
      ),
    );
  }

  var frac = 0.12;
  for (final p in suitePhases) {
    onProgress?.call(p.id, frac);
    frac = (frac + 0.78 / suitePhases.length).clamp(0.0, 0.95);
    phases.add(p);
  }

  final report = RobotVerifyReport(
    schemaVersion: RobotVerifyReport.currentSchema,
    suiteId: suiteId,
    klineRoot: klineRoot,
    started: started,
    phases: phases,
  );
  report.ended = DateTime.now().toIso8601String();
  onProgress?.call('report_ready', 1.0);

  final payload = report.toClipboardPayload();
  final verifyDir = RobotVerifyPaths.verifyDir(klineRoot: klineRoot);
  if (verifyDir != null) {
    await File('${verifyDir.path}/last_report.json').writeAsString(payload);
    await File('${verifyDir.path}/last_report.txt').writeAsString(payload);
    final ft = phases
        .where((p) => p.id == 'flutter_test_indicator_search')
        .toList();
    if (ft.isNotEmpty) {
      await File('${verifyDir.path}/flutter_test_log.json')
          .writeAsString(jsonEncode(ft.first.toJson()));
    }
  }

  return report;
}
