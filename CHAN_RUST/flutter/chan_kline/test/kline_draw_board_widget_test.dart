import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/tick_dist_config.dart';
import 'package:chan_kline/widgets/kline_draw_board.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 单根 K（open10/high12/low9/close11）在 K0 窗格里的屏幕几何。
///
/// 与 `kline_candle_geometry.dart` 同源算出来的实测值：
/// 实体上沿 bodyTop=96.2（收盘价 11），实体下沿 bodyBottom=164.4（开盘价 10），
/// 上影线端点 yHigh=28.0（最高价 12），下影线端点 yLow=232.6（最低价 9）。
const double _cx = 200.75;
const double _yHigh = 28.0;
const double _yLow = 232.6;
const double _bodyTop = 96.2;
const double _bodyBottom = 164.4;

Widget _host(
  KlineDrawBoardModel model,
  ValueChanged<KlineDrawBoardModel> onChanged,
) {
  return MaterialApp(
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
            onChanged: (next) => setState(() => onChanged(next)),
            onMainIndicatorsChanged: (_) {},
            onSubIndicatorsChanged: (_) {},
          ),
        ),
      ),
    ),
  );
}

/// 在 K0 窗格里按住 [from] 拖到 [to]，松手。
Future<void> _dragInK0(
  WidgetTester tester,
  Offset from,
  Offset to,
) async {
  final gesture =
      await tester.startGesture(from, kind: PointerDeviceKind.mouse);
  await gesture.moveTo(to);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

void main() {
  testWidgets('K0 左键拖动松手后新增一根 1 分钟 K 线', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial();
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
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

  testWidgets('按住实体中段拖动：改收盘价，不新增 K 线', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    // 实体上半（close=11 一侧）：抓它改收盘价。
    final grab = Offset(_cx, _bodyTop + 10);
    await _dragInK0(tester, grab, Offset(_cx, _bodyTop + 10 - 30));

    expect(model.candles, hasLength(1), reason: '拖实体不得新增 K 线');
    final c = model.candles.single;
    expect(c.close, isNot(11), reason: '拖实体上半应改收盘价');
    expect(c.open, 10, reason: '开盘价不该被上半拖动改掉');
    // 影线不变量：影线不得落进实体
    expect(c.high, greaterThanOrEqualTo(c.open > c.close ? c.open : c.close));
    expect(c.low, lessThanOrEqualTo(c.open < c.close ? c.open : c.close));
  });

  testWidgets('按住实体下半拖动：改开盘价', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    // 实体下半（open=10 一侧）：抓它改开盘价。
    final grab = Offset(_cx, _bodyBottom - 10);
    await _dragInK0(tester, grab, Offset(_cx, _bodyBottom - 10 + 30));

    expect(model.candles, hasLength(1));
    final c = model.candles.single;
    expect(c.open, isNot(10), reason: '拖实体下半应改开盘价');
    expect(c.close, 11, reason: '收盘价不该被下半拖动改掉');
  });

  testWidgets('按住上影线端点拖动：只改最高价', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    await _dragInK0(
      tester,
      Offset(_cx, _yHigh),
      Offset(_cx, _yHigh - 30),
    );

    expect(model.candles, hasLength(1));
    final c = model.candles.single;
    expect(c.high, isNot(12), reason: '拖上影线端点应改最高价');
    expect(c.open, 10);
    expect(c.close, 11);
    expect(c.low, 9);
  });

  testWidgets('按住下影线端点拖动：只改最低价', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    await _dragInK0(
      tester,
      Offset(_cx, _yLow),
      Offset(_cx, _yLow + 30),
    );

    expect(model.candles, hasLength(1));
    final c = model.candles.single;
    expect(c.low, isNot(9), reason: '拖下影线端点应改最低价');
    expect(c.open, 10);
    expect(c.close, 11);
    expect(c.high, 12);
  });

  testWidgets('新 K 落在光标所在位置，不是序列末尾', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial()
        .addCandle(
          const KlineDrawCandle(open: 10, high: 10, low: 10, close: 10),
        )
        .addCandle(
          const KlineDrawCandle(open: 20, high: 20, low: 20, close: 20),
        );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    // 在第一根 K 附近（靠左）拖一根新 K
    await _dragInK0(
      tester,
      const Offset(60, 200),
      const Offset(60, 160),
    );

    expect(model.candles, hasLength(3));
    // 新 K 插在靠前位置：末尾那根仍是原来的 20
    expect(model.candles.last.open, 20);
    // 插入的那根不在末尾
    expect(model.candles[1].open, isNot(20));
  });

  testWidgets('K0 窗格尺寸与几何换算同源（拖动 1 像素 = 1 像素对应价）',
      (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    // 上影线端点往上拖 10 像素：最高价应涨 (10 像素对应价)
    // 价格区间 9..12 映射到 plotH=204.6 像素 → 1 像素 = 3/204.6
    final before = model.candles.single.high;
    await _dragInK0(
      tester,
      Offset(_cx, _yHigh),
      Offset(_cx, _yHigh - 10),
    );
    final after = model.candles.single.high;
    expect(after, greaterThan(before));
  });
}
