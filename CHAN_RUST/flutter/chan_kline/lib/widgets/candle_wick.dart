import 'dart:math' as math;

/// 上下影线粗细：跟随实体宽度。
///
/// 实体越宽影线越粗，避免 K 放宽后影线细成一条缝；
/// 最细 1 像素（缩到最小仍能看见），最粗 12 像素（再粗会压过细 K）。
/// 比例取实体宽度约 **40%**（略粗于约三分之一，与虚线框同显时更易辨）。
/// [widthMult]：按状态再乘一档（构建中略细、确认后略粗）。
double candleWickWidth(double bodyWidth, {double widthMult = 1.0}) {
  final m = widthMult.clamp(0.5, 1.5).toDouble();
  return (bodyWidth * 0.40 * m).clamp(1.0, 12.0).toDouble();
}

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
