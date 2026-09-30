import 'robot_verify_model.dart';
import 'suites/indicator_search_opt_20260930.dart';

/// 机器人验证套件注册（suiteId 须与 [agent.md] 及 session.json 一致）。
Future<List<RobotVerifyPhase>> runRobotVerifySuitePhases({
  required String suiteId,
  required String klineRoot,
  bool skipFlutterTest = false,
}) async {
  switch (suiteId) {
    case 'indicator_search_opt_20260930':
      return runIndicatorSearchOpt20260930Phases(
        klineRoot: klineRoot,
        runFlutterTest: !skipFlutterTest,
      );
    default:
      return [
        RobotVerifyPhase(
          id: 'unknown_suite',
          ok: false,
          details: {'suiteId': suiteId},
        ),
      ];
  }
}
