import 'package:chan_kline/chart/level_window_layout.dart';
import 'package:chan_kline/widgets/level_window_settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 层级分窗设置弹窗：数量只能偶数、每窗层级用户指定、
/// 必须含 K0（否则弹模态警告并拒绝应用）、同一层级不得重复占用。
void main() {
  testWidgets('缺少 K0：弹模态警告并拒绝应用', (tester) async {
    await _open(tester, count: 2, slots: [1, 2]);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(find.text('无法应用'), findsOneWidget);
    expect(
      find.textContaining('必须选择 K0'),
      findsOneWidget,
      reason: '提示必须说清为什么不能应用',
    );
    // 原弹窗还在：用户可以改回去再应用。
    expect(find.text('层级分窗设置'), findsOneWidget);

    await tester.tap(find.text('知道了'));
    await tester.pumpAndSettle();
    expect(find.text('层级分窗设置'), findsOneWidget);
  });

  testWidgets('含 K0 且无重复：应用后回传数量与全部槽位', (tester) async {
    final host = await _open(tester, count: 2, slots: [0, 3]);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();

    expect(host.closed, isTrue);
    final cfg = host.captured;
    expect(cfg, isNotNull);
    expect(cfg!.count, 2);
    expect(cfg.slots.take(2).toList(), [0, 3]);
    expect(cfg.slots.length, kLevelWindowSlotCount,
        reason: '超出当前窗口数的槽位也要记住');
    expect(find.text('层级分窗设置'), findsNothing);
  });

  testWidgets('同一层级已被占用：该选项在下拉里置灰', (tester) async {
    await _open(tester, count: 2, slots: [0, 1]);

    // 第 1 个下拉是「窗口数量」，其后才是每窗层级；打开第 2 窗的层级下拉。
    await tester.tap(find.byType(DropdownButtonFormField<int>).at(2));
    await tester.pumpAndSettle();

    final items =
        tester.widgetList<DropdownMenuItem<int>>(
          find.byType(DropdownMenuItem<int>),
        ).toList();
    final zeros = items.where((e) => e.value == 0).toList();
    expect(
      zeros.where((e) => !e.enabled).length,
      1,
      reason: 'K0 已被第 1 窗占用，第 2 窗的菜单里必须置灰',
    );
    expect(
      zeros.where((e) => e.enabled).length,
      1,
      reason: '第 1 窗自己选中的 K0 仍应是可选项',
    );
    // 自己的 K1 可选。
    expect(items.any((e) => e.value == 1 && e.enabled), isTrue);
  });

  testWidgets('窗口数量只给偶数档，改数量后行数跟着变', (tester) async {
    await _open(tester, count: 2, slots: [0, 1, 2, 3]);

    expect(find.text('第 3 窗'), findsNothing);
    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();

    final values = tester
        .widgetList<DropdownMenuItem<int>>(
          find.byType(DropdownMenuItem<int>),
        )
        .map((e) => e.value)
        .toSet();
    expect(
      values.containsAll(kLevelWindowCountChoices),
      isTrue,
      reason: '数量下拉必须给出 2/4/6/8/10',
    );
    expect(values.contains(3), isFalse);
    expect(values.contains(5), isFalse);

    await tester.tap(find.text('4 窗').last);
    await tester.pumpAndSettle();

    expect(find.text('第 3 窗'), findsOneWidget);
    expect(find.text('第 4 窗'), findsOneWidget);
  });

  testWidgets('缩窗把 K0 挤出可见范围：自动换到第 1 窗并提示', (tester) async {
    await _open(tester, count: 4, slots: [2, 3, 0, 1]);

    await tester.tap(find.byType(DropdownButtonFormField<int>).first);
    await tester.pumpAndSettle();
    await tester.tap(find.text('2 窗').last);
    await tester.pumpAndSettle();

    expect(find.textContaining('已自动把 K0 换到第 1 窗'), findsOneWidget);

    await tester.tap(find.text('应用'));
    await tester.pumpAndSettle();
    expect(find.text('无法应用'), findsNothing);
    expect(find.text('层级分窗设置'), findsNothing,
        reason: 'K0 被保护后应能正常应用');
  });
}

/// 弹窗宿主：接住 `showDialog` 的返回值。
class _Host {
  LevelWindowConfig? captured;
  bool closed = false;
}

Future<_Host> _open(
  WidgetTester tester, {
  required int count,
  required List<int> slots,
}) async {
  final host = _Host();
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (ctx) => TextButton(
            onPressed: () async {
              host.captured = await showDialog<LevelWindowConfig>(
                context: ctx,
                builder: (_) => LevelWindowSettingsDialog(
                  initialCount: count,
                  initialSlots: slots,
                ),
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
