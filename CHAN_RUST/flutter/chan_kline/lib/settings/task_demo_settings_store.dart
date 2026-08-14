import 'dart:convert';
import 'dart:io';

/// 开发演示阶段开关落盘（默认开：启动 exe 自动加载最新任务演示）。
abstract final class TaskDemoSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_task_demo_settings.json';
  }

  /// 默认 true = 处于开发演示阶段，启动自动加载最新任务演示。
  static Future<bool> isDevelopmentDemoPhaseEnabled() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return true;
      final obj = jsonDecode(await f.readAsString());
      if (obj is! Map) return true;
      final map = Map<String, dynamic>.from(obj);
      return map['developmentDemoPhase'] as bool? ?? true;
    } catch (_) {
      return true;
    }
  }

  static Future<void> setDevelopmentDemoPhaseEnabled(bool enabled) async {
    try {
      final f = File(_path);
      Map<String, dynamic> map = {};
      if (await f.exists()) {
        final obj = jsonDecode(await f.readAsString());
        if (obj is Map) map = Map<String, dynamic>.from(obj);
      }
      map['developmentDemoPhase'] = enabled;
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(map),
      );
    } catch (_) {}
  }
}
