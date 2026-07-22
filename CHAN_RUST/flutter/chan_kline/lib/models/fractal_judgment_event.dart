/// 展示轨分型判断成立事件（确认式打点；x=触发当步 K0，禁止整框回填）。
/// 中组=[fractalX1,fractalX2]；右组=[rightX1,rightX2]（第三元素的 K0 跨度，全层同构）。
class FractalJudgmentEvent {
  final int x;
  final String fx; // TOP / BOTTOM
  final bool truncated;
  /// 分型中组左端
  final int fractalX1;
  /// 分型中组右端
  final int fractalX2;
  /// 右组左沿（进入右组第一根 K0）
  final int rightX1;
  /// 右组右沿（K0 单根时常=rightX1；Kn 为第三单元 viewX2）
  final int rightX2;

  const FractalJudgmentEvent({
    required this.x,
    required this.fx,
    this.truncated = false,
    this.fractalX1 = -1,
    this.fractalX2 = -1,
    this.rightX1 = -1,
    this.rightX2 = -1,
  });
}
