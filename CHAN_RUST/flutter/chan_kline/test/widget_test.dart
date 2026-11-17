import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/main.dart';

void main() {
  testWidgets('应用可挂载，设置面板默认收起且可展开到主图口径', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();

    // 默认收起：面板一开只有 5 张分类卡片，明细一项都不展开。
    for (final title in const [
      '数据与加载',
      '分析与指标',
      '界面与操作',
      '主图显示',
      '维护与同步',
    ]) {
      expect(find.text(title), findsOneWidget, reason: '分类卡片 $title 应可见');
    }
    expect(find.textContaining('截断'), findsNothing,
        reason: '默认收起时不应出现明细项');

    // 展开「主图显示」后才看得到口径明细。
    await tester.tap(find.text('主图显示'));
    await tester.pumpAndSettle();
    expect(find.textContaining('截断'), findsWidgets);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('每个设置分类展开后都不溢出（300px 窄面板无文字遮挡）',
      (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();

    for (final title in const [
      '数据与加载',
      '分析与指标',
      '界面与操作',
      '主图显示',
      '维护与同步',
    ]) {
      // 全部展开后内容高于测试视口，先把目标卡片滚进可视区再点，
      // 否则 tap 会落到屏外（命中不到控件，等于没验证）。
      await tester.ensureVisible(find.text(title));
      await tester.pumpAndSettle();
      await tester.tap(find.text(title));
      await tester.pumpAndSettle();
      // RenderFlex overflow / 文本裁剪断言失败都会以异常形式冒出来。
      expect(tester.takeException(), isNull, reason: '$title 展开后不应有布局溢出');
    }

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('设置面板下滚后，当前分类标题吸顶可见', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('设置'));
    await tester.pump(const Duration(milliseconds: 200));

    // 展开前两张卡，把内容撑到能滚（5 张全收起时总高小于面板，滚不动）。
    await tester.tap(find.text('数据与加载'));
    await tester.pump(const Duration(milliseconds: 300));
    await tester.ensureVisible(find.text('分析与指标'));
    await tester.tap(find.text('分析与指标'));
    await tester.pump(const Duration(milliseconds: 300));

    // 向下滚（拖三次，确保越过第一张卡）。
    // 设置滚动区里还嵌着 SelectionArea 的横向 scrollable，取第一个（纵向）。
    final scrollable = find.descendant(
      of: find.byKey(const Key('settings-scroll')),
      matching: find.byType(Scrollable),
    ).first;
    for (var i = 0; i < 3; i++) {
      await tester.drag(scrollable, const Offset(0, -200));
      await tester.pump(const Duration(milliseconds: 150));
    }

    // 吸顶条出现，且文字是五个分类之一（不是空、不是别的）。
    final sticky = find.byKey(const Key('settings-sticky-category'));
    expect(sticky, findsOneWidget, reason: '滚动后应有吸顶条');
    final texts = <String>[
      '数据与加载',
      '分析与指标',
      '界面与操作',
      '主图显示',
      '维护与同步',
    ];
    final hit = texts.any(
      (t) => find.descendant(of: sticky, matching: find.text(t)).evaluate().isNotEmpty,
    );
    expect(hit, isTrue, reason: '吸顶条要显示当前分类名');
  });
}
