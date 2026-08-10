/// 训练 / 验证 / 测试 切分（按样本 x 时间序，前→后）。
class MlSplitConfig {
  const MlSplitConfig({
    this.trainRatio = 0.6,
    this.validRatio = 0.2,
  }) : assert(trainRatio > 0 && validRatio > 0);

  /// 训练集占比；测试 = 1 - train - valid
  final double trainRatio;
  final double validRatio;

  double get testRatio {
    final t = 1.0 - trainRatio - validRatio;
    return t < 0 ? 0 : t;
  }

  MlSplitConfig copyWith({double? trainRatio, double? validRatio}) {
    var tr = (trainRatio ?? this.trainRatio).clamp(0.4, 0.8);
    var vr = (validRatio ?? this.validRatio).clamp(0.1, 0.4);
    // 保证测试至少约 10%
    if (tr + vr > 0.9) {
      final scale = 0.9 / (tr + vr);
      tr *= scale;
      vr *= scale;
    }
    return MlSplitConfig(trainRatio: tr, validRatio: vr);
  }

  String get summary =>
      '训练${(trainRatio * 100).round()}% / '
      '验证${(validRatio * 100).round()}% / '
      '测试${(testRatio * 100).round()}%（时序）';
}
