/// 展示轨分型判断成立事件（确认式打点；x=触发当步 K0，禁止整框回填）。
class FractalJudgmentEvent {
  final int x;
  final String fx; // TOP / BOTTOM
  final bool truncated;

  const FractalJudgmentEvent({
    required this.x,
    required this.fx,
    this.truncated = false,
  });
}
