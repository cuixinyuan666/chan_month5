/// 筹码峰 / 笔数峰编号模式（与筹码分布分桶无关，仅影响 -1/+1/框内序号）。
enum PeakRankMode {
  /// 外侧离 K 高低边界由近到远；框内离收盘由近到远。
  spatial,
  /// 各区内按峰位 total 从大到小。
  volume,
  /// 纯量级：忽略 K 的 OHLC 区间，按峰位 total 全局降序取前 N（后缀 PURE1..PUREn）。
  pure,
}

/// 峰编号档位上限（筹码与笔数峰共用）。
class PeakRankConfig {
  const PeakRankConfig({
    this.mode = PeakRankMode.spatial,
    this.maxOuterRank = 5,
    this.maxInBoxRank = 3,
    this.maxPureRank = 7,
  });

  final PeakRankMode mode;
  final int maxOuterRank;
  final int maxInBoxRank;
  /// 纯量级模式取前 N 个峰（默认 7，范围 1..12）。
  final int maxPureRank;

  static const defaults = PeakRankConfig();

  int get clampedMaxOuter => maxOuterRank.clamp(3, 7);
  int get clampedMaxInBox => maxInBoxRank.clamp(1, 5);
  int get clampedMaxPure => maxPureRank.clamp(1, 12);

  PeakRankConfig copyWith({
    PeakRankMode? mode,
    int? maxOuterRank,
    int? maxInBoxRank,
    int? maxPureRank,
  }) {
    return PeakRankConfig(
      mode: mode ?? this.mode,
      maxOuterRank: maxOuterRank ?? this.maxOuterRank,
      maxInBoxRank: maxInBoxRank ?? this.maxInBoxRank,
      maxPureRank: maxPureRank ?? this.maxPureRank,
    );
  }

  /// 配置指纹；spatial/volume 与历史一致，变更时须清空对应方案的筹码峰冻结仓。
  String get fingerprint =>
      '${mode.name}|$clampedMaxOuter|$clampedMaxInBox';

  /// 冻结仓分区键：spatial/volume 沿用 fingerprint；pure 额外含 maxPureRank。
  String get schemeId =>
      mode == PeakRankMode.pure ? 'pure|$clampedMaxPure' : fingerprint;

  Map<String, dynamic> toJson() => {
        'peakRankMode': mode.name,
        'maxOuterRank': maxOuterRank,
        'maxInBoxRank': maxInBoxRank,
        'maxPureRank': maxPureRank,
      };

  factory PeakRankConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return defaults;
    final modeName = json['peakRankMode'] as String? ?? 'spatial';
    final mode = PeakRankMode.values.firstWhere(
      (e) => e.name == modeName,
      orElse: () => PeakRankMode.spatial,
    );
    return PeakRankConfig(
      mode: mode,
      maxOuterRank: (json['maxOuterRank'] as num?)?.toInt() ?? 5,
      maxInBoxRank: (json['maxInBoxRank'] as num?)?.toInt() ?? 3,
      maxPureRank: (json['maxPureRank'] as num?)?.toInt() ?? 7,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PeakRankConfig &&
      other.mode == mode &&
      other.clampedMaxOuter == clampedMaxOuter &&
      other.clampedMaxInBox == clampedMaxInBox &&
      other.clampedMaxPure == clampedMaxPure;

  @override
  int get hashCode =>
      Object.hash(mode, clampedMaxOuter, clampedMaxInBox, clampedMaxPure);
}
