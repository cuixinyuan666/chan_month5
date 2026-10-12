import 'package:chan_kline/step_freeze/step_freeze_session_state.dart';
import 'package:chan_kline/step_freeze/step_freeze_signatures.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('StepFreezeSignatures diff empty states', () {
    final a = StepFreezeSessionState();
    final b = StepFreezeSessionState();
    expect(StepFreezeSignatures.diff(a, b), isEmpty);
  });
}
