import 'dart:io';

import '../models/kline_bar.dart';
import 'task_demo_manifest.dart';

/// 从 a_Data/test/demos 扫描任务演示
class TaskDemoLoader {
  static String demosRoot(String dataRoot) {
    return '$dataRoot${Platform.pathSeparator}test'
        '${Platform.pathSeparator}demos';
  }

  /// 列出所有有效 manifest（按 id 排序，跳过 _template）
  static Future<List<TaskDemoManifest>> listDemos(String dataRoot) async {
    final root = Directory(demosRoot(dataRoot));
    if (!await root.exists()) return const [];
    final out = <TaskDemoManifest>[];
    await for (final entity in root.list(followLinks: false)) {
      if (entity is! Directory) continue;
      final name = entity.path.split(Platform.pathSeparator).last;
      if (name.startsWith('_') || name.startsWith('.')) continue;
      final manifestFile = File(
        '${entity.path}${Platform.pathSeparator}manifest.json',
      );
      if (!await manifestFile.exists()) continue;
      final text = await manifestFile.readAsString();
      final m = TaskDemoManifest.tryParseFile(entity.path, text);
      if (m != null) out.add(m);
    }
    out.sort((a, b) => a.id.compareTo(b.id));
    return out;
  }

  /// 最新完成任务（completedAt 降序；同日期按 id 降序）
  static Future<TaskDemoManifest?> latestDemo(
    String dataRoot, {
    bool onlyAutoLaunch = true,
  }) async {
    final list = await listDemos(dataRoot);
    if (list.isEmpty) return null;
    final filtered = onlyAutoLaunch
        ? list.where((m) => m.autoLaunchOnStartup).toList()
        : list;
    if (filtered.isEmpty) return null;
    filtered.sort((a, b) {
      final c = b.completedAt.compareTo(a.completedAt);
      if (c != 0) return c;
      return b.id.compareTo(a.id);
    });
    return filtered.first;
  }

  static Future<List<KlineBar>> parseDemoCsv(String path) async {
    final lines = await File(path).readAsLines();
    final parsed = <KlineBar>[];
    var idx = 0;
    var timeMs = DateTime(2026, 1, 1).millisecondsSinceEpoch;
    for (var i = 0; i < lines.length; i++) {
      final line = lines[i].trim();
      if (line.isEmpty) continue;
      if (i == 0 && line.toLowerCase().startsWith('time')) continue;
      final parts = line.split(',');
      if (parts.length < 5) continue;
      final vol = parts.length > 5 ? double.tryParse(parts[5]) ?? 0 : 0.0;
      parsed.add(
        KlineBar(
          idx: idx,
          timeMs: timeMs,
          timeText: parts[0].trim(),
          open: double.parse(parts[1]),
          high: double.parse(parts[2]),
          low: double.parse(parts[3]),
          close: double.parse(parts[4]),
          volume: vol,
          amount: 0,
        ),
      );
      idx++;
      timeMs += 60000;
    }
    return parsed;
  }

  static Future<String?> readTextIfExists(String path) async {
    final f = File(path);
    if (!await f.exists()) return null;
    return f.readAsString();
  }

  static Future<bool> hasImage(String demoDirPath, String name) async {
    return File('$demoDirPath${Platform.pathSeparator}$name').exists();
  }

  static String imagePath(String demoDirPath, String name) {
    return '$demoDirPath${Platform.pathSeparator}$name';
  }

  static String? demoCsvPath(TaskDemoManifest m) {
    final csv = m.demoCsv.trim();
    if (csv.isEmpty) return null;
    return '${m.demoDirPath}${Platform.pathSeparator}$csv';
  }
}
