/// 套件能力登记：机器人验证按 suiteId 决定是否挂载各阶段（逻辑保留在 lib，按需调用）。
class RobotVerifySuiteMeta {
  const RobotVerifySuiteMeta({
    required this.id,
    this.continuousStepFreeze = false,
  });

  final String id;

  /// 是否运行 [runContinuousStepFreezePhase]（连续单步 vs 走完瘦包，数据对拍）。
  final bool continuousStepFreeze;
}

const Map<String, RobotVerifySuiteMeta> kRobotVerifySuiteMetas = {
  'indicator_search_opt_20260930': RobotVerifySuiteMeta(
    id: 'indicator_search_opt_20260930',
    continuousStepFreeze: true,
  ),
};

RobotVerifySuiteMeta? metaForSuite(String suiteId) =>
    kRobotVerifySuiteMetas[suiteId];
