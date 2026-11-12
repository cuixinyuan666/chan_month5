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

  test('ThemeSettings JSON 往返 + 护眼暖色强度默认值', () {
    const src = ThemeSettings(mode: AppThemeMode.eyeCare, eyeWarmth: 0.4);
    final json = src.toJson();
    expect(json, {'mode': 'eye', 'eyeWarmth': 0.4});
    final back = ThemeSettings.fromJson(json);
    expect(back.mode, AppThemeMode.eyeCare);
    expect(back.eyeWarmth, 0.4);
    // 旧文件只有 mode 键时默认满暖
    final legacy = ThemeSettings.fromJson(const {'mode': 'eye'});
    expect(legacy.eyeWarmth, 1.0);
    // 越界值收敛
    final clamped = ThemeSettings.fromJson(const {'mode': 'eye', 'eyeWarmth': 7.0});
    expect(clamped.eyeWarmth, 1.0);
  });

  group('护眼暖色强度', () {
    test('满暖=原米黄，零暖=浅色反色，中间按 lerp 插值', () {
      AppThemeController.instance.setMode(AppThemeMode.eyeCare);
      AppPalette.setEyeWarmth(1.0);
      final full = AppPalette.canvasBg;
      expect(full.toARGB32(), const Color(0xFFF4EFDF).toARGB32());
      final fullRgb = AppPalette.rgb(0xFF94A3B8);

      AppPalette.setEyeWarmth(0.0);
      final zeroRgb = AppPalette.rgb(0xFF94A3B8);
      expect(AppPalette.canvasBg, const Color(0xFFF6F7F9));
      expect(zeroRgb, isNot(fullRgb));
      // 零暖：灰字完全无暖调（色相/饱和度都归零），色字保留中性饱和
      final hsl0 = HSLColor.fromColor(AppPalette.rgb(0xFF808080));
      expect(hsl0.saturation, closeTo(0.0, 0.02));

      AppPalette.setEyeWarmth(0.5);
      final mid = AppPalette.canvasBg;
      expect(
        mid,
        Color.lerp(const Color(0xFFF6F7F9), const Color(0xFFF4EFDF), 0.5),
      );
      AppPalette.setEyeWarmth(1.0);
    });

    test('setEyeWarmth 收敛到 0~1', () {
      AppPalette.setEyeWarmth(4.0);
      expect(AppPalette.eyeWarmth, 1.0);
      AppPalette.setEyeWarmth(-2.0);
      expect(AppPalette.eyeWarmth, 0.0);
      AppPalette.setEyeWarmth(1.0);
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

  group('ThemeChooser 护眼暖色强度滑杆', () {
    testWidgets('仅护眼模式显示滑杆，对勾定位在选中项上，切走切回保留强度',
        (tester) async {
      for (final m in AppThemeMode.values) {
        AppThemeController.instance.setMode(m);
        await tester.pumpWidget(
          const MaterialApp(home: Scaffold(body: ThemeChooser())),
        );
        final warmthKey = const ValueKey('theme_eye_warmth');
        if (m == AppThemeMode.eyeCare) {
          expect(find.byKey(warmthKey), findsOneWidget);
        } else {
          expect(find.byKey(warmthKey), findsNothing);
        }
        // 对勾（选中 chip）始终定位在选中项上
        expect(find.byKey(ValueKey('theme_chip_${m.id}')), findsOneWidget);
      }
      // 切走再切回护眼：滑杆按保存值（默认 1.0）恢复
      AppThemeController.instance.setMode(AppThemeMode.light);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ThemeChooser())),
      );
      AppThemeController.instance.setMode(AppThemeMode.eyeCare);
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: ThemeChooser())),
      );
      expect(
        tester.widget<Slider>(find.byKey(const ValueKey('theme_eye_warmth')))
            .value,
        1.0,
      );
      AppThemeController.instance.setMode(AppThemeMode.dark);
    });
  });
}
