import 'package:flutter/material.dart';

/// 筹码分布配置（进程内；与 Skill 字段对齐）。
class ChipConfig {
  const ChipConfig({
    this.enabled = true,
    this.bucketStep = 0.1,
    this.stretchLevel = 5,
    this.paneWidth = 88,
    this.sColor = const Color(0xC722C55E),
    this.bColor = const Color(0xC7DC2626),
    this.peakLineEnabled = true,
    this.peakLineColor = const Color(0xFF2563EB),
    this.peakLineWidth = 1.2,
    this.peakLineDashed = true,
    this.peakDotColor = const Color(0xFFF59E0B),
    this.peakDotRadius = 2.5,
  });

  /// 总开关（与副图勾选叠加：关则不画）
  final bool enabled;
  /// 价格桶宽（元）
  final double bucketStep;
  /// 对比度拉伸 1..20
  final int stretchLevel;
  /// 主图右侧筹码区宽度
  final double paneWidth;
  final Color sColor;
  final Color bColor;
  final bool peakLineEnabled;
  final Color peakLineColor;
  final double peakLineWidth;
  final bool peakLineDashed;
  final Color peakDotColor;
  final double peakDotRadius;

  ChipConfig copyWith({
    bool? enabled,
    double? bucketStep,
    int? stretchLevel,
    double? paneWidth,
    Color? sColor,
    Color? bColor,
    bool? peakLineEnabled,
    Color? peakLineColor,
    double? peakLineWidth,
    bool? peakLineDashed,
    Color? peakDotColor,
    double? peakDotRadius,
  }) {
    return ChipConfig(
      enabled: enabled ?? this.enabled,
      bucketStep: bucketStep ?? this.bucketStep,
      stretchLevel: stretchLevel ?? this.stretchLevel,
      paneWidth: paneWidth ?? this.paneWidth,
      sColor: sColor ?? this.sColor,
      bColor: bColor ?? this.bColor,
      peakLineEnabled: peakLineEnabled ?? this.peakLineEnabled,
      peakLineColor: peakLineColor ?? this.peakLineColor,
      peakLineWidth: peakLineWidth ?? this.peakLineWidth,
      peakLineDashed: peakLineDashed ?? this.peakLineDashed,
      peakDotColor: peakDotColor ?? this.peakDotColor,
      peakDotRadius: peakDotRadius ?? this.peakDotRadius,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'bucketStep': bucketStep,
        'stretchLevel': stretchLevel,
        'paneWidth': paneWidth,
        'peakLineEnabled': peakLineEnabled,
        'peakLineWidth': peakLineWidth,
        'peakLineDashed': peakLineDashed,
      };

  factory ChipConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const ChipConfig();
    return ChipConfig(
      enabled: json['enabled'] as bool? ?? true,
      bucketStep: (json['bucketStep'] as num?)?.toDouble() ?? 0.1,
      stretchLevel: (json['stretchLevel'] as num?)?.toInt() ?? 5,
      paneWidth: (json['paneWidth'] as num?)?.toDouble() ?? 88,
      peakLineEnabled: json['peakLineEnabled'] as bool? ?? true,
      peakLineWidth: (json['peakLineWidth'] as num?)?.toDouble() ?? 1.2,
      peakLineDashed: json['peakLineDashed'] as bool? ?? true,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is ChipConfig &&
      other.enabled == enabled &&
      other.bucketStep == bucketStep &&
      other.stretchLevel == stretchLevel &&
      other.paneWidth == paneWidth &&
      other.sColor == sColor &&
      other.bColor == bColor &&
      other.peakLineEnabled == peakLineEnabled &&
      other.peakLineColor == peakLineColor &&
      other.peakLineWidth == peakLineWidth &&
      other.peakLineDashed == peakLineDashed &&
      other.peakDotColor == peakDotColor &&
      other.peakDotRadius == peakDotRadius;

  @override
  int get hashCode => Object.hash(
        enabled,
        bucketStep,
        stretchLevel,
        paneWidth,
        sColor,
        bColor,
        peakLineEnabled,
        peakLineColor,
        peakLineWidth,
        peakLineDashed,
        peakDotColor,
        peakDotRadius,
      );
}
