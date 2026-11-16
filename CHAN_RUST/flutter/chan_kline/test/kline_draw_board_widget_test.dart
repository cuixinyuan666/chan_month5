import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/tick_dist_config.dart';
import 'package:chan_kline/widgets/kline_chart.dart';
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
/// 其槽位右缘 = 200.75 + 393.5/2 = 397.5（≈画布最右；旧版曾把它当绘制
/// 放行线，导致只剩最右 2px 能画，2026-11-16 已改为以 cx 为界）。
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

  testWidgets('按住实体拖动：整根平移（四价同移），不新增 K 线', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    // 板上仅这一根 K（无钳制区间）：抓实体中段上拖，整根上移。
    final grab = Offset(_cx, _bodyTop + 10);
    await _dragInK0(tester, grab, Offset(_cx, _bodyTop + 10 - 30));

    expect(model.candles, hasLength(1), reason: '拖实体不得新增 K 线');
    final c = model.candles.single;
    expect(c.close, isNot(11), reason: '整根平移应改掉收盘价');
    expect(c.open, isNot(10), reason: '整根平移应改掉开盘价');
    // 形状不变：四价同移（开收差 1、高开差 2、开低差 1）。
    expect(c.close - c.open, closeTo(1, 1e-6));
    expect(c.high - c.close, closeTo(1, 1e-6));
    expect(c.open - c.low, closeTo(1, 1e-6));
  });

  testWidgets('按住实体下半拖动：整根平移（形状不变）', (tester) async {
    KlineDrawBoardModel model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(
      _host(model, (next) => model = next),
    );
    await tester.pump();

    final grab = Offset(_cx, _bodyBottom - 10);
    await _dragInK0(tester, grab, Offset(_cx, _bodyBottom - 10 + 30));

    expect(model.candles, hasLength(1));
    final c = model.candles.single;
    expect(c.open, isNot(10), reason: '整根平移应改掉开盘价');
    expect(c.close, isNot(11), reason: '整根平移应改掉收盘价');
    expect(c.close - c.open, closeTo(1, 1e-6), reason: '形状不得变');
  });

  testWidgets('按住上影线端点拖动：整根平移（不再单独改最高价）', (tester) async {
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
    // 2026-11-16 起无部位语义：抓影线端点=整根上移，四价同动。
    expect(c.high, isNot(12), reason: '整根上移应改掉最高价');
    expect(c.open, isNot(10), reason: '开盘价同移（不再是 10）');
    expect(c.close, isNot(11), reason: '收盘价同移（不再是 11）');
    expect(c.low, isNot(9), reason: '最低价同移（不再是 9）');
    expect(c.close - c.open, closeTo(1, 1e-6), reason: '形状不得变');
  });

  testWidgets('按住下影线端点拖动：整根平移（不再单独改最低价）', (tester) async {
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
    expect(c.low, isNot(9), reason: '整根下移应改掉最低价');
    expect(c.open, isNot(10), reason: '开盘价同移');
    expect(c.close, isNot(11), reason: '收盘价同移');
    expect(c.high, isNot(12), reason: '最高价同移');
    expect(c.close - c.open, closeTo(1, 1e-6), reason: '形状不得变');
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

    // 选中 K 中心（cx=200.75）左方的空白：拖动＝平移。
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

    // 选中 K 中心（cx=200.75）右方拖动即可画新 K，不必贴最右边。
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

  testWidgets('选中 K 右边但非最右边的空白也能画新 K（不再限定槽位右缘）',
      (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model));
    await tester.pump();

    // 单根 K：中心 cx=200.75，槽位右缘≈397.5 已贴画布最右。
    // 旧逻辑要求 x>397.5 才能起笔（只剩最右 2px）——正是用户反馈的
    // 「必须在最右边才能画」。取 x=300（中心右方、离最右边很远）验证修复。
    const drawX = 300.0;
    await _dragInK0(
      tester,
      const Offset(drawX, 200),
      const Offset(drawX, 150),
    );

    final m = _live(tester);
    expect(m.candles, hasLength(2),
        reason: '选中 K 中心右侧的空白应能起笔画新 K，不该只剩最右边能画');
    expect(m.candles.first.open, 10, reason: '原 K 不动');
    expect(m.selected, 1, reason: '新 K 自动选中');
  });

  testWidgets('防压缩：拖一根 K 越不过按下时全体可见 K 的价格区间', (tester) async {
    // 两根 K：A(9..12)、B(19..22)。全体并集 [9,22]。
    // 只有一屏时两根都可见：拖 A 向上 300 像素也到不了并集上沿之上。
    final model = KlineDrawBoardModel.initial()
        .addCandle(
          const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
        )
        .addCandle(
          const KlineDrawCandle(open: 20, high: 22, low: 19, close: 21),
        );
    await tester.pumpWidget(_host(model));
    await tester.pump();

    // 按住 A 实体中段向上拖 300 像素（远超并集上沿）。
    await _dragInK0(
      tester,
      const Offset(_cxTwo, _candle0BodyY),
      const Offset(_cxTwo, _candle0BodyY - 300),
    );

    final m = _live(tester);
    expect(m.candles, hasLength(2));
    // 钳制生效：A 的高点不得越过并集上沿 22（B 的顶），其余 K 不被压扁。
    expect(m.candles[0].high, lessThanOrEqualTo(22.000001));
    // B 完全不动。
    expect(m.candles[1].high, 22);
    expect(m.candles[1].low, 19);
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

  testWidgets('左上角操作窗固定显示「1分钟 K0」且无周期下拉', (tester) async {
    final model = KlineDrawBoardModel.initial().addCandle(
      const KlineDrawCandle(open: 10, high: 12, low: 9, close: 11),
    );
    await tester.pumpWidget(_host(model));
    await tester.pump();

    expect(find.text('1\u5206\u949f K0'), findsOneWidget,
        reason: '左上角操作窗角标固定为 1分钟 K0');
    // K1/周期文本在下拉项里也会出现，只要求它们存在即可。
    expect(find.text('K1'), findsWidgets, reason: '右上窗是 K1');
    expect(find.text('5\u5206\u949f'), findsWidgets);
    expect(find.text('15\u5206\u949f'), findsWidgets);
    // 4 窗里只有 3 个非操作窗有下拉；左上角操作窗不给下拉。
    expect(find.byType(DropdownButton<String>), findsNWidgets(3));
  });

  testWidgets('各周期窗显示自己的聚合数据，不再与 1 分钟窗相同', (tester) async {
    var model = KlineDrawBoardModel.initial();
    for (var i = 0; i < 10; i++) {
      model = model.addCandle(
        KlineDrawCandle(
          open: 10.0 + i,
          high: 11.0 + i,
          low: 9.0 + i,
          close: 10.5 + i,
        ),
      );
    }
    await tester.pumpWidget(_host(model));
    await tester.pump();

    KlineChart chart(String key) =>
        tester.widget<KlineChart>(find.byKey(ValueKey<String>(key)));
    final k0 = chart('kline-draw-0-0-1m');
    final k1 = chart('kline-draw-1-1-1m');
    final m5 = chart('kline-draw-2-0-5m');
    final m15 = chart('kline-draw-3-0-15m');

    expect(k0.bars, hasLength(10), reason: '操作窗保持 10 根 1 分钟');
    expect(k1.bars, hasLength(10), reason: 'K1 层级窗仍用原始 1m 数据');
    expect(m5.bars, hasLength(2), reason: '5 分钟窗 = 10/5 = 2 根');
    expect(m15.bars, hasLength(1), reason: '15 分钟窗 = 10 根聚成 1 根');
    // 5 分钟的首根开=第 1 根 1m 开，末根收=第 5 根 1m 收。
    expect(m5.bars.first.open, 10);
    expect(m5.bars.first.close, 14.5);
    expect(m5.bars.first.high, 15);
    expect(m5.bars.first.low, 9);
  });
}
