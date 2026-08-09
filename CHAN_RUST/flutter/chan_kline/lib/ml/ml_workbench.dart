import 'package:flutter/material.dart';

import 'ml_bsp_sample.dart';
import 'ml_dataset_split.dart';
import 'ml_feature_schema.dart';
import 'ml_split_config.dart';

/// ML 准备阶段（新手引导）。
enum MlPreparePhase {
  idle,
  loading,
  computing,
  scoring,
  ready,
  error,
}

/// 成果页查看范围。
enum MlResultTab { all, train, exam }

/// K0 一类 BS 成果页：无 K 线图；训练集/考试集可切换查看。
class MlWorkbench extends StatefulWidget {
  const MlWorkbench({
    super.key,
    required this.onExit,
    required this.onExport,
    required this.onLoadModelPredict,
    required this.phase,
    required this.splitConfig,
    required this.onSplitConfigChanged,
    this.samples = const [],
    this.errorText,
    this.statusLine = '',
    this.exporting = false,
    this.predicting = false,
    this.modelLoaded = false,
  });

  final VoidCallback onExit;
  final Future<void> Function() onExport;
  final Future<void> Function() onLoadModelPredict;
  final MlPreparePhase phase;
  final MlSplitConfig splitConfig;
  final ValueChanged<MlSplitConfig> onSplitConfigChanged;
  final List<MlBspSample> samples;
  final String? errorText;
  final String statusLine;
  final bool exporting;
  final bool predicting;
  final bool modelLoaded;

  @override
  State<MlWorkbench> createState() => _MlWorkbenchState();
}

class _MlWorkbenchState extends State<MlWorkbench> {
  MlResultTab _tab = MlResultTab.exam;

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
          child: widget.phase == MlPreparePhase.ready
              ? _resultsBody()
              : _guideBody(),
        ),
      ],
    );
  }

  Widget _topBar() {
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
                widget.phase == MlPreparePhase.ready
                    ? '机器学习成果 · 无K线图 · schema v${MlFeatureSchema.schemaVersion}'
                    : '机器学习准备中（后台算特征，不加载K线图）',
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (widget.phase == MlPreparePhase.ready) ...[
              TextButton(
                onPressed: widget.exporting || widget.predicting
                    ? null
                    : () => widget.onExport(),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: Text(widget.exporting ? '导出中…' : '导出数据'),
              ),
              TextButton(
                onPressed: widget.exporting || widget.predicting
                    ? null
                    : () => widget.onLoadModelPredict(),
                style: TextButton.styleFrom(foregroundColor: Colors.white),
                child: Text(widget.predicting ? '预测中…' : '加载模型预测'),
              ),
            ],
            TextButton(
              onPressed:
                  widget.exporting || widget.predicting ? null : widget.onExit,
              style: TextButton.styleFrom(foregroundColor: Colors.orangeAccent),
              child: const Text('退出机器学习'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _guideBody() {
    final steps = <(MlPreparePhase, String)>[
      (MlPreparePhase.loading, '① 按设置后台取数（不打开K线图）'),
      (MlPreparePhase.computing, '② 完整逐K计算并采集 K0 一类 BS'),
      (MlPreparePhase.scoring, '③ α 打标 + 按比例切分训练/考试集'),
      (MlPreparePhase.ready, '④ 查看考试集结果（可导出/预测）'),
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
                const Text(
                  '新手引导',
                  style: TextStyle(
                    color: Colors.white,
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  widget.phase == MlPreparePhase.error
                      ? (widget.errorText ?? '准备失败')
                      : '不加载K线图界面；后台完成计算后直接看训练/考试结果。'
                          '当前切分：${widget.splitConfig.summary}',
                  style: TextStyle(
                    color: widget.phase == MlPreparePhase.error
                        ? Colors.orangeAccent
                        : Colors.grey.shade300,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 16),
                for (final s in steps) _stepRow(s.$1, s.$2),
                if (widget.phase != MlPreparePhase.error &&
                    widget.phase != MlPreparePhase.ready) ...[
                  const SizedBox(height: 16),
                  const LinearProgressIndicator(),
                ],
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
      MlPreparePhase.scoring,
      MlPreparePhase.ready,
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
      case MlResultTab.exam:
        return MlDatasetSplit.examOf(widget.samples);
    }
  }

  Widget _resultsBody() {
    final trainM = MlDatasetSplit.metrics(MlDatasetSplit.trainOf(widget.samples));
    final examM = MlDatasetSplit.metrics(MlDatasetSplit.examOf(widget.samples));
    final shown = _visibleSamples;

    return ListView(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 12),
      children: [
        _splitCard(trainM, examM),
        const SizedBox(height: 8),
        SegmentedButton<MlResultTab>(
          segments: const [
            ButtonSegment(value: MlResultTab.exam, label: Text('考试集')),
            ButtonSegment(value: MlResultTab.train, label: Text('训练集')),
            ButtonSegment(value: MlResultTab.all, label: Text('全部')),
          ],
          selected: {_tab},
          onSelectionChanged: (s) => setState(() => _tab = s.first),
        ),
        const SizedBox(height: 8),
        _metricsBanner(
          _tab == MlResultTab.exam
              ? examM
              : _tab == MlResultTab.train
                  ? trainM
                  : MlDatasetSplit.metrics(widget.samples),
          title: _tab == MlResultTab.exam
              ? '考试集结果'
              : _tab == MlResultTab.train
                  ? '训练集结果'
                  : '全部样本',
        ),
        const SizedBox(height: 8),
        if (shown.isEmpty)
          Text(
            '当前页无样本。可调整训练比例后重新进入机器学习。',
            style: TextStyle(color: Colors.grey.shade500),
          )
        else
          for (final s in shown) _sampleCard(s),
      ],
    );
  }

  Widget _splitCard(MlSplitMetrics trainM, MlSplitMetrics examM) {
    final pct = (widget.splitConfig.trainRatio * 100).round();
    return Card(
      color: const Color(0xFF222833),
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '切分设置 · ${widget.splitConfig.summary}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 15,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              '训练 $pct%（${trainM.total}条） / 考试 ${100 - pct}%（${examM.total}条）'
              ' · 按样本时间序切分 · 不展示K线图',
              style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
            ),
            Row(
              children: [
                const Text('训练比例', style: TextStyle(color: Colors.white70, fontSize: 12)),
                Expanded(
                  child: Slider(
                    value: widget.splitConfig.trainRatio,
                    min: 0.5,
                    max: 0.9,
                    divisions: 8,
                    label: '$pct%',
                    onChanged: (v) => widget.onSplitConfigChanged(
                      widget.splitConfig.copyWith(trainRatio: v),
                    ),
                  ),
                ),
                Text('$pct%', style: const TextStyle(color: Colors.white)),
              ],
            ),
            Text(
              '拖动比例会立即重切当前样本（无需重算）。导出时训练集用于训练，考试集用于评估。'
              '本结果仅供学习，不构成投资建议。',
              style: TextStyle(color: Colors.grey.shade500, fontSize: 11, height: 1.35),
            ),
          ],
        ),
      ),
    );
  }

  Widget _metricsBanner(MlSplitMetrics m, {required String title}) {
    return Card(
      color: const Color(0xFF1A2433),
      child: Padding(
        padding: const EdgeInsets.all(12),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '$title · ${m.total}条',
              style: const TextStyle(
                color: Colors.white,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              m.alphaSummary,
              style: const TextStyle(color: Colors.lightGreenAccent, fontSize: 13),
            ),
            Text(
              widget.modelLoaded ? m.predSummary : '模型预测：未加载模型',
              style: TextStyle(color: Colors.grey.shade300, fontSize: 12),
            ),
          ],
        ),
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
    final splitTag = s.split == MlSampleSplit.train ? '训练' : '考试';
    final pred = s.predictScore;
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
          '[$splitTag] ${s.side == 'B' ? '买' : '卖'} ${s.label} @x=${s.x}  '
          '价=${s.price.toStringAsFixed(3)}',
          style: const TextStyle(color: Colors.white, fontSize: 13),
        ),
        subtitle: Text(
          '${s.openTime} · ${s.labelReason}'
          '${pred != null ? " · 预测=${pred.toStringAsFixed(4)}" : ""}',
          style: TextStyle(color: Colors.grey.shade500, fontSize: 11),
        ),
      ),
    );
  }
}
