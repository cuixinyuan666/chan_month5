import 'package:flutter/material.dart';

import 'chip_config.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// 笔数分布配置（主图左侧；与筹码同构，仅 K0）。
class TickDistConfig {
  const TickDistConfig({
    this.enabled = false,
    this.bucketStep = 0.01,
    this.stretchLevel = 5,
    this.paneWidth = 88,
    this.sColor,
    this.bColor,
    this.wColor,
    this.peakLineEnabled = false,
    this.peakLineWidth = 1.2,
    this.peakLineMode = PeakLineMode.bySign,
    this.peakDotRadius = 2.5,
  });

  final bool enabled;
  final double bucketStep;
  final int stretchLevel;
  final double paneWidth;
  final Color? sColor;
  final Color? bColor;
  final Color? wColor;

  Color get sColorResolved => sColor ?? AppPalette.rgb(0xC722C55E);
  Color get bColorResolved => bColor ?? AppPalette.rgb(0xC7DC2626);
  Color get wColorResolved => wColor ?? AppPalette.rgb(0xC79CA3AF);
  final bool peakLineEnabled;
  final double peakLineWidth;
  final PeakLineMode peakLineMode;
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
        peakLineMode: peakLineMode,
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
      peakLineMode: peakLineMode,
      peakDotRadius: peakDotRadius,
    );
  }

  Map<String, dynamic> toJson() => {
        'enabled': enabled,
        'bucketStep': bucketStep,
        'stretchLevel': stretchLevel,
        'paneWidth': paneWidth,
        'peakLineEnabled': peakLineEnabled,
        'peakLineMode': peakLineMode.name,
      };

  factory TickDistConfig.fromJson(Map<String, dynamic>? json) {
    if (json == null) return const TickDistConfig();
    return TickDistConfig(
      enabled: json['enabled'] as bool? ?? false,
      bucketStep: (json['bucketStep'] as num?)?.toDouble() ?? 0.01,
      stretchLevel: (json['stretchLevel'] as num?)?.toInt() ?? 5,
      paneWidth: (json['paneWidth'] as num?)?.toDouble() ?? 88,
      peakLineEnabled: json['peakLineEnabled'] as bool? ?? false,
      peakLineMode: peakLineModeFromJson(json),
    );
  }

  @override
  bool operator ==(Object other) =>
      other is TickDistConfig &&
      other.enabled == enabled &&
      other.bucketStep == bucketStep &&
      other.stretchLevel == stretchLevel &&
      other.paneWidth == paneWidth &&
      other.peakLineMode == peakLineMode &&
      other.peakLineEnabled == peakLineEnabled;

  @override
  int get hashCode => Object.hash(
        enabled,
        bucketStep,
        stretchLevel,
        paneWidth,
        peakLineMode,
        peakLineEnabled,
      );
}
