import 'package:flutter/material.dart';

/// 单个已选指标条目（单击：灰度关闭 / 再点打开）。
class IndicatorChipEntry {
  const IndicatorChipEntry({
    required this.label,
    required this.onTapToggle,
    required this.displayLevel,
    this.muted = false,
    this.valueText,
  });

  final String label;
  final VoidCallback onTapToggle;
  /// 显示层号：同层用 /，跨层用 ※ 分隔（chip 须先按 displayLevel 排序）
  final int displayLevel;
  /// true=灰度关闭（不绘制），再点恢复
  final bool muted;
  /// 副图变量读数（跟在名称后方，如 "12.3"；无则只显示名称）
  final String? valueText;
}

/// 主/副图左上角读数条：展示已选指标名 + 变量值；单击名称灰度开关。
class IndicatorPickerChip extends StatefulWidget {
  const IndicatorPickerChip({
    super.key,
    required this.entries,
    this.maxWidth = 280,
    this.maxHeight = 120,
    this.horizontalScroll = false,
  });

  final List<IndicatorChipEntry> entries;
  final double maxWidth;
  final double maxHeight;
  final bool horizontalScroll;

  @override
  State<IndicatorPickerChip> createState() => _IndicatorPickerChipState();
}

class _IndicatorPickerChipState extends State<IndicatorPickerChip> {
  bool _hovered = false;

  static const _activeColor = Color(0xFFFFFFFF);
  static const _mutedColor = Color(0xFF6B7280);
  static const _sepActive = Color(0xAAFFFFFF);
  static const _sepMuted = Color(0x556B7280);
  static const _valueColor = Color(0xFF38BDF8);

  Widget _separator(IndicatorChipEntry cur, IndicatorChipEntry prev) {
    final bothMuted = cur.muted && prev.muted;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        cur.displayLevel != prev.displayLevel ? ' ※ ' : '/',
        style: TextStyle(
          color: bothMuted ? _sepMuted : _sepActive,
          fontSize: 12,
          height: 1.2,
        ),
      ),
    );
  }

  Widget _entryText(IndicatorChipEntry e) {
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: e.onTapToggle,
      child: Tooltip(
        message: e.muted ? '单击打开「${e.label}」' : '单击关闭「${e.label}」',
        waitDuration: const Duration(milliseconds: 500),
        child: Text.rich(
          TextSpan(
            children: [
              TextSpan(
                text: e.label,
                style: TextStyle(
                  color: e.muted ? _mutedColor : _activeColor,
                  fontSize: 12,
                  fontWeight: e.muted ? FontWeight.w400 : FontWeight.w600,
                  height: 1.2,
                  decoration:
                      e.muted ? TextDecoration.lineThrough : TextDecoration.none,
                  decorationColor: _mutedColor,
                ),
              ),
              if (e.valueText != null && e.valueText!.isNotEmpty)
                TextSpan(
                  text: ':${e.valueText}',
                  style: TextStyle(
                    color: e.muted ? _mutedColor : _valueColor,
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                    height: 1.2,
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _horizontalList(List<IndicatorChipEntry> entries) {
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          for (var i = 0; i < entries.length; i++) ...[
            if (i > 0) _separator(entries[i], entries[i - 1]),
            _entryText(entries[i]),
          ],
        ],
      ),
    );
  }

  Widget _wrapList(List<IndicatorChipEntry> entries) {
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 0,
      runSpacing: 2,
      children: [
        for (var i = 0; i < entries.length; i++) ...[
          if (i > 0) _separator(entries[i], entries[i - 1]),
          _entryText(entries[i]),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    final opacity = _hovered ? 1.0 : 0.88;
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
            constraints: BoxConstraints(
              maxWidth: widget.maxWidth,
              maxHeight: widget.maxHeight,
            ),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(6, 2, 6, 2),
              child: entries.isEmpty
                  ? const Text(
                      '暂无已选指标',
                      style: TextStyle(
                        color: _mutedColor,
                        fontSize: 12,
                        height: 1.2,
                      ),
                    )
                  : widget.horizontalScroll
                      ? _horizontalList(entries)
                      : SingleChildScrollView(
                          child: _wrapList(entries),
                        ),
            ),
          ),
        ),
      ),
    );
  }
}
