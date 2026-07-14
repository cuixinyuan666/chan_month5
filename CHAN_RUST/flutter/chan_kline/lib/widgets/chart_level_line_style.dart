import 'package:flutter/material.dart';

/// Kn 主图连线样式（内部 level≥1；level=1 仅跨段中枢框 K0跨段中枢使用，连线/合并≥2）。
/// 展示名 K(level-1)：level=2→K1连线，3→K2连线，…；level=1→K0跨段中枢框。旧称「n段」。
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
    Color(0xCCF59E0B), // 展示 K1连线（内部 level=2）：琥珀
    Color(0xCCEC4899), // 展示 K2连线（内部 level=3）：玫红
    Color(0xCC10B981), // 展示 K3连线（内部 level=4）：翠绿
    Color(0xCC8B5CF6), // 展示 K4连线（内部 level=5）：紫
    Color(0xCC06B6D4), // 展示 K5连线（内部 level=6）：青
    Color(0xCCF97316), // 展示 K6连线（内部 level=7）：橙
  ];

  /// 按内部 level 取样式（level=1→K0跨段中枢框；2→展示 K1连线，3→K2连线，…）。
  /// KuaDuan(n) 复用本函数与合并/连线同层同色系；level=1 为 K0跨段中枢，独立取蓝靛色以区别于 K1连线(琥珀)。
  static ChartLevelLineStyle forLevel(int level) {
    assert(level >= 1);
    if (level == 1) {
      // K0跨段中枢框：独立蓝靛色，不与 K1连线(琥珀 level=2)撞色
      return const ChartLevelLineStyle(
        color: Color(0xCC3B82F6),
        strokeWidth: 1.9,
        buildingStrokeWidth: 1.5,
        buildingDashPattern: const [5, 4],
      );
    }
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

  /// 图例短标签（连线展示名：内部 level → K(level-1)）
  static String shortLabel(int level) => 'K${level - 1}';
}
