import 'package:flutter/material.dart';

import '../models/chart_indicator.dart';

/// 副图指标选择：支持单选 / 叠加；点遮罩外关闭并保存；可全不选。
/// [available] 由当前数据 maxKn 动态生成。
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
  late bool _stackMode;

  @override
  void initState() {
    super.initState();
    _draft = Set<SubChartIndicator>.from(widget.initial);
    _stackMode = _draft.length > 1;
    widget.onDraftChanged(_draft);
  }

  void _setDraft(Set<SubChartIndicator> next) {
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

  void _pickSingle(SubChartIndicator item) {
    Navigator.of(context).pop(<SubChartIndicator>{item});
  }

  void _toggleStackItem(SubChartIndicator item, bool? checked) {
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

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      title: const Text('副图指标', style: TextStyle(color: Colors.white)),
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
                child: Text('暂无可选指标', style: TextStyle(color: Color(0x99FFFFFF))),
              ),
            ...widget.available.map((item) {
              if (_stackMode) {
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.trailing,
                  activeColor: const Color(0xFF42A5F5),
                  title: Text(item.label, style: const TextStyle(fontSize: 14)),
                  value: _draft.contains(item),
                  onChanged: (v) => _toggleStackItem(item, v),
                );
              }
              final picked = _draft.contains(item);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                title: Text(item.label),
                trailing: Icon(
                  picked ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 18,
                  color: picked ? const Color(0xFF42A5F5) : const Color(0x66FFFFFF),
                ),
                onTap: () => _pickSingle(item),
              );
            }),
          ],
        ),
      ),
      actions: const [],
    );
  }
}
