import 'dart:convert';
import 'dart:io';

import 'robot_verify_model.dart';

/// Run `flutter test` and summarize via JSON reporter (no raw console capture).
Future<RobotVerifyPhase> runFlutterTestJsonPhase({
  required String phaseId,
  required String workingDirectory,
  required List<String> testPathArgs,
}) async {
  if (!Directory(workingDirectory).existsSync()) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'invalid_working_directory', 'path': workingDirectory},
    );
  }

  final args = <String>[
    'test',
    ...testPathArgs,
    '--reporter',
    'json',
  ];

  final process = await Process.start(
    'flutter',
    args,
    workingDirectory: workingDirectory,
    runInShell: true,
  );

  final stdoutStr = await process.stdout.transform(utf8.decoder).join();
  final stderrStr = await process.stderr.transform(utf8.decoder).join();
  final exitCode = await process.exitCode;

  var passed = 0;
  var failed = 0;
  final failures = <Map<String, Object?>>[];

  for (final line in stdoutStr.split('\n')) {
    final t = line.trim();
    if (t.isEmpty || !t.startsWith('{')) continue;
    try {
      final ev = jsonDecode(t) as Map<String, dynamic>;
      final type = ev['type'] as String?;
      if (type == 'testDone') {
        final result = ev['result'] as String?;
        if (result == 'success') {
          passed++;
        } else if (result != null) {
          failed++;
          failures.add({
            'testID': ev['testID'],
            'result': result,
            if (ev['error'] != null) 'error': '${ev['error']}',
          });
        }
      }
    } catch (_) {
      // ignore non-json lines
    }
  }

  final ok = exitCode == 0 && failed == 0;
  return RobotVerifyPhase(
    id: phaseId,
    ok: ok,
    details: {
      'exitCode': exitCode,
      'passed': passed,
      'failed': failed,
      if (failures.isNotEmpty) 'failures': failures,
      if (!ok && stderrStr.trim().isNotEmpty)
        'stderrTail': _tailLines(stderrStr, 12),
    },
  );
}

String _tailLines(String text, int maxLines) {
  final lines = text.split('\n');
  if (lines.length <= maxLines) return text.trim();
  return lines.sublist(lines.length - maxLines).join('\n').trim();
}
