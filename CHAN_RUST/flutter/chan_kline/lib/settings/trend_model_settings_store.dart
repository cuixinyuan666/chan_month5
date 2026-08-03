import 'dart:convert';
import 'dart:io';

import '../models/trend_model_config.dart';

/// 均线/通道周期本地持久化。
abstract final class TrendModelSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_trend_model_config.json';
  }

  static Future<TrendModelConfig> load() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return const TrendModelConfig();
      final obj = jsonDecode(await f.readAsString());
      final map = obj is Map<String, dynamic>
          ? obj
          : (obj is Map ? Map<String, dynamic>.from(obj) : null);
      return TrendModelConfig.fromJson(map);
    } catch (_) {
      return const TrendModelConfig();
    }
  }

  static Future<void> save(TrendModelConfig cfg) async {
    try {
      final f = File(_path);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {
      // 写失败静默
    }
  }
}
