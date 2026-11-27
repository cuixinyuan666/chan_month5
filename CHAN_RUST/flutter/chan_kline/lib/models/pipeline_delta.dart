import 'bar_crosshair_feature.dart';
import 'kline_combine_bundle.dart';

/// Rust `PipelineDelta`：当步 1 行 `bar_feature` + 其余 Full 字段（flatten）。
/// 不含历史 `bar_features` 数组。
class PipelineDelta {
  final int idx;
  final BarCrosshairFeature barFeature;

  /// 除 bar_features 外的当步结构（fromJson 时 bar_features 为空）。
  final KlineCombineBundle structure;

  const PipelineDelta({
    required this.idx,
    required this.barFeature,
    required this.structure,
  });

  factory PipelineDelta.fromJson(
    Map<String, dynamic> json, {
    bool slim = false,
  }) {
    final rawFeat = json['bar_feature'];
    if (rawFeat is! Map) {
      throw FormatException('PipelineDelta 缺少 bar_feature');
    }
    return PipelineDelta(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      barFeature: BarCrosshairFeature.fromJson(
        Map<String, dynamic>.from(rawFeat),
      ),
      structure: KlineCombineBundle.fromJson(json, slim: slim),
    );
  }
}
