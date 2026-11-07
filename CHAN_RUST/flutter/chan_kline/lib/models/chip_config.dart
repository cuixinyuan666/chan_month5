import 'package:flutter/material.dart';

import 'peak_rank_config.dart';

/// 筹码/笔数峰延长线线型：solid 全实线 / dashed 全虚线 / bySign 按符号（+虚 −实 IN实）。
enum PeakLineMode {
  solid,
  dashed,
  bySign,
}

/// 配置反序列化兼容：新版读 peakLineMode；旧版 peakLineDashed(bool) 映射
/// true→dashed、false→solid；两者皆无则默认 bySign。
PeakLineMode peakLineModeFromJson(Map<String, dynamic>? json) {
  final name = json?['peakLineMode'] as String?;
  if (name != null) {
    return PeakLineMode.values.firstWhere(
      (e) => e.name == name,
      orElse: () => PeakLineMode.bySign,
    );
  }
  final old = json?['peakLineDashed'] as bool?;
  if (old != null) return old ? PeakLineMode.dashed : PeakLineMode.solid;
  return PeakLineMode.bySign;
}

/// 筹码分布配置（进程内；与 Skill 字段对齐）。
class ChipConfig {
  const ChipConfig({
    this.enabled = false,
    this.bucketStep = 0.01,
    this.stretchLevel = 5,
    this.peakRankMode = PeakRankMode.spatial,
    this.maxOuterRank = 5,
    this.maxInBoxRank = 3,
    this.chipPeakPureRank = 7,
    this.paneWidth = 88,
    this.sColor = const Color(0xC722C55E),
    this.bColor = const Color(0xC7DC2626),
    this.wColor = const Color(0xC79CA3AF),
    this.peakLineEnabled = false,
    this.peakLineWidth = 1.2,
    this.peakLineMode = PeakLineMode.bySign,
    this.peakDotRadius = 2.5,
  });

  /// 总开关（与副图勾选叠加：关则不画）
  final bool enabled;
  /// 价格桶宽（元）
  final double bucketStep;
  /// 对比度拉伸 1..20
  final int stretchLevel;
  /// 筹码峰编号：空间序 / 量级序（与笔数峰共用；纯量级已拆为主图独立指标）
  final PeakRankMode peakRankMode;
  /// 外侧 ±n 登记上限 3..7
  final int maxOuterRank;
  /// 框内 INn 档数 1..5
  final int maxInBoxRank;
  /// 纯量级筹码峰取前 N 个峰（1..12）
  final int chipPeakPureRank;
  /// 主图右侧筹码区宽度
  final double paneWidth;

  PeakRankConfig get peakRankConfig => PeakRankConfig(
        mode: peakRankMode,
        maxOuterRank: maxOuterRank,
        maxInBoxRank: maxInBoxRank,
      );

  /// 空间序方案配置（主图「筹码峰·空间序」指标）。
  PeakRankConfig get peakRankSpatialConfig => PeakRankConfig(
        mode: PeakRankMode.spatial,
        maxOuterRank: maxOuterRank,
        maxInBoxRank: maxInBoxRank,
      );

  /// 量级序方案配置（主图「筹码峰·量级序」指标）。
  PeakRankConfig get peakRankVolumeConfig => PeakRankConfig(
        mode: PeakRankMode.volume,
        maxOuterRank: maxOuterRank,
        maxInBoxRank: maxInBoxRank,
      );

  /// 纯量级方案配置（主图「筹码峰·纯量级」指标；忽略 OHLC，全局取前 N）。
  PeakRankConfig get peakRankPureConfig => PeakRankConfig(
        mode: PeakRankMode.pure,
        maxOuterRank: maxOuterRank,
        maxInBoxRank: maxInBoxRank,
        maxPureRank: chipPeakPureRank,
      );
  final Color sColor;
  final Color bColor;
  /// 灰度（无方向分笔）柱色
  final Color wColor;
  final bool peakLineEnabled;
  final double peakLineWidth;
  final PeakLineMode peakLineMode;
  final double peakDotRadius;

  ChipConfig copyWith({
    bool? enabled,
    double? bucketStep,
    int? stretchLevel,
    PeakRankMode? peakRankMode,
    int? maxOuterRank,
    int? maxInBoxRank,
    int? chipPeakPureRank,
    double? paneWidth,
    Color? sColor,
    Color? bColor,
    Color? wColor,
    bool? peakLineEnabled,
    double? peakLineWidth,
    PeakLineMode? peakLineMode,
    double? peakDotRadius,
  }) {
    return ChipConfig(
      enabled: enabled ?? this.enabled,
      bucketStep: bucketStep ?? this.bucketStep,
      stretchLevel: stretchLevel ?? this.stretchLevel,
      peakRankMode: peakRankMode ?? this.peakRankMode,
      maxOuterRank: maxOuterRank ?? this.maxOuterRank,
      maxInBoxRank: maxInBoxRank ?? this.maxInBoxRank,
      chipPeakPureRank: chipPeakPureRank ?? this.chipPeakPureRank,
      paneWidth: paneWidth ?? this.paneWidth,
      sColor: sColor ?? this.sColor,
      bColor: bColor ?? this.bColor,
      wColor: wColor ?? this.wColor,
      peakLineEnabled: peakLineEnabled ?? this.peakLineEnabled,
      peakLineWidth: peakLineWidth ?? this.peakLineWidth,
      peakLineMode: peakLineMode ?? this.peakLineMode,
      peakDotRadius: peakDotRadius ?? this.peakDotRadius,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'bucketStep': bucketStep,
        'stretchLevel': stretchLevel,
        'peakRankMode': peakRankMode.name,
        'maxOuterRank': maxOuterRank,
        'maxInBoxRank': maxInBoxRank,
        'chipPeakPureRank': chipPeakPureRank,
        'paneWidth': paneWidth,
        'peakLineEnabled': peakLineEnabled,
        'peakLineWidth': peakLineWidth,
        'peakLineMode': peakLineMode.name,
      };

  factory ChipConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ChipConfig();
    return ChipConfig(
      enabled: json['enabled'] as bool? ?? false,
      bucketStep: (json['bucketStep'] as num?)?.toDouble() ?? 0.01,
      stretchLevel: (json['stretchLevel'] as num?)?.toInt() ?? 5,
      peakRankMode: PeakRankConfig.fromJson(json).mode,
      maxOuterRank: (json['maxOuterRank'] as num?)?.toInt() ?? 5,
      maxInBoxRank: (json['maxInBoxRank'] as num?)?.toInt() ?? 3,
      chipPeakPureRank: (json['chipPeakPureRank'] as num?)?.toInt() ?? 7,
      paneWidth: (json['paneWidth'] as num?)?.toDouble() ?? 88,
      peakLineEnabled: json['peakLineEnabled'] as bool? ?? false,
      peakLineWidth: (json['peakLineWidth'] as num?)?.toDouble() ?? 1.2,
      peakLineMode: peakLineModeFromJson(json),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChipConfig &&
      other.enabled == enabled &&
      other.bucketStep == bucketStep &&
      other.stretchLevel == stretchLevel &&
      other.peakRankMode == peakRankMode &&
      other.maxOuterRank == maxOuterRank &&
      other.maxInBoxRank == maxInBoxRank &&
      other.chipPeakPureRank == chipPeakPureRank &&
      other.paneWidth == paneWidth &&
      other.sColor == sColor &&
      other.bColor == bColor &&
      other.wColor == wColor &&
      other.peakLineEnabled == peakLineEnabled &&
      other.peakLineWidth == peakLineWidth &&
      other.peakLineMode == peakLineMode &&
      other.peakDotRadius == peakDotRadius;

  @override
  int get hashCode => Object.hash(
        enabled,
        bucketStep,
        stretchLevel,
        peakRankMode,
        maxOuterRank,
        maxInBoxRank,
        chipPeakPureRank,
        paneWidth,
        sColor,
        bColor,
        wColor,
        peakLineEnabled,
        peakLineWidth,
        peakLineMode,
        peakDotRadius,
      );
}
