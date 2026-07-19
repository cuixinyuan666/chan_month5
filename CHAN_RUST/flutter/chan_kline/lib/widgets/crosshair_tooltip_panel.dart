import 'package:flutter/material.dart';

import '../models/bar_feature_lookup.dart';

/// 十字线 tooltip：两列对齐 + 半透明底 + 可滚轮下翻。
class CrosshairTooltipPanel extends StatelessWidget {
  const CrosshairTooltipPanel({
    super.key,
    required this.rows,
    required this.scrollController,
    required this.maxWidth,
    required this.maxHeight,
  });

  final List<CrosshairTooltipRow> rows;
  final ScrollController scrollController;
  final double maxWidth;
  final double maxHeight;

  static const _labelStyle = TextStyle(
    color: Color(0xFFE2E8F0),
    fontSize: 11,
    fontWeight: FontWeight.w600,
    fontFamily: 'Consolas',
    height: 1.35,
  );
  static const _valueStyle = TextStyle(
    color: Color(0xFFE2E8F0),
    fontSize: 11,
    fontWeight: FontWeight.w500,
    fontFamily: 'Consolas',
    height: 1.35,
  );
  static const _sepStyle = TextStyle(
    color: Color(0x99E2E8F0),
    fontSize: 10,
    fontFamily: 'Consolas',
    height: 1.1,
  );

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.transparent,
      child: Container(
        constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
        decoration: BoxDecoration(
          // 深色实底（近不透明）：与图表价签同调，浅色字对比强、不再黑白混色
          color: const Color(0xEE121212),
          border: Border.all(color: const Color(0x55E2E8F0), width: 1),
          borderRadius: BorderRadius.circular(2),
        ),
        child: ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(scrollbars: true),
          child: SingleChildScrollView(
            controller: scrollController,
            physics: const ClampingScrollPhysics(),
            padding: const EdgeInsets.fromLTRB(8, 6, 8, 6),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rows)
                  if (row.isSeparator)
                    // 分隔线「=」铺满 tooltip 内容区（左右内边距之间），而非固定长度
                    LayoutBuilder(
                      builder: (context, constraints) {
                        const eq = '=';
                        final tp = TextPainter(
                          text: const TextSpan(text: eq, style: _sepStyle),
                          textDirection: TextDirection.ltr,
                        )..layout();
                        final count =
                            tp.width > 0 ? (constraints.maxWidth / tp.width).ceil() : 0;
                        return Padding(
                          padding: const EdgeInsets.symmetric(vertical: 3),
                          child: Text(
                            eq * count,
                            style: _sepStyle,
                            maxLines: 1,
                            softWrap: false,
                            overflow: TextOverflow.clip,
                          ),
                        );
                      },
                    )
                  else
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 1),
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 左列标签定宽，便于各层对齐（含「K0合并K0序」）
                          SizedBox(
                            width: 108,
                            child: Text(
                              '${row.label}:',
                              style: _labelStyle,
                              softWrap: false,
                              overflow: TextOverflow.clip,
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Text(
                              row.value,
                              style: _valueStyle,
                              textAlign: TextAlign.right,
                            ),
                          ),
                        ],
                      ),
                    ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
