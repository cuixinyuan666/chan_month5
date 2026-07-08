import '../models/bi_virtual_bar.dart';
import '../models/bi_virtual_bar_view.dart';

/// 由计算层笔 K 生成展示视图：相邻笔在共享分钟 K 上左/右半侧衔接，view 横向无缝。
List<BiVirtualBarView> buildBiVirtualBarViews(List<BiVirtualBar> bars) {
  if (bars.isEmpty) return const [];

  final n = bars.length;
  final viewX1 = List<int>.generate(n, (i) => bars[i].x1);
  final viewX2 = List<int>.generate(n, (i) => bars[i].x2);
  final endAtLeftHalf = List<bool>.filled(n, false);
  final startAtRightHalf = List<bool>.filled(n, false);

  for (var i = 0; i < n - 1; i++) {
    final cur = bars[i];
    final next = bars[i + 1];
    // 相邻笔 x 区间交叠：衔接 K = 上一笔末端分钟 K，两端同索引、半侧锚定
    if (next.x1 <= cur.x2) {
      final junction = cur.x2.clamp(cur.x1, next.x2);
      viewX2[i] = junction;
      viewX1[i + 1] = junction;
      endAtLeftHalf[i] = true;
      startAtRightHalf[i + 1] = true;
    }
  }

  for (var i = 0; i < n; i++) {
    if (viewX2[i] < viewX1[i]) {
      viewX2[i] = viewX1[i];
    }
  }

  return List.generate(
    n,
    (i) => BiVirtualBarView(
      bar: bars[i],
      viewX1: viewX1[i],
      viewX2: viewX2[i],
      endAtLeftHalf: endAtLeftHalf[i],
      startAtRightHalf: startAtRightHalf[i],
    ),
  );
}
