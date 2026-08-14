/// 演示步：点击「下一步」推进一格；phase 控制高亮原本/本次说明区。
enum TaskDemoWalkPhase { before, after, both }

class TaskDemoWalkthroughStep {
  const TaskDemoWalkthroughStep({
    required this.stepIdx,
    required this.phase,
    required this.caption,
  });

  final int stepIdx;
  final TaskDemoWalkPhase phase;
  final String caption;

  factory TaskDemoWalkthroughStep.fromJson(Map<String, dynamic> json) {
    final phaseRaw = json['phase']?.toString() ?? 'after';
    TaskDemoWalkPhase phase;
    switch (phaseRaw) {
      case 'before':
        phase = TaskDemoWalkPhase.before;
      case 'both':
        phase = TaskDemoWalkPhase.both;
      default:
        phase = TaskDemoWalkPhase.after;
    }
    final idx = json['stepIdx'];
    return TaskDemoWalkthroughStep(
      stepIdx: idx is int ? idx : (idx is num ? idx.toInt() : 0),
      phase: phase,
      caption: json['caption']?.toString() ?? '',
    );
  }
}
