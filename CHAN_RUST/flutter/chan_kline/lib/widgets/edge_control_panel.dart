import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// 加载设置浮层（由标题栏「设置」按钮打开，可贴左/右）。
class EdgeControlPanel extends StatelessWidget {
  const EdgeControlPanel({
    super.key,
    required this.edge,
    required this.onClose,
    required this.onCycleEdge,
    required this.child,
    this.title = '设置',
    this.scrollController,
    this.stickyHeader,
  });

  /// 0=左 1=右
  final int edge;
  final VoidCallback onClose;
  final VoidCallback onCycleEdge;
  final Widget child;

  /// 标题条文字。面板里已不只「加载设置」（还有主题、主图口径、维护同步），
  /// 统一叫「设置」，避免标题与内容对不上。
  final String title;

  /// 滚动控制器（可选）：调用方用它监听偏移，算「当前该吸顶哪个分类」。
  final ScrollController? scrollController;

  /// 吸顶条（可选）：叠在滚动区顶部、不随内容滚走。
  ///
  /// 2026-11-17 用户明确：滚轮下滚时分类标题（如「数据与加载」）要一直可见。
  /// 由调用方按滚动偏移算出当前分类后传进来，这里只负责叠放，不猜语义。
  final Widget? stickyHeader;

  static const double panelW = 300;

  bool get _left => edge == 0;

  @override
  Widget build(BuildContext context) {
    return Positioned(
      left: _left ? 0 : null,
      right: _left ? null : 0,
      top: 36,
      bottom: 8,
      width: panelW,
      child: Material(
        elevation: 8,
        color: AppPalette.rgb(0xF01A1A1A),
        clipBehavior: Clip.hardEdge,
        borderRadius: BorderRadius.horizontal(
          left: _left ? Radius.zero : const Radius.circular(8),
          right: _left ? const Radius.circular(8) : Radius.zero,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 40,
              child: Row(
                children: [
                  IconButton(
                    tooltip: '关闭',
                    onPressed: onClose,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                    icon: Icon(
                      Icons.close,
                      color: AppPalette.controlInk,
                      size: 18,
                    ),
                  ),
                  Expanded(
                    child: Text(
                      title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                          fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '换边吸附',
                    onPressed: onCycleEdge,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                     icon: Icon(
                       Icons.swap_horiz,
                       color: AppPalette.controlInk,
                       size: 18,
                     ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: Stack(
                children: [
                  Positioned.fill(
                    child: SingleChildScrollView(
                      key: const Key('settings-scroll'),
                      controller: scrollController,
                      padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                      child: child,
                    ),
                  ),
                  if (stickyHeader != null)
                    Positioned(
                      left: 0,
                      right: 0,
                      top: 0,
                      child: stickyHeader!,
                    ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
