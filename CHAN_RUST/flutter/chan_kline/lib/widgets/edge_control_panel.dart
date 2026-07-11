import 'package:flutter/material.dart';

/// 加载设置浮层（由标题栏「设置」按钮打开，可贴左/右）。
class EdgeControlPanel extends StatelessWidget {
  const EdgeControlPanel({
    super.key,
    required this.edge,
    required this.onClose,
    required this.onCycleEdge,
    required this.child,
  });

  /// 0=左 1=右
  final int edge;
  final VoidCallback onClose;
  final VoidCallback onCycleEdge;
  final Widget child;

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
        color: const Color(0xF01A1A1A),
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
                    icon: const Icon(Icons.close, color: Color(0xFFE2E8F0), size: 18),
                  ),
                  const Expanded(
                    child: Text(
                      '加载设置',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                    ),
                  ),
                  IconButton(
                    tooltip: '换边吸附',
                    onPressed: onCycleEdge,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints.tightFor(width: 36, height: 36),
                    icon: const Icon(Icons.swap_horiz, size: 18),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: SingleChildScrollView(
                padding: const EdgeInsets.fromLTRB(10, 8, 10, 12),
                child: child,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
