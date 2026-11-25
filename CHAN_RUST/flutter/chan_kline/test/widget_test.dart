import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/main.dart';

void main() {
  testWidgets('应用可挂载，设置打开后停在行情，结构页才看到口径', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();

    for (final title in const ['行情', '结构', '分布', '研究', '工作台']) {
      expect(find.byKey(Key('settings-rail-$title')), findsOneWidget,
          reason: '左侧分区 $title 应可见');
    }
    expect(find.textContaining('截断'), findsNothing,
        reason: '默认停在行情，结构口径先不展开');

    await tester.tap(find.byKey(const Key('settings-rail-结构')));
    await tester.pump();
    expect(find.textContaining('截断'), findsWidgets);

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('五个设置分区来回切换都不溢出', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();

    for (final title in const ['行情', '结构', '分布', '研究', '工作台']) {
      await tester.tap(find.byKey(Key('settings-rail-$title')));
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.takeException(), isNull, reason: '$title 不应有布局溢出');
    }

    await tester.pump(const Duration(seconds: 5));
  });

  testWidgets('设置页往下滚，当前分区标题仍钉在内容区顶部', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.byTooltip('设置'));
    await tester.pump(const Duration(milliseconds: 200));

    final sticky = find.byKey(const Key('settings-sticky-category'));
    expect(sticky, findsOneWidget);
    expect(
      find.descendant(of: sticky, matching: find.text('行情')),
      findsOneWidget,
    );

    await tester.drag(find.byKey(const Key('settings-scroll')), const Offset(0, -240));
    await tester.pump(const Duration(milliseconds: 150));

    expect(sticky, findsOneWidget, reason: '滚动后标题不能跟着走');
    expect(
      find.descendant(of: sticky, matching: find.text('行情')),
      findsOneWidget,
    );

    await tester.tap(find.byKey(const Key('settings-rail-结构')));
    await tester.pump();
    expect(
      find.descendant(of: sticky, matching: find.text('结构')),
      findsOneWidget,
    );
  });
}
