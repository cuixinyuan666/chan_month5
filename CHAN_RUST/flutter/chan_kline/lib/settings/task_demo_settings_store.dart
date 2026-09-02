import 'dart:convert';
import 'dart:io';

/// 开发演示阶段开关落盘（对外默认关：启动不自动加载任务演示）。
abstract final class TaskDemoSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_task_demo_settings.json';
  }

  /// 默认 false = 对外包不自动弹演示；研究/开发可在设置里打开。
  static Future<bool> isDevelopmentDemoPhaseEnabled() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return false;
      final obj = jsonDecode(await f.readAsString());
      if (obj is! Map) return false;
      final map = Map<String, dynamic>.from(obj);
      return map['developmentDemoPhase'] as bool? ?? false;
    } catch (_) {
      return false;
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
