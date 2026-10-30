/// @file lib/indicator_search/indicator_search_job.dart
/// @brief 指标寻优「一次完整扫描」的唯一实现：取数 → 冻结 → 枚举 → 扫描 → 落盘。
///
/// 对话框（GUI）与 Agent API 共用本 job，禁止各写一份（R2：同源口径）。
/// 仅做编排与 IO，不新增任何缠论/回测/寻优口径。
import 'dart:io';

import 'package:chan_kline/backtest/backtest_step_harness.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/settings/indicator_search_settings_store.dart';

import 'candidate_builder.dart';
import 'indicator_search_runner.dart';
import 'search_core.dart';
import 'search_env.dart';
import 'variable_pool.dart';

/// 冻结阶段被取消：内部用于提前收尾（不向外抛）。
class _JobCancel {
  const _JobCancel();
}

/// 寻优任务参数（与对话框取数/冻结/枚举参数一一对应）。
class IndicatorSearchJobParams {
  const IndicatorSearchJobParams({
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.dataRoot,
    required this.tickSource,
    required this.mathConfig,
    required this.chipConfig,
    required this.strategyConfig,
    required this.resultsPath,
    this.logPath,
    this.featureLookup,
    this.truncationCheck = true,
    this.mainSessionHarness,
    this.initialBars,
    this.candidateOverride,
    this.scanYieldEvery = 25,
    this.maxCandidates,
    this.inRatio = 0.7,
  });

  final String code;
  final String period;
  final String beginText;
  final String endText;
  final String dataRoot;
  final String tickSource;
  final MathIndicatorConfig mathConfig;
  final ChipConfig chipConfig;
  final StrategyConfig strategyConfig;

  /// 结果 TSV 目标路径（调用方解析，GUI 与 API 各用各自路径）。
  final String resultsPath;

  /// 进度日志路径（可空 = 不写日志）。
  final String? logPath;

  final BarFeatureLookup? featureLookup;
  final bool truncationCheck;

  /// 非空时复用主界面冻结仓（跳过 harness 重冻）。
  final BacktestStepHarnessResult? mainSessionHarness;
  final List<KlineBar>? initialBars;

  /// 仅供测试注入：直接给定候选，跳过枚举。
  final List<ComboCand>? candidateOverride;

  /// 扫描让出频率（测试可设 1 以便中途取消）。
  final int scanYieldEvery;

  /// 覆盖设置里的候选上限（null = 用设置值）。
  final int? maxCandidates;

  /// 样本内比例（与 `splitBarIdx` 同口径，GUI 默认 0.7）。
  final double inRatio;
}

/// 进度回调（阶段名 + 可读说明 + 进度比例）。
class IndicatorSearchJobProgress {
  final String phase;
  final String detail;
  final double? fraction;

  /// 最近跑通的若干条（仅扫描阶段，供 GUI 实时展示）。
  final List<ComboVerdict> recentRan;

  const IndicatorSearchJobProgress({
    required this.phase,
    required this.detail,
    this.fraction,
    this.recentRan = const [],
  });
}

/// 一次寻优的结果（GUI 与 API 共用）。
class IndicatorSearchJobResult {
  final IndicatorSearchRunStats stats;
  final List<KlineBar> bars;
  final SearchEnv env;
  final int barCount;
  final int maxKn;
  final int splitX;
  final CandidateBuildSummary buildSummary;
  final IndicatorSearchAlignSnapshot align;
  final String resultsPath;
  final bool useOptimizedBuild;
  final int maxCandidates;

  const IndicatorSearchJobResult({
    required this.stats,
    required this.bars,
    required this.env,
    required this.barCount,
    required this.maxKn,
    required this.splitX,
    required this.buildSummary,
    required this.align,
    required this.resultsPath,
    required this.useOptimizedBuild,
    required this.maxCandidates,
  });

  bool get cancelled => stats.cancelled;
}

class IndicatorSearchJob {
  IndicatorSearchJob(this.params, {IndicatorSearchRunner? runner})
      : _injectedRunner = runner;

  final IndicatorSearchJobParams params;

  /// 测试注入（生产为 null，内部新建 runner）。
  final IndicatorSearchRunner? _injectedRunner;

  IndicatorSearchRunner? _runner;
  bool _cancelRequested = false;

  /// 已请求取消（扫描中或冻结中）。
  bool get cancelRequested => _cancelRequested;

  /// 请求取消：扫描阶段交给 runner，冻结阶段由进度回调抛出内部信号。
  void cancel() {
    _cancelRequested = true;
    _runner?.requestCancel();
  }

  /// 执行一次完整寻优。
  ///
  /// 返回 null 表示**冻结阶段**已取消（未产生结果）；扫描阶段取消会返回
  /// `result.cancelled == true`，并保留部分 TSV（与 GUI 口径一致）。
  Future<IndicatorSearchJobResult?> run({
    void Function(IndicatorSearchJobProgress p)? onProgress,
  }) async {
    final p = params;
    await IndicatorSearchSettingsStore.load();
    final base = IndicatorSearchSettingsStore.current;
    final settings =
        p.maxCandidates == null ? base : base.copyWith(maxCandidates: p.maxCandidates);
    final logPath = p.logPath;

    void report(
      String phase,
      String detail, {
      double? fraction,
      List<ComboVerdict> recentRan = const [],
    }) {
      onProgress?.call(
        IndicatorSearchJobProgress(
          phase: phase,
          detail: detail,
          fraction: fraction,
          recentRan: recentRan,
        ),
      );
    }

    // 1) 取数。
    report('取数', '${p.code} ${p.period}');
    List<KlineBar> bars;
    if (p.initialBars != null && p.initialBars!.isNotEmpty) {
      bars = List<KlineBar>.from(p.initialBars!);
    } else {
      final loaded = ChanBridge.instance.loadKlinesEx(
        dataRoot: p.dataRoot,
        code: p.code,
        beginDate: p.beginText,
        endDate: p.endText,
        period: p.period,
        tickSource: p.tickSource,
      );
      bars = loaded.bars;
    }
    if (bars.isEmpty) throw Exception('区间内无 K 线');
    final barCount = bars.length;
    logProgress('载入 ${bars.length} 根', logFilePath: logPath);

    // 2) 冻结（主图会话优先，缺省独立 harness）。
    final BacktestStepHarnessResult h;
    final session = p.mainSessionHarness;
    if (session != null) {
      if (session.bars.length != bars.length) {
        throw Exception(
          '主图已载入 ${session.bars.length} 根，与寻优区间 ${bars.length} 根不一致',
        );
      }
      report(
        '主图冻结',
        '复用当前会话冻结仓（与策略回测同源，共 ${bars.length} 根）',
        fraction: 1,
      );
      logProgress('复用主图会话冻结 maxKn=${session.maxKn}', logFilePath: logPath);
      h = session;
    } else {
      report('步进冻结', '共 ${bars.length} 根 K0（独立 harness，无主图会话时）',
          fraction: 0);
      final freezeStarted = DateTime.now();
      try {
        h = await driveStepHarnessWithProgress(
          bars,
          mathConfig: p.mathConfig,
          chipConfig: p.chipConfig,
          truncationCheck: p.truncationCheck,
          onProgress: (d, t) {
            if (_cancelRequested) throw const _JobCancel();
            report(
              '步进冻结',
              '冻结 $d / $t · 已用 '
                  '${DateTime.now().difference(freezeStarted).inSeconds}s',
              fraction: t <= 0 ? null : d / t,
            );
          },
        );
      } on _JobCancel {
        logProgress('cancelled during freeze', logFilePath: logPath);
        return null;
      }
      logProgress('冻结完成 maxKn=${h.maxKn}', logFilePath: logPath);
    }
    if (_cancelRequested) {
      logProgress('cancelled during freeze', logFilePath: logPath);
      return null;
    }

    // 3) 枚举候选（优化枚举 / 全量）。
    final pool = VariablePool(h.maxKn);
    final opts = settings.toBuildOptions();
    final cands = p.candidateOverride ?? buildCandidates(pool, opts);
    final buildSummary = summarizeCandidates(cands);
    logProgress(
      '候选 ${cands.length} 条 profile=${opts.profile.name} · ${buildSummary.toDisplayLine()}',
      logFilePath: logPath,
    );

    report(
      '回测扫描',
      '候选 ${cands.length} 条 · 预编译复用 · 全量列出（不筛选/不排名）',
      fraction: 0,
    );

    // 4) 扫描（样本内外各独立回测）。
    final workbenchAlign = SearchWorkbenchAlign(
      strategyTemplate: p.strategyConfig,
      features: p.featureLookup,
      bucketStep: p.chipConfig.bucketStep,
      bollN: p.mathConfig.bollN,
      donchianN: p.mathConfig.donchianN,
      regressK: p.mathConfig.regressK,
    );
    final align = IndicatorSearchAlignSnapshot.fromAlign(workbenchAlign);
    final env = SearchEnv(
      bars,
      h,
      p.code,
      p.period,
      p.beginText,
      p.endText,
      align: workbenchAlign,
    );

    final tmpResults = '${p.resultsPath}.tmp';
    try {
      File(tmpResults).writeAsStringSync('');
    } catch (_) {}
    final sink = VerdictSink(tmpResults);
    final runner = _injectedRunner ?? IndicatorSearchRunner();
    _runner = runner;
    if (_cancelRequested) runner.requestCancel();
    final stats = await runner.runAll(
      bars: bars,
      env: env,
      cands: cands,
      maxKn: h.maxKn,
      yieldEvery: p.scanYieldEvery,
      inRatio: p.inRatio,
      sink: sink,
      onProgress: (prog) {
        report(
          '回测扫描',
          '${prog.done}/${prog.total} · 编译${prog.compiled} 跑通${prog.ran} · '
              '已用 ${prog.elapsed?.inMinutes ?? 0}m${(prog.elapsed?.inSeconds ?? 0) % 60}s · '
              '剩余 ${_fmtEta(prog.eta)}',
          fraction: prog.phaseFraction,
          recentRan: prog.recentRan,
        );
        logProgress(
          '扫描 ${prog.done}/${prog.total} 跑通${prog.ran} eta=${_fmtEta(prog.eta)}',
          logFilePath: logPath,
        );
      },
    );
    sink.close();
    _runner = null;

    // 5) 结果落盘（取消也保留部分 TSV，与 GUI 一致）。
    _promoteTmp(tmpResults, p.resultsPath);
    logProgress(
      stats.cancelled
          ? 'cancelled at ${stats.ran}/${stats.total}'
          : '完成 跑通${stats.ran} 耗时${stats.elapsed.inSeconds}s',
      logFilePath: logPath,
    );

    return IndicatorSearchJobResult(
      stats: stats,
      bars: bars,
      env: env,
      barCount: barCount,
      maxKn: h.maxKn,
      splitX: stats.splitX,
      buildSummary: buildSummary,
      align: align,
      resultsPath: p.resultsPath,
      useOptimizedBuild: settings.useOptimizedBuild,
      maxCandidates: settings.maxCandidates,
    );
  }

  /// tmp → 正式名：rename 失败时 copy+delete（Windows 占用兜底）。
  static void _promoteTmp(String tmp, String target) {
    try {
      File(tmp).renameSync(target);
    } catch (_) {
      try {
        File(tmp).copySync(target);
        File(tmp).deleteSync();
      } catch (_) {}
    }
  }
}

String _fmtEta(Duration? d) {
  if (d == null) return '—';
  if (d.inHours > 0) return '约 ${d.inHours}h${d.inMinutes % 60}m';
  if (d.inMinutes > 0) return '约 ${d.inMinutes}m${d.inSeconds % 60}s';
  return '约 ${d.inSeconds}s';
}
