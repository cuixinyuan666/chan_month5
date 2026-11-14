import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/theme/app_palette.dart';
import 'package:chan_kline/theme/theme_chooser.dart';
import 'package:chan_kline/theme/theme_settings_store.dart';

Future<void> _selectTheme(WidgetTester tester, AppThemeMode mode) async {
  await tester.tap(find.byType(DropdownButtonFormField<AppThemeMode>));
  await tester.pumpAndSettle();
  final overlayLabel = find.descendant(
    of: find.byType(Overlay),
    matching: find.byKey(ValueKey<String>('theme_chip_${mode.id}')),
  );
  await tester.ensureVisible(overlayLabel);
  await tester.tap(overlayLabel);
  await tester.pumpAndSettle();
}

/// 主题三选一的验收口径：
/// 1. 点一下芯片，调色板真的换（不是只有外壳换），K 线画布底色跟着走；
/// 2. 深色保持旧版原色，逐像素不变；
/// 3. 选完写盘，重启读回来还是同一个主题。
void main() {
  setUp(() => AppThemeController.instance.setMode(AppThemeMode.dark));

  testWidgets('点浅色：调色板立刻转浅色，画布不再是黑底', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ThemeChooser())),
    );

    expect(AppPalette.isDark, isTrue);
    await _selectTheme(tester, AppThemeMode.light);

    expect(AppPalette.isDark, isFalse);
    expect(AppThemeController.instance.mode, AppThemeMode.light);
    expect(AppPalette.canvasBg, const Color(0xFFF6F7F9));
    // 画布里写死的深色字面量也要跟着走，不能还是 0xFF121212
    expect(AppPalette.rgb(0xFF121212), isNot(const Color(0xFF121212)));
  });

  testWidgets('点护眼：底色转米黄，且仍是浅底', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ThemeChooser())),
    );

    await _selectTheme(tester, AppThemeMode.eyeCare);

    expect(AppThemeController.instance.mode, AppThemeMode.eyeCare);
    expect(AppPalette.canvasBg, const Color(0xFFF4EFDF));
    expect(AppPalette.isDark, isFalse);
  });

  testWidgets('点深色：回到旧版原色 0xFF121212，与改造前一致', (tester) async {
    await tester.pumpWidget(
      const MaterialApp(home: Scaffold(body: ThemeChooser())),
    );

    await _selectTheme(tester, AppThemeMode.light);
    await _selectTheme(tester, AppThemeMode.dark);

    expect(AppPalette.isDark, isTrue);
    expect(AppPalette.rgb(0xFF121212), const Color(0xFF121212));
    expect(AppPalette.canvasBg, const Color(0xFF121212));
  });

  test('写盘再读回来还是同一个主题（重启保留）', () async {
    await ThemeSettingsStore.save(
      const ThemeSettings(mode: AppThemeMode.eyeCare),
    );
    expect(ThemeSettingsStore.loadSync().mode, AppThemeMode.eyeCare);

    await ThemeSettingsStore.save(const ThemeSettings());
    expect(ThemeSettingsStore.loadSync().mode, AppThemeMode.dark);
  });
}
