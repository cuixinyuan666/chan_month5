import 'level_models.dart';

/// 单根 K 十字线特征（Rust `BarCrosshairFeature`）。

class BarCrosshairFeature {
  final int idx;
  final String weekday;
  /// K线合并K线序（合并 K 线框内 0 起）
  final int mergeInnerSeq;

  /// 截至当步合并根数（逐K当下）
  final int mergeCount;

  /// 截至当步分型（未确认=UNKNOWN）
  final String combineFx;

  /// 截至当步 K线合并区间最高价（逐K当下）
  final double combineHigh;

  /// 截至当步 K线合并区间最低价（逐K当下）
  final double combineLow;

  /// 距最近冻结笔确认分型极点间隔根数（不含极点 K）；首笔确认前=0
  final int fractalPeakDist;

  /// 当步所属笔 K 序号；首笔确认前=null
  final int? biIdx;

  /// 当步笔 K 在笔K线合并框内序号（tooltip: 笔K线合并笔K线序，0 起）
  final int biMergeInnerSeq;

  /// 当步所在笔K线合并框已含笔 K 根数（逐K当下）
  final int biMergeCount;

  final double biOpen;
  final double biHigh;
  final double biLow;
  final double biClose;
  final double biVolume;

  /// 当步笔K线合并区间最高价（逐K当下）
  final double biCombineHigh;

  /// 当步笔K线合并区间最低价（逐K当下）
  final double biCombineLow;

  /// 当步笔K线合并分型（未确认=UNKNOWN）
  final String biCombineFx;

  /// 各层 N 段快照（levels[0]=1段/笔，levels[1]=2段/线段，…穷尽）
  final List<LevelSnap> levels;

  const BarCrosshairFeature({
    required this.idx,
    required this.weekday,
    required this.mergeInnerSeq,
    this.mergeCount = 1,
    this.combineFx = 'UNKNOWN',
    this.combineHigh = 0,
    this.combineLow = 0,
    this.fractalPeakDist = 0,
    this.biIdx,
    this.biMergeInnerSeq = 0,
    this.biMergeCount = 1,
    this.biOpen = 0,
    this.biHigh = 0,
    this.biLow = 0,
    this.biClose = 0,
    this.biVolume = 0,
    this.biCombineHigh = 0,
    this.biCombineLow = 0,
    this.biCombineFx = 'UNKNOWN',
    this.levels = const [],
  });

  factory BarCrosshairFeature.fromJson(Map<String, dynamic> json) {
    final biRaw = json['bi_idx'];
    return BarCrosshairFeature(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      weekday: json['weekday'] as String? ?? '-',
      mergeInnerSeq: (json['merge_inner_seq'] as num?)?.toInt() ?? 0,
      mergeCount: (json['merge_count'] as num?)?.toInt() ?? 1,
      combineFx: json['combine_fx'] as String? ?? 'UNKNOWN',
      combineHigh: (json['combine_high'] as num?)?.toDouble() ?? 0,
      combineLow: (json['combine_low'] as num?)?.toDouble() ?? 0,
      fractalPeakDist: (json['fractal_peak_dist'] as num?)?.toInt() ?? 0,
      biIdx: biRaw == null ? null : (biRaw as num).toInt(),
      biMergeInnerSeq: (json['bi_merge_inner_seq'] as num?)?.toInt() ?? 0,
      biMergeCount: (json['bi_merge_count'] as num?)?.toInt() ?? 1,
      biOpen: (json['bi_open'] as num?)?.toDouble() ?? 0,
      biHigh: (json['bi_high'] as num?)?.toDouble() ?? 0,
      biLow: (json['bi_low'] as num?)?.toDouble() ?? 0,
      biClose: (json['bi_close'] as num?)?.toDouble() ?? 0,
      biVolume: (json['bi_volume'] as num?)?.toDouble() ?? 0,
      biCombineHigh: (json['bi_combine_high'] as num?)?.toDouble() ?? 0,
      biCombineLow: (json['bi_combine_low'] as num?)?.toDouble() ?? 0,
      biCombineFx: json['bi_combine_fx'] as String? ?? 'UNKNOWN',
      levels: (json['levels'] as List? ?? const [])
          .map((e) => LevelSnap.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
