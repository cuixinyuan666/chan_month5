import 'level_models.dart';

/// 单根 K 十字线特征（Rust `BarCrosshairFeature`）。
class BarCrosshairFeature {
  final int idx;
  final String weekday;
  /// K0合并K0序（合并框内 0 起）
  final int mergeInnerSeq;

  /// 截至当步合并根数（逐K当下）
  final int mergeCount;

  /// 截至当步分型（未确认=UNKNOWN）
  final String combineFx;

  /// 截至当步 K0合并区间最高价（逐K当下）
  final double combineHigh;

  /// 截至当步 K0合并区间最低价（逐K当下）
  final double combineLow;

  /// 距最近冻结K0连线确认分型极点间隔根数（不含极点 K）；首K0连线确认前=0
  final int fractalPeakDist;

  /// 当步所属 K1 序号；首 K1 确认前=null
  final int? k1Idx;

  /// 当步 K1 在 K1合并框内序号（0 起）
  final int k1MergeInnerSeq;

  /// 当步所在 K1合并框已含 K1 根数（逐K当下）
  final int k1MergeCount;

  final double k1Open;
  final double k1High;
  final double k1Low;
  final double k1Close;
  final double k1Volume;

  /// 当步 K1合并区间最高价（逐K当下）
  final double k1CombineHigh;

  /// 当步 K1合并区间最低价（逐K当下）
  final double k1CombineLow;

  /// 当步 K1合并分型（未确认=UNKNOWN）
  final String k1CombineFx;

  /// 各层 Kn 快照（levels[0]=K1/K0连线，levels[1]=K2/K1连线，…穷尽）
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
    this.k1Idx,
    this.k1MergeInnerSeq = 0,
    this.k1MergeCount = 1,
    this.k1Open = 0,
    this.k1High = 0,
    this.k1Low = 0,
    this.k1Close = 0,
    this.k1Volume = 0,
    this.k1CombineHigh = 0,
    this.k1CombineLow = 0,
    this.k1CombineFx = 'UNKNOWN',
    this.levels = const [],
  });

  factory BarCrosshairFeature.fromJson(Map<String, dynamic> json) {
    final k1Raw = json['k1_idx'];
    return BarCrosshairFeature(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      weekday: json['weekday'] as String? ?? '-',
      mergeInnerSeq: (json['merge_inner_seq'] as num?)?.toInt() ?? 0,
      mergeCount: (json['merge_count'] as num?)?.toInt() ?? 1,
      combineFx: json['combine_fx'] as String? ?? 'UNKNOWN',
      combineHigh: (json['combine_high'] as num?)?.toDouble() ?? 0,
      combineLow: (json['combine_low'] as num?)?.toDouble() ?? 0,
      fractalPeakDist: (json['fractal_peak_dist'] as num?)?.toInt() ?? 0,
      k1Idx: k1Raw == null ? null : (k1Raw as num).toInt(),
      k1MergeInnerSeq: (json['k1_merge_inner_seq'] as num?)?.toInt() ?? 0,
      k1MergeCount: (json['k1_merge_count'] as num?)?.toInt() ?? 1,
      k1Open: (json['k1_open'] as num?)?.toDouble() ?? 0,
      k1High: (json['k1_high'] as num?)?.toDouble() ?? 0,
      k1Low: (json['k1_low'] as num?)?.toDouble() ?? 0,
      k1Close: (json['k1_close'] as num?)?.toDouble() ?? 0,
      k1Volume: (json['k1_volume'] as num?)?.toDouble() ?? 0,
      k1CombineHigh: (json['k1_combine_high'] as num?)?.toDouble() ?? 0,
      k1CombineLow: (json['k1_combine_low'] as num?)?.toDouble() ?? 0,
      k1CombineFx: json['k1_combine_fx'] as String? ?? 'UNKNOWN',
      levels: (json['levels'] as List? ?? const [])
          .map((e) => LevelSnap.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
