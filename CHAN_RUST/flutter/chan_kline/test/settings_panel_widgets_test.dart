import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/theme/app_palette.dart';
import 'package:chan_kline/theme/theme_rebuild_scope.dart';
import 'package:chan_kline/theme/theme_settings_store.dart';
import 'package:chan_kline/ui/settings_panel_widgets.dart';

/// 主题实时预览 + 设置面板版式的验收口径。
///
/// 注意：主题控制器会把配置写盘（真实 I/O）。widget 测试默认在 fake-async
/// 区域里跑，直接 `await` 这个 Future 会挂住，所以统一走 `tester.runAsync`。
void main() {
  Future<void> resetTheme(WidgetTester tester) async {
    await tester.runAsync(() async {
      await AppThemeController.instance.setMode(AppThemeMode.dark);
      await AppThemeController.instance.setWarmth(0.0);
      await AppThemeController.instance.setBrightness(0.5);
    });
    await tester.pump();
  }

  group('ThemeRebuildScope（主题实时预览）', () {
    Future<Color> pumpCanvas(WidgetTester tester) async {
      await tester.pumpWidget(
        MaterialApp(
          home: ThemeRebuildScope(
            builder: (context) => Scaffold(
              body: ColoredBox(
                key: const ValueKey('canvas'),
                color: AppPalette.canvasBg,
                child: const SizedBox.expand(),
              ),
            ),
          ),
        ),
      );
      return tester
          .widget<ColoredBox>(find.byKey(const ValueKey('canvas')))
          .color;
    }

    Color canvasColor(WidgetTester tester) => tester
        .widget<ColoredBox>(find.byKey(const ValueKey('canvas')))
        .color;

    testWidgets('切主题后范围内的画布立刻换色（不用关掉重开）', (tester) async {
      await resetTheme(tester);
      final before = await pumpCanvas(tester);
      expect(before, const Color(0xFF121212), reason: '深色基准');

      await tester.runAsync(
        () => AppThemeController.instance.setMode(AppThemeMode.light),
      );
      await tester.pump();

      final after = canvasColor(tester);
      expect(after, const Color(0xFFF6F7F9));
      expect(after, isNot(before));
    });

    testWidgets('拖暖色/亮度滑杆同样即时重建', (tester) async {
      await resetTheme(tester);
      final before = await pumpCanvas(tester);

      await tester.runAsync(
        () => AppThemeController.instance.setWarmth(0.8),
      );
      await tester.pump();
      final warm = canvasColor(tester);
      expect(warm, isNot(before), reason: '暖色注入后底色应变化');

      await tester.runAsync(
        () => AppThemeController.instance.setBrightness(0.2),
      );
      await tester.pump();
      expect(canvasColor(tester), isNot(warm), reason: '亮度压低后底色应继续变化');
    });
  });

  group('SettingsCategory（卡片化 / 默认收起 / 聚合度）', () {
    Widget host(Widget child) => MaterialApp(
          home: Scaffold(
            body: Align(
              alignment: Alignment.topLeft,
              child: SizedBox(width: 300, child: child),
            ),
          ),
        );

    testWidgets('默认收起，点标题才展开子项', (tester) async {
      await tester.pumpWidget(host(
        const SettingsCategory(
          title: '主图显示',
          icon: Icons.candlestick_chart_outlined,
          summary: '首框 高高 · 分窗 关',
          children: [
            Text('子项A'),
            Text('子项B'),
          ],
        ),
      ));

      // 卡片标题与收起摘要可见，明细不可见。
      expect(find.text('主图显示'), findsOneWidget);
      expect(find.text('首框 高高 · 分窗 关'), findsOneWidget);
      expect(find.text('子项A'), findsNothing, reason: '默认必须是收起态');

      await tester.tap(find.text('主图显示'));
      await tester.pumpAndSettle();

      expect(find.text('子项A'), findsOneWidget);
      expect(find.text('子项B'), findsOneWidget);
    });

    testWidgets('children 里的 SizedBox 占位被剔除，项间距只有一层', (tester) async {
      await tester.pumpWidget(host(
        const SettingsCategory(
          title: '分组',
          icon: Icons.tune,
          initiallyExpanded: true,
          children: [
            Text('A'),
            SizedBox(height: 8),
            Text('B'),
            SizedBox(height: 10),
            Text('C'),
          ],
        ),
      ));
      await tester.pumpAndSettle();

      // 调用方自带的 8/10 占位若生效，A 与 B 的间距会变成 8+8；
      // 这里只允许卡片统一给的一层 fieldGap。
      final a = tester.getRect(find.text('A'));
      final b = tester.getRect(find.text('B'));
      expect(
        b.top - a.bottom,
        moreOrLessEquals(SettingsPanelTheme.fieldGap, epsilon: 0.5),
        reason: '项间距应等于 fieldGap，不能叠加调用方的 SizedBox',
      );
    });
  });

  group('SettingsChoiceDropdown（帮助入口不挤占、不遮挡）', () {
    testWidgets('问号在输入框内，输入框保持整宽', (tester) async {
      var helped = 0;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: SizedBox(
              width: 300,
              child: SettingsChoiceDropdown<bool>(
                label: '首分型前合并框',
                value: true,
                helper: '开启后首框按高高口径生长',
                onHelp: () => helped++,
                items: const [
                  DropdownMenuItem(value: true, child: Text('开启')),
                  DropdownMenuItem(value: false, child: Text('关闭')),
                ],
                onChanged: (_) {},
              ),
            ),
          ),
        ),
      ));

      // 输入框占满 300（旧版左侧 48px 的 IconButton 会把它压到 252）。
      final fieldW = tester
          .getSize(find.byType(DropdownButtonFormField<bool>))
          .width;
      expect(fieldW, moreOrLessEquals(300, epsilon: 0.5));

      await tester.tap(find.byIcon(Icons.help_outline));
      await tester.pump();
      expect(helped, 1);
    });
  });

  group('设置分区台', () {
    testWidgets('只显示当前页，搜索能跳到匹配分区，标题一直在', (tester) async {
      await tester.pumpWidget(const MaterialApp(home: _DeskHost()));
      expect(find.text('股票下拉'), findsOneWidget);
      expect(find.text('截断机制'), findsNothing);
      expect(find.byKey(const Key('settings-sticky-category')), findsOneWidget);

      await tester.tap(find.byKey(const Key('settings-rail-结构')));
      await tester.pump();
      expect(find.text('截断机制'), findsOneWidget);

      await tester.enterText(find.byKey(const Key('settings-desk-search')), '股票');
      await tester.pump();
      expect(find.text('股票下拉'), findsOneWidget);
      expect(find.text('截断机制'), findsNothing);
    });

    testWidgets('开关和四档点选把新值交回去', (tester) async {
      var on = false;
      String? picked;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 360,
            child: Column(
              children: [
                SettingsSwitchRow(
                  label: '截断机制',
                  value: on,
                  onChanged: (v) => on = v,
                ),
                SettingsChoiceCards<String>(
                  label: '首框',
                  value: picked ?? '高高',
                  layout: SettingsChoiceLayout.grid,
                  onChanged: (v) => picked = v,
                  options: const [
                    SettingsChoiceOption(value: '经典', title: '经典'),
                    SettingsChoiceOption(value: '种子框', title: '种子框'),
                    SettingsChoiceOption(value: '高高', title: '高高'),
                    SettingsChoiceOption(value: '低低', title: '低低'),
                  ],
                ),
              ],
            ),
          ),
        ),
      ));

      await tester.tap(find.byType(Switch));
      await tester.pump();
      expect(on, isTrue);

      await tester.tap(find.text('低低'));
      await tester.pump();
      expect(picked, '低低');
    });
  });
}

class _DeskHost extends StatefulWidget {
  const _DeskHost();

  @override
  State<_DeskHost> createState() => _DeskHostState();
}

class _DeskHostState extends State<_DeskHost> {
  int index = 0;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      body: SizedBox(
        width: 432,
        height: 640,
        child: SettingsDesk(
          index: index,
          onChanged: (i) => setState(() => index = i),
          sections: const [
            SettingsDeskSection(
              title: '行情',
              railLabel: '行情',
              icon: Icons.show_chart,
              summary: 'test · 1分钟',
              searchTerms: '股票 周期',
              children: [Text('股票下拉')],
            ),
            SettingsDeskSection(
              title: '结构',
              railLabel: '结构',
              icon: Icons.account_tree_outlined,
              summary: '高高',
              searchTerms: '截断 首框',
              children: [Text('截断机制')],
            ),
          ],
        ),
      ),
    );
  }
}
