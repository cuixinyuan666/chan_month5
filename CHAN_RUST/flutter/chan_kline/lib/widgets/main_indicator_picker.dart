import 'package:flutter/material.dart';

import '../models/chart_indicator.dart';

/// 主图指标选择：大类 Divider；过长可滚轮滚动；点遮罩外关闭并保存。
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
  late bool _stackMode;
  final _scrollCtrl = ScrollController();

  @override
  void initState() {
    super.initState();
    _draft = Set<MainChartIndicator>.from(widget.initial);
    _stackMode = _draft.length > 1;
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

  void _toggleStack(bool v) {
    setState(() {
      _stackMode = v;
      if (!_stackMode && _draft.length > 1) {
        _setDraft({_draft.first});
      }
    });
  }

  void _pickSingle(MainChartIndicator item) {
    Navigator.of(context).pop(<MainChartIndicator>{item});
  }

  void _toggleStackItem(MainChartIndicator item, bool? checked) {
    setState(() {
      final next = Set<MainChartIndicator>.from(_draft);
      if (checked == true) {
        next.add(item);
      } else {
        next.remove(item);
      }
      _setDraft(next);
    });
  }

  List<Widget> _buildTiles() {
    final tiles = <Widget>[];
    MainIndicatorKind? prevKind;
    for (final item in widget.available) {
      // 大类切换处加 Divider（如 K4合并 | K1连线）
      if (prevKind != null && prevKind != item.kind) {
        tiles.add(
          const Divider(
            height: 16,
            thickness: 1,
            color: Color(0x44FFFFFF),
          ),
        );
      }
      prevKind = item.kind;
      if (_stackMode) {
        tiles.add(
          CheckboxListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            controlAffinity: ListTileControlAffinity.trailing,
            activeColor: const Color(0xFF42A5F5),
            title: Text(item.label, style: const TextStyle(fontSize: 14)),
            value: _draft.contains(item),
            onChanged: (v) => _toggleStackItem(item, v),
          ),
        );
      } else {
        final picked = _draft.contains(item);
        tiles.add(
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            title: Text(item.label),
            trailing: Icon(
              picked ? Icons.radio_button_checked : Icons.radio_button_off,
              size: 18,
              color: picked ? const Color(0xFF42A5F5) : const Color(0x66FFFFFF),
            ),
            onTap: () => _pickSingle(item),
          ),
        );
      }
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
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                const Spacer(),
                TextButton.icon(
                  onPressed: () => _toggleStack(!_stackMode),
                  icon: Icon(
                    _stackMode ? Icons.check_box : Icons.check_box_outline_blank,
                    size: 18,
                    color: const Color(0xFF42A5F5),
                  ),
                  label: const Text('叠加', style: TextStyle(fontSize: 13)),
                  style: TextButton.styleFrom(
                    foregroundColor: const Color(0xFF42A5F5),
                    padding: EdgeInsets.zero,
                    minimumSize: Size.zero,
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            if (widget.available.isEmpty)
              const Padding(
                padding: EdgeInsets.symmetric(vertical: 12),
                child: Text('暂无可选指标',
                    style: TextStyle(color: Color(0x99FFFFFF))),
              )
            else
              ConstrainedBox(
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
          ],
        ),
      ),
      actions: const [],
    );
  }
}
