import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/main.dart';

void main() {
  testWidgets('应用可挂载', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    await tester.tap(find.byTooltip('设置'));
    await tester.pump();
    expect(find.textContaining('截断'), findsWidgets);
    await tester.pump(const Duration(seconds: 5));
  });
}
