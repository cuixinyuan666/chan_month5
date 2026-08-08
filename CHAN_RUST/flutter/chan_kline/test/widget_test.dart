import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/main.dart';

void main() {
  testWidgets('应用可挂载', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    // MaterialApp.title 不进 widget 树；验可见中文 UI
    expect(find.textContaining('截断'), findsWidgets);
  });
}
