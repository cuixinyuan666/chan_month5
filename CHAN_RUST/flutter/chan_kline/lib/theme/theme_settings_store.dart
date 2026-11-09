import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_palette.dart';

/// 主题偏好（落盘 `.chan_theme_settings.json`，只存一个主题名，重启保留）。
class ThemeSettings {
  const ThemeSettings({this.mode = AppThemeMode.dark});

  final AppThemeMode mode;

  ThemeSettings copyWith({AppThemeMode? mode}) =>
      ThemeSettings(mode: mode ?? this.mode);

  factory ThemeSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ThemeSettings();
    return ThemeSettings(mode: AppThemeMode.parse(json['mode'] as String?));
  }

  Map<String, dynamic> toJson() => {'mode': mode.id};
}

abstract final class ThemeSettingsStore {
  static String get path {
    final base = Directory.current.path;
    return '$base${Platform.pathSeparator}.chan_theme_settings.json';
  }

  /// 同步读：App 启动时要在第一帧就把对的配色摆上，不为此引入异步等待。
  static ThemeSettings loadSync() {
    try {
      final f = File(path);
      if (!f.existsSync()) return const ThemeSettings();
      final obj = jsonDecode(f.readAsStringSync());
      if (obj is Map) {
        return ThemeSettings.fromJson(Map<String, dynamic>.from(obj));
      }
    } catch (_) {}
    return const ThemeSettings();
  }

  static Future<void> save(ThemeSettings cfg) async {
    try {
      await File(path).writeAsString(
        const JsonEncoder.withIndent('  ').convert(cfg.toJson()),
      );
    } catch (_) {}
  }
}

/// 主题总线：设置里选完立刻生效（重建整棵树），同时写盘供下次启动。
class AppThemeController extends ChangeNotifier {
  AppThemeController._();

  static final AppThemeController instance = AppThemeController._();

  ThemeSettings _cfg = const ThemeSettings();

  ThemeSettings get settings => _cfg;

  AppThemeMode get mode => _cfg.mode;

  /// 启动时调用：读盘 → 刷到调色板，但不通知（首帧还没人监听）。
  void loadFromDisk() {
    _cfg = ThemeSettingsStore.loadSync();
    AppPalette.setMode(_cfg.mode);
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (_cfg.mode == mode) return;
    _cfg = _cfg.copyWith(mode: mode);
    AppPalette.setMode(mode);
    notifyListeners();
    await ThemeSettingsStore.save(_cfg);
  }
}
