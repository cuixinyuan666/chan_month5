import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'app_palette.dart';

/// 主题偏好（落盘 `.chan_theme_settings.json`，重启保留）。
///
/// 默认值保证深色逐像素与旧版一致：warmth=0（深色不注入暖色）、brightness=0.5（基准明度）。
/// 三模式均开放 warmth 与 brightness 调节。
class ThemeSettings {
  const ThemeSettings({
    this.mode = AppThemeMode.dark,
    this.warmth = 0.0,
    this.brightness = 0.5,
  });

  final AppThemeMode mode;

  /// 暖色强度 0~1（三模式通用；0=纯中性，1=满暖调）。
  /// 深色默认 0（与旧版逐像素一致）；护眼切到时由 [AppThemeController] 默认拉到 1。
  final double warmth;

  /// 亮度 0~1（三模式通用；0.5=基准不变，<0.5 压暗，>0.5 提亮）。
  final double brightness;

  /// 兼容旧名：护眼暖色强度，等价于 [warmth]。
  double get eyeWarmth => warmth;

  ThemeSettings copyWith({AppThemeMode? mode, double? warmth, double? brightness}) =>
      ThemeSettings(
        mode: mode ?? this.mode,
        warmth: warmth ?? this.warmth,
        brightness: brightness ?? this.brightness,
      );

  factory ThemeSettings.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ThemeSettings();
    final mode = AppThemeMode.parse(json['mode'] as String?);
    double parseWarmth() {
      // 新键 warmth 优先；旧键 eyeWarmth 兼容。
      final raw = json['warmth'] ?? json['eyeWarmth'];
      if (raw is num) return raw.toDouble().clamp(0.0, 1.0);
      // 无任何暖色键：按主题旧默认（护眼=满暖 1.0；深色/浅色=0，逐像素与原版一致）。
      return mode == AppThemeMode.eyeCare ? 1.0 : 0.0;
    }
    final rawBright = json['brightness'];
    final brightness =
        rawBright is num ? rawBright.toDouble().clamp(0.0, 1.0) : 0.5;
    return ThemeSettings(
      mode: mode,
      warmth: parseWarmth(),
      brightness: brightness,
    );
  }

  Map<String, dynamic> toJson() =>
      {'mode': mode.id, 'warmth': warmth, 'brightness': brightness};
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

  /// 暖色强度 0~1（三模式通用）。
  double get warmth => _cfg.warmth;

  /// 兼容旧名。
  double get eyeWarmth => _cfg.warmth;

  /// 亮度 0~1（三模式通用；0.5 基准）。
  double get brightness => _cfg.brightness;

  /// 启动时调用：读盘 → 刷到调色板，但不通知（首帧还没人监听）。
  void loadFromDisk() {
    _cfg = ThemeSettingsStore.loadSync();
    AppPalette.setMode(_cfg.mode);
    AppPalette.setWarmth(_cfg.warmth);
    AppPalette.setBrightness(_cfg.brightness);
  }

  Future<void> setMode(AppThemeMode mode) async {
    if (_cfg.mode == mode) return;
    // 未手动调过暖色时按主题给默认：护眼=满暖(1.0，旧版米黄)，深色/浅色=0（旧版原色）。
    // 用户一旦拖动过暖色滑杆，则其值全局沿用（对三主题都生效）。
    final warmth = _warmthTouched
        ? _cfg.warmth
        : (mode == AppThemeMode.eyeCare ? 1.0 : 0.0);
    _cfg = _cfg.copyWith(mode: mode, warmth: warmth);
    AppPalette.setMode(mode);
    AppPalette.setWarmth(warmth);
    AppPalette.setBrightness(_cfg.brightness);
    notifyListeners();
    await ThemeSettingsStore.save(_cfg);
  }

  bool _warmthTouched = false;

  /// 暖色强度（0~1，三模式通用）：即时生效并落盘。
  Future<void> setWarmth(double v) async {
    final warmth = v.clamp(0.0, 1.0);
    if ((_cfg.warmth - warmth).abs() < 0.005) return;
    _warmthTouched = true;
    _cfg = _cfg.copyWith(warmth: warmth);
    AppPalette.setWarmth(warmth);
    notifyListeners();
    await ThemeSettingsStore.save(_cfg);
  }

  /// 兼容旧名。
  Future<void> setEyeWarmth(double v) => setWarmth(v);

  /// 亮度（0~1，三模式通用；0.5 基准）：即时生效并落盘。
  Future<void> setBrightness(double v) async {
    final brightness = v.clamp(0.0, 1.0);
    if ((_cfg.brightness - brightness).abs() < 0.005) return;
    _cfg = _cfg.copyWith(brightness: brightness);
    AppPalette.setBrightness(brightness);
    notifyListeners();
    await ThemeSettingsStore.save(_cfg);
  }
}
