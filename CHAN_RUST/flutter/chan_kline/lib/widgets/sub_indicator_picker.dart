import 'package:flutter/material.dart';

import '../models/kline_combine_frame.dart';

/// 副图指标选择：支持单选 / 叠加。
Future<Set<SubChartIndicator>?> showSubIndicatorPicker({
  required BuildContext context,
  required Set<SubChartIndicator> selected,
}) {
  return showDialog<Set<SubChartIndicator>>(
    context: context,
    builder: (ctx) => _SubIndicatorPickerDialog(initial: selected),
  );
}

class _SubIndicatorPickerDialog extends StatefulWidget {
  const _SubIndicatorPickerDialog({required this.initial});

  final Set<SubChartIndicator> initial;

  @override
  State<_SubIndicatorPickerDialog> createState() =>
      _SubIndicatorPickerDialogState();
}

class _SubIndicatorPickerDialogState extends State<_SubIndicatorPickerDialog> {
  late Set<SubChartIndicator> _draft;
  late bool _stackMode; // 叠加（原多选）

  @override
  void initState() {
    super.initState();
    _draft = Set<SubChartIndicator>.from(widget.initial);
    if (_draft.isEmpty) {
      _draft = {SubChartIndicator.biConfirm};
    }
    _stackMode = _draft.length > 1;
  }

  void _toggleStack(bool v) {
    setState(() {
      _stackMode = v;
      if (!_stackMode && _draft.length > 1) {
        _draft = {_draft.first};
      }
    });
  }

  void _pickSingle(SubChartIndicator item) {
    Navigator.of(context).pop(<SubChartIndicator>{item});
  }

  void _toggleStackItem(SubChartIndicator item, bool? checked) {
    setState(() {
      if (checked == true) {
        _draft.add(item);
      } else {
        _draft.remove(item);
      }
      if (_draft.isEmpty) {
        _draft.add(SubChartIndicator.biConfirm);
      }
    });
  }

  void _confirmStack() {
    Navigator.of(context).pop(Set<SubChartIndicator>.from(_draft));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: const Color(0xFF1E1E1E),
      titlePadding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      title: Row(
        children: [
          TextButton.icon(
            onPressed: () => _toggleStack(!_stackMode),
            icon: Icon(
              _stackMode ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: _stackMode ? const Color(0xFF42A5F5) : const Color(0x99FFFFFF),
            ),
            label: Text(
              '叠加',
              style: TextStyle(
                color: _stackMode ? const Color(0xFF42A5F5) : const Color(0xFFE2E8F0),
                fontSize: 13,
              ),
            ),
            style: TextButton.styleFrom(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              minimumSize: Size.zero,
              tapTargetSize: MaterialTapTargetSize.shrinkWrap,
            ),
          ),
          const Spacer(),
          Text(
            _stackMode ? '勾选后点确定' : '点选即切换',
            style: const TextStyle(color: Color(0x99FFFFFF), fontSize: 11),
          ),
        ],
      ),
      content: SizedBox(
        width: 260,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const SizedBox(height: 4),
            ...SubChartIndicator.values.map((item) {
              // 单选/叠加：选择框统一靠右
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
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        if (_stackMode)
          FilledButton(
            onPressed: _confirmStack,
            child: Text('确定 (${_draft.length})'),
          ),
      ],
    );
  }
}
