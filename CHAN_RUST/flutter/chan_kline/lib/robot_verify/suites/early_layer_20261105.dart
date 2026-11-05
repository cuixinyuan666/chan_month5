import '../robot_verify_flutter_test.dart';
import '../robot_verify_model.dart';
import '../robot_verify_suite_meta.dart';

const String kEarlyLayer20261105SuiteId = 'early_layer_20261105';

Future<List<RobotVerifyPhase>> runEarlyLayer20261105Phases({
  required String klineRoot,
  bool runFlutterTest = true,
}) async {
  final phases = <RobotVerifyPhase>[];
  if (runFlutterTest) {
    phases.add(
      await runFlutterTestJsonPhase(
        phaseId: 'flutter_test_early_layer_accept',
        workingDirectory: klineRoot,
        testPathArgs: [
          'test/early_layer_002003_accept_test.dart',
          'test/early_layer_dynamic_accept_test.dart',
        ],
      ),
    );
  }
  return phases;
}
