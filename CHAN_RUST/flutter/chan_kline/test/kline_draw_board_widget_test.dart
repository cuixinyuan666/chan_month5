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

/// 两根 K（candle0=(10,12,9,11)，candle1=(20,22,19,21)）时的实测几何：
/// K0 视口 399.5 宽，槽宽 slotW=393.5，candle0 中心 cx=200.75，
/// 其槽位右缘 = 200.75 + 393.5/2 = 397.5（「选中 K 右方」从这以右开始）。
/// 价格区间 9..22（span 13）：yOf(11)=201.1、yOf(10)=216.9，
/// candle0 实体中段约在 y=209。
const double _cxTwo = 200.75;
const double _slotRight = 397.5;
const double _candle0BodyY = 209.0;

/// 承载画板的宿主：**内部持有 model** 并在 onChanged 时 setState 换新，
/// 与 App 里「setState 换新 model」同一条链路。
///
/// 旧版把 model 当构造参数传进 StatefulBuilder，重建时永远读到旧值，
/// 「点击选中→图表拿到新锚点」这类靠重建生效的行为根本测不出来。
class _BoardHost extends StatefulWidget {
  const _BoardHost({required this.initial, this.onChanged});

  final KlineDrawBoardModel initial;
  final ValueChanged<KlineDrawBoardModel>? onChanged;

  @override
  State<_BoardHost> createState() => _BoardHostState();
}

class _BoardHostState extends State<_BoardHost> {
  late KlineDrawBoardModel model = widget.initial;

  void _onChanged(KlineDrawBoardModel next) {
    setState(() => model = next);
    widget.onChanged?.call(next);
  }

  @override
  Widget build(BuildContext context) => KlineDrawBoard(
        model: model,
        bundle: KlineCombineBundle.empty(),
        mainIndicators: const <MainChartIndicator>{},
        subIndicators: const <SubChartIndicator>{},
        truncationCheck: true,
        earlyDynamicUnit: true,
        showBuildingDash: true,
        chipConfig: const ChipConfig(),
        tickDistConfig: const TickDistConfig(),
        onChanged: _onChanged,
        onMainIndicatorsChanged: (_) {},
        onSubIndicatorsChanged: (_) {},
      );
}

Widget _host(
  KlineDrawBoardModel model, [
  ValueChanged<KlineDrawBoardModel>? onChanged,
]) {
  return MaterialApp(
    home: Scaffold(
      body: SizedBox(
        width: 900,
        height: 700,
        child: _BoardHost(initial: model, onChanged: onChanged),
      ),
    ),
  );
}

/// 宿主当前持有的 model（画板实际看到的那份）。
KlineDrawBoardModel _live(WidgetTester tester) =>
    tester.state<_BoardHostState>(find.byType(_BoardHost)).model;

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

/// 在 K0 窗格里 [at] 处按下再松手（不移动）＝点击。
Future<void> _clickInK0(WidgetTester tester, Offset at) async {
  final gesture =
      await tester.startGesture(at, kind: PointerDeviceKind.mouse);
  await tester.pump();
  await gesture.up();
  await tester.pump();
}

/// 树里是否存在聚焦箭头 painter（点击选中后出现）。
Finder get _focusArrows => find.byWidgetPredicate(
      (w) =>
          w is CustomPaint &&
          w.painter.runtimeType.toString().contains('FocusArrows'),
    );

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

  testWidgets('点击已画好的 K 线出现聚焦图形（选中 + 四箭头）', (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model.copyWith(selected: -1)));
    await tester.pump();

    // 未选中：没有聚焦箭头。
    expect(_focusArrows, findsNothing);
    expect(_live(tester).selected, -1);

    // 点击实体（按下即选中）。
    await _clickInK0(tester, Offset(_cx, _bodyTop + 10));

    expect(_live(tester).selected, 0, reason: '点击 K 线应选中它');
    expect(_focusArrows, findsOneWidget, reason: '选中后应出现四支聚焦箭头');
  });

  testWidgets('在选中 K 左方空白拖动：不新增 K（平移）', (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model));
    await tester.pump();
    expect(_live(tester).selected, 0, reason: 'addCandle 后新 K 即选中');

    // 选中 K 槽位（右缘 397.5）左方的空白：拖动＝平移。
    await _dragInK0(
      tester,
      const Offset(60, 200),
      const Offset(60, 160),
    );

    expect(_live(tester).candles, hasLength(1),
        reason: '左方空白拖动是平移，不得新增 K 线');
  });

  testWidgets('未选中且非空板：空白拖动不新增 K（平移）', (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model.copyWith(selected: -1)));
    await tester.pump();
    expect(_live(tester).selected, -1);

    await _dragInK0(
      tester,
      const Offset(60, 200),
      const Offset(60, 160),
    );

    expect(_live(tester).candles, hasLength(1),
        reason: '未选中时无绘制锚点，空白拖动是平移');
  });

  testWidgets('在选中 K 右方空白拖动：新 K 落在其右方', (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model));
    await tester.pump();

    // 选中 K 槽位右缘以右（x>397.5）拖动：才画新 K。
    await _dragInK0(
      tester,
      const Offset(_slotRight + 1, 200),
      const Offset(_slotRight + 1, 150),
    );

    final m = _live(tester);
    expect(m.candles, hasLength(2), reason: '选中 K 右方拖动应新增 K 线');
    expect(m.candles[0].open, 10, reason: '原 K 不该被动到');
    expect(m.selected, 1, reason: '新 K 自动成为选中');
  });

  testWidgets('新 K 落在选中 K 右方的光标位置，不是序列末尾', (tester) async {
    final model = KlineDrawBoardModel.initial()
        .addCandle(
          const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
        )
        .addCandle(
          const KlineDrawCandle(open: 20, high: 22, low: 19, close: 21),
        );
    await tester.pumpWidget(_host(model));
    await tester.pump();

    // 先点击第一根 K（几何见 _cxTwo/_candle0BodyY 注释）选中它。
    await _clickInK0(tester, const Offset(_cxTwo, _candle0BodyY));
    expect(_live(tester).selected, 0);

    // 再在选中 K 右方空白拖一根新 K。
    await _dragInK0(
      tester,
      const Offset(_slotRight + 1, 200),
      const Offset(_slotRight + 1, 150),
    );

    final m = _live(tester);
    expect(m.candles, hasLength(3));
    // 新 K 插在选中 K 右侧（index 1）：末尾那根仍是原来的 20。
    expect(m.candles.last.open, 20, reason: '末尾仍是原第二根');
    expect(m.candles[1].open, isNot(20), reason: '新 K 插在 index 1，不在末尾');
  });

  testWidgets('K0 窗格尺寸与几何换算同源（拖动 1 像素 = 1 像素对应价）',
      (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model));
    await tester.pump();

    // 抓着上影线端点向上拖 10 像素：最高价应抬升 10 像素对应价。
    // 价格区间 9..12（span 3）铺满 plotH：1 像素 = 3/204.6
    final before = _live(tester).candles.single.high;
    await _dragInK0(
      tester,
      Offset(_cx, _yHigh),
      Offset(_cx, _yHigh - 10),
    );
    final after = _live(tester).candles.single.high;
    expect(after, greaterThan(before));
  });
}
