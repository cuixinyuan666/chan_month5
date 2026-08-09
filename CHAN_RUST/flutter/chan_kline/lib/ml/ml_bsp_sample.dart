import 'ml_dataset_split.dart';

/// K0 一类 BS 机器学习样本（对齐 Vespa demo5 事件样本）。
class MlBspSample {
  MlBspSample({
    required this.x,
    required this.side,
    required this.label,
    required this.price,
    required this.segIdx,
    required this.openTime,
    required this.featureFrozenAt,
    required this.features,
    this.isCorrect,
    this.labelReason = '',
    this.predictScore,
    this.split = MlSampleSplit.train,
  });

  /// 发现步 K0 idx（步进当下）
  final int x;
  /// B / S
  final String side;
  final String label;
  final double price;
  final int segIdx;
  final String openTime;
  final int featureFrozenAt;
  /// 扁平固定键特征（禁止 tip 动态名）
  final Map<String, double> features;

  /// α：跳末后是否仍正确；未标注前为 null
  bool? isCorrect;
  String labelReason;
  double? predictScore;

  /// 训练集 / 考试集
  MlSampleSplit split;

  String get sampleKey => '$side|$x|$label|$segIdx';

  int get libsvmLabel => (isCorrect ?? false) ? 1 : 0;

  Map<String, dynamic> toJson() => {
        'x': x,
        'side': side,
        'label': label,
        'price': price,
        'seg_idx': segIdx,
        'open_time': openTime,
        'feature_frozen_at': featureFrozenAt,
        'is_correct': isCorrect,
        'label_reason': labelReason,
        'predict_score': predictScore,
        'split': split == MlSampleSplit.train ? 'train' : 'exam',
        'features': features,
      };
}
