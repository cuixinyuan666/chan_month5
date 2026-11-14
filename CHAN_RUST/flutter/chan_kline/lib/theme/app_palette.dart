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
  /// 暖色强度 0~1：0=纯中性，1=满暖调。三模式通用；深色默认 0（与旧版逐像素一致）。
  static double _warmth = 0.0;
  /// 亮度 0~1：0.5=各主题基准明度（与旧版一致），<0.5 压暗，>0.5 提亮。三模式通用。
  static double _brightness = 0.5;

  static AppThemeMode get mode => _mode;

  static void setMode(AppThemeMode m) {
    _mode = m;
  }

  static bool get isDark => _mode == AppThemeMode.dark;

  /// 暖色强度 0~1（三模式通用）。
  static double get warmth => _warmth;

  static void setWarmth(double v) {
    _warmth = v.clamp(0.0, 1.0);
  }

  /// 兼容旧名：护眼暖色强度。等价于 [warmth]。
  static double get eyeWarmth => _warmth;

  static void setEyeWarmth(double v) => setWarmth(v);

  /// 亮度 0~1（三模式通用）；0.5 为基准。
  static double get brightness => _brightness;

  static void setBrightness(double v) {
    _brightness = v.clamp(0.0, 1.0);
  }

  /// 窗控 / 伸缩延展类控件墨水色：深色保持浅墨，浅色与护眼统一近黑。
  static Color get controlInk => switch (_mode) {
        AppThemeMode.dark => const Color(0xFFE2E8F0),
        AppThemeMode.light => const Color(0xFF111111),
        AppThemeMode.eyeCare => const Color(0xFF111111),
      };

  /// 三模式命名单色。
  ///
  /// 暖色强度 [warmth] 与亮度 [brightness] 三模式通用：
  /// - dark/light：warmth=0 时为原主题中性色（深色默认 0，保证切回深色逐像素不变）；
  ///   warmth>0 时向「暖色版」插值（扩大可感区间：满暖把中性灰推向暖橙黄）。
  /// - eyeCare：warmth=1 时为满暖米黄（旧默认），warmth=0 退回浅色中性。
  /// - brightness：0.5 为基准（输出不变），<0.5 压暗、>0.5 提亮，对三模式统一生效。
  static Color _t(Color dark, Color light, Color eye) {
    final Color base;
    final Color warm;
    switch (_mode) {
      case AppThemeMode.dark:
        base = dark;
        // 暗底满暖：把中性暗色推向暖橙调（明度略升、色相偏暖），区间显著大于旧版。
        warm = _warmVariant(dark, strength: 0.55);
      case AppThemeMode.light:
        base = light;
        warm = _warmVariant(light, strength: 0.6);
      case AppThemeMode.eyeCare:
        base = light;
        warm = eye;
    }
    final c = Color.lerp(base, warm, _warmth) ?? base;
    return _applyBrightness(c);
  }

  /// 由一个中性色派生暖色版：固定暖色相（38°、适中的暖饱和），明度与源色一致，
  /// 再按 [strength] 从源色插值过去。这样近白→米白/暖白，暗色→暖黑，不会洗白或跑绿。
  /// [strength] 控制暖化幅度（0~1），越大越暖。
  static Color _warmVariant(Color src, {required double strength}) {
    final hsl = HSLColor.fromColor(src);
    final anchor = HSLColor.fromAHSL(
      hsl.alpha,
      38.0, // 暖橙黄色相
      0.42, // 暖色饱和（近白/近黑都会被拉出明显暖调）
      hsl.lightness, // 保持明度，避免亮度被暖色顺带改掉
    ).toColor();
    return Color.lerp(src, anchor, strength) ?? src;
  }

  /// 亮度调节：0.5 基准不变；滑块 0~1 线性映射到明度倍率 0.6~1.4。
  static Color _applyBrightness(Color c) {
    if ((_brightness - 0.5).abs() < 0.005) return c;
    final scale = 0.6 + _brightness * 0.8; // 0.6 ... 1.4
    final hsl = HSLColor.fromColor(c);
    return hsl
        .withLightness((hsl.lightness * scale).clamp(0.0, 1.0))
        .toColor();
  }

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
  ///
  /// 暖色强度 [warmth] 与亮度 [brightness] 三模式通用：
  /// - 深色 warmth=0（默认）时原样返回 dark（切回深色逐像素不变）；warmth>0 注入暖色。
  /// - 浅色/护眼：中性灰反相后按 warmth 注入暖橙；彩色保留色相按 warmth 微调。
  /// - brightness 偏离 0.5 时统一拉伸明度。
  static Color c(Color dark) {
    final hsl = HSLColor.fromColor(dark);
    final l = hsl.lightness;
    final s = hsl.saturation;
    final bool achromatic = s < 0.12;

    // 深色：默认（warmth=0）原样返回；warmth>0 时向暖色版插值。
    if (_mode == AppThemeMode.dark) {
      if (_warmth <= 0.0) return _applyBrightness(dark);
      final warm = _warmVariant(dark, strength: 0.55);
      return _applyBrightness(Color.lerp(dark, warm, _warmth) ?? dark);
    }

    double l2;
    double s2 = s;
    double h2 = hsl.hue;
    if (achromatic) {
      l2 = (1.0 - l).clamp(0.06, 0.96);
      // 浅色/护眼：按 warmth 注入暖橙（旧版仅护眼注入，现三模式一致；深色在上面单独处理）。
      h2 = 42.0 * _warmth;
      s2 = 0.10 * _warmth;
    } else if (_mode == AppThemeMode.light) {
      l2 = l.clamp(0.28, 0.52);
      // 浅色也按 warmth 微暖（旧版无此，现三模式一致）。
      s2 = (s * (1.0 - 0.12 * _warmth)).clamp(0.0, 1.0);
      h2 = h2 - 2.0 * _warmth < 0 ? 358.0 : h2;
    } else {
      // eyeCare
      l2 = l.clamp(0.30, 0.55);
      s2 = (s * (1.0 - 0.12 * _warmth)).clamp(0.0, 1.0);
      h2 = h2 - 2.0 * _warmth < 0 ? 358.0 : h2;
    }
    final out = hsl
        .withLightness(l2)
        .withSaturation(s2)
        .withHue(h2)
        .toColor();
    return _applyBrightness(out);
  }
}
