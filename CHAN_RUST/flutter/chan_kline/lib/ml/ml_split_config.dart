/// 训练集 / 考试集切分配置（按样本 x 时间序）。
class MlSplitConfig {
  const MlSplitConfig({
    this.trainRatio = 0.7,
  });

  /// 训练集占比 0.5..0.9；考试集 = 1 - trainRatio
  final double trainRatio;

  double get examRatio => 1.0 - trainRatio;

  MlSplitConfig copyWith({double? trainRatio}) {
    final r = (trainRatio ?? this.trainRatio).clamp(0.5, 0.9);
    return MlSplitConfig(trainRatio: r);
  }

  String get summary =>
      '训练${(trainRatio * 100).round()}% / 考试${(examRatio * 100).round()}%（按样本时间序）';
}
