import 'dart:async';
import 'dart:io';

import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/indicator_search/candidate_builder.dart';
import 'package:chan_kline/indicator_search/indicator_search_runner.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/indicator_search/search_env.dart';
import 'package:chan_kline/indicator_search/variable_pool.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/widgets/indicator_search_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import '../synth_bars.dart';

/// 测试环境无平台插件：把 path_provider 指到临时目录，
/// 让对话框的进度日志 / TSV 落盘可用（否则 _run() 在取路径时就夭折）。
class _TempPathProvider extends PathProviderPlatform {
  _TempPathProvider(this.root);

  final String root;

  @override
  Future<String?> getApplicationSupportPath() async => root;

  @override
  Future<String?> getApplicationDocumentsPath() async => root;

  @override
  Future<String?> getTemporaryPath() async => root;

  @override
  Future<String?> getApplicationCachePath() async => root;

  @override
  Future<String?> getLibraryPath() async => root;

  @override
  Future<String?> getDownloadsPath() async => root;
}

void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2004/07/19 09:30:00';
  const end = '2004/07/20 15:00:00';

  group('取消扫描：Runner 语义', () {
    test(
      '扫描开始后 requestCancel → stats.cancelled=true 且提前收尾',
      () async {
        final bridge = ChanBridge.instance;
        bridge.ensureInitialized();
        final bars = bridge
            .loadKlinesEx(
              dataRoot: bridge.defaultDataRoot(),
              code: code,
              beginDate: begin,
              endDate: end,
              period: period,
              tickSource: 'protocol',
            )
            .bars;
        expect(bars.length, greaterThan(100));
        final h = await driveStepHarness(bars);
        final env = SearchEnv(bars, h, code, period, begin, end);
        final cands = buildCandidates(
          VariablePool(h.maxKn),
          const CandidateBuildOptions.optimized(maxCandidates: 300),
        );
        expect(cands.length, greaterThan(20));

        final runner = IndicatorSearchRunner();
        final stats = await runner.runAll(
          bars: bars,
          env: env,
          cands: cands,
          gate: const PassGate(minTrades: 2),
          maxKn: h.maxKn,
          yieldEvery: 1,
          onProgress: (p) {
            // 第一次进度回调就请求取消
            if (p.done >= 1) runner.requestCancel();
          },
        );

        expect(stats.cancelled, isTrue);
        // 取消后保留已跑出的部分结果（供「保留部分 TSV」文案）
        expect(stats.verdicts, isNotEmpty);
        expect(stats.ran, lessThan(cands.length));
        expect(stats.ran, stats.verdicts.length);
      },
      timeout: const Timeout(Duration(minutes: 10)),
    );

    test('未取消时 stats.cancelled=false', () async {
      final bridge = ChanBridge.instance;
      bridge.ensureInitialized();
      final bars = bridge
          .loadKlinesEx(
            dataRoot: bridge.defaultDataRoot(),
            code: code,
            beginDate: begin,
            endDate: end,
            period: period,
            tickSource: 'protocol',
          )
          .bars;
      final h = await driveStepHarness(bars);
      final env = SearchEnv(bars, h, code, period, begin, end);
      final cands = buildCandidates(
        VariablePool(h.maxKn),
        const CandidateBuildOptions.optimized(maxCandidates: 20),
      );
      final runner = IndicatorSearchRunner();
      final stats = await runner.runAll(
        bars: bars,
        env: env,
        cands: cands,
        gate: const PassGate(minTrades: 2),
        maxKn: h.maxKn,
      );
      expect(stats.cancelled, isFalse);
    }, timeout: const Timeout(Duration(minutes: 10)));
  });

  group('取消扫描：对话框 UI', () {
    testWidgets('点「取消扫描」→ 阶段变「已取消」并保留结果面板', (tester) async {
      tester.view.physicalSize = const Size(1400, 1200);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.reset);

      // 注入临时落盘目录（对话框 _run() 取 path_provider 路径）
      final tmp = Directory.systemTemp.createTempSync('chan_search_cancel');
      addTearDown(() {
        try {
          tmp.deleteSync(recursive: true);
        } catch (_) {}
      });
      PathProviderPlatform.instance = _TempPathProvider(tmp.path);

      final bridge = ChanBridge.instance;
      bridge.ensureInitialized();
      // 用小规模合成 K 线：UI 层只验「取消」这条链路，不依赖数据规模；
      // 真实数据口径已由同文件的 Runner 层用例覆盖。
      final bars = synthZigzag(legs: 10, legLen: 6, step: 0.5, base: 10.0);
      expect(bars.length, 60);

      // testWidgets 跑在 FakeAsync 里：FFI 冻结等真实异步必须放进 runAsync，
      // 否则 await 永不完成（表现为测试一直挂着）。
      late final BacktestStepHarnessResult harness;
      await tester.runAsync(() async {
        harness = await driveStepHarness(bars);
      });
      expect(harness.bars.length, bars.length);

      // 候选直接注入（跳过 2000 条枚举）：UI 层只需一条能跑起来的候选。
      final cands = await tester.runAsync(
        () async => buildCandidates(
          VariablePool(harness.maxKn),
          const CandidateBuildOptions.legacyFull(),
        ),
      );
      final candsShort = cands!.take(40).toList();
      expect(candsShort.length, 40);

      // 关键（FakeAsync 两面性，缺一不可）：
      // 1) 真实 IO / FFI（取路径、TSV 落盘）只在 runAsync 里推进；
      // 2) 扫描循环挂在 Future.delayed(Duration.zero) 上，属 FakeAsync 定时器，
      //    只能 pump() 逐步推进；且必须用**无时长** pump —— pump(duration)
      //    会把窗口内零时长定时器一次性排空，一次就把候选全跑完，来不及取消。
      // 因此候选给 40 条 + yieldEvery=1（每条都让出）+ 无时长 pump，
      // 取消时机才稳定可复现。
      var cancelSignalled = false;
      final runner = IndicatorSearchRunner(
        onCancelRequested: () => cancelSignalled = true,
      );
      var runnerCreated = false;

      // 必须走 showDialog：IndicatorSearchDialog.build 返回 AlertDialog，
      // 直接塞进 body 不会构建出按钮（需 Dialog 路由内的 Overlay）。
      await tester.pumpWidget(
        const MaterialApp(home: Scaffold(body: SizedBox.shrink())),
      );
      unawaited(
        showDialog<void>(
          context: tester.element(find.byType(Scaffold)),
          builder: (ctx) => IndicatorSearchDialog(
            code: code,
            period: period,
            beginText: begin,
            endText: end,
            dataRoot: bridge.defaultDataRoot(),
            tickSource: 'protocol',
            mathConfig: const MathIndicatorConfig(),
            chipConfig: const ChipConfig(),
            strategyConfig: const StrategyConfig(),
            initialBars: bars,
            mainSessionHarness: harness,
            candidateOverride: candsShort,
            scanYieldEvery: 1,
            runnerFactory: () {
              runnerCreated = true;
              return runner;
            },
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(find.text('指标寻优'), findsOneWidget);
      expect(find.text('取消扫描'), findsOneWidget);

      // 「取消扫描」按钮从 initState 起就存在（_running 初值 true），
      // 但点击要生效必须 _activeRunner 已创建（在「回测扫描」阶段之后）。
      // _run() 内是真实异步（FFI 冻结 / 回测），必须用 runAsync 推进，
      // 单靠 tester.pump() 会让阶段卡在「准备」。
      //
      // 这里循环点击：既避开「阶段已变但 runner 还没建好」的竞态，
      // 也不必赌取消时机落在扫描中段。
      // 关键（FakeAsync 两面性，缺一不可）：
      // 1) 真实 IO / FFI（取路径、冻结、TSV 落盘）只在 runAsync 里推进；
      // 2) 扫描循环挂在 Future.delayed(Duration.zero) 上，属 FakeAsync 定时器，
      //    只能 pump() 逐步推进；且必须用**无时长** pump —— pump(duration)
      //    会把窗口内零时长定时器一次性排空，一次就把 2000 条跑完，来不及取消。
      //
      // 取消时机：阶段切到「回测扫描」即 _activeRunner 已创建（runnerCreated）。
      // 点一次即可 —— onCancelRequested 钩子会证明取消信号确实送达扫描器。
      var steps = 0;
      var tapped = false;
      var cancelled = false;
      while (steps < 400 && !cancelled) {
        // 真实 IO（path_provider 取路径、TSV 落盘）只在 runAsync 里推进。
        if (tapped) {
          // 已点取消：改用**带时长** pump。扫描循环挂在
          // Future.delayed(Duration.zero) 上，无时长 pump 不会唤醒它，
          // 必须给 pump 一个时长才会推进到循环开头的取消检查。
          await tester.pump(const Duration(milliseconds: 1));
        } else {
          // 还没点：每轮 runAsync(真实 IO) + 无时长 pump(避免一次跑完 40 条)，
          // 让「回测扫描」阶段先稳定出现。
          await tester.runAsync(
            () => Future<void>.delayed(const Duration(milliseconds: 1)),
          );
          await tester.pump();
        }
        steps++;
        if (find.textContaining('阶段：已取消').evaluate().isNotEmpty) {
          cancelled = true;
          break;
        }
        if (!tapped &&
            runnerCreated &&
            find.text('取消扫描').evaluate().isNotEmpty) {
          await tester.tap(find.text('取消扫描'));
          await tester.pump();
          tapped = true;
        }
      }
      expect(runnerCreated, isTrue, reason: '扫描器未被创建，无法验证取消');
      expect(tapped, isTrue, reason: '未能在扫描阶段点到「取消扫描」');
      // 取消信号确实送到了扫描器（不只是按钮被点了一下）
      expect(cancelSignalled, isTrue, reason: '点取消后扫描器未收到取消信号');
      expect(
        cancelled,
        isTrue,
        reason: () {
          final all = tester
              .widgetList<Text>(find.byType(Text))
              .map((t) => t.data ?? '')
              .where((s) => s.isNotEmpty)
              .toList();
          return 'pump $steps 步后仍未见「已取消」，当前界面文本：$all';
        }(),
      );
      expect(find.textContaining('阶段：已取消'), findsOneWidget);

      expect(find.text('取消扫描'), findsNothing);
      // 取消后仍展示结果面板（保留部分 TSV）
      expect(find.textContaining('保留部分 TSV'), findsOneWidget);
    }, timeout: const Timeout(Duration(minutes: 5)));
  });
}
