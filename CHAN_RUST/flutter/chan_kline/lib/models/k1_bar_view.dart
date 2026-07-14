import 'k1_bar.dart';

/// K1 bar 展示视图：计算层 [K1Bar] 的 x 裁剪，仅用于绘制。
///
/// OHLC / dir / confirmX 仍取自完整 K0连线区间，不参与合并 K1 bar、K1连线分析、ML。
/// 相邻 K0连线在共享分钟 K 上：上一根末端占左半侧，下一根起始占右半侧，于中轴无缝衔接。
class K1BarView {
  final K1Bar bar;
  final int viewX1;
  final int viewX2;
  /// 末端落在 viewX2 对应分钟 K 左半侧（右边界=该 K 中轴）
  final bool endAtLeftHalf;
  /// 起始落在 viewX1 对应分钟 K 右半侧（左边界=该 K 中轴）
  final bool startAtRightHalf;

  const K1BarView({
    required this.bar,
    required this.viewX1,
    required this.viewX2,
    this.endAtLeftHalf = false,
    this.startAtRightHalf = false,
  });

  int get idx => bar.idx;
  int get dir => bar.dir;
  double get open => bar.open;
  double get high => bar.high;
  double get low => bar.low;
  double get close => bar.close;
  int get confirmX => bar.confirmX;
  bool get isUp => bar.isUp;

  /// 计算层原始区间（调试对照）
  int get rawX1 => bar.x1;
  int get rawX2 => bar.x2;
}
