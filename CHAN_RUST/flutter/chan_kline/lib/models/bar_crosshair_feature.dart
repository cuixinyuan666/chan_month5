/// 单根 K 十字线特征（Rust `BarCrosshairFeature`）。

class BarCrosshairFeature {

  final int idx;

  final String weekday;

  final int mergeInnerSeq;

  /// 截至当步合并根数（逐K当下）

  final int mergeCount;

  /// 截至当步分型（未确认=UNKNOWN）

  final String combineFx;

  /// 截至当步合并区间最高价（逐K当下）

  final double combineHigh;

  /// 截至当步合并区间最低价（逐K当下）

  final double combineLow;

  /// 距最近冻结笔确认分型极点间隔根数（不含极点 K）；首笔确认前=0

  final int fractalPeakDist;



  const BarCrosshairFeature({

    required this.idx,

    required this.weekday,

    required this.mergeInnerSeq,

    this.mergeCount = 1,

    this.combineFx = 'UNKNOWN',

    this.combineHigh = 0,

    this.combineLow = 0,

    this.fractalPeakDist = 0,

  });



  factory BarCrosshairFeature.fromJson(Map<String, dynamic> json) {

    return BarCrosshairFeature(

      idx: (json['idx'] as num?)?.toInt() ?? 0,

      weekday: json['weekday'] as String? ?? '-',

      mergeInnerSeq: (json['merge_inner_seq'] as num?)?.toInt() ?? 1,

      mergeCount: (json['merge_count'] as num?)?.toInt() ?? 1,

      combineFx: json['combine_fx'] as String? ?? 'UNKNOWN',

      combineHigh: (json['combine_high'] as num?)?.toDouble() ?? 0,

      combineLow: (json['combine_low'] as num?)?.toDouble() ?? 0,

      fractalPeakDist: (json['fractal_peak_dist'] as num?)?.toInt() ?? 0,

    );

  }

}

