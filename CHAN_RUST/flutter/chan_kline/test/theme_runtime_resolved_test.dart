import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/backtest/strategy_signal_painter.dart';
import 'package:chan_kline/theme/app_palette.dart';
import 'package:chan_kline/theme/theme_chooser.dart';
import 'package:chan_kline/theme/theme_settings_store.dart';
import 'package:chan_kline/widgets/chart_level_line_style.dart';
import 'package:chan_kline/widgets/fractal_confirm_paint.dart';
import 'package:chan_kline/widgets/indicator_legend.dart';
import 'package:chan_kline/widgets/kline_chip.dart';

/// 回归守卫：主题切换后取色必须实时重解析。
/// 历史上这些颜色写成了 static final / 顶层 final 缓存，只在类首次加载时按
/// 深色算一次；切到浅色/护眼后画布变亮，缓存的深色字面量就变成「亮底配暗色
/// 冲突」或「暗底配亮色」。现在全部改成运行时 getter，这里钉住该行为。
void main() {
  setUp(() => AppThemeController.instance.setMode(AppThemeMode.dark));

  test('切主题后取色实时重解析，切回深色逐像素不变', () {
    final darkBottom = FractalConfirmColors.bottom;
    final darkMacdDif = IndicatorLinePalette.macdDif;
    final darkBuy = kStrategyBuyColor;

    AppThemeController.instance.setMode(AppThemeMode.light);
    expect(FractalConfirmColors.bottom, isNot(darkBottom));
    expect(IndicatorLinePalette.macdDif, isNot(darkMacdDif));
    expect(kStrategyBuyColor, isNot(darkBuy));

    AppThemeController.instance.setMode(AppThemeMode.dark);
    expect(FractalConfirmColors.bottom, darkBottom);
    expect(IndicatorLinePalette.macdDif, darkMacdDif);
    expect(kStrategyBuyColor, darkBuy);
  });

  test('截断/节奏/零轴等派生色同样实时重解析', () {
    final darkAccent = TruncationMarkerColors.accent;
    final darkAxisRef = IndicatorLinePalette.axisRef;
    final darkWarm0 = IndicatorLinePalette.rhythmWarm.first;

    AppThemeController.instance.setMode(AppThemeMode.eyeCare);
    expect(TruncationMarkerColors.accent, isNot(darkAccent));
    expect(IndicatorLinePalette.axisRef, isNot(darkAxisRef));
    expect(IndicatorLinePalette.rhythmWarm.first, isNot(darkWarm0));
  });

  test('主图层色/买卖点/筹码峰配色同样实时重解析', () {
    final darkK0 = ChartLevelLineStyle.colorForDisplayKn(0);
    final darkCls9Buy = ChartLevelLineStyle.forBSP(9, true);
    final darkPure1 = ChipProfilePainter.peakRingColor('PURE1');

    AppThemeController.instance.setMode(AppThemeMode.light);
    expect(ChartLevelLineStyle.colorForDisplayKn(0), isNot(darkK0));
    expect(ChartLevelLineStyle.forBSP(9, true), isNot(darkCls9Buy));
    expect(ChipProfilePainter.peakRingColor('PURE1'), isNot(darkPure1));

    AppThemeController.instance.setMode(AppThemeMode.dark);
    expect(ChartLevelLineStyle.colorForDisplayKn(0), darkK0);
    expect(ChartLevelLineStyle.forBSP(9, true), darkCls9Buy);
    expect(ChipProfilePainter.peakRingColor('PURE1'), darkPure1);
  });

  test('ThemeSettings JSON 往返 + 暖色/亮度默认值 + 旧键兼容', () {
    const src = ThemeSettings(
      mode: AppThemeMode.eyeCare,
      warmth: 0.4,
      brightness: 0.7,
    );
    final json = src.toJson();
    expect(json, {'mode': 'eye', 'warmth': 0.4, 'brightness': 0.7});
    final back = ThemeSettings.fromJson(json);
    expect(back.mode, AppThemeMode.eyeCare);
    expect(back.warmth, 0.4);
    expect(back.brightness, 0.7);

    // 旧文件：仅 eyeWarmth 键 → 按旧护眼默认 1.0 读入，亮度回基准 0.5
    final legacy = ThemeSettings.fromJson(const {'mode': 'eye', 'eyeWarmth': 0.6});
    expect(legacy.warmth, 0.6);
    expect(legacy.brightness, 0.5);
    final legacyOnlyMode = ThemeSettings.fromJson(const {'mode': 'eye'});
    expect(legacyOnlyMode.warmth, 1.0);

    // 全新文件（无键）：深色默认 warmth=0、brightness=0.5（逐像素与旧版一致）
    final fresh = ThemeSettings.fromJson(const {'mode': 'dark'});
    expect(fresh.warmth, 0.0);
    expect(fresh.brightness, 0.5);

    // 越界值收敛
    final clamped = ThemeSettings.fromJson(
        const {'mode': 'eye', 'warmth': 7.0, 'brightness': -3.0});
    expect(clamped.warmth, 1.0);
    expect(clamped.brightness, 0.0);
  });

  group('暖色强度与亮度（三主题通用）', () {
    test('护眼满暖=原米黄，零暖=浅色中性，中间按 lerp 插值（旧语义兼容）', () {
      AppThemeController.instance.setMode(AppThemeMode.eyeCare);
      AppPalette.setWarmth(1.0);
      final full = AppPalette.canvasBg;
      expect(full.toARGB32(), const Color(0xFFF4EFDF).toARGB32());
      final fullRgb = AppPalette.rgb(0xFF94A3B8);

      AppPalette.setWarmth(0.0);
      final zeroRgb = AppPalette.rgb(0xFF94A3B8);
      expect(AppPalette.canvasBg, const Color(0xFFF6F7F9));
      expect(zeroRgb, isNot(fullRgb));
      // 零暖：灰字完全无暖调（色相/饱和度都归零），色字保留中性饱和
      final hsl0 = HSLColor.fromColor(AppPalette.rgb(0xFF808080));
      expect(hsl0.saturation, closeTo(0.0, 0.02));

      AppPalette.setWarmth(0.5);
      final mid = AppPalette.canvasBg;
      expect(
        mid,
        Color.lerp(const Color(0xFFF6F7F9), const Color(0xFFF4EFDF), 0.5),
      );
      AppPalette.setWarmth(1.0);
    });

    test('深色零暖零亮差=原值逐像素不变；暖色/亮度可调', () {
      // 深色 + warmth=0 + brightness=0.5：三处取色必须逐像素等于深色原字面量。
      AppThemeController.instance.setMode(AppThemeMode.dark);
      AppPalette.setWarmth(0.0);
      AppPalette.setBrightness(0.5);
      expect(AppPalette.canvasBg, const Color(0xFF121212));
      expect(AppPalette.rgb(0xFF94A3B8), const Color(0xFF94A3B8));

      // 暖色注入深色：三处应变暖（红通道 ↑ 或整体非原值）。
      AppPalette.setWarmth(1.0);
      final warmCanvas = AppPalette.canvasBg;
      expect(warmCanvas, isNot(const Color(0xFF121212)));
      final hWarm = HSLColor.fromColor(warmCanvas);
      expect(hWarm.hue, inExclusiveRange(15, 60));
      AppPalette.setWarmth(0.0);

      // 亮度提亮深色。
      AppPalette.setBrightness(0.8);
      final brightCanvas = HSLColor.fromColor(AppPalette.canvasBg);
      expect(brightCanvas.lightness, greaterThan(0.07));
      AppPalette.setBrightness(0.5);
    });

    test('浅色暖色/亮度可调', () {
      AppThemeController.instance.setMode(AppThemeMode.light);
      AppPalette.setWarmth(0.0);
      AppPalette.setBrightness(0.5);
      expect(AppPalette.canvasBg, const Color(0xFFF6F7F9));
      AppPalette.setWarmth(1.0);
      final warm = HSLColor.fromColor(AppPalette.canvasBg);
      expect(warm.hue, inExclusiveRange(15, 60));
      AppPalette.setWarmth(0.0);
      AppPalette.setBrightness(0.2);
      expect(
        HSLColor.fromColor(AppPalette.canvasBg).lightness,
        lessThan(0.9),
      );
      AppPalette.setBrightness(0.5);
    });

    test('setWarmth/setBrightness 收敛到 0~1', () {
      AppPalette.setWarmth(4.0);
      expect(AppPalette.warmth, 1.0);
      AppPalette.setWarmth(-2.0);
      expect(AppPalette.warmth, 0.0);
      AppPalette.setBrightness(2.0);
      expect(AppPalette.brightness, 1.0);
      AppPalette.setBrightness(-1.0);
      expect(AppPalette.brightness, 0.0);
      AppPalette.setWarmth(1.0);
      AppPalette.setBrightness(0.5);
    });
  });

  group('控件墨水色 controlInk', () {
    test('深色保持浅墨，浅色/护眼统一近黑', () {
      for (final m in AppThemeMode.values) {
        AppThemeController.instance.setMode(m);
        if (m == AppThemeMode.dark) {
          expect(AppPalette.controlInk, const Color(0xFFE2E8F0));
        } else {
          expect(AppPalette.controlInk, const Color(0xFF111111));
        }
      }
    });
  });

  group('ThemeChooser 暖色/亮度滑杆（三主题通用）', () {
    testWidgets('三主题均显示暖色+亮度滑杆，对勾定位在选中项上，切走切回保留',
        (tester) async {
      for (final m in AppThemeMode.values) {
        AppThemeController.instance.setMode(m);
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: ThemeChooser())),
        );
        expect(find.byKey(const ValueKey('theme_warmth')), findsOneWidget);
        expect(find.byKey(const ValueKey('theme_brightness')), findsOneWidget);
        // 对勾（选中 chip）始终定位在选中项上
        expect(find.byKey(ValueKey('theme_chip_${m.id}')), findsOneWidget);
      }
      // 切走再切回：滑杆按保存值恢复
      AppThemeController.instance.setMode(AppThemeMode.light);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ThemeChooser())),
      );
      AppThemeController.instance.setMode(AppThemeMode.eyeCare);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ThemeChooser())),
      );
      expect(
        tester.widget<Slider>(find.byKey(const ValueKey('theme_warmth'))).value,
        1.0,
      );
      AppThemeController.instance.setMode(AppThemeMode.dark);
    });
  });
}
