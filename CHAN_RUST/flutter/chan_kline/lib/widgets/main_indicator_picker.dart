import 'package:flutter/material.dart';

import '../models/chart_indicator.dart';

/// 主图指标选择：默认叠加多选；最上「Kn指标」层全选；点遮罩外关闭并保存。
Future<Set<MainChartIndicator>?> showMainIndicatorPicker({
  required BuildContext context,
  required Set<MainChartIndicator> selected,
  required List<MainChartIndicator> available,
}) {
  final draftHolder = <Set<MainChartIndicator>>[
    Set<MainChartIndicator>.from(selected),
  ];
  return showDialog<Set<MainChartIndicator>>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _MainIndicatorPickerDialog(
      initial: selected,
      available: available,
      onDraftChanged: (d) => draftHolder[0] = d,
    ),
  ).then((r) => r ?? draftHolder[0]);
}

class _MainIndicatorPickerDialog extends StatefulWidget {
  const _MainIndicatorPickerDialog({
    required this.initial,
    required this.available,
    required this.onDraftChanged,
  });

  final Set<MainChartIndicator> initial;
  final List<MainChartIndicator> available;
  final ValueChanged<Set<MainChartIndicator>> onDraftChanged;

  @override
  State<_MainIndicatorPickerDialog> createState() =>
      _MainIndicatorPickerDialogState();
}

class _MainIndicatorPickerDialogState extends State<_MainIndicatorPickerDialog> {
  late Set<MainChartIndicator> _draft;
  final _scrollCtrl = ScrollController();

  static const _activeColor = Color(0xFFFFFFFF);
  static const _inactiveColor = Color(0xFF6B7280);

  @override
  void initState() {
    super.initState();
    _draft = Set<MainChartIndicator>.from(widget.initial);
    widget.onDraftChanged(_draft);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _setDraft(Set<MainChartIndicator> next) {
    _draft = next;
    widget.onDraftChanged(_draft);
  }

  void _toggleItem(MainChartIndicator item) {
    setState(() {
      final next = Set<MainChartIndicator>.from(_draft);
      if (next.contains(item)) {
        next.remove(item);
      } else {
        next.add(item);
      }
      _setDraft(next);
    });
  }

  void _toggleLevel(int displayLevel) {
    final members = mainIndicatorsForLevel(displayLevel, widget.available);
    if (members.isEmpty) return;
    final allOn = members.every(_draft.contains);
    setState(() {
      final next = Set<MainChartIndicator>.from(_draft);
      if (allOn) {
        next.removeAll(members);
      } else {
        next.addAll(members);
      }
      _setDraft(next);
    });
  }

  TextStyle _labelStyle(bool selected) => TextStyle(
        color: selected ? _activeColor : _inactiveColor,
        fontSize: 14,
        fontWeight: selected ? FontWeight.w600 : FontWeight.w400,
        decoration: selected ? TextDecoration.none : TextDecoration.lineThrough,
        decorationColor: _inactiveColor,
      );

  Widget _tapRow({
    required String label,
    required bool selected,
    required VoidCallback onTap,
    EdgeInsets padding = const EdgeInsets.symmetric(vertical: 6),
  }) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: padding,
        child: Align(
          alignment: Alignment.centerLeft,
          child: Text(label, style: _labelStyle(selected)),
        ),
      ),
    );
  }

  List<Widget> _buildTiles() {
    final tiles = <Widget>[];
    final levels = mainDisplayLevels(widget.available);
    for (final lv in levels) {
      final members = mainIndicatorsForLevel(lv, widget.available);
      if (members.isEmpty) continue;
      final allOn = members.every(_draft.contains);
      tiles.add(
        _tapRow(
          label: 'K$lv指标',
          selected: allOn,
          onTap: () => _toggleLevel(lv),
        ),
      );
    }
    if (levels.isNotEmpty && widget.available.isNotEmpty) {
      tiles.add(
        const Divider(
          height: 16,
          thickness: 1,
          color: Color(0x44FFFFFF),
        ),
      );
    }

    MainIndicatorKind? prevKind;
    for (final item in widget.available) {
      if (prevKind != null && prevKind != item.kind) {
        tiles.add(
          Container(
            padding: const EdgeInsets.only(top: 10, bottom: 2),
            child: Text(
              item.kind.categoryLabel,
              style: const TextStyle(
                color: Color(0xFF42A5F5),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      } else if (prevKind == null) {
        tiles.add(
          Container(
            padding: const EdgeInsets.only(top: 4, bottom: 2),
            child: Text(
              item.kind.categoryLabel,
              style: const TextStyle(
                color: Color(0xFF42A5F5),
                fontSize: 13,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        );
      }
      prevKind = item.kind;
      tiles.add(
        _tapRow(
          label: item.label,
          selected: _draft.contains(item),
          onTap: () => _toggleItem(item),
        ),
      );
    }
    return tiles;
  }

  @override
  Widget build(BuildContext context) {
    final maxH = MediaQuery.sizeOf(context).height * 0.55;
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('主图指标', style: TextStyle(color: Colors.white)),
      content: SizedBox(
        width: 320,
        child: widget.available.isEmpty
            ? const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无可选指标',
                    style: TextStyle(color: Color(0x99FFFFFF))),
              )
            : ConstrainedBox(
                constraints: BoxConstraints(maxHeight: maxH),
                child: Scrollbar(
                  controller: _scrollCtrl,
                  thumbVisibility: true,
                  child: SingleChildScrollView(
                    controller: _scrollCtrl,
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: _buildTiles(),
                    ),
                  ),
                ),
              ),
      ),
      actions: const [],
    );
  }
}
