import 'package:flutter/material.dart';

import 'ml_bsp_sample.dart';
import 'ml_dataset_split.dart';
import 'ml_experience_trainer.dart';
import 'ml_feature_schema.dart';
import 'ml_label_config.dart';
import 'ml_split_config.dart';
import 'ml_xgb_trainer.dart';

/// ML 阶段：先设三截切分 → 加载 → 验证调参 → 测试只报一次并锁定。
enum MlPreparePhase {
  setup,
  loading,
  computing,
  labeling,
  training,
  tuning,
  evaluating,
  ready,
  error,
}

enum MlResultTab { test, valid, train, all }

enum MlTrainerKind { logistic, xgb }

/// 无 K 线图；当前股票；LR 内存训 / XGB 子进程训后 Rust 打分。
class MlWorkbench extends StatefulWidget {
  const MlWorkbench({
    super.key,
    required this.onExit,
    required this.onLoad,
    required this.phase,
    required this.splitConfig,
    required this.onSplitConfigChanged,
    required this.labelConfig,
    required this.onLabelConfigChanged,
    required this.testLocked,
    required this.code,
    required this.period,
    required this.dataRoot,
    required this.isXgbMode,
    required this.onTrainerKindChanged,
    required this.xgbParams,
    required this.onXgbParamsChanged,
    required this.forceXgbRetrain,
    required this.onForceXgbRetrainChanged,
    this.samples = const [],
    this.report,
    this.errorText,
    this.statusLine = '',
    this.progressHint = '',
  });

  final VoidCallback onExit;
  final Future<void> Function() onLoad;
  final MlPreparePhase phase;
  final MlSplitConfig splitConfig;
  final ValueChanged<MlSplitConfig> onSplitConfigChanged;
  final MlLabelConfig labelConfig;
  final ValueChanged<MlLabelConfig> onLabelConfigChanged;
  final bool testLocked;
  final String code;
  final String period;
  final String dataRoot;
  final bool isXgbMode;
  final ValueChanged<MlTrainerKind> onTrainerKindChanged;
  final XgbTrainParams xgbParams;
  final ValueChanged<XgbTrainParams> onXgbParamsChanged;
  final bool forceXgbRetrain;
  final ValueChanged<bool> onForceXgbRetrainChanged;
  final List<MlBspSample> samples;
  final MlRunReport? report;
  final String? errorText;
  final String statusLine;
  final String progressHint;

  @override
  State<MlWorkbench> createState() => _MlWorkbenchState();
}

class _MlWorkbenchState extends State<MlWorkbench> {
  MlResultTab _tab = MlResultTab.test;

  bool get _busy =>
      widget.phase == MlPreparePhase.loading ||
      widget.phase == MlPreparePhase.computing ||
      widget.phase == MlPreparePhase.labeling ||
      widget.phase == MlPreparePhase.training ||
      widget.phase == MlPreparePhase.tuning ||
      widget.phase == MlPreparePhase.evaluating;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _topBar(),
        if (widget.statusLine.isNotEmpty)
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 0),
            child: Text(
              widget.statusLine,
              style: TextStyle(fontSize: 11, color: Colors.grey.shade400),
            ),
          ),
        Expanded(
          child: switch (widget.phase) {
            MlPreparePhase.ready => _resultsBody(),
            MlPreparePhase.setup || MlPreparePhase.error => _setupBody(),
            _ => _progressBody(),
          },
        ),
      ],
    );
  }

  Widget _topBar() {
    final title = switch (widget.phase) {
      MlPreparePhase.ready =>
        widget.testLocked
            ? '测试已锁定 · ${widget.code}'
            : '测试集结果 · ${widget.code}',
      MlPreparePhase.setup || MlPreparePhase.error =>
        '机器学习 · 训练/验证/测试（时序）',
      _ => '加载中 · ${widget.code}',
    };
    return Material(
      color: const Color(0xFF1E3A5F),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
        child: Row(
          children: [
            const Icon(Icons.psychology, color: Colors.white70, size: 18),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                '$title · schema v${MlFeatureSchema.schemaVersion}'
                '${widget.isXgbMode ? " · XGB" : " · LR"}',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            TextButton(
              onPressed: _busy ? null : widget.onExit,
              style: TextButton.styleFrom(foregroundColor: Colors.orangeAccent),
              child: const Text('退出'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _setupBody() {
    final tr = (widget.splitConfig.trainRatio * 100).round();
    final vr = (widget.splitConfig.validRatio * 100).round();
    final te = (widget.splitConfig.testRatio * 100).round();
    final hz = widget.labelConfig.horizonBars;
    final canEdit = !widget.testLocked && !_busy;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          color: const Color(0xFF1A1A1A),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  Text(
                    '当前股票：${widget.code} · ${widget.period}',
                    style: const TextStyle(
                      color: Colors.white,
                      fontSize: 16,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    widget.isXgbMode
                        ? 'α=展望窗；时序三截；导出 libsvm→Python XGB 训练→Rust 打分；'
                            '验证选阈值；测试只评估一次并锁定。\n'
                            '特征 0-based；缺失=-9999999；模型带 code/period/schema。'
                        : 'α=发现后固定展望窗（非跳末）；时序三截；验证调参；测试只评估一次并锁定。\n'
                            '本阶段逻辑回归在内存拟合；不展示K线图。',
                    style: TextStyle(color: Colors.grey.shade300, height: 1.4),
                  ),
                  const SizedBox(height: 12),
                  Text(
                    '训练器',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                  const SizedBox(height: 6),
                  SegmentedButton<MlTrainerKind>(
                    segments: const [
                      ButtonSegment(
                        value: MlTrainerKind.logistic,
                        label: Text('逻辑回归'),
                      ),
                      ButtonSegment(
                        value: MlTrainerKind.xgb,
                        label: Text('XGB'),
                      ),
                    ],
                    selected: {
                      widget.isXgbMode
                          ? MlTrainerKind.xgb
                          : MlTrainerKind.logistic,
                    },
                    onSelectionChanged: canEdit
                        ? (s) => widget.onTrainerKindChanged(s.first)
                        : null,
                  ),
                  if (widget.phase == MlPreparePhase.error) ...[
                    const SizedBox(height: 10),
                    Text(
                      widget.errorText ?? '加载失败',
                      style: const TextStyle(color: Colors.orangeAccent),
                    ),
                  ],
                  if (widget.testLocked) ...[
                    const SizedBox(height: 8),
                    const Text(
                      '测试已锁定：不可改切分/展望窗/训练器后重跑。请点「退出」再重新进入。',
                      style:
                          TextStyle(color: Colors.orangeAccent, fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 14),
                  Text(
                    '切分：${widget.splitConfig.summary}',
                    style: const TextStyle(color: Colors.lightBlueAccent),
                  ),
                  _ratioSlider(
                    label: '训练',
                    value: widget.splitConfig.trainRatio,
                    min: 0.4,
                    max: 0.8,
                    divisions: 8,
                    display: '$tr%',
                    onChanged: canEdit
                        ? (v) => widget.onSplitConfigChanged(
                              widget.splitConfig.copyWith(trainRatio: v),
                            )
                        : null,
                  ),
                  _ratioSlider(
                    label: '验证',
                    value: widget.splitConfig.validRatio,
                    min: 0.1,
                    max: 0.4,
                    divisions: 6,
                    display: '$vr%',
                    onChanged: canEdit
                        ? (v) => widget.onSplitConfigChanged(
                              widget.splitConfig.copyWith(validRatio: v),
                            )
                        : null,
                  ),
                  Text(
                    '测试（自动余量）$te% · 时序最末段',
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '展望窗：${widget.labelConfig.summary}',
                    style: const TextStyle(color: Colors.lightBlueAccent),
                  ),
                  _ratioSlider(
                    label: '窗K',
                    value: hz.toDouble(),
                    min: 8,
                    max: 256,
                    divisions: 31,
                    display: '$hz',
                    onChanged: canEdit
                        ? (v) => widget.onLabelConfigChanged(
                              widget.labelConfig.copyWith(
                                horizonBars: v.round(),
                              ),
                            )
                        : null,
                  ),
                  if (widget.isXgbMode) ...[
                    const SizedBox(height: 12),
                    const Text(
                      'XGB 超参',
                      style: TextStyle(color: Colors.lightBlueAccent),
                    ),
                    _ratioSlider(
                      label: '深度',
                      value: widget.xgbParams.maxDepth.toDouble(),
                      min: 2,
                      max: 10,
                      divisions: 8,
                      display: '${widget.xgbParams.maxDepth}',
                      onChanged: canEdit
                          ? (v) => widget.onXgbParamsChanged(
                                widget.xgbParams.copyWith(maxDepth: v.round()),
                              )
                          : null,
                    ),
                    _ratioSlider(
                      label: '轮数',
                      value: widget.xgbParams.numRound.toDouble(),
                      min: 20,
                      max: 300,
                      divisions: 28,
                      display: '${widget.xgbParams.numRound}',
                      onChanged: canEdit
                          ? (v) => widget.onXgbParamsChanged(
                                widget.xgbParams.copyWith(numRound: v.round()),
                              )
                          : null,
                    ),
                    _ratioSlider(
                      label: 'lr',
                      value: widget.xgbParams.learningRate,
                      min: 0.01,
                      max: 0.3,
                      divisions: 29,
                      display:
                          widget.xgbParams.learningRate.toStringAsFixed(2),
                      onChanged: canEdit
                          ? (v) => widget.onXgbParamsChanged(
                                widget.xgbParams.copyWith(learningRate: v),
                              )
                          : null,
                    ),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      dense: true,
                      title: const Text(
                        '强制重训（关闭则指纹一致时可复用 model）',
                        style: TextStyle(color: Colors.white70, fontSize: 12),
                      ),
                      value: widget.forceXgbRetrain,
                      onChanged:
                          canEdit ? widget.onForceXgbRetrainChanged : null,
                    ),
                    Text(
                      '数据根：${widget.dataRoot.isEmpty ? "(未就绪)" : widget.dataRoot}',
                      style: TextStyle(
                        color: Colors.grey.shade500,
                        fontSize: 11,
                      ),
                    ),
                  ],
                  const SizedBox(height: 12),
                  FilledButton.icon(
                    onPressed: (!canEdit && widget.testLocked) || _busy
                        ? null
                        : () => widget.onLoad(),
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      widget.testLocked
                          ? '已锁定（请退出重进）'
                          : widget.phase == MlPreparePhase.error
                              ? '重新加载'
                              : (widget.isXgbMode ? '加载并训练 XGB' : '加载'),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _ratioSlider({
    required String label,
    required double value,
    required double min,
    required double max,
    required int divisions,
    required String display,
    required ValueChanged<double>? onChanged,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 36,
          child: Text(label, style: const TextStyle(color: Colors.white70)),
        ),
        Expanded(
          child: Slider(
            value: value.clamp(min, max),
            min: min,
            max: max,
            divisions: divisions,
            label: display,
            onChanged: onChanged,
          ),
        ),
        Text(display, style: const TextStyle(color: Colors.white)),
      ],
    );
  }

  Widget _progressBody() {
    final steps = <(MlPreparePhase, String)>[
      (MlPreparePhase.loading, '① 取当前股票数据（不展示K线图）'),
      (MlPreparePhase.computing, '② 逐K采集 + 展望窗α打标'),
      (MlPreparePhase.labeling, '③ 检查标签完整性'),
      (
        MlPreparePhase.training,
        widget.isXgbMode ? '④ 导出 libsvm + XGB 训练' : '④ 时序切分训练/验证/测试',
      ),
      (
        MlPreparePhase.tuning,
        widget.isXgbMode ? '⑤ 验证集选阈值（测试不参与）' : '⑤ 仅验证集网格调参',
      ),
      (MlPreparePhase.evaluating, '⑥ 测试只评估一次并锁定'),
    ];
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 560),
        child: Card(
          color: const Color(0xFF1A1A1A),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '加载进度 · ${widget.code}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                if (widget.progressHint.isNotEmpty) ...[
                  const SizedBox(height: 6),
                  Text(
                    widget.progressHint,
                    style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
                  ),
                ],
                const SizedBox(height: 12),
                for (final s in steps) _stepRow(s.$1, s.$2),
                const SizedBox(height: 16),
                const LinearProgressIndicator(),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _stepRow(MlPreparePhase step, String label) {
    final order = [
      MlPreparePhase.loading,
      MlPreparePhase.computing,
      MlPreparePhase.labeling,
      MlPreparePhase.training,
      MlPreparePhase.tuning,
      MlPreparePhase.evaluating,
    ];
    final cur = order.indexOf(widget.phase);
    final mine = order.indexOf(step);
    final done = cur > mine || widget.phase == MlPreparePhase.ready;
    final active = widget.phase == step;
    final color = done
        ? Colors.lightGreenAccent
        : active
            ? Colors.lightBlueAccent
            : Colors.grey;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Icon(
            done
                ? Icons.check_circle
                : active
                    ? Icons.timelapse
                    : Icons.radio_button_unchecked,
            size: 18,
            color: color,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(label, style: TextStyle(color: color, fontSize: 13)),
          ),
        ],
      ),
    );
  }

  List<MlBspSample> get _visibleSamples {
    switch (_tab) {
      case MlResultTab.all:
        return widget.samples;
      case MlResultTab.train:
        return MlDatasetSplit.trainOf(widget.samples);
      case MlResultTab.valid:
        return MlDatasetSplit.validOf(widget.samples);
      case MlResultTab.test:
        return MlDatasetSplit.testOf(widget.samples);
    }
  }

  Widget _resultsBody() {
    final r = widget.report;
    final shown = _visibleSamples;
    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        if (r != null) _reportCard(r),
        const SizedBox(height: 8),
        SegmentedButton<MlResultTab>(
          segments: const [
            ButtonSegment(value: MlResultTab.test, label: Text('测试')),
            ButtonSegment(value: MlResultTab.valid, label: Text('验证')),
            ButtonSegment(value: MlResultTab.train, label: Text('训练')),
            ButtonSegment(value: MlResultTab.all, label: Text('全部')),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Text('无样本', style: TextStyle(color: Colors.grey.shade500))
        else
          for (final s in shown) _sampleCard(s),
      ],
    );
  }

  Widget _reportCard(MlRunReport r) {
    String pct(double v) => '${(v * 100).toStringAsFixed(1)}%';
    String sideRate(int win, int n) =>
        n == 0 ? '-' : '${pct(win / n)}（$win/$n）';
    final t = r.testStats;
    final v = r.validStats;
    final x = r.xgb;

    return Card(
      color: const Color(0xFF1A2433),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              r.headline,
              style: const TextStyle(
                color: Colors.lightGreenAccent,
                fontSize: 15,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              r.tuneSummary,
              style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
            ),
            Text(
              '股票 ${widget.code} · ${widget.period} · ${widget.splitConfig.summary}'
              ' · ${widget.labelConfig.summary}',
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
            if (x != null) ...[
              const SizedBox(height: 4),
              Text(
                '模型 ${x.modelPath}',
                style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
              ),
            ],
            const SizedBox(height: 6),
            Text(
              r.drift.labelRateSummary,
              style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
            ),
            Text(
              r.drift.driftSummary,
              style: TextStyle(
                color:
                    r.drift.alert ? Colors.orangeAccent : Colors.grey.shade300,
                fontSize: 12,
              ),
            ),
            if (widget.testLocked)
              const Padding(
                padding: EdgeInsets.only(top: 6),
                child: Text(
                  '🔒 测试已锁定一次评估：不可改比例重跑（退出 ML 后解锁）',
                  style: TextStyle(color: Colors.orangeAccent, fontSize: 12),
                ),
              ),
            const SizedBox(height: 10),
            _statLine(
              '训练集',
              '${r.trainTotal}条 · 基准胜率 ${pct(r.trainWinRate)}（只拟合，不调参）',
            ),
            _statLine(
              '验证集',
              '${v.total}条 · 调参用 · 准确率 ${pct(v.experienceAccuracy)}'
              ' · 经验胜率 ${pct(v.experienceWinRate)}',
            ),
            _statLine(
              '测试集',
              '${t.total}条 · 只报一次 · 基准 ${pct(t.alphaWinRate)}'
              '（√${t.alphaWin}/×${t.alphaLose}）',
            ),
            _statLine(
              '测试经验胜率',
              '${pct(t.experienceWinRate)}（采纳${t.adopted}中 √${t.adoptedWin}）',
            ),
            _statLine('测试准确率', pct(t.experienceAccuracy)),
            _statLine('测试覆盖率', pct(t.coverage)),
            _statLine('买侧经验胜率', sideRate(t.buyAdoptedWin, t.buyAdopted)),
            _statLine('卖侧经验胜率', sideRate(t.sellAdoptedWin, t.sellAdopted)),
            if (x != null) ...[
              _statLine('trainAUC', x.trainAuc?.toStringAsFixed(3) ?? '-'),
              _statLine('validAUC', x.validAuc?.toStringAsFixed(3) ?? '-'),
              _statLine('XGB轮数', '${x.numRounds}'),
              _statLine('耗时', '${x.elapsedSec.toStringAsFixed(1)}s'),
            ],
            const SizedBox(height: 8),
            Text(
              r.isXgb
                  ? '说明：XGB 在 Python 训、Rust 推；阈值只在验证集选；'
                      '测试锁定防窥探。Rust 树 walker 读 default_left。仅供学习。'
                  : '说明：α用展望窗内live帧+asOf极值；超参只在验证集选；'
                      '测试锁定防窥探。仅供学习，不构成投资建议。',
              style: TextStyle(
                color: Colors.grey.shade500,
                fontSize: 11,
                height: 1.35,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _statLine(String k, String v) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          SizedBox(
            width: 100,
            child: Text(
              k,
              style: TextStyle(color: Colors.grey.shade400, fontSize: 12),
            ),
          ),
          Expanded(
            child: Text(
              v,
              style: const TextStyle(color: Colors.white, fontSize: 13),
            ),
          ),
        ],
      ),
    );
  }

  Widget _sampleCard(MlBspSample s) {
    final ok = s.isCorrect == true;
    final mark = s.isCorrect == null ? '?' : (ok ? '√' : '×');
    final markColor = s.isCorrect == null
        ? Colors.grey
        : ok
            ? Colors.lightGreenAccent
            : Colors.redAccent;
    final splitTag = switch (s.split) {
      MlSampleSplit.train => '训练',
      MlSampleSplit.valid => '验证',
      MlSampleSplit.test => '测试',
    };
    final thr = widget.report?.bestThreshold ?? 0.5;
    final pred = s.predictScore;
    final adopted = pred != null && pred >= thr;
    return Card(
      color: const Color(0xFF1A1A1A),
      margin: const EdgeInsets.only(bottom: 6),
      child: ListTile(
        dense: true,
        leading: Text(
          mark,
          style: TextStyle(
            color: markColor,
            fontSize: 22,
            fontWeight: FontWeight.bold,
          ),
        ),
        title: Text(
          '[$splitTag${adopted ? "·采纳" : ""}] '
          '${s.side == 'B' ? '买' : '卖'} ${s.label} @x=${s.x}',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: Text(
          '${s.openTime} · ${s.labelReason}'
          '${pred != null ? " · 经验分=${pred.toStringAsFixed(3)}" : ""}',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
        ),
      ),
    );
  }
}
