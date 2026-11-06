import 'dart:math' as math;

/// 上下影线粗细：跟随实体宽度。
///
/// 实体越宽影线越粗，避免 K 放宽后影线细成一条缝；
/// 最细 1 像素（缩到最小仍能看见），最粗 8 像素（再粗会压过细 K）。
/// 比例取实体宽度约 **26%**（约四分之一），比初版 16% 更易辨认。
double candleWickWidth(double bodyWidth) =>
    (bodyWidth * 0.26).clamp(1.0, 8.0).toDouble();

/// 影线是否穿过实体。
///
/// 影线只该出现在实体之外的上下两段；实体中间留竖杠会把阳线、阴线从中劈开。
/// [bodyTop] / [bodyBottom] 是实体上下边沿（像素，上小下大）。
bool candleWickCrossesBody({
  required double wickTop,
  required double wickBottom,
  required double bodyTop,
  required double bodyBottom,
}) {
  final lo = math.min(wickTop, wickBottom);
  final hi = math.max(wickTop, wickBottom);
  return lo < bodyBottom - 0.5 && hi > bodyTop + 0.5;
}
