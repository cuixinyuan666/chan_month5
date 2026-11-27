import '../models/level_models.dart';

/// 相邻两段已完成线段的缺口标记。
///
/// [side] 只能是 `buy` 或 `sell`。
/// [barIndex] 是前段 [LevelSegmentN.endConfirmX]。
/// [price] 买入取后段 low，卖出取后段 high。
class WnmrSegmentMark {
  final int barIndex;
  final String side;
  final double price;

  const WnmrSegmentMark({
    required this.barIndex,
    required this.side,
    required this.price,
  });
}

/// 对调用者传入的已完成线段做相邻缺口判定。
///
/// [segments] 已按 idx 升序，且为同一 level。只比较相邻两段：
/// 前段 high < 后段 low → buy，price = 后段 low；
/// 前段 low > 后段 high → sell，price = 后段 high。
/// 区间重叠或端点相等都不输出。
List<WnmrSegmentMark> wnmrSegmentMarks(List<LevelSegmentN> segments) {
  if (segments.length < 2) return const [];

  final out = <WnmrSegmentMark>[];
  for (var i = 0; i < segments.length - 1; i++) {
    final prev = segments[i];
    final next = segments[i + 1];

    final String side;
    final double price;
    if (prev.high < next.low) {
      side = 'buy';
      price = next.low;
    } else if (prev.low > next.high) {
      side = 'sell';
      price = next.high;
    } else {
      continue;
    }

    out.add(
      WnmrSegmentMark(
        barIndex: prev.endConfirmX,
        side: side,
        price: price,
      ),
    );
  }
  return out;
}
