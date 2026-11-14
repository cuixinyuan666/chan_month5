import 'package:flutter/material.dart';
import '../models/bar_feature_lookup.dart';

/// 十字线 tooltip 桥：KlineChart 向父布局(main.dart)广播「是否显示 + 当前行」，
/// 使父层可把 tooltip 停靠为左侧独立子窗口（不再悬浮覆盖 K 线）。
///
/// - [shown]：是否处于 withTooltip 态（开十字线且含信息框）。
/// - [rows]：当前聚焦 K 的结构化行；十字线移动即更新。
/// - [scrollController]：由 KlineChart 注入，父层面板复用同一控制器（滚轮翻页同源）。
/// - [onRequestClose]：父层关闭钮回调，KlineChart 注入自身 _closeTooltipKeepCrosshair。
class CrosshairTooltipBridge {
  final ValueNotifier<bool> shown = ValueNotifier<bool>(false);
  final ValueNotifier<List<CrosshairTooltipRow>> rows =
      ValueNotifier<List<CrosshairTooltipRow>>(const []);

  ScrollController? scrollController;
  VoidCallback? onRequestClose;

  /// 点了关闭钮之后的这一小段时间（毫秒时间戳）。
  ///
  /// 关闭钮在面板上，面板在主图外面：点下去时鼠标会先被算进主窗口，
  /// 主窗口随即接手十字线并把信息开关重新打开，关闭等于没点。
  /// 这段时间内主窗口不得把信息开关升回去。
  int suppressTooltipUntilMs = 0;

  bool get tooltipSuppressed =>
      DateTime.now().millisecondsSinceEpoch < suppressTooltipUntilMs;

  void dispose() {
    shown.dispose();
    rows.dispose();
  }
}
