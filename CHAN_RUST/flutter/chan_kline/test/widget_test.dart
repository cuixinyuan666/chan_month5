import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/main.dart';

void main() {
  testWidgets('应用可挂载', (WidgetTester tester) async {
    await tester.pumpWidget(const ChanKlineApp());
    expect(find.textContaining('CHAN_RUST'), findsWidgets);
  });
}
