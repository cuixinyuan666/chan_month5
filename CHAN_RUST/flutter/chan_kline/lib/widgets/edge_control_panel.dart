import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// 设置浮层（由标题栏「设置」按钮打开，可贴左/右）。
///
/// 外壳只负责吸附、关闭和换边。分区、搜索和滚动都在里面的分区台，
/// 当前分区标题钉在内容区顶部，不随页内滚动离开。
class EdgeControlPanel extends StatelessWidget {
  const EdgeControlPanel({
    super.key,
    required this.edge,
    required this.onClose,
    required this.onCycleEdge,
    required this.child,
    this.title = '设置',
  });

  /// 0=左 1=右
  final int edge;
  final VoidCallback onClose;
  final VoidCallback onCycleEdge;
  final Widget child;
  final String title;

  static const double panelW = 432;

  bool get _left => edge == 0;

  @override
  Widget build(BuildContext context) {
    final radius = const Radius.circular(18);
    return Positioned(
      left: _left ? 0 : null,
      right: _left ? null : 0,
      top: 36,
      bottom: 8,
      width: panelW,
      child: Material(
        elevation: 12,
        shadowColor: const Color(0x66000000),
        surfaceTintColor: Colors.transparent,
        color: AppPalette.surface,
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.horizontal(
            left: _left ? Radius.zero : radius,
            right: _left ? radius : Radius.zero,
          ),
          side: BorderSide(color: AppPalette.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            SizedBox(
              height: 52,
              child: DecoratedBox(
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(color: AppPalette.accent, width: 2),
                  ),
                ),
                child: Row(
                  children: [
                    IconButton(
                      tooltip: '关闭',
                      onPressed: onClose,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 36, height: 36),
                      icon: Icon(
                        Icons.close,
                        color: AppPalette.controlInk,
                        size: 18,
                      ),
                    ),
                    Expanded(
                      child: Column(
                        mainAxisAlignment: MainAxisAlignment.center,
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            '工作台',
                            style: TextStyle(
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              color: AppPalette.accent,
                            ),
                          ),
                          Text(
                            title,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 16,
                              height: 1.1,
                              fontWeight: FontWeight.w700,
                              color: AppPalette.textPrimary,
                            ),
                          ),
                        ],
                      ),
                    ),
                    IconButton(
                      tooltip: '换边吸附',
                      onPressed: onCycleEdge,
                      padding: EdgeInsets.zero,
                      constraints:
                          const BoxConstraints.tightFor(width: 36, height: 36),
                      icon: Icon(
                        Icons.swap_horiz,
                        color: AppPalette.controlInk,
                        size: 18,
                      ),
                    ),
                  ],
                ),
              ),
            ),
            Expanded(child: child),
          ],
        ),
      ),
    );
  }
}
