import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/chan_bridge.dart';
import '../indicator_search/candidate_builder.dart';
import '../indicator_search/indicator_search_runner.dart';
import '../indicator_search/search_core.dart';
import '../indicator_search/search_env.dart';
import '../indicator_search/variable_pool.dart';
import '../indicator_search/search_verdict_views.dart';
import '../backtest/backtest_step_harness.dart';
import '../backtest/backtest_run.dart';
import '../backtest/backtest_report_panel.dart';
import '../backtest/strategy_config.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chip_config.dart';
import '../models/kline_bar.dart';
import '../models/math_indicator_config.dart';
import '../settings/indicator_search_last_result_store.dart';
import '../settings/indicator_search_settings_store.dart';
import 'indicator_search_result_panel.dart';

/// 冻结阶段取消了扫描：用于从 harness onProgress 抛出、提前收尾。
class _SearchCancel {
  const _SearchCancel();
}

class IndicatorSearchDialog extends StatefulWidget {
  const IndicatorSearchDialog({
    super.key,
    required this.code,
    required this.period,
    required this.beginText,
    required this.endText,
    required this.dataRoot,
    required this.tickSource,
    required this.mathConfig,
    required this.chipConfig,
    required this.strategyConfig,
    this.featureLookup,
    this.truncationCheck = true,
    this.mainSessionHarness,
    this.initialBars,
    this.runnerFactory,
    this.candidateOverride,
    this.scanYieldEvery,
    this.onApplyToChart,
    this.enablePreview = true,
    this.onCacheSession,
    this.restoreSnapshot,
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
  final BarFeatureLookup? featureLookup;
  final bool truncationCheck;

  /// 非空时直接复用主界面冻结仓，跳过 harness 重冻。
  final BacktestStepHarnessResult? mainSessionHarness;
  final List<KlineBar>? initialBars;

  /// 仅供机器人验证的 Widget 测试注入：替换扫描器（生产路径为 null）。
  final IndicatorSearchRunner Function()? runnerFactory;

  /// 仅供机器人验证的 Widget 测试注入：直接给定候选，跳过枚举。
  final List<ComboCand>? candidateOverride;

  /// 仅供机器人验证的 Widget 测试注入：扫描让出频率（生产为 null → 默认 25）。
  /// 设为 1 可让每条候选之间都让出事件循环，便于测试在中途点「取消扫描」。
  final int? scanYieldEvery;

  /// 眼睛覆盖层「在 K 线图查看」回调：把该行买卖条件替换当前策略后跑出的回测
  /// 投到主界面 K 线图（由主界面负责关弹窗并上图）。null 时按钮隐藏（如快照界面）。
  final void Function(BacktestRun run, StrategyConfig appliedConfig)? onApplyToChart;

  /// 是否允许眼睛预览（需当前界面能即时重跑回测）。
  /// 快照与当前主图区间不一致时为 false，眼睛置灰并给提示。
  final bool enablePreview;

  /// 点击「在 K 线图查看」时，把可恢复的会话（排序/展开/身份）回传给主界面，
  /// 供「返回寻优结果」原样恢复（无需重扫）。
  final void Function(IndicatorSearchSessionSnapshot)? onCacheSession;

  /// 恢复模式：非空时跳过 _run，直接用快照 verdicts 渲染（上次结果 / 返回寻优）。
  final IndicatorSearchSessionSnapshot? restoreSnapshot;

  @override
  State<IndicatorSearchDialog> createState() => _IndicatorSearchDialogState();
}

class _IndicatorSearchDialogState extends State<IndicatorSearchDialog> {
  String _phase = '准备';
  String _detail = '';
  double? _progress;
  bool _running = true;
  bool _cancelling = false;
  bool _searchCancelled = false;
  String? _error;
  IndicatorSearchRunStats? _stats;
  List<ComboVerdict> _liveRan = const [];
  String? _resultsPath;
  int _barCount = 0;
  int _maxKn = 0;
  int _splitX = 0;
  IndicatorSearchSettings _settings = IndicatorSearchSettingsStore.current;
  CandidateBuildSummary? _buildSummary;
  IndicatorSearchAlignSnapshot? _alignSnap;
  IndicatorSearchRunner? _activeRunner;
  SearchEnv? _env;
  List<KlineBar> _bars = const [];

  /// 排序 / 展开状态上提到对话框，便于「返回寻优结果」原样恢复。
  VerdictSortState _sort = const VerdictSortState();
  int? _expanded;

  /// 眼睛按钮打开的回测预览（覆盖层）；非空时覆盖结果表但寻优弹窗保持挂载。
  BacktestRun? _previewRun;
  ComboVerdict? _previewVerdict;
  BacktestReportTab _previewTab = BacktestReportTab.metrics;

  @override
  void initState() {
    super.initState();
    if (widget.restoreSnapshot != null) {
      _initFromSnapshot();
    } else {
      _run();
    }
  }

  void _initFromSnapshot() {
    final s = widget.restoreSnapshot!;
    _stats = IndicatorSearchRunStats(
      compiled: s.compiled,
      ran: s.ran,
      total: s.verdicts.length,
      splitX: s.splitX,
      verdicts: s.verdicts,
      elapsed: s.elapsed,
    );
    _splitX = s.splitX;
    _alignSnap = s.align;
    _buildSummary = s.buildSummary;
    _maxKn = s.maxKn;
    _barCount = s.barCount;
    _sort = s.sort;
    _expanded = s.expanded;
    // 恢复模式也必须有 TSV 路径：结果表的渲染条件是 `_stats != null && _resultsPath != null`，
    // 旧实现恢复时留空 → 表格整块不渲染（表现为「图表为空」）。
    _resultsPath = s.resultsFilePath.isNotEmpty ? s.resultsFilePath : null;
    if (widget.mainSessionHarness != null &&
        widget.initialBars != null &&
        widget.initialBars!.isNotEmpty) {
      final h = widget.mainSessionHarness!;
      _bars = List<KlineBar>.from(widget.initialBars!);
      _env = SearchEnv(
        _bars,
        h,
        widget.code,
        widget.period,
        widget.beginText,
        widget.endText,
        align: s.align?.toAlign(),
      );
    }
    setState(() {
      _running = false;
      _phase = '完成';
      _detail = '恢复上次寻优结果（${s.verdicts.length} 条）';
      _progress = 1;
    });
    // 旧快照无路径字段：异步补一次默认 TSV 路径，保证结果表可渲染。
    if (_resultsPath == null) _resolveResultsPathFallback();
  }

  Future<void> _resolveResultsPathFallback() async {
    try {
      final f = await IndicatorSearchSettingsStore.resultsFile();
      if (!mounted || _resultsPath != null) return;
      setState(() => _resultsPath = f.path);
    } catch (_) {}
  }

  String _fmtEta(Duration? d) {
    if (d == null) return '—';
    if (d.inHours > 0) return '约 ${d.inHours}h${d.inMinutes % 60}m';
    if (d.inMinutes > 0) return '约 ${d.inMinutes}m${d.inSeconds % 60}s';
    return '约 ${d.inSeconds}s';
  }

  Future<void> _run() async {
    await IndicatorSearchSettingsStore.load();
    _settings = IndicatorSearchSettingsStore.current;
    final logPath = (await IndicatorSearchSettingsStore.logFile()).path;
    _resultsPath = (await IndicatorSearchSettingsStore.resultsFile()).path;
    try {
      setState(() {
        _phase = '取数';
        _detail = '${widget.code} ${widget.period}';
        _progress = null;
      });
      List<KlineBar> bars;
      if (widget.initialBars != null && widget.initialBars!.isNotEmpty) {
        bars = List<KlineBar>.from(widget.initialBars!);
      } else {
        final loaded = ChanBridge.instance.loadKlinesEx(
          dataRoot: widget.dataRoot,
          code: widget.code,
          beginDate: widget.beginText,
          endDate: widget.endText,
          period: widget.period,
          tickSource: widget.tickSource,
        );
        bars = loaded.bars;
      }
      if (bars.isEmpty) throw Exception('区间内无 K 线');
      _barCount = bars.length;
      _splitX = splitBarIdx(bars);
      logProgress('载入 ${bars.length} 根', logFilePath: logPath);

      final BacktestStepHarnessResult h;
      final session = widget.mainSessionHarness;
      if (session != null) {
        if (session.bars.length != bars.length) {
          throw Exception(
            '主图已载入 ${session.bars.length} 根，与寻优区间 ${bars.length} 根不一致',
          );
        }
        setState(() {
          _phase = '主图冻结';
          _detail = '复用当前会话冻结仓（与策略回测同源，共 ${bars.length} 根）';
          _progress = 1;
        });
        logProgress('复用主图会话冻结 maxKn=${session.maxKn}', logFilePath: logPath);
        h = session;
      } else {
        setState(() {
          _phase = '步进冻结';
          _detail = '共 ${bars.length} 根 K0（独立 harness，无主图会话时）';
          _progress = 0;
        });
        final freezeStarted = DateTime.now();
        try {
          h = await driveStepHarnessWithProgress(
            bars,
            mathConfig: widget.mathConfig,
            chipConfig: widget.chipConfig,
            truncationCheck: widget.truncationCheck,
            onProgress: (d, t) {
              if (_searchCancelled) throw const _SearchCancel();
              if (!mounted) return;
              setState(() {
                _progress = d / t;
                _detail = '冻结 $d / $t · 已用 '
                    '${DateTime.now().difference(freezeStarted).inSeconds}s';
              });
            },
          );
        } on _SearchCancel {
          if (!mounted) return;
          setState(() {
            _running = false;
            _phase = '已取消';
            _detail = '冻结阶段已取消（未产生结果）';
            _progress = 1;
          });
          logProgress('cancelled during freeze', logFilePath: logPath);
          return;
        }
        logProgress('冻结完成 maxKn=${h.maxKn}', logFilePath: logPath);
      }
      _maxKn = h.maxKn;

      final pool = VariablePool(h.maxKn);
      final opts = _settings.toBuildOptions();
      final cands = widget.candidateOverride ?? buildCandidates(pool, opts);
      _buildSummary = summarizeCandidates(cands);
      logProgress(
        '候选 ${cands.length} 条 profile=${opts.profile.name} · ${_buildSummary!.toDisplayLine()}',
        logFilePath: logPath,
      );

      setState(() {
        _phase = '回测扫描';
        _detail = '候选 ${cands.length} 条 · 预编译复用 · 全量列出（不筛选/不排名）';
        _progress = 0;
        _liveRan = const [];
      });

      final workbenchAlign = SearchWorkbenchAlign(
        strategyTemplate: widget.strategyConfig,
        features: widget.featureLookup,
        bucketStep: widget.chipConfig.bucketStep,
        bollN: widget.mathConfig.bollN,
        donchianN: widget.mathConfig.donchianN,
        regressK: widget.mathConfig.regressK,
      );
      _alignSnap = IndicatorSearchAlignSnapshot.fromAlign(workbenchAlign);
      final env = SearchEnv(
        bars,
        h,
        widget.code,
        widget.period,
        widget.beginText,
        widget.endText,
        align: workbenchAlign,
      );
      _env = env;
      _bars = bars;
      final tmpResults = '${_resultsPath!}.tmp';
      try {
        File(tmpResults).writeAsStringSync('');
      } catch (_) {}
      final sink = VerdictSink(tmpResults);
      final runner = widget.runnerFactory?.call() ?? IndicatorSearchRunner();
      _activeRunner = runner;
      final stats = await runner.runAll(
        bars: bars,
        env: env,
        cands: cands,
        maxKn: h.maxKn,
        yieldEvery: widget.scanYieldEvery ?? 25,
        sink: sink,
        onProgress: (p) {
          if (!mounted) return;
          logProgress(
            '扫描 ${p.done}/${p.total} 跑通${p.ran} eta=${_fmtEta(p.eta)}',
            logFilePath: logPath,
          );
          setState(() {
            _progress = p.phaseFraction;
            _detail = '${p.done}/${p.total} · 编译${p.compiled} 跑通${p.ran} · '
                '已用 ${p.elapsed?.inMinutes ?? 0}m${(p.elapsed?.inSeconds ?? 0) % 60}s · '
                '剩余 ${_fmtEta(p.eta)}';
            _liveRan = p.recentRan;
          });
        },
      );
      sink.close();
      _activeRunner = null;
      if (stats.cancelled) {
        // 保留部分 TSV，使「完整 TSV」链接在取消后仍有效。
        try {
          File(tmpResults).renameSync(_resultsPath!);
        } catch (_) {
          try {
            File(tmpResults).copySync(_resultsPath!);
            File(tmpResults).deleteSync();
          } catch (_) {}
        }
        logProgress(
          'cancelled at ${stats.ran}/${stats.total}',
          logFilePath: logPath,
        );
        if (!mounted) return;
        setState(() {
          _running = false;
          _phase = '已取消';
          _detail = '已扫描 ${stats.ran} 条，保留部分 TSV';
          _stats = stats;
        });
        return;
      }
      try {
        File(tmpResults).renameSync(_resultsPath!);
      } catch (_) {
        try {
          File(tmpResults).copySync(_resultsPath!);
          File(tmpResults).deleteSync();
        } catch (_) {}
      }

      logProgress(
        '完成 跑通${stats.ran} 耗时${stats.elapsed.inSeconds}s',
        logFilePath: logPath,
      );

      await IndicatorSearchLastResultStore.save(
        IndicatorSearchLastResult.fromRun(
          finishedAt: DateTime.now(),
          code: widget.code,
          period: widget.period,
          beginText: widget.beginText,
          endText: widget.endText,
          barCount: _barCount,
          stats: stats,
          resultsFilePath: _resultsPath!,
          maxKn: h.maxKn,
          useOptimizedBuild: _settings.useOptimizedBuild,
          maxCandidates: _settings.maxCandidates,
          align: _alignSnap,
        ),
      );

      if (!mounted) return;
      setState(() {
        _running = false;
        _stats = stats;
        _phase = '完成';
        _detail = '编译${stats.compiled} 跑通${stats.ran} · '
            '耗时 ${stats.elapsed.inMinutes}分${stats.elapsed.inSeconds % 60}秒';
        _progress = 1;
      });
    } catch (e) {
      _activeRunner = null;
      logProgress('失败 $e', logFilePath: logPath);
      if (!mounted) return;
      setState(() {
        _running = false;
        _error = e.toString();
        _phase = '失败';
      });
    }
  }

  void _onSort(VerdictSortColumn col) => setState(() {
        _sort = _sort.toggle(col);
        _expanded = null;
      });

  void _onRemoveSort(VerdictSortColumn col) => setState(() {
        _sort = _sort.remove(col);
        _expanded = null;
      });

  void _onClearSort() => setState(() {
        _sort = VerdictSortState();
        _expanded = null;
      });

  void _onToggleExpand(int i) =>
      setState(() => _expanded = _expanded == i ? null : i);

  /// 眼睛按钮：以该行买卖条件替换当前策略（保留本金/数量/费用/滑点/成交模式），
  /// 跑全区间回测并打开回测台覆盖层（绩效页）。
  void _previewBacktest(ComboVerdict v) {
    if (_env == null || _bars.isEmpty || !v.hasAst) return;
    final run = _env!.runFull(v.buyAst!, v.sellAst!, _bars.last.idx);
    if (run == null) return;
    setState(() {
      _previewRun = run;
      _previewVerdict = v;
      _previewTab = BacktestReportTab.metrics;
    });
  }

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width > 900 ? 880.0 : size.width * 0.92;
    final h = size.height > 700 ? 620.0 : size.height * 0.85;

    // 扫描进行中禁止关闭（点遮罩/ESC/返回都不生效），跑完出结果后才可点非结果处关闭；
    // 整块包 SelectionArea：弹窗内所有字符串（含结果宽表每一行、展开明细）都可拖选复制。
    return PopScope(
      canPop: !_running,
      child: SelectionArea(
        child: AlertDialog(
          title: const Text('指标寻优'),
      content: SizedBox(
        width: w,
        height: h,
        child: Stack(
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Text(
                  '阶段：$_phase',
                  style: const TextStyle(fontWeight: FontWeight.w600),
                ),
                const SizedBox(height: 4),
                Text(_detail, style: const TextStyle(fontSize: 12)),
                if (_progress != null) ...[
                  const SizedBox(height: 8),
                  LinearProgressIndicator(
                    value: _cancelling ? null : (_running ? _progress : 1),
                  ),
                ],
                if (_running && _liveRan.isNotEmpty) ...[
                  const SizedBox(height: 8),
                  Text(
                    '最近跑通',
                    style: TextStyle(fontSize: 11, color: Colors.green.shade800),
                  ),
                  ..._liveRan
                      .take(3)
                      .map(
                        (v) => Text(
                          '· ${v.categoryLabel} 买:${v.buyText} 卖:${v.sellText}',
                          style: const TextStyle(fontSize: 10),
                          maxLines: 3,
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                ],
                if (_error != null) ...[
                  const SizedBox(height: 12),
                  Text(_error!, style: TextStyle(color: Colors.red.shade700)),
                ],
                // 只以 _stats 为准：恢复模式（返回寻优结果 / 上次寻优结果）下
                // _resultsPath 可能要异步补齐，若一并当条件会在补齐前整帧空表。
                if (_stats != null) ...[
                  const SizedBox(height: 12),
                  Expanded(
                    child: IndicatorSearchResultPanel(
                      verdicts: _stats!.verdicts,
                      resultsFilePath: _resultsPath ?? '',
                      elapsed: _stats!.elapsed,
                      code: widget.code,
                      period: widget.period,
                      beginText: widget.beginText,
                      endText: widget.endText,
                      splitX: _splitX,
                      align: _alignSnap,
                      maxKn: _maxKn,
                      buildSummary: _buildSummary,
                      sort: _sort,
                      onSort: _onSort,
                      onRemoveSort: _onRemoveSort,
                      onClearSort: _onClearSort,
                      expanded: _expanded,
                      onToggleExpand: _onToggleExpand,
                      onPreviewBacktest:
                          widget.enablePreview ? _previewBacktest : null,
                      previewHint: widget.enablePreview
                          ? null
                          : '当前主图区间与快照不一致，无法即时回测；请用相同参数重新寻优',
                    ),
                  ),
                ] else if (_running)
                  const Spacer(),
              ],
            ),
            if (_previewRun != null) Positioned.fill(child: _previewOverlay()),
          ],
        ),
      ),
      actions: [
        if (_running)
          TextButton(
            onPressed: _cancelling
                ? null
                : () {
                    setState(() {
                      _phase = '正在取消';
                      _detail = '正在取消扫描…';
                      _cancelling = true;
                    });
                    _searchCancelled = true;
                    _activeRunner?.requestCancel();
                  },
            child: Text(_cancelling ? '正在取消…' : '取消扫描'),
          ),
        TextButton(
          onPressed: _running ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
        ),
      ),
    );
  }

  Widget _previewOverlay() {
    return ColoredBox(
      color: Theme.of(context).colorScheme.surface,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            color: Theme.of(context).colorScheme.surfaceContainerHighest,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    '回测预览（该行买卖条件 · 全区间）',
                    style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
                  ),
                ),
                if (widget.onApplyToChart != null && _previewVerdict != null) ...[
                  TextButton.icon(
                    onPressed: () {
                      final cfg = widget.strategyConfig.copyWith(
                        buyAst: _previewVerdict!.buyAst,
                        sellAst: _previewVerdict!.sellAst,
                      );
                      widget.onCacheSession?.call(_buildSessionSnapshot());
                      widget.onApplyToChart!(_previewRun!, cfg);
                    },
                    icon: const Icon(Icons.show_chart, size: 16),
                    label: const Text('在 K 线图查看'),
                  ),
                ],
                TextButton.icon(
                  onPressed: () => setState(() => _previewRun = null),
                  icon: const Icon(Icons.close, size: 16),
                  label: const Text('返回寻优'),
                ),
              ],
            ),
          ),
          Expanded(
            child: BacktestReportPanel(
              run: _previewRun!,
              bars: _bars,
              tab: _previewTab,
              onTab: (t) => setState(() => _previewTab = t),
              showTabBar: true,
              selectedSignalId: null,
              selectedTradeId: null,
              onSelectTrade: (_) {},
              onSelectSignal: (_) {},
              onJumpX: (_) {},
            ),
          ),
        ],
      ),
    );
  }

  IndicatorSearchSessionSnapshot _buildSessionSnapshot() => IndicatorSearchSessionSnapshot(
        verdicts: _stats?.verdicts ?? const [],
        compiled: _stats?.compiled ?? 0,
        ran: _stats?.ran ?? 0,
        splitX: _splitX,
        elapsed: _stats?.elapsed ?? Duration.zero,
        sort: _sort,
        expanded: _expanded,
        code: widget.code,
        period: widget.period,
        beginText: widget.beginText,
        endText: widget.endText,
        barCount: _barCount,
        align: _alignSnap,
        buildSummary: _buildSummary,
        maxKn: _maxKn,
        resultsFilePath: _resultsPath ?? '',
      );
}

Future<void> showIndicatorSearchHelp(BuildContext context) async {
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: const Text('指标寻优说明'),
      content: const SingleChildScrollView(
        child: Text(
          '操作步骤：\n'
          '1. 在设置里选好股票、周期、加载起止时间，并先「加载 K 线」。\n'
          '2. 须步进到区间最后一根 K（可一键跳末），再点「寻优」：直接复用主图冻结仓（与策略回测同源）→ 枚举组合 → 样本内外各独立回测。\n'
          '3. 结果以单张宽表展示：所有可编译候选（含 0 成交）均列出，不做达标/排名筛选；不可计算值显示「—」。\n'
          '4. 点击每行前置「眼睛」按钮：以该行买卖条件替换当前策略（保留本金/数量/费用/滑点/成交模式），立即运行全区间回测，并在寻优界面上方打开回测台（绩效页）；覆盖层内点「在 K 线图查看」可把该行策略投到主 K 线图，关闭寻优后直接看买卖标记；投图后回测台顶部常驻一条横幅，写明图上当前生效的买/卖条件，右侧「返回寻优结果」可原样回到那张宽表（排序与展开行都保留，不重扫）；关闭回测台后寻优结果与排序保持不变。\n'
          '5. 点击表头列排序（可多列累积，角标①②③表优先级；再次点同列切换升/降序，长按列移除该键，「清除排序」一键还原）；点列排序会自动回到首行；点击行可展开样本内/外的其余详细指标。\n'
          '6. 完整结果见 TSV 文件；进度条含剩余时间估算，日志见 indicator_search_progress.log。\n'
          '7. 跑完后可在设置点「上次寻优结果」查看快照（与当次一致；若当前主图区间与快照一致，还可眼睛预览与「在 K 线图查看」，否则置灰提示须用相同参数重新寻优）。\n'
          '8. 关闭与复制：扫描过程中点外面不会关（防误触丢进度），跑完出结果后点非结果处（遮罩）直接关闭；弹窗内所有文字（含结果宽表每一行、展开的明细、摘要与参数行）都能用鼠标拖选复制；鼠标右键点某一行＝复制该行整行（制表符分列，列序与表头一致，可直接贴进表格）。\n\n'
          '指标显示说明：「在 K 线图查看」会「完全按本行策略条件重设」主图/副图显示——默认那批（K线/合并/中枢/连线、分型与中枢确认判断等）不再显示，只留本行条件用到的指标，并固定带上用到的那几层的 K线 与 连线当骨架。因此「不会包含上一次点的行」，你手工勾选的指标也会被清掉（看完想恢复请自己重新勾）。\n\n'
          '注意：寻优占用 CPU，勿同时开机器学习；非投资建议。',
          style: TextStyle(fontSize: 13, height: 1.45),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(ctx),
          child: const Text('知道了'),
        ),
      ],
    ),
  );
}

Future<IndicatorSearchSettings?> showIndicatorSearchSettingsSheet(
  BuildContext context,
) async {
  var cfg = IndicatorSearchSettingsStore.current;
  return showModalBottomSheet<IndicatorSearchSettings>(
    context: context,
    showDragHandle: true,
    builder: (ctx) {
      return StatefulBuilder(
        builder: (ctx, setLocal) {
          return Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                const Text(
                  '寻优参数',
                  style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600),
                ),
                SwitchListTile(
                  title: const Text('优化枚举（推荐）'),
                  subtitle: const Text('模板 + 事件全量 + 数值/阈值有上限；关闭=全量枚举（极慢）'),
                  value: cfg.useOptimizedBuild,
                  onChanged: (v) =>
                      setLocal(() => cfg = cfg.copyWith(useOptimizedBuild: v)),
                ),
                ListTile(
                  title: Text(
                    '候选上限：${cfg.useOptimizedBuild ? cfg.maxCandidates : "无"}',
                  ),
                  subtitle: Slider(
                    value: cfg.maxCandidates.clamp(2000, 50000).toDouble(),
                    min: 2000,
                    max: 50000,
                    divisions: 24,
                    label: '${cfg.maxCandidates}',
                    onChanged: cfg.useOptimizedBuild
                        ? (v) => setLocal(
                            () => cfg = cfg.copyWith(maxCandidates: v.round()),
                          )
                        : null,
                  ),
                ),
                const SizedBox(height: 8),
                Row(
                  children: [
                    TextButton(
                      onPressed: () => Navigator.pop(ctx),
                      child: const Text('取消'),
                    ),
                    const Spacer(),
                    FilledButton(
                      onPressed: () async {
                        await IndicatorSearchSettingsStore.save(cfg);
                        if (!ctx.mounted) return;
                        Navigator.pop(ctx, cfg);
                      },
                      child: const Text('保存'),
                    ),
                  ],
                ),
              ],
            ),
          );
        },
      );
    },
  );
}
