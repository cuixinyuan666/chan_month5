import 'package:flutter/material.dart';

import 'chip_config.dart';

/// 笔数分布配置（主图左侧；与筹码同构，仅 K0）。
class TickDistConfig {
  const TickDistConfig({
    this.enabled = false,
    this.bucketStep = 0.01,
    this.stretchLevel = 5,
    this.paneWidth = 88,
    this.sColor = const Color(0xC722C55E),
    this.bColor = const Color(0xC7DC2626),
    this.wColor = const Color(0xC79CA3AF),
    this.peakLineEnabled = false,
    this.peakLineWidth = 1.2,
    this.peakLineDashed = true,
    this.peakDotRadius = 2.5,
  });

  final bool enabled;
  final double bucketStep;
  final int stretchLevel;
  final double paneWidth;
  final Color sColor;
  final Color bColor;
  final Color wColor;
  final bool peakLineEnabled;
  final double peakLineWidth;
  final bool peakLineDashed;
  final double peakDotRadius;

  ChipConfig toChipConfig() => ChipConfig(
        enabled: enabled,
        bucketStep: bucketStep,
        stretchLevel: stretchLevel,
        paneWidth: paneWidth,
        sColor: sColor,
        bColor: bColor,
        wColor: wColor,
        peakLineEnabled: peakLineEnabled,
        peakLineWidth: peakLineWidth,
        peakLineDashed: peakLineDashed,
        peakDotRadius: peakDotRadius,
      );

  TickDistConfig copyWith({
    bool? enabled,
    double? bucketStep,
    int? stretchLevel,
    double? paneWidth,
    bool? peakLineEnabled,
  }) {
    return TickDistConfig(
      enabled: enabled ?? this.enabled,
      bucketStep: bucketStep ?? this.bucketStep,
      stretchLevel: stretchLevel ?? this.stretchLevel,
      paneWidth: paneWidth ?? this.paneWidth,
      sColor: sColor,
      bColor: bColor,
      wColor: wColor,
      peakLineEnabled: peakLineEnabled ?? this.peakLineEnabled,
      peakLineWidth: peakLineWidth,
      peakLineDashed: peakLineDashed,
      peakDotRadius: peakDotRadius,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'bucketStep': bucketStep,
        'stretchLevel': stretchLevel,
        'paneWidth': paneWidth,
        'peakLineEnabled': peakLineEnabled,
      };

  factory TickDistConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TickDistConfig();
    return TickDistConfig(
      enabled: json['enabled'] as bool? ?? false,
      bucketStep: (json['bucketStep'] as num?)?.toDouble() ?? 0.01,
      stretchLevel: (json['stretchLevel'] as num?)?.toInt() ?? 5,
      paneWidth: (json['paneWidth'] as num?)?.toDouble() ?? 88,
      peakLineEnabled: json['peakLineEnabled'] as bool? ?? false,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TickDistConfig &&
      other.enabled == enabled &&
      other.bucketStep == bucketStep &&
      other.stretchLevel == stretchLevel &&
      other.paneWidth == paneWidth &&
      other.peakLineEnabled == peakLineEnabled;

  @override
  int get hashCode =>
      Object.hash(enabled, bucketStep, stretchLevel, paneWidth, peakLineEnabled);
}
