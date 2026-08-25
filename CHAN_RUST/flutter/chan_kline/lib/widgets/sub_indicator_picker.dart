import 'package:flutter/material.dart';

import '../models/chart_indicator.dart';
import '../models/divergence_algo.dart';

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

  static const _activeColor = Color(0xFFFFFFFF);
  static const _inactiveColor = Color(0xFF6B7280);

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

  void _toggleItem(SubChartIndicator item) {
    setState(() {
      final next = Set<SubChartIndicator>.from(_draft);
      if (next.contains(item)) {
        next.remove(item);
      } else {
        next.add(item);
      }
      _setDraft(next);
    });
  }

  void _toggleLevel(int displayLevel) {
    final members = subIndicatorsForLevel(displayLevel, widget.available);
    if (members.isEmpty) return;
    final allOn = members.every(_draft.contains);
    setState(() {
      final next = Set<SubChartIndicator>.from(_draft);
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
    final levels = subDisplayLevels(widget.available);
    for (final lv in levels) {
      final members = subIndicatorsForLevel(lv, widget.available);
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

    SubIndicatorKind? prevKind;
    DivergenceAlgo? prevDiverAlgo;
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
        prevDiverAlgo = null;
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
      if (item.kind == SubIndicatorKind.divergence &&
          item.diverAlgo != null &&
          item.diverAlgo != prevDiverAlgo) {
        prevDiverAlgo = item.diverAlgo;
        tiles.add(
          Container(
            padding: const EdgeInsets.only(top: 6, bottom: 1, left: 4),
            child: Text(
              '· ${item.diverAlgo!.labelSuffix}',
              style: const TextStyle(
                color: Color(0xFF94A3B8),
                fontSize: 12,
              ),
            ),
          ),
        );
      }
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
