import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/tick_dist_config.dart';
import 'package:chan_kline/widgets/kline_draw_board.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  testWidgets('K0 左键拖动松手后新增一根 1 分钟 K 线', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: StatefulBuilder(
            builder: (context, setState) => KlineDrawBoard(
              model: model,
              bundle: KlineCombineBundle.empty(),
              mainIndicators: const <MainChartIndicator>{},
              subIndicators: const <SubChartIndicator>{},
              truncationCheck: true,
              earlyDynamicUnit: true,
              showBuildingDash: true,
              chipConfig: const ChipConfig(),
              tickDistConfig: const TickDistConfig(),
              onChanged: (next) => setState(() => model = next),
              onMainIndicatorsChanged: (_) {},
              onSubIndicatorsChanged: (_) {},
            ),
          ),
        ),
      ),
    ));
    await tester.pump();

    final start = const Offset(300, 260);
    final end = const Offset(300, 180);
    final gesture = await tester.startGesture(start, kind: PointerDeviceKind.mouse);
    await gesture.moveTo(end);
    await tester.pump();
    expect(find.byType(CustomPaint), findsWidgets);
    await gesture.up();
    await tester.pump();

    expect(model.candles, hasLength(1));
    final candle = model.candles.single;
    expect(candle.open, isNot(equals(candle.close)));
    expect(candle.high, candle.open > candle.close ? candle.open : candle.close);
    expect(candle.low, candle.open < candle.close ? candle.open : candle.close);
    expect(model.toBars().single.timeText, '2026/07/10 09:30:00');
    expect(find.text('K1'), findsWidgets);
    expect(find.text('5\u5206\u949f'), findsWidgets);
  });
}
