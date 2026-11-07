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
        final passed = flutter.first.details['passed'] as int?;
        // 应过滤 hidden；下界=实测 test/indicator_search/ 的用例总数 42：
        //   候选构建5 + 编译对拍1 + 早停对拍1 + 引擎对拍1 + oos切片1 + 主对拍1
        //   + 分段编译对拍1 + raw_score_json1 = 12（寻优对拍）
        //   + 报告头与面板 UI 8 + 占仓扭曲 4 + 取消扫描 3 + 全胜小样本体检 15 = 43
        //   注：suite 报告的 passed 为「真实用例数 - 文件数」，故取 42 留余量。
        const minExpected = 42;
        expect(
          passed,
          greaterThanOrEqualTo(minExpected),
          reason:
              '寻优测试用例数应不少于 $minExpected'
              '（含报告头/占仓扭曲/取消扫描/全胜体检）',
        );
      }

      for (final p in report.phases) {
        if (p.skipped) continue;
        expect(p.ok, isTrue, reason: '阶段 ${p.id} 未通过: ${p.details}');
      }
      expect(report.ok, isTrue, reason: report.toClipboardPayload());

      final dir = RobotVerifyPaths.verifyDir(klineRoot: klineRoot);
      expect(dir, isNotNull);
      expect(File('${dir!.path}/last_report.json').existsSync(), isTrue);
    },
    timeout: const Timeout(Duration(minutes: 25)),
  );
}
