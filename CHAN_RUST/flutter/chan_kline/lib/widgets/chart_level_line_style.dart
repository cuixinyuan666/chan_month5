import 'package:flutter/material.dart';

/// Kn 主图连线样式（内部 level≥1；level=1 也可被 OverSeg 中枢框复用配色）。
/// 展示名 K(level-1)：level=2→K1连线，3→K2连线，…。旧称「n段」。
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

  /// 按内部 level 取样式（2→展示 K1连线，3→K2连线，…；level=1 蓝靛供中枢框）。
  /// 中枢复用本函数与合并/连线同层同色系；level=1 独立取蓝靛色以区别于 K1连线(琥珀)。
  static ChartLevelLineStyle forLevel(int level) {
    assert(level >= 1);
    if (level == 1) {
      // K0 中枢框：独立蓝靛色，不与 K1连线(琥珀 level=2)撞色
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
          buildingDashPattern: const [5, 5],
          frozenDashPattern: const [8, 4],
        );
      case 5:
        return ChartLevelLineStyle(
          color: _colors[3],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.4,
          buildingDashPattern: const [10, 6],
          frozenDashPattern: const [10, 5],
        );
      case 6:
        return ChartLevelLineStyle(
          color: _colors[4],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.45,
          buildingDashPattern: const [6, 4],
          frozenDashPattern: const [8, 4],
        );
      default:
        return ChartLevelLineStyle(
          color: _colors[i],
          strokeWidth: w,
          buildingStrokeWidth: w - 0.45,
          buildingDashPattern: [8.0 + (level % 3), 5.0],
          frozenDashPattern: level >= 4 ? const [8, 4] : null,
        );
    }
  }

  /// 图例短标签（连线展示名：内部 level → K(level-1)）
  static String shortLabel(int level) => 'K${level - 1}';

  /// 中枢专属配色（蓝青系，Normal）；下标=展示 Kn（0=K0中枢）。
  static const _zsColors = <Color>[
    Color(0xCC3B82F6), // K0中枢：蓝
    Color(0xCC06B6D4), // K1中枢：青
    Color(0xCC6366F1), // K2中枢：靛紫
    Color(0xCC14B8A6), // K3中枢：青绿
    Color(0xCC0EA5E9), // K4中枢：天蓝
    Color(0xCC22D3EE), // K5中枢：亮青
  ];

  /// 中枢专属配色（紫红系，OverSeg）；下标=展示 Kn（0=K0中枢）。
  /// 与 Normal 同层不同色，用于区分不同类型的中枢段。
  static const _zsOverSegColors = <Color>[
    Color(0xFF9B59B6), // K0中枢：紫
    Color(0xFFE74C3C), // K1中枢：红
    Color(0xFF3498DB), // K2中枢：蓝
    Color(0xFF2ECC71), // K3中枢：绿
    Color(0xFFD35400), // K4中枢：橙
    Color(0xFF1ABC9C), // K5中枢：青绿
  ];

  /// 按展示 Kn 取中枢样式（0=K0中枢，1=K1中枢，…）。
  static ChartLevelLineStyle forZS(int kn) {
    assert(kn >= 0);
    final i = kn.clamp(0, _zsColors.length - 1);
    final w = 1.9 + kn * 0.25;
    return ChartLevelLineStyle(
      color: _zsColors[i],
      strokeWidth: w,
      buildingStrokeWidth: w - 0.3,
      buildingAlpha: 0.7,
      buildingDashPattern: const [4, 3],
    );
  }

  /// 按展示 Kn 取 OverSeg 中枢样式（0=K0中枢，1=K1中枢，…）。
  /// 同层中枢与 Normal 配色不同，用于区分不同类型的中枢段。
  static ChartLevelLineStyle forZSOverSeg(int kn) {
    assert(kn >= 0);
    final i = kn.clamp(0, _zsOverSegColors.length - 1);
    final w = 1.9 + kn * 0.25;
    return ChartLevelLineStyle(
      color: _zsOverSegColors[i],
      strokeWidth: w,
      buildingStrokeWidth: w - 0.3,
      buildingAlpha: 0.7,
      buildingDashPattern: const [4, 3],
    );
  }

  /// 三类买卖点（BSP）专属配色：买=红、卖=绿（涨红跌绿），三类用不同色阶区分。
  /// cls=1/2/3 与 isBuy 组合出 6 色；主图点标记按类用不同形状（圆/三角/菱形）增强辨识。
  static const _bspBuyColors = <Color>[
    Color(0xFFE53935), // 一类买：红
    Color(0xFFFB8C00), // 二类买：橙红
    Color(0xFFFDD835), // 三类买：黄
  ];
  static const _bspSellColors = <Color>[
    Color(0xFF43A047), // 一类卖：绿
    Color(0xFF00ACC1), // 二类卖：青
    Color(0xFF8E24AA), // 三类卖：紫
  ];

  /// 按类与买卖取买卖点颜色（cls 越界时夹到 1..3）。
  static Color forBSP(int cls, bool isBuy) {
    final i = (cls.clamp(1, 3) - 1);
    return isBuy ? _bspBuyColors[i] : _bspSellColors[i];
  }
}
