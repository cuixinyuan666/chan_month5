import 'dart:convert';
import 'dart:io';

import '../models/math_indicator_config.dart';

/// 数学指标参数落盘（兼容旧 `.chan_trend_model_config.json`）。
abstract final class MathIndicatorSettingsStore {
  static String get _path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_trend_model_config.json';
  }

  static Future<MathIndicatorConfig> load() async {
    try {
      final f = File(_path);
      if (!await f.exists()) return const MathIndicatorConfig();
      final obj = jsonDecode(await f.readAsString());
      final map = obj is Map<String, dynamic>
          ? obj
          : (obj is Map ? Map<String, dynamic>.from(obj) : null);
      var cfg = MathIndicatorConfig.fromJson(map);
      // 旧默认 1e9=保送 → 迁移为 1.0（等力度阈值）
      if (cfg.divergenceRate > 100) {
        cfg = cfg.copyWith(divergenceRate: 1.0);
        await save(cfg);
      }
      return cfg;
    } catch (_) {
      return const MathIndicatorConfig();
    }
  }

  static Future<void> save(MathIndicatorConfig cfg) async {
    try {
      final f = File(_path);
      await f.writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {}
  }
}
