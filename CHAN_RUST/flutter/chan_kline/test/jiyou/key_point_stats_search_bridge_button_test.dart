import 'dart:io';

import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/key_point_stats/key_point_stat_runner.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/settings/key_point_stats_settings_store.dart';
import 'package:chan_kline/widgets/key_point_stats_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

/// 计优「拿去寻优」按钮的回归。
///
/// 钉死一件事：计优算出的组合区分度，能通过按钮变成寻优候选交回主界面，
/// 而不是只躺在面板上给人看。

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

/// 顶组 RSI/KDJ 都明显高于底组，两个指标同向 → 会产出组合。
Map<String, dynamic> _row(int idx, {required String fx}) {
  final isTop = fx == 'TOP';
  return {
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
      'rsi_0': isTop ? 75.0 + idx : 25.0 + idx,
      'kdj_k_0': isTop ? 80.0 + idx : 20.0 + idx,
      'fractal_judgment_0': fx,
    },
  };
}

/// 4 个顶 + 4 个底，前 3 个底在切点（20 根的 70% = 14）之前确认。
List<K0ConfirmSignal> _signals() => [
      for (var i = 0; i < 4; i++)
        K0ConfirmSignal(
          x: i * 2 + 1,
          fx: 'TOP',
          value: 1,
          fractalX1: i * 2,
          fractalX2: i * 2,
        ),
      for (var i = 4; i < 8; i++)
        K0ConfirmSignal(
          x: i * 2 + 1,
          fx: 'BOTTOM',
          value: -1,
          fractalX1: i * 2,
          fractalX2: i * 2,
        ),
    ];

Map<int, Map<String, dynamic>> _byIdx() => {
      for (final s in _signals())
        s.fractalX1: _row(s.fractalX1, fx: s.fx),
    };

KeyPointStatResult _result() {
  final bs = _bars(20);
  return KeyPointStatRunner.run(
    lookup: BarFeatureLookup.fromCached(byIdx: _byIdx()),
    collect: collectKeyPoints(
      bars: bs,
      levels: const [],
      k0Confirms: _signals(),
      asOf: 19,
    ),
    settings: const KeyPointStatSettings(),
    code: '002003',
    period: '1m',
    barCount: 20,
    maxKn: 1,
  );
}

/// testWidgets 跑在 FakeAsync 里：path_provider 取路径与 JSON/TSV 落盘是真实 IO，
/// 只在 [WidgetTester.runAsync] 里推进；对话框阶段切换挂 `Future.delayed(Duration.zero)`，
/// 属 FakeAsync 定时器，要用带时长的 pump 才能排空。两者交替几轮，对话框就跑完。
Future<void> settleDialog(WidgetTester tester) async {
  for (var i = 0; i < 20; i++) {
    await tester.runAsync(
      () => Future<void>.delayed(const Duration(milliseconds: 5)),
    );
    await tester.pump(const Duration(milliseconds: 1));
  }
}

void main() {
  late Directory tmp;

  setUpAll(() {
    tmp = Directory.systemTemp.createTempSync('jiyou_bridge_button_test');
    PathProviderPlatform.instance = _FakePathProvider(tmp.path);
  });

  tearDownAll(() {
    // 并行跑全套时，落盘句柄可能还没完全释放；清理失败不该判测试失败。
    try {
      if (tmp.existsSync()) tmp.deleteSync(recursive: true);
    } on FileSystemException {
      // 交给系统临时目录回收。
    }
  });

  testWidgets('有组合时出现「拿去寻优」，点击后把候选交回主界面', (tester) async {
    final result = _result();
    expect(result.comboContrasts, isNotEmpty,
        reason: '两个同向指标应产出组合区分度');

    List<ComboCand>? captured;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => KeyPointStatsDialog(
                    code: '002003',
                    period: '1m',
                    beginText: '2004/07/19 09:30:00',
                    endText: '2004/07/20 15:00:00',
                    bars: _bars(20),
                    levels: const [],
                    lookup: BarFeatureLookup.fromCached(byIdx: _byIdx()),
                    maxKn: 1,
                    k0Confirms: _signals(),
                    resultOverride: result,
                    onSearchWithCombos: (cands) async => captured = cands,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await settleDialog(tester);

    expect(find.text('拿去寻优'), findsOneWidget);
    await tester.tap(find.text('拿去寻优'));
    await settleDialog(tester);

    expect(captured, isNotNull);
    expect(captured!, isNotEmpty);
    // 每个候选都必须是可编译的买卖条件，而不是半截。
    for (final c in captured!) {
      expect(c.buyAst, isNotNull);
      expect(c.sellAst, isNotNull);
      expect(c.name, startsWith('计优组合｜'));
    }
  });

  testWidgets('没有回调时不显示「拿去寻优」', (tester) async {
    final result = _result();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => Center(
            child: TextButton(
              onPressed: () {
                showDialog<void>(
                  context: context,
                  builder: (_) => KeyPointStatsDialog(
                    code: '002003',
                    period: '1m',
                    beginText: '2004/07/19 09:30:00',
                    endText: '2004/07/20 15:00:00',
                    bars: _bars(20),
                    levels: const [],
                    lookup: BarFeatureLookup.fromCached(byIdx: {}),
                    maxKn: 1,
                    resultOverride: result,
                  ),
                );
              },
              child: const Text('打开'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('打开'));
    await settleDialog(tester);
    expect(find.text('拿去寻优'), findsNothing);
  });
}
