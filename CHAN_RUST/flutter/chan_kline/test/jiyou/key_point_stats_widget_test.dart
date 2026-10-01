import 'dart:io';

import 'package:chan_kline/key_point_stats/key_point.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:chan_kline/widgets/key_point_stats_dialog.dart';
import 'package:chan_kline/widgets/key_point_stats_result_panel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

class _FakePathProvider extends PathProviderPlatform {
  _FakePathProvider(this.root);
  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;
}

List<KlineBar> _bars(int n) => [
      for (var i = 0; i < n; i++)
        KlineBar(
          idx: i,
          timeMs: i * 60000,
          timeText: '2004/07/19 09:30:00',
          open: 10 + i.toDouble(),
          high: 12 + i.toDouble(),
          low: 8 + i.toDouble(),
          close: 11 + i.toDouble(),
          volume: 1000 + i.toDouble(),
          amount: 2000 + i.toDouble(),
        ),
    ];

Map<String, dynamic> _row(int idx, {required String fx}) => {
      'idx': idx,
      'time_ms': idx * 60000,
      'time_text': '2004/07/19 09:30:00',
      'weekday': '-',
      'open': 10.0,
      'high': 12.0,
      'low': 8.0,
      'close': 10.0 + idx,
      'volume': 1000 + idx.toDouble(),
      'combine_fx': fx,
      'sub': <String, dynamic>{
        'rsi_0': 40.0 + idx,
        'fractal_judgment_0': fx,
      },
    };

KeyPointStatResult _result({int topCount = 3, int bottomCount = 3}) {
  final pts = <KeyPoint>[
    for (var i = 0; i < topCount; i++)
      KeyPoint(
        level: 1,
        fx: 'TOP',
        poleX: i * 3,
        confirmX: i * 3 + 1,
        source: 't',
      ),
    for (var i = 0; i < bottomCount; i++)
      KeyPoint(
        level: 1,
        fx: 'BOTTOM',
        poleX: i * 3 + 1,
        confirmX: i * 3 + 2,
        source: 't',
      ),
  ];
  final lookup = BarFeatureLookup.fromCached(
    byIdx: {
      for (var i = 0; i < topCount + bottomCount; i++)
        i: _row(i, fx: i.isEven ? 'TOP' : 'BOTTOM'),
    },
  );
  return KeyPointStatRunner.run(
    lookup: lookup,
    collect: KeyPointCollectResult(keyPoints: pts),
    settings: const KeyPointStatSettings(),
    code: '002003',
    period: '1m',
    barCount: 12,
    maxKn: 1,
  );
}
void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('jiyou_key_point_stat_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() {
    if (tmp.existsSync()) tmp.deleteSync(recursive: true);
  });

  Future<void> pumpPanel(WidgetTester tester, KeyPointStatResult r) async {
    tester.view.physicalSize = const Size(1500, 1100);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: KeyPointStatsResultPanel(
            result: r,
            jsonPath: 'D:/tmp/key_point_stats_002003_1m.json',
            tsvPath: 'D:/tmp/key_point_stats_002003_1m.tsv',
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
  }

  /// testWidgets 跑在 FakeAsync 里：path_provider 取路径与 JSON/TSV 落盘是**真实 IO**，
  /// 只在 [WidgetTester.runAsync] 里推进；对话框阶段切换挂 `Future.delayed(Duration.zero)`，
  /// 属 FakeAsync 定时器，要用**带时长** pump 才能排空。两者交替几轮，对话框就跑完。
  Future<void> settleDialog(WidgetTester tester) async {
    for (var i = 0; i < 20; i++) {
      await tester.runAsync(
        () => Future<void>.delayed(const Duration(milliseconds: 5)),
      );
      await tester.pump(const Duration(milliseconds: 1));
    }
  }

  group('计优结果面板（UI 层）', () {
    testWidgets('渲染口径行：极点K取值 + 事后统计 + 众数分桶提示', (tester) async {
      await pumpPanel(tester, _result());
      expect(find.textContaining('转折极点 K'), findsWidgets);
      expect(find.textContaining('事后统计'), findsWidgets);
      expect(find.textContaining('分桶近似'), findsWidgets);
    });

    testWidgets('Tab 按「级别 × 顶/底 + 全部汇总」分组并带转折点数', (tester) async {
      await pumpPanel(tester, _result());
      expect(find.text('K1 顶 (3)'), findsOneWidget);
      expect(find.text('K1 底 (3)'), findsOneWidget);
      expect(find.text('全部转折点 (6)'), findsOneWidget);
    });

    testWidgets('表头列出平均数 / 中位数 / 标准差 / 众数', (tester) async {
      await pumpPanel(tester, _result());
      // 表头带排序箭头（当前列渲染成「指标 ↑」），故用包含匹配。
      expect(find.textContaining('指标'), findsWidgets);
      expect(find.textContaining('平均数'), findsWidgets);
      expect(find.textContaining('中位数'), findsWidgets);
      expect(find.textContaining('标准差'), findsWidgets);
      expect(find.textContaining('众数'), findsWidgets);
    });

    testWidgets('过滤：切到「类别型」后看不到数值型指标', (tester) async {
      await pumpPanel(tester, _result());
      expect(find.textContaining('类别 combine_fx'), findsWidgets);
      await tester.tap(find.widgetWithText(ChoiceChip, '类别型'));
      await tester.pumpAndSettle();
      expect(find.textContaining('类别 combine_fx'), findsWidgets);
      expect(find.textContaining('sub.rsi_0'), findsNothing);
    });

    testWidgets('摘要行给出关键点数 / 分组数 / 落盘路径', (tester) async {
      await pumpPanel(tester, _result());
      expect(find.textContaining('关键点位 6 个'), findsWidgets);
      expect(find.textContaining('统计分组 3 张'), findsWidgets);
      expect(find.textContaining('key_point_stats_002003_1m.tsv'), findsWidgets);
    });

    testWidgets('无转折点时给出中文引导而不是空白表', (tester) async {
      final empty = KeyPointStatRunner.run(
        lookup: BarFeatureLookup.fromCached(byIdx: const {}),
        collect: const KeyPointCollectResult(keyPoints: []),
        settings: const KeyPointStatSettings(),
      );
      await pumpPanel(tester, empty);
      expect(find.textContaining('还没有已确认的连线转折点'), findsOneWidget);
    });
  });
group('计优对话框', () {
    testWidgets('注入结果 → 渲染统计面板并可关闭', (tester) async {
      tester.view.physicalSize = const Size(1500, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      var closed = false;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () async {
                  await showDialog<void>(
                    context: ctx,
                    barrierDismissible: false,
                    builder: (_) => KeyPointStatsDialog(
                      code: '002003',
                      period: '1m',
                      beginText: '2004/07/19 09:30:00',
                      endText: '2004/07/20 15:00:00',
                      bars: _bars(12),
                      levels: const [],
                      lookup: BarFeatureLookup.fromCached(
                        byIdx: {0: _row(0, fx: 'TOP')},
                      ),
                      maxKn: 1,
                      resultOverride: _result(),
                    ),
                  );
                  closed = true;
                },
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );

      await tester.tap(find.text('打开'));
      await settleDialog(tester);
      expect(find.text('计优 · 002003 1m'), findsOneWidget);
      expect(find.textContaining('转折极点 K'), findsWidgets);

      await tester.tap(find.text('关闭'));
      await tester.pumpAndSettle();
      expect(closed, isTrue);
    });

    testWidgets('账本为空时给出中文报错，不静默出空表', (tester) async {
      tester.view.physicalSize = const Size(1500, 1100);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => showDialog<void>(
                  context: ctx,
                  builder: (_) => KeyPointStatsDialog(
                    code: '002003',
                    period: '1m',
                    beginText: 'b',
                    endText: 'e',
                    bars: _bars(3),
                    levels: const [],
                    lookup: BarFeatureLookup.fromCached(byIdx: const {}),
                    maxKn: 0,
                  ),
                ),
                child: const Text('打开'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('打开'));
      await settleDialog(tester);
      expect(find.textContaining('主图冻结账为空'), findsOneWidget);
    });
  });
}