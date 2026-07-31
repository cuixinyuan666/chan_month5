import 'package:flutter/material.dart';

import '../models/chart_indicator.dart';

/// 副图指标选择：默认叠加多选；最上「Kn指标」层全选；点遮罩外关闭并保存。
Future<Set<SubChartIndicator>?> showSubIndicatorPicker({
  required BuildContext context,
  required Set<SubChartIndicator> selected,
  required List<SubChartIndicator> available,
}) {
  final draftHolder = <Set<SubChartIndicator>>[
    Set<SubChartIndicator>.from(selected),
  ];
  return showDialog<Set<SubChartIndicator>>(
    context: context,
    barrierDismissible: true,
    builder: (ctx) => _SubIndicatorPickerDialog(
      initial: selected,
      available: available,
      onDraftChanged: (d) => draftHolder[0] = d,
    ),
  ).then((r) => r ?? draftHolder[0]);
}

class _SubIndicatorPickerDialog extends StatefulWidget {
  const _SubIndicatorPickerDialog({
    required this.initial,
    required this.available,
    required this.onDraftChanged,
  });

  final Set<SubChartIndicator> initial;
  final List<SubChartIndicator> available;
  final ValueChanged<Set<SubChartIndicator>> onDraftChanged;

  @override
  State<_SubIndicatorPickerDialog> createState() =>
      _SubIndicatorPickerDialogState();
}

class _SubIndicatorPickerDialogState extends State<_SubIndicatorPickerDialog> {
  late Set<SubChartIndicator> _draft;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _draft = Set<SubChartIndicator>.from(widget.initial);
    widget.onDraftChanged(_draft);
  }

  @override
  void dispose() {
    _scrollCtrl.dispose();
    super.dispose();
  }

  void _setDraft(Set<SubChartIndicator> next) {
    _draft = next;
    widget.onDraftChanged(_draft);
  }

  void _toggleItem(SubChartIndicator item, bool? checked) {
    setState(() {
      final next = Set<SubChartIndicator>.from(_draft);
      if (checked == true) {
        next.add(item);
      } else {
        next.remove(item);
      }
      _setDraft(next);
    });
  }

  void _toggleLevel(int displayLevel, bool? checked) {
    final members = subIndicatorsForLevel(displayLevel, widget.available);
    if (members.isEmpty) return;
    setState(() {
      final next = Set<SubChartIndicator>.from(_draft);
      if (checked == true) {
        next.addAll(members);
      } else {
        next.removeAll(members);
      }
      _setDraft(next);
    });
  }

  bool? _levelTriState(int displayLevel) {
    final members = subIndicatorsForLevel(displayLevel, widget.available);
    if (members.isEmpty) return false;
    final n = members.where(_draft.contains).length;
    if (n == 0) return false;
    if (n == members.length) return true;
    return null;
  }

  List<Widget> _buildTiles() {
    final tiles = <Widget>[];
    final levels = subDisplayLevels(widget.available);
    for (final lv in levels) {
      final members = subIndicatorsForLevel(lv, widget.available);
      if (members.isEmpty) continue;
      tiles.add(
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          activeColor: const Color(0xFF42A5F5),
          tristate: true,
          title: Text('K$lv指标', style: const TextStyle(fontSize: 14)),
          value: _levelTriState(lv),
          onChanged: (v) => _toggleLevel(lv, v == true),
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

    int? prevDisplay;
    for (final item in widget.available) {
      // 按显示层分隔，使相邻比例/步进节奏落在对应 Kn 组内
      if (prevDisplay != null && prevDisplay != item.displayLevel) {
        tiles.add(
          const Divider(
            height: 16,
            thickness: 1,
            color: Color(0x44FFFFFF),
          ),
        );
      }
      prevDisplay = item.displayLevel;
      tiles.add(
        CheckboxListTile(
          dense: true,
          contentPadding: EdgeInsets.zero,
          controlAffinity: ListTileControlAffinity.trailing,
          activeColor: const Color(0xFF42A5F5),
          title: Text(item.label, style: const TextStyle(fontSize: 14)),
          value: _draft.contains(item),
          onChanged: (v) => _toggleItem(item, v),
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
      title: const Text('副图指标', style: TextStyle(color: Colors.white)),
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
