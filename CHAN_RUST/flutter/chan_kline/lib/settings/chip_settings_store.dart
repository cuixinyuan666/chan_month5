import 'dart:convert';
import 'dart:io';

import '../models/chip_config.dart';

/// 筹码配置本地持久化（JSON 文件；与其它进程内开关不同，按计划可落盘）。
abstract final class ChipSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_chip_config.json';
  }

  static Future<ChipConfig> load() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return const ChipConfig();
      final text = await f.readAsString();
      final obj = jsonDecode(text);
      if (obj is Map<String, dynamic>) {
        return ChipConfig.fromJson(obj);
      }
      if (obj is Map) {
        return ChipConfig.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {
      // 损坏/无权限 → 默认
    }
    return const ChipConfig();
  }

  static Future<void> save(ChipConfig cfg) async {
    try {
      final f = File(_path);
      await f.writeAsString(const JsonEncoder.withIndent('  ').convert(cfg.toJson()));
    } catch (_) {
      // 写失败静默（桌面权限）；进程内仍生效
    }
  }
}
