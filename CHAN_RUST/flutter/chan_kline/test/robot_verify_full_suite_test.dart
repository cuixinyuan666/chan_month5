import 'dart:io';

import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/robot_verify/robot_verify_paths.dart';
import 'package:chan_kline/robot_verify/robot_verify_runner.dart';
import 'package:flutter_test/flutter_test.dart';

/// 与 App 内 `runFullRobotVerify` 同编排（CLI 落盘报告，供智能体验收）。
void main() {
  const suiteId = 'indicator_search_opt_20260930';

  test(
    '机器人验证全套件 indicator_search_opt_20260930',
    () async {
      final klineRoot = Directory.current.path;
      ChanBridge.instance.ensureInitialized();

      final report = await runFullRobotVerify(
        suiteId: suiteId,
        klineRoot: klineRoot,
      );

      final flutter = report.phases
          .where((p) => p.id == 'flutter_test_indicator_search')
          .toList();
      if (flutter.isNotEmpty) {
        final passed = flutter.first.details['passed'];
        expect(passed, 12, reason: '应过滤 hidden，12 个真实用例');
      }

      for (final p in report.phases) {
        if (p.skipped) continue;
        expect(p.ok, isTrue, reason: '阶段 ${p.id} 未通过: ${p.details}');
      }
      expect(report.ok, isTrue, reason: report.toClipboardPayload());

      final dir = RobotVerifyPaths.verifyDir(klineRoot: klineRoot);
      expect(dir, isNotNull);
      expect(
        File('${dir!.path}/last_report.json').existsSync(),
        isTrue,
      );
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
