import 'package:flutter/material.dart';

/// 三套主题。深色是改造前的现网配色，所以切回深色必须与旧版逐像素一致。
enum AppThemeMode {
  dark('深色'),
  light('浅色'),
  eyeCare('护眼');

  const AppThemeMode(this.label);

  final String label;

  String get id => switch (this) {
        AppThemeMode.dark => 'dark',
        AppThemeMode.light => 'light',
        AppThemeMode.eyeCare => 'eye',
      };

  static AppThemeMode parse(String? raw) {
    switch ((raw ?? '').trim().toLowerCase()) {
      case 'light':
        return AppThemeMode.light;
      case 'eye':
      case 'eyecare':
      case 'eye-care':
        return AppThemeMode.eyeCare;
      default:
        return AppThemeMode.dark;
    }
  }
}

/// 全局调色板。
///
/// 目的：把散落在各文件里写死的深色字面量收成一层，切主题时统一换算，
/// 而不是只换外壳、让 K 线画布继续黑着。
///
/// 用法：
/// * 新代码优先用具名 token（`AppPalette.canvasBg` 等），语义清楚；
/// * 存量长尾字面量用 `AppPalette.rgb(0xFF94A3B8)` 包一层即可，
///   它按「这个深色值在深色主题里演什么角色」自动折算到当前主题：
///   暗底变亮底、亮字变暗字、彩色保留色相只调明度，透明度原样保留。
///
/// 深色模式下 `rgb()` 原样返回传入值，保证老界面零变化。
abstract final class AppPalette {
  static AppThemeMode _mode = AppThemeMode.dark;

  static AppThemeMode get mode => _mode;

  static void setMode(AppThemeMode m) {
    _mode = m;
  }

  static bool get isDark => _mode == AppThemeMode.dark;

  static Color _t(Color dark, Color light, Color eye) => switch (_mode) {
        AppThemeMode.dark => dark,
        AppThemeMode.light => light,
        AppThemeMode.eyeCare => eye,
      };

  // ---------------- 具名 token ----------------

  /// 画布底（K 线区、页面底）。
  static Color get canvasBg =>
      _t(const Color(0xFF121212), const Color(0xFFF6F7F9), const Color(0xFFF4EFDF));

  /// 面板 / 卡片底。
  static Color get surface =>
      _t(const Color(0xFF1E1E1E), const Color(0xFFFFFFFF), const Color(0xFFFBF6EA));

  /// 面板上的次级底（分组、输入框）。
  static Color get surfaceAlt =>
      _t(const Color(0xFF1E293B), const Color(0xFFEDF1F5), const Color(0xFFF0E9D8));

  /// 分隔线 / 描边。
  static Color get border =>
      _t(const Color(0x33FFFFFF), const Color(0xFFD8DEE6), const Color(0xFFD9CFB8));

  /// 主文字。
  static Color get textPrimary =>
      _t(const Color(0xFFE2E8F0), const Color(0xFF1B2430), const Color(0xFF2E2A22));

  /// 次文字（说明、副标题）。
  static Color get textSecondary =>
      _t(const Color(0xFF94A3B8), const Color(0xFF5B6875), const Color(0xFF6B6252));

  /// 弱文字（辅助提示）。
  static Color get textMuted =>
      _t(const Color(0xFFCBD5E1), const Color(0xFF7A8794), const Color(0xFF8A8172));

  /// 强调色（按钮、选中态）。
  static Color get accent =>
      _t(const Color(0xFF2563EB), const Color(0xFF1D4ED8), const Color(0xFF2F5D8A));

  /// 涨 / 跌 / 警示。缠论图上的红绿也走这三个，不各自写死。
  static Color get up =>
      _t(const Color(0xFFE53935), const Color(0xFFD32F2F), const Color(0xFFB3261E));

  static Color get down =>
      _t(const Color(0xFF26A69A), const Color(0xFF00796B), const Color(0xFF1F6F66));

  static Color get warn =>
      _t(const Color(0xFFF59E0B), const Color(0xFFB45309), const Color(0xFF9A6300));

  /// 网格 / 刻度线。
  static Color get grid =>
      _t(const Color(0x33FFFFFF), const Color(0x33607080), const Color(0x336B6252));

  /// 悬浮层底（tooltip、弹层）。
  static Color get overlayBg =>
      _t(const Color(0xE61A1A1A), const Color(0xF2FFFFFF), const Color(0xF5FBF6EA));

  /// 遮罩（点击关闭浮层）。
  static Color get scrim =>
      _t(const Color(0x66000000), const Color(0x33000000), const Color(0x33000000));

  // ---------------- 长尾字面量换算 ----------------

  /// 把一个「深色主题下的写死色」折算到当前主题。
  static Color rgb(int argb) => c(Color(argb));

  /// 同上，入参是 Color。
  static Color c(Color dark) {
    if (_mode == AppThemeMode.dark) return dark;
    final hsl = HSLColor.fromColor(dark);
    final l = hsl.lightness;
    final s = hsl.saturation;
    // 彩色（红绿蓝等）保留色相，只把明度压到浅底上也看得清的范围；
    // 中性灰则整体反过来（暗底↔亮底、亮字↔暗字），透明度一律不动。
    final bool achromatic = s < 0.12;
    double l2;
    double s2 = s;
    double h2 = hsl.hue;
    if (achromatic) {
      l2 = (1.0 - l).clamp(0.06, 0.96);
      if (_mode == AppThemeMode.eyeCare) {
        h2 = 42.0;
        s2 = 0.10;
      }
    } else if (_mode == AppThemeMode.light) {
      l2 = l.clamp(0.28, 0.52);
    } else {
      l2 = l.clamp(0.30, 0.55);
      s2 = (s * 0.88).clamp(0.0, 1.0);
      h2 = h2 - 2.0 < 0 ? 358.0 : h2;
    }
    return hsl
        .withLightness(l2)
        .withSaturation(s2)
        .withHue(h2)
        .toColor();
  }
}
