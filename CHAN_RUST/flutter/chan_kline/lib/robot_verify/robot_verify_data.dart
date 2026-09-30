import 'dart:io';

import 'robot_verify_paths.dart';

/// Offline 002003 tick/1m files under repo `a_Data/002003`.
bool hasOffline002003Data({String? klineRoot}) {
  final repo = RobotVerifyPaths.resolveRepoRoot(klineRoot: klineRoot);
  if (repo == null) return false;
  final dir = Directory('$repo/a_Data/002003');
  if (!dir.existsSync()) return false;
  return dir.listSync().any(
        (e) => e is File && e.path.toLowerCase().endsWith('.txt'),
      );
}
