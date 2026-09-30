import 'dart:io';

import 'package:flutter/material.dart';

import '../bridge/chan_bridge.dart';
import '../indicator_search/candidate_builder.dart';
import '../indicator_search/indicator_search_runner.dart';
import '../indicator_search/search_core.dart';
import '../indicator_search/search_env.dart';
import '../indicator_search/variable_pool.dart';
import '../backtest/backtest_step_harness.dart';
import '../backtest/strategy_config.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chip_config.dart';
import '../models/kline_bar.dart';
import '../models/math_indicator_config.dart';
import '../settings/indicator_search_last_result_store.dart';
import '../settings/indicator_search_settings_store.dart';
import 'indicator_search_result_panel.dart';

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

  @override
  State<IndicatorSearchDialog> createState() => _IndicatorSearchDialogState();
}

class _IndicatorSearchDialogState extends State<IndicatorSearchDialog> {
  String _phase = '准备';
  String _detail = '';
  double? _progress;
  bool _running = true;
  String? _error;
  IndicatorSearchRunStats? _stats;
  List<ComboVerdict> _livePassed = const [];
  String? _resultsPath;
  int _barCount = 0;
  int _maxKn = 0;
  IndicatorSearchSettings _settings = IndicatorSearchSettingsStore.current;
  CandidateBuildSummary? _buildSummary;
  IndicatorSearchAlignSnapshot? _alignSnap;
  IndicatorSearchRunner? _activeRunner;

  @override
  void initState() {
    super.initState();
    _run();
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
        h = await driveStepHarnessWithProgress(
          bars,
          mathConfig: widget.mathConfig,
          chipConfig: widget.chipConfig,
          truncationCheck: widget.truncationCheck,
          onProgress: (d, t) {
            if (!mounted) return;
            setState(() {
              _progress = d / t;
              _detail = '冻结 $d / $t · 已用 '
                  '${DateTime.now().difference(freezeStarted).inSeconds}s';
            });
          },
        );
        logProgress('冻结完成 maxKn=${h.maxKn}', logFilePath: logPath);
      }
      _maxKn = h.maxKn;

      final pool = VariablePool(h.maxKn);
      final opts = _settings.toBuildOptions();
      final cands = buildCandidates(pool, opts);
      _buildSummary = summarizeCandidates(cands);
      logProgress(
        '候选 ${cands.length} 条 profile=${opts.profile.name} · ${_buildSummary!.toDisplayLine()}',
        logFilePath: logPath,
      );

      setState(() {
        _phase = '回测扫描';
        _detail =
            '候选 ${cands.length} 条 · 预编译复用 · '
            '内段不过关则外段不参与双达标=${_settings.skipOosEarly}';
        _progress = 0;
        _livePassed = const [];
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
      const gate = PassGate();
      final tmpResults = '${_resultsPath!}.tmp';
      try {
        File(tmpResults).writeAsStringSync('');
      } catch (_) {}
      final sink = VerdictSink(tmpResults);
      final runner = IndicatorSearchRunner();
      _activeRunner = runner;
      final stats = await runner.runAll(
        bars: bars,
        env: env,
        cands: cands,
        gate: gate,
        maxKn: h.maxKn,
        skipOosEarly: _settings.skipOosEarly,
        sink: sink,
        onProgress: (p) {
          if (!mounted) return;
          logProgress(
            '扫描 ${p.done}/${p.total} 跑通${p.ran} 达标${p.passed} eta=${_fmtEta(p.eta)}',
            logFilePath: logPath,
          );
          setState(() {
            _progress = p.phaseFraction;
            _detail =
                '${p.done}/${p.total} · 编译${p.compiled} 跑通${p.ran} 达标${p.passed} · '
                '已用 ${p.elapsed?.inMinutes ?? 0}m${(p.elapsed?.inSeconds ?? 0) % 60}s · '
                '剩余 ${_fmtEta(p.eta)}';
            _livePassed = p.recentPassed;
          });
        },
      );
      sink.close();
      _activeRunner = null;
      if (stats.cancelled) {
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
        '完成 达标${stats.passed} 耗时${stats.elapsed.inSeconds}s',
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
          skipOosEarly: _settings.skipOosEarly,
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
        _detail =
            '编译${stats.compiled} 跑通${stats.ran} 双达标${stats.passed} · '
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

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final w = size.width > 900 ? 880.0 : size.width * 0.92;
    final h = size.height > 700 ? 620.0 : size.height * 0.85;

    return AlertDialog(
      title: const Text('指标寻优'),
      content: SizedBox(
        width: w,
        height: h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text('阶段：$_phase', style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text(_detail, style: const TextStyle(fontSize: 12)),
            if (_progress != null) ...[
              const SizedBox(height: 8),
              LinearProgressIndicator(value: _running ? _progress : 1),
            ],
            if (_running && _livePassed.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('最新双达标', style: TextStyle(fontSize: 11, color: Colors.green.shade800)),
              ..._livePassed.take(3).map(
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
            if (_stats != null && _resultsPath != null) ...[
              const SizedBox(height: 12),
              Expanded(
                child: IndicatorSearchResultPanel(
                  header: reportHeader(
                    code: widget.code,
                    period: widget.period,
                    bars: _barCount,
                    splitX: _stats!.splitX,
                    gateTrades: const PassGate().minTrades,
                    align: _alignSnap,
                  ),
                  verdicts: _stats!.verdicts,
                  resultsFilePath: _resultsPath!,
                  elapsed: _stats!.elapsed,
                  maxKn: _maxKn,
                  skipOosEarly: _settings.skipOosEarly,
                  buildSummary: _buildSummary,
                ),
              ),
            ] else if (_running)
              const Spacer(),
          ],
        ),
      ),
      actions: [
        if (_running)
          TextButton(
            onPressed: () => _activeRunner?.requestCancel(),
            child: const Text('取消扫描'),
          ),
        TextButton(
          onPressed: _running ? null : () => Navigator.pop(context),
          child: const Text('关闭'),
        ),
      ],
    );
  }
}

/// 设置 · 上次寻优结果（读本地快照，无需重跑）。
Future<void> showIndicatorSearchLastResultDialog(BuildContext context) async {
  await IndicatorSearchLastResultStore.load();
  final snap = IndicatorSearchLastResultStore.current;
  if (!context.mounted) return;
  if (snap == null || snap.verdicts.isEmpty) {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('上次寻优结果'),
        content: const Text('暂无已保存的寻优快照，请先完整跑完一次寻优。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
        ],
      ),
    );
    return;
  }

  if (!context.mounted) return;
  final size = MediaQuery.sizeOf(context);
  final w = size.width > 900 ? 880.0 : size.width * 0.92;
  final h = size.height > 700 ? 620.0 : size.height * 0.85;
  final header = reportHeader(
    code: snap.code,
    period: snap.period,
    bars: snap.barCount,
    splitX: snap.splitX,
    gateTrades: const PassGate().minTrades,
    align: snap.align,
  );

  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      title: Text(
        '上次寻优 · ${snap.code} ${snap.period} '
        '(${snap.finishedAt.toLocal().toString().substring(0, 16)})',
      ),
      content: SizedBox(
        width: w,
        height: h,
        child: IndicatorSearchResultPanel(
          header: '$header\n区间：${snap.beginText} ~ ${snap.endText}',
          verdicts: snap.verdicts,
          resultsFilePath: snap.resultsFilePath,
          elapsed: snap.elapsed,
          maxKn: snap.maxKn,
          skipOosEarly: snap.skipOosEarly,
          buildSummary: null,
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭')),
      ],
    ),
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
          '2. 须步进到区间最后一根 K（可一键跳末），再点「寻优」：直接复用主图冻结仓（与策略回测同源）→ 枚举组合 → 样本内外回测。\n'
          '3. 结果以表格展示（双达标 / 保守分 Top）；完整列表见 TSV。\n'
          '4. 进度条含剩余时间估算；日志见 indicator_search_progress.log。\n'
          '5. 默认优化枚举 + 候选上限；可开启「内段不过关则外段不参与双达标」（内外各独立回测一次，外段标「未测」仅表示未参与双达标）。\n'
          '   关闭该开关后外段参与门槛判定；报告头会写明成交价与费率等复现参数。\n'
          '6. 跑完后可在设置点「上次寻优结果」查看快照（与当次表格一致）。\n\n'
          '注意：寻优占用 CPU，勿同时开机器学习；非投资建议。',
          style: TextStyle(fontSize: 13, height: 1.45),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('知道了')),
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
                const Text('寻优参数', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w600)),
                SwitchListTile(
                  title: const Text('优化枚举（推荐）'),
                  subtitle: const Text('模板 + 事件全量 + 数值/阈值有上限；关闭=全量枚举（极慢）'),
                  value: cfg.useOptimizedBuild,
                  onChanged: (v) => setLocal(() => cfg = cfg.copyWith(useOptimizedBuild: v)),
                ),
                ListTile(
                  title: Text('候选上限：${cfg.useOptimizedBuild ? cfg.maxCandidates : "无"}'),
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
                SwitchListTile(
                  title: const Text('内段不过关则外段不参与双达标'),
                  subtitle: const Text(
                    '全区间仍回测一次；内段未过门槛时外段不计入双达标且表中标「未测」（与 0 笔区分）',
                  ),
                  value: cfg.skipOosEarly,
                  onChanged: (v) => setLocal(() => cfg = cfg.copyWith(skipOosEarly: v)),
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
