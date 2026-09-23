/// 筹码峰 / 笔数峰编号模式（与筹码分布分桶无关，仅影响 -1/+1/框内序号）。
enum PeakRankMode {
  /// 外侧离 K 高低边界由近到远；框内离收盘由近到远。
  spatial,
  /// 各区内按峰位 total 从大到小。
  volume,
}

/// 峰编号档位上限（筹码与笔数峰共用）。
class PeakRankConfig {
  const PeakRankConfig({
    this.mode = PeakRankMode.spatial,
    this.maxOuterRank = 5,
    this.maxInBoxRank = 3,
  });

  final PeakRankMode mode;
  final int maxOuterRank;
  final int maxInBoxRank;

  static const defaults = PeakRankConfig();

  int get clampedMaxOuter => maxOuterRank.clamp(3, 7);
  int get clampedMaxInBox => maxInBoxRank.clamp(1, 5);

  PeakRankConfig copyWith({
    PeakRankMode? mode,
    int? maxOuterRank,
    int? maxInBoxRank,
  }) {
    return PeakRankConfig(
      mode: mode ?? this.mode,
      maxOuterRank: maxOuterRank ?? this.maxOuterRank,
      maxInBoxRank: maxInBoxRank ?? this.maxInBoxRank,
    );
  }

  /// 配置指纹；变更时须清空筹码峰冻结仓。
  String get fingerprint =>
      '${mode.name}|$clampedMaxOuter|$clampedMaxInBox';

  Map<String, dynamic> toJson() => {
        'peakRankMode': mode.name,
        'maxOuterRank': maxOuterRank,
        'maxInBoxRank': maxInBoxRank,
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
    );
  }

  @override
  bool operator ==(Object other) =>
      other is PeakRankConfig &&
      other.mode == mode &&
      other.clampedMaxOuter == clampedMaxOuter &&
      other.clampedMaxInBox == clampedMaxInBox;

  @override
  int get hashCode => Object.hash(mode, clampedMaxOuter, clampedMaxInBox);
}
