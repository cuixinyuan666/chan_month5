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

/// 主/副图指标选择入口：↓ 打开选择；右侧名称单击灰度开关；自动换行。
class IndicatorPickerChip extends StatefulWidget {
  const IndicatorPickerChip({
    super.key,
    required this.entries,
    required this.onTapDropdown,
    this.maxWidth = 280,
    this.emptyHint = '未选',
    this.horizontalScroll = false,
  });

  final List<IndicatorChipEntry> entries;
  final VoidCallback onTapDropdown;
  final double maxWidth;
  /// 无勾选时右侧提示（主图关全部≈只留K0；副图关全部=收起）
  final String emptyHint;
  /// 手机端横向滚动，避免多行撑高挤占副图标记区
  final bool horizontalScroll;

  @override
  State<IndicatorPickerChip> createState() => _IndicatorPickerChipState();
}

class _IndicatorPickerChipState extends State<IndicatorPickerChip> {
  bool _hovered = false;

  // 开启态高对比；灰度态明显变暗以便区分
  static const _activeColor = Color(0xFFFFFFFF);
  static const _mutedColor = Color(0xFF6B7280);
  static const _sepActive = Color(0xAAFFFFFF);
  static const _sepMuted = Color(0x556B7280);
  static const _valueColor = Color(0xFF38BDF8);

  @override
  Widget build(BuildContext context) {
    final entries = widget.entries;
    // 平时略压透明度（仍可读），悬停拉满；避免过低导致灰度难辨
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
            constraints: BoxConstraints(maxWidth: widget.maxWidth),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(0, 2, 4, 2),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: widget.onTapDropdown,
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 2, vertical: 2),
                      child: Icon(
                        Icons.arrow_drop_down,
                        size: 18,
                        color: Color(0xFFFFFFFF),
                      ),
                    ),
                  ),
                  if (entries.isEmpty)
                    Padding(
                      padding: const EdgeInsets.only(right: 4, top: 3),
                      child: Text(
                        widget.emptyHint,
                        style: const TextStyle(
                          color: _activeColor,
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          height: 1.2,
                        ),
                      ),
                    )
                  else if (widget.horizontalScroll)
                    Expanded(
                      child: SingleChildScrollView(
                        scrollDirection: Axis.horizontal,
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            for (var i = 0; i < entries.length; i++) ...[
                              if (i > 0)
                                Padding(
                                  padding:
                                      const EdgeInsets.symmetric(horizontal: 2),
                                  child: Text(
                                    entries[i].displayLevel !=
                                            entries[i - 1].displayLevel
                                        ? ' ※ '
                                        : '/',
                                    style: TextStyle(
                                      color: (entries[i].muted &&
                                              entries[i - 1].muted)
                                          ? _sepMuted
                                          : _sepActive,
                                      fontSize: 12,
                                      height: 1.2,
                                    ),
                                  ),
                                ),
                              GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTap: entries[i].onTapToggle,
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: entries[i].label,
                                        style: TextStyle(
                                          color: entries[i].muted
                                              ? _mutedColor
                                              : _activeColor,
                                          fontSize: 12,
                                          fontWeight: entries[i].muted
                                              ? FontWeight.w400
                                              : FontWeight.w600,
                                          height: 1.2,
                                          decoration: entries[i].muted
                                              ? TextDecoration.lineThrough
                                              : TextDecoration.none,
                                          decorationColor: _mutedColor,
                                        ),
                                      ),
                                      if (entries[i].valueText != null &&
                                          entries[i].valueText!.isNotEmpty)
                                        TextSpan(
                                          text: ':${entries[i].valueText}',
                                          style: TextStyle(
                                            color: entries[i].muted
                                                ? _mutedColor
                                                : _valueColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            height: 1.2,
                                          ),
                                        ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ],
                        ),
                      ),
                    )
                  else
                    Flexible(
                      child: Wrap(
                        crossAxisAlignment: WrapCrossAlignment.center,
                        spacing: 0,
                        runSpacing: 2,
                        children: [
                          for (var i = 0; i < entries.length; i++) ...[
                            if (i > 0)
                              Padding(
                                padding:
                                    const EdgeInsets.symmetric(horizontal: 2),
                                child: Text(
                                  entries[i].displayLevel !=
                                          entries[i - 1].displayLevel
                                      ? ' ※ '
                                      : '/',
                                  style: TextStyle(
                                    color: (entries[i].muted &&
                                            entries[i - 1].muted)
                                        ? _sepMuted
                                        : _sepActive,
                                    fontSize: 12,
                                    height: 1.2,
                                  ),
                                ),
                              ),
                            GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: entries[i].onTapToggle,
                              child: Tooltip(
                                message: entries[i].muted
                                    ? '单击打开「${entries[i].label}」'
                                    : '单击关闭「${entries[i].label}」',
                                waitDuration:
                                    const Duration(milliseconds: 500),
                                child: Text.rich(
                                  TextSpan(
                                    children: [
                                      TextSpan(
                                        text: entries[i].label,
                                        style: TextStyle(
                                          color: entries[i].muted
                                              ? _mutedColor
                                              : _activeColor,
                                          fontSize: 12,
                                          fontWeight: entries[i].muted
                                              ? FontWeight.w400
                                              : FontWeight.w600,
                                          height: 1.2,
                                          decoration: entries[i].muted
                                              ? TextDecoration.lineThrough
                                              : TextDecoration.none,
                                          decorationColor: _mutedColor,
                                        ),
                                      ),
                                      if (entries[i].valueText != null &&
                                          entries[i].valueText!.isNotEmpty)
                                        TextSpan(
                                          text: ':${entries[i].valueText}',
                                          style: TextStyle(
                                            color: entries[i].muted
                                                ? _mutedColor
                                                : _valueColor,
                                            fontSize: 12,
                                            fontWeight: FontWeight.w600,
                                            height: 1.2,
                                          ),
                                        ),
                                    ],
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
