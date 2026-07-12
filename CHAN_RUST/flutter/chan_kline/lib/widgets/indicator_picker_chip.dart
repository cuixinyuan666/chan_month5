import 'package:flutter/material.dart';

/// 单个已选指标条目（双击名称可关闭）。
class IndicatorChipEntry {
  const IndicatorChipEntry({
    required this.label,
    required this.onDoubleTapClose,
  });

  final String label;
  final VoidCallback onDoubleTapClose;
}

/// 主/副图指标选择入口：↓ 打开选择；右侧名称双击关闭；悬停提高透明度。
class IndicatorPickerChip extends StatefulWidget {
  const IndicatorPickerChip({
    super.key,
    required this.entries,
    required this.onTapDropdown,
    this.maxWidth = 280,
    this.emptyHint = '未选',
  });

  final List<IndicatorChipEntry> entries;
  final VoidCallback onTapDropdown;
  final double maxWidth;
  /// 无勾选时右侧提示（主图关全部≈只留K0；副图关全部=收起）
  final String emptyHint;

  @override
  State<IndicatorPickerChip> createState() => _IndicatorPickerChipState();
}

class _IndicatorPickerChipState extends State<IndicatorPickerChip> {
  bool _hovered = false;

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    // 平时压低透明度，鼠标移入恢复
    final opacity = _hovered ? 1.0 : 0.38;
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: AnimatedOpacity(
        duration: const Duration(milliseconds: 120),
        opacity: opacity,
        child: Material(
          color: const Color(0xCC1A1A1A),
          borderRadius: BorderRadius.circular(4),
          child: ConstrainedBox(
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 2, 4, 2),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  // ↓：点击打开主/副图指标选择
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: widget.onTapDropdown,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                      child: Icon(
                        Icons.arrow_drop_down,
                        size: 18,
                        color: Color(0xFFE2E8F0),
                      ),
                    ),
                  ),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 4),
                      child: Text(
                        widget.emptyHint,
                        style: const TextStyle(
                          color: Color(0xFFE2E8F0),
                          fontSize: 11,
                          height: 1,
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          for (var i = 0; i < entries.length; i++) ...[
                            if (i > 0)
                              const Padding(
                                padding: EdgeInsets.symmetric(horizontal: 2),
                                child: Text(
                                  '/',
                                  style: TextStyle(
                                    color: Color(0x66FFFFFF),
                                    fontSize: 11,
                                    height: 1,
                                  ),
                                ),
                              ),
                            // 双击名称关闭该指标；超宽时均分压字
                            Flexible(
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onDoubleTap: entries[i].onDoubleTapClose,
                                child: Tooltip(
                                  message: '双击关闭「${entries[i].label}」',
                                  waitDuration: const Duration(milliseconds: 500),
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    alignment: Alignment.centerLeft,
                                    child: Text(
                                      entries[i].label,
                                      maxLines: 1,
                                      softWrap: false,
                                      style: const TextStyle(
                                        color: Color(0xFFE2E8F0),
                                        fontSize: 11,
                                        height: 1,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ],
                        ],
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}
