import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// Kn 主图层样式：连线 / 合并 / 中枢 **同层同色**。
/// 方案B：按 displayKn（≥0）取色/线宽；原始 Kn 蜡烛仍红绿涨跌，不走本表。
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

  /// 展示层色表：下标=displayKn（0=K0…）；合并/连线/中枢共用。
  static final _displayKnColors = <Color>[
    AppPalette.rgb(0xCC6366F1), // K0：蓝（原 K0 合并色）
    AppPalette.rgb(0xCCF59E0B), // K1：黄/琥珀
    AppPalette.rgb(0xCCEC4899), // K2：粉
    AppPalette.rgb(0xCC10B981), // K3：翠绿
    AppPalette.rgb(0xCC8B5CF6), // K4：紫
    AppPalette.rgb(0xCC06B6D4), // K5：青
    AppPalette.rgb(0xCCF97316), // K6：橙
  ];

  /// 按展示 Kn 取层色（0=K0，1=K1，…）。
  static Color colorForDisplayKn(int kn) {
    final i = kn < 0
        ? 0
        : (kn >= _displayKnColors.length ? _displayKnColors.length - 1 : kn);
    return _displayKnColors[i];
  }

  /// 方案B：按 displayKn（≥0）取样式；等同 [forDisplayKn]。
  static ChartLevelLineStyle forLevel(int displayKn) =>
      forDisplayKn(displayKn);

  /// 按 displayKn（≥0）取连线/合并样式。
  static ChartLevelLineStyle forDisplayKn(int displayKn) {
    assert(displayKn >= 0);
    final color = colorForDisplayKn(displayKn);
    if (displayKn == 0) {
      return ChartLevelLineStyle(
        color: color,
        strokeWidth: 1.9,
        buildingStrokeWidth: 1.5,
        buildingDashPattern: const [5, 4],
      );
    }
    final w = 2.2 + (displayKn - 1) * 0.5;
    switch (displayKn) {
      case 1:
        return ChartLevelLineStyle(
          color: color,
          strokeWidth: w,
          buildingStrokeWidth: w - 0.35,
          buildingDashPattern: const [5, 4],
        );
      case 2:
        return ChartLevelLineStyle(
          color: color,
          strokeWidth: w,
          buildingStrokeWidth: w - 0.35,
          buildingDashPattern: const [7, 5],
        );
      case 3:
        return ChartLevelLineStyle(
          color: color,
          strokeWidth: w,
          buildingStrokeWidth: w - 0.4,
          buildingDashPattern: const [5, 5],
          frozenDashPattern: const [8, 4],
        );
      case 4:
        return ChartLevelLineStyle(
          color: color,
          strokeWidth: w,
          buildingStrokeWidth: w - 0.4,
          buildingDashPattern: const [10, 6],
          frozenDashPattern: const [10, 5],
        );
      case 5:
        return ChartLevelLineStyle(
          color: color,
          strokeWidth: w,
          buildingStrokeWidth: w - 0.45,
          buildingDashPattern: const [6, 4],
          frozenDashPattern: const [8, 4],
        );
      default:
        return ChartLevelLineStyle(
          color: color,
          strokeWidth: w,
          buildingStrokeWidth: w - 0.45,
          buildingDashPattern: [8.0 + (displayKn % 3), 5.0],
          frozenDashPattern: displayKn >= 3 ? const [8, 4] : null,
        );
    }
  }

  /// 图例短标签（方案B：displayKn 即展示名）
  static String shortLabel(int displayKn) => 'K$displayKn';

  /// 按展示 Kn 取中枢样式（0=K0中枢，1=K1…）；色与同层合并/连线一致。
  static ChartLevelLineStyle forZS(int kn) {
    assert(kn >= 0);
    final color = colorForDisplayKn(kn);
    final w = 1.9 + kn * 0.25;
    return ChartLevelLineStyle(
      color: color,
      strokeWidth: w,
      buildingStrokeWidth: w - 0.3,
      buildingAlpha: 0.7,
      buildingDashPattern: const [4, 3],
    );
  }

  /// 买卖点配色：B=暖色族、S=冷色族；cls 越大同族内更浅。
  /// cls=1..9 分档；越界夹到 1..9。副图 BS，不跟主图层色。
  static final _bspBuyColors = <Color>[
    AppPalette.rgb(0xFFC62828), // 一类买：深红
    AppPalette.rgb(0xFFE53935), // 二类买：红
    AppPalette.rgb(0xFFFB8C00), // 三类买：橙
    AppPalette.rgb(0xFFFFA726), // 四类买：浅橙
    AppPalette.rgb(0xFFFFB74D), // 五类买
    AppPalette.rgb(0xFFFFCC80), // 六类买
    AppPalette.rgb(0xFFFFD54F), // 七类买：琥珀
    AppPalette.rgb(0xFFFFE082), // 八类买
    AppPalette.rgb(0xFFFFF59D), // 九类买：浅暖黄
  ];
  static final _bspSellColors = <Color>[
    AppPalette.rgb(0xFF1565C0), // 一类卖：深蓝
    AppPalette.rgb(0xFF1E88E5), // 二类卖：蓝
    AppPalette.rgb(0xFF00ACC1), // 三类卖：青
    AppPalette.rgb(0xFF26C6DA), // 四类卖
    AppPalette.rgb(0xFF4DD0E1), // 五类卖
    AppPalette.rgb(0xFF80DEEA), // 六类卖
    AppPalette.rgb(0xFF5C6BC0), // 七类卖：靛蓝
    AppPalette.rgb(0xFF7986CB), // 八类卖
    AppPalette.rgb(0xFF9FA8DA), // 九类卖：浅冷
  ];

  /// 按类与买卖取买卖点颜色（cls 越界时夹到 1..9）。
  static Color forBSP(int cls, bool isBuy) {
    final i = (cls.clamp(1, 9) - 1);
    return isBuy ? _bspBuyColors[i] : _bspSellColors[i];
  }
}
