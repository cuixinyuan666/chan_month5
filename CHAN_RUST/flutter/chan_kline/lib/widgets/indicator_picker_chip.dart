import 'package:flutter/material.dart';

/// 单个指标条目（单击切换选中；已选白字，未选灰字+删除线）。
class IndicatorChipEntry {
  const IndicatorChipEntry({
    required this.label,
    required this.onTapToggle,
    required this.displayLevel,
    this.selected = true,
    this.valueText,
  });

  final String label;
  final VoidCallback onTapToggle;
  /// 显示层号：同层用 /，跨层用 ※ 分隔（chip 须先按 displayLevel 排序）
  final int displayLevel;
  /// true=已选中（白字）；false=未选中（灰字+删除线）
  final bool selected;
  /// 副图变量读数（跟在名称后方，如 "12.3"；无则只显示名称）
  final String? valueText;
}

/// 主/副图指标列表：展开后直接展示全量可选指标，单击切换选中态。
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
  /// 列表最大高度，超出纵向滚动
  final double maxHeight;
  /// 手机端横向滚动，避免多行撑高挤占副图标记区
  final bool horizontalScroll;

  @override
  State<IndicatorPickerChip> createState() => _IndicatorPickerChipState();
}

class _IndicatorPickerChipState extends State<IndicatorPickerChip> {
  bool _hovered = false;

  static const _activeColor = Color(0xFFFFFFFF);
  static const _inactiveColor = Color(0xFF6B7280);
  static const _sepActive = Color(0xAAFFFFFF);
  static const _sepInactive = Color(0x556B7280);
  static const _valueColor = Color(0xFF38BDF8);

  TextStyle _labelStyle(IndicatorChipEntry e) {
    final on = e.selected;
    return TextStyle(
      color: on ? _activeColor : _inactiveColor,
      fontSize: 12,
      fontWeight: on ? FontWeight.w600 : FontWeight.w400,
      height: 1.2,
      decoration: on ? TextDecoration.none : TextDecoration.lineThrough,
      decorationColor: _inactiveColor,
    );
  }

  TextStyle _valueStyle(IndicatorChipEntry e) => TextStyle(
        color: e.selected ? _valueColor : _inactiveColor,
        fontSize: 12,
        fontWeight: FontWeight.w600,
        height: 1.2,
      );

  Widget _separator(IndicatorChipEntry cur, IndicatorChipEntry prev) {
    final bothOn = cur.selected && prev.selected;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2),
      child: Text(
        cur.displayLevel != prev.displayLevel ? ' ※ ' : '/',
        style: TextStyle(
          color: bothOn ? _sepActive : _sepInactive,
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
      child: Text.rich(
        TextSpan(
          children: [
            TextSpan(text: e.label, style: _labelStyle(e)),
            if (e.valueText != null && e.valueText!.isNotEmpty)
              TextSpan(text: ':${e.valueText}', style: _valueStyle(e)),
          ],
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
                      '暂无可选指标',
                      style: TextStyle(
                        color: _inactiveColor,
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
