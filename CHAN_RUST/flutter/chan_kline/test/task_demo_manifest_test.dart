import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/task_demo/task_demo_manifest.dart';

void main() {
  test('TaskDemoManifest 解析 manifest.json', () {
    const json = '''
{
  "id": "demo-1",
  "title": "标题",
  "completedAt": "2026-08-15",
  "agent": "cursor",
  "isNewFeature": false,
  "beforeSummary": "旧",
  "afterSummary": "新",
  "verificationPoints": ["a", "b"],
  "keySteps": [1, 2],
  "demoCsv": "demo.ohlc.csv"
}
''';
    final m = TaskDemoManifest.tryParseFile('/tmp/demo-1', json);
    expect(m, isNotNull);
    expect(m!.id, 'demo-1');
    expect(m.verificationPoints, ['a', 'b']);
    expect(m.keySteps, [1, 2]);
    expect(m.demoCsv, 'demo.ohlc.csv');
  });
}
