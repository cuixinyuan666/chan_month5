import 'dart:math' as math;

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
  final int displayLevel;
  final bool selected;
  final String? valueText;
}

/// 近乎铺满界面的指标选择列表：每行一项，主/副图统一样式。
class IndicatorPickerOverlay extends StatelessWidget {
  const IndicatorPickerOverlay({
    super.key,
    required this.title,
    required this.entries,
    required this.onClose,
  });

  final String title;
  final List<IndicatorChipEntry> entries;
  final VoidCallback onClose;

  static const _activeColor = Color(0xFFFFFFFF);
  static const _inactiveColor = Color(0xFF6B7280);
  static const _valueColor = Color(0xFF38BDF8);

  TextStyle _rowStyle(bool selected) => TextStyle(
        color: selected ? _activeColor : _inactiveColor,
        fontSize: 15,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        height: 1.35,
        decoration: selected ? TextDecoration.none : TextDecoration.lineThrough,
        decorationColor: _inactiveColor,
      );

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    final marginH = math.max(12.0, size.width * 0.04);
    final marginV = math.max(28.0, size.height * 0.05);
    return Positioned.fill(
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onClose,
        child: Container(
          color: const Color(0x99000000),
          alignment: Alignment.center,
          padding: EdgeInsets.fromLTRB(marginH, marginV, marginH, marginV),
          child: GestureDetector(
            onTap: () {},
            child: Material(
              color: const Color(0xF01A1A1A),
              borderRadius: BorderRadius.circular(10),
              child: SizedBox(
                width: size.width - marginH * 2,
                height: size.height - marginV * 2,
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(14, 10, 6, 4),
                      child: Row(
                        children: [
                          Text(
                            title,
                            style: const TextStyle(
                              fontSize: 16,
                              fontWeight: FontWeight.w600,
                              color: Color(0xFFE2E8F0),
                            ),
                          ),
                          const Spacer(),
                          IconButton(
                            tooltip: '关闭',
                            visualDensity: VisualDensity.compact,
                            onPressed: onClose,
                            icon: const Icon(
                              Icons.close,
                              size: 22,
                              color: Color(0xFF94A3B8),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const Divider(height: 1, color: Color(0x33FFFFFF)),
                    Expanded(
                      child: entries.isEmpty
                          ? const Center(
                              child: Text(
                                '暂无可选指标',
                                style: TextStyle(
                                  color: _inactiveColor,
                                  fontSize: 14,
                                ),
                              ),
                            )
                          : ListView.separated(
                              padding: const EdgeInsets.symmetric(vertical: 4),
                              itemCount: entries.length,
                              separatorBuilder: (_, __) => const Divider(
                                height: 1,
                                indent: 14,
                                endIndent: 14,
                                color: Color(0x22FFFFFF),
                              ),
                              itemBuilder: (context, i) {
                                final e = entries[i];
                                return InkWell(
                                  onTap: e.onTapToggle,
                                  child: Padding(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 14,
                                      vertical: 11,
                                    ),
                                    child: Text.rich(
                                      TextSpan(
                                        children: [
                                          TextSpan(
                                            text: e.label,
                                            style: _rowStyle(e.selected),
                                          ),
                                          if (e.valueText != null &&
                                              e.valueText!.isNotEmpty)
                                            TextSpan(
                                              text: '  ${e.valueText}',
                                              style: TextStyle(
                                                color: e.selected
                                                    ? _valueColor
                                                    : _inactiveColor,
                                                fontSize: 14,
                                                fontWeight: FontWeight.w600,
                                              ),
                                            ),
                                        ],
                                      ),
                                    ),
                                  ),
                                );
                              },
                            ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}
