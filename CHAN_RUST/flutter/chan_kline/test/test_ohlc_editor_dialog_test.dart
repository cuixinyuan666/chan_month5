import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/test_ohlc_editor_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// test 自定义 OHLC 编辑弹窗：逐格 ▲/▼ 步进、悬停滚轮调值（并劫持表格滚动）、
/// 行尾「+」复制本行插入下方、「添加一行」按钮已移除。
void main() {
  // 逐格编辑在自由模式下（分笔模板会联动/锁定时间，另测）。
  Future<_Host> openFree(WidgetTester tester, List<KlineBar> bars) =>
      _open(tester, bars: bars, tickTemplate: false);

  testWidgets('步进按钮：时间 +1 分钟 / 价 ±0.01（去尾零）/ 量 ±1', (tester) async {
    await openFree(tester, _seedBars(2));

    // 时间：09:30:00 → 09:31:00
    await tester.tap(_stepAt(tester, 0, 0, Icons.keyboard_arrow_up, false));
    await tester.pump();
    expect(_cellText(tester, 0, 0), '2026/07/10 09:31:00');

    // 开 3 → 3.01；再减回 3
    await tester.tap(_stepAt(tester, 0, 1, Icons.keyboard_arrow_up, false));
    await tester.pump();
    expect(_cellText(tester, 0, 1), '3.01');
    await tester.tap(_stepAt(tester, 0, 1, Icons.keyboard_arrow_down, false));
    await tester.pump();
    expect(_cellText(tester, 0, 1), '3');

    // 3.10 + 0.01 → 3.11（保留两位）；3.09 + 0.01 → 3.1（去尾零、无浮点伪影）
    await tester.enterText(_cellAt(0, 1), '3.10');
    await tester.tap(_stepAt(tester, 0, 1, Icons.keyboard_arrow_up, false));
    await tester.pump();
    expect(_cellText(tester, 0, 1), '3.11');
    await tester.enterText(_cellAt(0, 1), '3.09');
    await tester.tap(_stepAt(tester, 0, 1, Icons.keyboard_arrow_up, false));
    await tester.pump();
    expect(_cellText(tester, 0, 1), '3.1');

    // 量 2：+1 → 3，−1 → 2
    await tester.tap(_stepAt(tester, 0, 5, Icons.keyboard_arrow_up, false));
    await tester.pump();
    expect(_cellText(tester, 0, 5), '3');
    await tester.tap(_stepAt(tester, 0, 5, Icons.keyboard_arrow_down, false));
    await tester.pump();
    expect(_cellText(tester, 0, 5), '2');
  });

  testWidgets('行尾加号可点击并复制本行到下方', (tester) async {
    await openFree(tester, _seedBars(2));

    expect(_rowCount(tester), 2);
    expect(_cellText(tester, 0, 1), '3');
    expect(_cellText(tester, 1, 1), '3.1');

    await tester.tap(_rowAddAt(tester, 0));
    await tester.pump();

    expect(_rowCount(tester), 3);
    expect(_cellText(tester, 1, 1), '3');
    expect(_cellText(tester, 2, 1), '3.1');
  });

  testWidgets('悬停格内滚轮调值且表格不滚；非悬停时滚轮滚表格不动值', (tester) async {
    await openFree(tester, _seedBars(30));

    final scrollable = tester.state<ScrollableState>(_tableScrollable());
    expect(_cellText(tester, 0, 0), '2026/07/10 09:30:00');

    // 先滚一段（滚轮落在空白处，表格应滚动）
    await tester.sendEventToBinding(
      const PointerScrollEvent(position: Offset(440, 300), scrollDelta: Offset(0, 200)),
    );
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(0));

    // 滚回顶部，让第 0 行重新进入可视区再测悬停劫持
    scrollable.position.jumpTo(0);
    await tester.pump();

    // 悬停在第 0 行价格格上滚轮：值变、表格不再滚
    await tester.sendEventToBinding(
      const PointerScrollEvent(position: Offset(10, 10)), // 移动指针先
    );
    final cellCenter = tester.getCenter(_cellAt(0, 1));
    final pointer = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(pointer.hover(cellCenter));
    await tester.pump();
    final before = scrollable.position.pixels;
    final beforeVal = _cellText(tester, 0, 1);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, -200)));
    await tester.pump();
    expect(scrollable.position.pixels, before, reason: '悬停格内滚轮被劫持，表格不滚');
    expect(_cellText(tester, 0, 1), isNot(beforeVal), reason: '悬停格内滚轮调值');

    // 指针移到「#」索引列（非数据格）再滚：表格恢复滚动、值不动
    final tableTopLeft = tester.getTopLeft(find.byType(Table));
    await tester.sendEventToBinding(
        pointer.hover(tableTopLeft + const Offset(14, 60)));
    await tester.pump();
    final valAfter = _cellText(tester, 0, 1);
    await tester.sendEventToBinding(pointer.scroll(const Offset(0, 200)));
    await tester.pump();
    expect(scrollable.position.pixels, greaterThan(0), reason: '非悬停滚轮滚表格');
    expect(_cellText(tester, 0, 1), valAfter, reason: '非悬停滚轮不动值');
  });

  testWidgets('行尾「+」复制本行插入下方；「添加一行」按钮已移除', (tester) async {
    await openFree(tester, _seedBars(2));
    expect(_rowCount(tester), 2);

    // 复制第 0 行 → 插到 index 1，新行文本与源行一致
    await tester.tap(find.byIcon(Icons.add_circle_outline).at(0));
    await tester.pump();
    expect(_rowCount(tester), 3);
    for (final c in [0, 1, 2, 3, 4, 5]) {
      expect(_cellText(tester, 1, c), _cellText(tester, 0, c),
          reason: '复制行第 $c 格应等值');
    }

    // 复制的是纯文本快照：改动源行不影响新行
    await tester.tap(_stepAt(tester, 0, 1, Icons.keyboard_arrow_up, false));
    await tester.pump();
    expect(_cellText(tester, 1, 1), '3');

    expect(find.text('添加一行'), findsNothing,
        reason: '左下角「添加一行」按钮已由行尾 + 替代');
  });

  testWidgets('仅保存：回传全部行且 loadAfterSave=false', (tester) async {
    final host = await openFree(tester, _seedBars(2));

    await tester.tap(find.text('仅保存'));
    await tester.pumpAndSettle();

    expect(host.closed, isTrue);
    expect(host.captured, isNotNull);
    expect(host.captured!.loadAfterSave, isFalse);
    expect(host.captured!.bars.length, 2);
    expect(host.captured!.bars[0].timeText, '2026/07/10 09:30:00');
    expect(host.captured!.bars[1].open, 3.1);
  });

  group('分笔模板（默认启用）', () {
    testWidgets('默认开启：时间自动 3 秒一笔、四价联动、量可改', (tester) async {
      await _open(tester, bars: _seedBars(3));

      // 时间自动：09:30:00 / 09:30:03 / 09:30:06，且为只读（步进钮被省略）
      expect(_cellText(tester, 0, 0), '2026/07/10 09:30:00');
      expect(_cellText(tester, 1, 0), '2026/07/10 09:30:03');
      expect(_cellText(tester, 2, 0), '2026/07/10 09:30:06');
      expect(
        tester.widget<TextField>(_cellAt(0, 0)).readOnly,
        isTrue,
        reason: '模板下时间由系统生成，只读',
      );

      // 四价已联动为开盘价（一字线）
      for (var i = 0; i < 3; i++) {
        final open = _cellText(tester, i, 1);
        expect(_cellText(tester, i, 2), open);
        expect(_cellText(tester, i, 3), open);
        expect(_cellText(tester, i, 4), open);
      }

      // 改开一格 → 高低收联动
      await tester.enterText(_cellAt(0, 1), '3.5');
      await tester.pump();
      expect(_cellText(tester, 0, 2), '3.5');
      expect(_cellText(tester, 0, 3), '3.5');
      expect(_cellText(tester, 0, 4), '3.5');

      // 价格步进钮也联动整行
      await tester.tap(_stepAt(tester, 0, 1, Icons.keyboard_arrow_up, true));
      await tester.pump();
      expect(_cellText(tester, 0, 1), '3.51');
      expect(_cellText(tester, 0, 4), '3.51');

      // 量仍可自由修改
      await tester.enterText(_cellAt(0, 5), '9');
      await tester.pump();
      expect(_cellText(tester, 0, 5), '9');
    });

    testWidgets('行尾复制/删除后时间重新按 3 秒重排', (tester) async {
      await _open(tester, bars: _seedBars(2));
      // 复制第 0 行 → 3 行，时间 09:30:00/03/06
      await tester.tap(find.byIcon(Icons.add_circle_outline).at(0));
      await tester.pump();
      expect(_rowCount(tester), 3);
      expect(_cellText(tester, 2, 0), '2026/07/10 09:30:06');

      // 删除第 1 行 → 时间重新收紧为 00/03
      await tester.tap(find.byIcon(Icons.remove_circle_outline).at(1));
      await tester.pump();
      expect(_rowCount(tester), 2);
      expect(_cellText(tester, 1, 0), '2026/07/10 09:30:03');
    });

    testWidgets('保存并加载：模板下产物为每 3 秒一笔的一字线分笔', (tester) async {
      final host = await _open(tester, bars: _seedBars(3));
      await tester.enterText(_cellAt(0, 1), '3.5');
      await tester.pump();
      await tester.tap(find.text('保存并加载'));
      await tester.pumpAndSettle();

      expect(host.captured, isNotNull);
      expect(host.captured!.loadAfterSave, isTrue);
      final bars = host.captured!.bars;
      expect(bars.length, 3);
      expect(bars[0].timeText, '2026/07/10 09:30:00');
      expect(bars[1].timeText, '2026/07/10 09:30:03');
      // 一字线：四价一致
      expect(bars[0].open, 3.5);
      expect(bars[0].high, 3.5);
      expect(bars[0].low, 3.5);
      expect(bars[0].close, 3.5);
    });
  });
}

/// 造测试种子：n 根严格递增的 1 分钟 K 线。
List<KlineBar> _seedBars(int n) => [
      for (var i = 0; i < n; i++)
        KlineBar(
          idx: i,
          timeMs: i * 60000,
          timeText:
              '2026/07/10 ${(9 + i ~/ 60).toString().padLeft(2, '0')}:${(30 + i % 60).toString().padLeft(2, '0')}:00',
          open: 3 + i * 0.1,
          high: 4 + i * 0.1,
          low: 3 + i * 0.1,
          close: 4 + i * 0.1,
          volume: 2.0 + i,
          amount: 0,
        ),
    ];

/// 弹窗宿主：接住 `showTestOhlcEditorDialog` 的返回值。
class _Host {
  TestOhlcEditorResult? captured;
  bool closed = false;
}

Future<_Host> _open(
  WidgetTester tester, {
  required List<KlineBar> bars,
  bool tickTemplate = true,
}) async {
  tester.view.physicalSize = const Size(1280, 720);
  tester.view.devicePixelRatio = 1.0;
  addTearDown(tester.view.reset);

  final host = _Host();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              host.captured = await showTestOhlcEditorDialog(
                context: ctx,
                initialBars: bars,
                tickTemplate: tickTemplate,
              );
              host.closed = true;
            },
            child: const Text('打开'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('打开'));
  await tester.pumpAndSettle();
  return host;
}

/// 表格内的第 row 行第 cell 列的 TextField（0=时间 1=开 2=高 3=低 4=收 5=量）。
/// 只找表格自身，避免把弹窗顶部「起始时间」那个 TextField 算进来。
Finder _cellAt(int row, int cell) => find
    .descendant(of: find.byType(Table), matching: find.byType(TextField))
    .at(row * 6 + cell);

String _cellText(WidgetTester tester, int row, int cell) =>
    tester.widget<TextField>(_cellAt(row, cell)).controller!.text;

/// 某行某列 ▲/▼ 步进按钮。
///
/// 分笔模板下时间格只读（无按钮），行内按钮序为「开高低收量」各两枚；
/// 自由模式下六格都有。`find.byIcon` 只枚举同一种箭头，故按「每行箭头数」定位。
Finder _stepAt(WidgetTester tester, int row, int cell, IconData icon,
    bool template) {
  final buttonsPerRow = template ? 5 : 6;
  final colStart = template ? (cell - 1).clamp(0, 4) : cell;
  final idx = row * buttonsPerRow + colStart;
  return find.byIcon(icon).at(idx);
}

/// 行数 = 行尾「+」按钮个数。
int _rowCount(WidgetTester tester) =>
    tester.widgetList(find.byIcon(Icons.add_circle_outline)).length;

Finder _rowAddAt(WidgetTester tester, int row) =>
    find.byIcon(Icons.add_circle_outline).at(row);

/// 表格自身的 Scrollable（SingleChildScrollView 内部那一个）。
Finder _tableScrollable() => find
    .descendant(of: find.byType(SingleChildScrollView), matching: find.byType(Scrollable))
    .first;
