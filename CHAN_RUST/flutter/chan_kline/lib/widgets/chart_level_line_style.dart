import 'package:flutter/material.dart';

/// Kn 主图连线样式（level≥2：K2=线段，K3+ 用色/线型/粗细区分；旧称「n段」）。
class ChartLevelLineStyle {
  /// 连线颜色（含 alpha）
  final Color color;

  /// 已冻结段线宽
  final double strokeWidth;

  /// 构建中段线宽
  final double buildingStrokeWidth;

  /// 构建中段透明度系数（乘在 color.alpha 上）
  final double buildingAlpha;

  /// 已冻结段虚线 pattern（null=实线；值为 [画, 空, 画, 空, …] 像素长度）
  final List<double>? frozenDashPattern;

  /// 构建中段虚线 pattern
  final List<double> buildingDashPattern;

  const ChartLevelLineStyle({
    required this.color,
    required this.strokeWidth,
    required this.buildingStrokeWidth,
    this.buildingAlpha = 0.65,
    this.frozenDashPattern,
    this.buildingDashPattern = const [5, 4],
  });

  static const _colors = <Color>[
    Color(0xCCF59E0B), // K2：琥珀
    Color(0xCCEC4899), // K3：玫红
    Color(0xCC10B981), // K4：翠绿
    Color(0xCC8B5CF6), // K5：紫
    Color(0xCC06B6D4), // K6：青
    Color(0xCCF97316), // K7：橙
  ];

  /// 按 Kn 层级取样式（level=2→K2，3→K3，…）。
  static ChartLevelLineStyle forLevel(int level) {
    assert(level >= 2);
    final i = (level - 2).clamp(0, _colors.length - 1);
    final w = 2.2 + (level - 2) * 0.5;
    switch (level) {
      case 2:
        return ChartLevelLineStyle(
          color: _colors[0],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.35,
          buildingDashPattern: const [5, 4],
        );
      case 3:
        return ChartLevelLineStyle(
          color: _colors[1],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.35,
          buildingDashPattern: const [7, 5],
        );
      case 4:
        return ChartLevelLineStyle(
          color: _colors[2],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.4,
          frozenDashPattern: const [10, 4],
          buildingDashPattern: const [5, 5],
        );
      case 5:
        return ChartLevelLineStyle(
          color: _colors[3],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.4,
          buildingDashPattern: const [10, 6],
        );
      case 6:
        return ChartLevelLineStyle(
          color: _colors[4],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.45,
          frozenDashPattern: const [12, 4, 2, 4],
          buildingDashPattern: const [6, 4],
        );
      default:
        final parity = (level - 2) % 2 == 0;
        return ChartLevelLineStyle(
          color: _colors[i],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.45,
          frozenDashPattern: parity ? null : const [8, 4],
          buildingDashPattern: [8.0 + (level % 3), 5.0],
        );
    }
  }

  /// 图例短标签（状态栏用）
  static String shortLabel(int level) => 'K$level';
}
