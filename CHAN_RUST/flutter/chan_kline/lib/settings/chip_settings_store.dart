import 'dart:convert';
import 'dart:io';

import '../models/chip_config.dart';
import '../models/tick_dist_config.dart';

/// 筹码/笔数分布配置本地持久化（同 JSON；笔数分布嵌套 tickDist）。
abstract final class ChipSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_chip_config.json';
  }

  static Future<(ChipConfig, TickDistConfig)> loadBoth() async {
    try {
      final f = File(_path);
      if (!await f.exists()) {
        return (const ChipConfig(), const TickDistConfig());
      }
      final text = await f.readAsString();
      final obj = jsonDecode(text);
      final map = obj is Map<String, dynamic>
          ? obj
          : (obj is Map ? Map<String, dynamic>.from(obj) : null);
      if (map == null) {
        return (const ChipConfig(), const TickDistConfig());
      }
      final tickRaw = map['tickDist'];
      final tickMap = tickRaw is Map
          ? Map<String, dynamic>.from(tickRaw)
          : null;
      return (ChipConfig.fromJson(map), TickDistConfig.fromJson(tickMap));
    } catch (_) {
      // 损坏/无权限 → 默认
    }
    return (const ChipConfig(), const TickDistConfig());
  }

  static Future<ChipConfig> load() async {
    final both = await loadBoth();
    return both.$1;
  }

  static Future<void> save(ChipConfig cfg, {TickDistConfig? tickDist}) async {
    try {
      final f = File(_path);
      final map = Map<String, dynamic>.from(cfg.toJson());
      if (tickDist != null) {
        map['tickDist'] = tickDist.toJson();
      } else if (await f.exists()) {
        try {
          final old = jsonDecode(await f.readAsString());
          if (old is Map && old['tickDist'] != null) {
            map['tickDist'] = old['tickDist'];
          }
        } catch (_) {}
      }
      await f.writeAsString(
          const JsonEncoder.withIndent('  ').convert(map));
    } catch (_) {
      // 写失败静默（桌面权限）；进程内仍生效
    }
  }
}
