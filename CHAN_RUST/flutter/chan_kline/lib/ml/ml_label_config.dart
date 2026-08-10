/// α 展望窗：发现后固定 K 根内可判定，禁止用全样本末态。
class MlLabelConfig {
  const MlLabelConfig({
    this.horizonBars = 64,
  });

  /// 发现 x 之后再看这么多根（含截断到数据末）
  final int horizonBars;

  MlLabelConfig copyWith({int? horizonBars}) => MlLabelConfig(
        horizonBars: (horizonBars ?? this.horizonBars).clamp(8, 512),
      );

  String get summary => '展望窗 ${horizonBars}K（发现后固定窗，非跳末）';
}
