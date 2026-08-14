import 'dart:io';

import 'package:flutter/material.dart';

import 'task_demo_manifest.dart';
import 'task_demo_walkthrough_step.dart';

/// 开发阶段：主图底部叠层——上原本 / 下本次 + 点击下一步步进演示
class TaskDemoWalkthroughOverlay extends StatelessWidget {
  const TaskDemoWalkthroughOverlay({
    super.key,
    required this.manifest,
    required this.steps,
    required this.walkIndex,
    required this.currentStepIdx,
    required this.beforeMd,
    required this.hasBeforePng,
    required this.onPrev,
    required this.onNext,
    required this.onExitWalkthrough,
    required this.onExitDevelopmentPhase,
    this.autoPlayActive = false,
    this.onToggleAutoPlay,
  });

  final TaskDemoManifest manifest;
  final List<TaskDemoWalkthroughStep> steps;
  final int walkIndex;
  final int currentStepIdx;
  final String? beforeMd;
  final bool hasBeforePng;
  final VoidCallback onPrev;
  final VoidCallback onNext;
  final VoidCallback onExitWalkthrough;
  final VoidCallback onExitDevelopmentPhase;
  final bool autoPlayActive;
  final VoidCallback? onToggleAutoPlay;

  TaskDemoWalkthroughStep? get _step =>
      walkIndex >= 0 && walkIndex < steps.length ? steps[walkIndex] : null;

  @override
  Widget build(BuildContext context) {
    final step = _step;
    final phase = step?.phase ?? TaskDemoWalkPhase.both;
    final highlightBefore =
        phase == TaskDemoWalkPhase.before || phase == TaskDemoWalkPhase.both;
    final highlightAfter =
        phase == TaskDemoWalkPhase.after || phase == TaskDemoWalkPhase.both;

    return Material(
      elevation: 12,
      color: const Color(0xF0101018),
      child: SafeArea(
        top: false,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            _buildHeader(context),
            Flexible(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(12, 0, 12, 8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    _buildComparePanels(highlightBefore, highlightAfter),
                    if (step != null) ...[
                      const SizedBox(height: 8),
                      Container(
                        padding: const EdgeInsets.all(8),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E293B),
                          borderRadius: BorderRadius.circular(6),
                          border: Border.all(color: const Color(0xFF3B82F6)),
                        ),
                        child: Text(
                          '当前演示步 ${walkIndex + 1}/${steps.length} · '
                          'K0 step=$currentStepIdx\n${step.caption}',
                          style: const TextStyle(fontSize: 12, height: 1.35),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
            ),
            _buildControls(context),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      color: const Color(0xFF0F172A),
      child: Row(
        children: [
          const Icon(Icons.school, size: 18, color: Color(0xFF60A5FA)),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              '开发演示：${manifest.title}',
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          IconButton(
            tooltip: '退出本次演示',
            icon: const Icon(Icons.close, size: 18),
            onPressed: onExitWalkthrough,
          ),
        ],
      ),
    );
  }

  Widget _buildComparePanels(bool highlightBefore, bool highlightAfter) {
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Expanded(
            child: _Panel(
              title: '原本实现',
              accent: Colors.orange.shade700,
              highlighted: highlightBefore,
              summary: manifest.beforeSummary,
              body: beforeMd,
              imagePath: hasBeforePng
                  ? '${manifest.demoDirPath}${Platform.pathSeparator}before.png'
                  : null,
              dimmed: manifest.isNewFeature,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: _Panel(
              title: '本次实现',
              accent: Colors.lightGreen.shade600,
              highlighted: highlightAfter,
              summary: manifest.afterSummary,
              body: null,
              imagePath: null,
              dimmed: false,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildControls(BuildContext context) {
    final atStart = walkIndex <= 0;
    final atEnd = walkIndex >= steps.length - 1;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: Color(0x33FFFFFF))),
      ),
      child: Row(
        children: [
          TextButton(
            onPressed: onExitDevelopmentPhase,
            child: const Text('退出演示阶段', style: TextStyle(fontSize: 11)),
          ),
          const Spacer(),
          if (onToggleAutoPlay != null)
            IconButton(
              tooltip: autoPlayActive ? '暂停自动步进' : '自动步进演示',
              icon: Icon(
                autoPlayActive ? Icons.pause_circle : Icons.play_circle,
                size: 22,
              ),
              onPressed: onToggleAutoPlay,
            ),
          OutlinedButton(
            onPressed: atStart ? null : onPrev,
            child: const Text('上一步'),
          ),
          const SizedBox(width: 8),
          FilledButton.icon(
            onPressed: atEnd ? null : onNext,
            icon: const Icon(Icons.navigate_next, size: 18),
            label: Text(atEnd ? '演示结束' : '下一步'),
          ),
        ],
      ),
    );
  }
}

class _Panel extends StatelessWidget {
  const _Panel({
    required this.title,
    required this.accent,
    required this.highlighted,
    required this.summary,
    this.body,
    this.imagePath,
    required this.dimmed,
  });

  final String title;
  final Color accent;
  final bool highlighted;
  final String summary;
  final String? body;
  final String? imagePath;
  final bool dimmed;

  @override
  Widget build(BuildContext context) {
    final border = highlighted
        ? Border.all(color: accent, width: 2)
        : Border.all(color: const Color(0x22FFFFFF));
    return Opacity(
      opacity: dimmed ? 0.45 : 1,
      child: Container(
        padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(
          color: accent.withValues(alpha: highlighted ? 0.12 : 0.05),
          borderRadius: BorderRadius.circular(6),
          border: border,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.bold,
                color: accent,
              ),
            ),
            const SizedBox(height: 4),
            Text(summary, style: const TextStyle(fontSize: 11)),
            if (imagePath != null) ...[
              const SizedBox(height: 4),
              Image.file(
                File(imagePath!),
                height: 56,
                fit: BoxFit.contain,
                errorBuilder: (_, _, _) => const SizedBox.shrink(),
              ),
            ],
            if (body != null && body!.trim().isNotEmpty)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: Text(
                  body!.length > 280 ? '${body!.substring(0, 280)}…' : body!,
                  style: const TextStyle(fontSize: 10, height: 1.3),
                ),
              ),
          ],
        ),
      ),
    );
  }
}
