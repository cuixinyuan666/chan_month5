import 'dart:convert';
import 'dart:io';

/// 机器人验证落盘路径（供 App 写报告、智能体读报告收尾）。
class RobotVerifyPaths {
  RobotVerifyPaths._();

  static String? resolveRepoRoot({String? klineRoot}) {
    final fromEnv = Platform.environment['CHAN_REPO_ROOT'];
    if (fromEnv != null && fromEnv.isNotEmpty) {
      return fromEnv;
    }
    final kr = klineRoot ?? Platform.environment['CHAN_KLINE_ROOT'] ?? '';
    if (kr.isNotEmpty) {
      final kline = Directory(kr);
      if (kline.existsSync()) {
        return kline.parent.parent.parent.path;
      }
    }
    final cwd = Directory.current.path.replaceAll('\\', '/');
    if (cwd.endsWith('chan_kline') || cwd.contains('/chan_kline')) {
      final kline = Directory(Directory.current.path);
      if (kline.existsSync()) {
        return kline.parent.parent.parent.path;
      }
    }
    return null;
  }

  static Directory? verifyDir({String? klineRoot}) {
    final repo = resolveRepoRoot(klineRoot: klineRoot);
    if (repo == null) return null;
    final dir = Directory('$repo/a_Data/robot_verify');
    if (!dir.existsSync()) {
      dir.createSync(recursive: true);
    }
    return dir;
  }

  static File? lastReportFile({String? klineRoot}) {
    final dir = verifyDir(klineRoot: klineRoot);
    if (dir == null) return null;
    return File('${dir.path}/last_report.txt');
  }

  static File? lastReportJsonFile({String? klineRoot}) {
    final dir = verifyDir(klineRoot: klineRoot);
    if (dir == null) return null;
    return File('${dir.path}/last_report.json');
  }

  static File? statusFile({String? klineRoot}) {
    final dir = verifyDir(klineRoot: klineRoot);
    if (dir == null) return null;
    return File('${dir.path}/status.json');
  }

  static Future<void> writeStatus({
    required String phase,
    required bool? ok,
    String? message,
    String? klineRoot,
  }) async {
    final f = statusFile(klineRoot: klineRoot);
    if (f == null) return;
    await f.writeAsString(
      jsonEncode({
        'phase': phase,
        'ok': ok,
        'message': message,
        'updatedAt': DateTime.now().toIso8601String(),
      }),
    );
  }

  /// 会话 active 时，用户手动打开 App 也可进入机器人验证（见 agent.md）。
  static bool sessionAuthorized({String? klineRoot}) {
    final dir = verifyDir(klineRoot: klineRoot);
    if (dir == null) return false;
    final f = File('${dir.path}/session.json');
    if (!f.existsSync()) return false;
    try {
      final m = jsonDecode(f.readAsStringSync()) as Map<String, dynamic>;
      return m['active'] == true;
    } catch (_) {
      return false;
    }
  }
}
