import 'level_models.dart';

/// 单根 K 上的中枢命中（Rust `BarZsHit`）。
class BarZsHit {
  final int kn;
  final int seq;
  final double high;
  final double low;
  final bool isSure;

  const BarZsHit({
    required this.kn,
    required this.seq,
    required this.high,
    required this.low,
    this.isSure = false,
  });

  factory BarZsHit.fromJson(Map<String, dynamic> json) {
    return BarZsHit(
      kn: (json['kn'] as num?)?.toInt() ?? 0,
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      isSure: json['is_sure'] as bool? ?? false,
    );
  }
}

/// 单根 K 上的一类 BS discovery（Rust `BarBs1Hit`）。
class BarBs1Hit {
  final int kn;
  final String side;
  final String label;
  final int x;
  final double price;

  const BarBs1Hit({
    required this.kn,
    required this.side,
    required this.label,
    required this.x,
    required this.price,
  });

  factory BarBs1Hit.fromJson(Map<String, dynamic> json) {
    return BarBs1Hit(
      kn: (json['kn'] as num?)?.toInt() ?? 0,
      side: json['side'] as String? ?? '',
      label: json['label'] as String? ?? '',
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
    );
  }
}

/// 单根 K 十字线特征（Rust `BarCrosshairFeature`）。
class BarCrosshairFeature {
  final int idx;
  final String weekday;
  /// K0合并K0序（合并框内 0 起）
  final int mergeInnerSeq;

  /// 截至当步合并根数（逐K当下）
  final int mergeCount;

  /// 截至当步 K0 合并框序号（第几个合并框，1 起；0=未成框）
  final int mergeBoxSeq;

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

  /// k1_* 字段=structure0 虚拟K（K0连线合成；键名历史兼容，≠displayKn=1）
  /// 各层 Kn 快照（方案B：levels[0].level=0=K0连线…）
  final List<LevelSnap> levels;

  /// 当步盖住本 K0 的中枢（逐K当下）
  final List<BarZsHit> zsHits;

  /// 当步 discovery 的一类 BS（x==本 idx）
  final List<BarBs1Hit> bs1Hits;

  const BarCrosshairFeature({
    required this.idx,
    required this.weekday,
    required this.mergeInnerSeq,
    this.mergeCount = 1,
    this.mergeBoxSeq = -1,
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
    this.zsHits = const [],
    this.bs1Hits = const [],
  });

  factory BarCrosshairFeature.fromJson(Map<String, dynamic> json) {
    final k1Raw = json['k1_idx'];
    return BarCrosshairFeature(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      weekday: json['weekday'] as String? ?? '-',
      mergeInnerSeq: (json['merge_inner_seq'] as num?)?.toInt() ?? 0,
      mergeCount: (json['merge_count'] as num?)?.toInt() ?? 1,
      mergeBoxSeq: (json['merge_box_seq'] as num?)?.toInt() ?? -1,
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
      zsHits: (json['zs_hits'] as List? ?? const [])
          .map((e) => BarZsHit.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      bs1Hits: (json['bs1_hits'] as List? ?? const [])
          .map((e) => BarBs1Hit.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
    );
  }
}
