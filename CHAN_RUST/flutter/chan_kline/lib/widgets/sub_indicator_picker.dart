import 'package:flutter/material.dart';

import '../models/kline_combine_frame.dart';

/// 副图指标选择：支持单选 / 多选叠加。
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
  late bool _multiMode;

  @override
  void initState() {
    super.initState();
    _draft = Set<SubChartIndicator>.from(widget.initial);
    if (_draft.isEmpty) {
      _draft = {SubChartIndicator.biConfirm};
    }
    _multiMode = _draft.length > 1;
  }

  void _toggleMulti(bool v) {
    setState(() {
      _multiMode = v;
      if (!_multiMode && _draft.length > 1) {
        _draft = {_draft.first};
      }
    });
  }

  void _pickSingle(SubChartIndicator item) {
    Navigator.of(context).pop(<SubChartIndicator>{item});
  }

  void _toggleMultiItem(SubChartIndicator item, bool? checked) {
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

  void _confirmMulti() {
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
            onPressed: () => _toggleMulti(!_multiMode),
            icon: Icon(
              _multiMode ? Icons.check_box : Icons.check_box_outline_blank,
              size: 18,
              color: _multiMode ? const Color(0xFF42A5F5) : const Color(0x99FFFFFF),
            ),
            label: Text(
              '多选',
              style: TextStyle(
                color: _multiMode ? const Color(0xFF42A5F5) : const Color(0xFFE2E8F0),
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
            _multiMode ? '勾选后点确定' : '点选即切换',
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
              if (_multiMode) {
                return CheckboxListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  activeColor: const Color(0xFF42A5F5),
                  title: Text(item.label, style: const TextStyle(fontSize: 14)),
                  value: _draft.contains(item),
                  onChanged: (v) => _toggleMultiItem(item, v),
                );
              }
              final picked = _draft.contains(item);
              return ListTile(
                dense: true,
                contentPadding: EdgeInsets.zero,
                leading: Icon(
                  picked ? Icons.radio_button_checked : Icons.radio_button_off,
                  size: 18,
                  color: picked ? const Color(0xFF42A5F5) : const Color(0x66FFFFFF),
                ),
                title: Text(item.label),
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
        if (_multiMode)
          FilledButton(
            onPressed: _confirmMulti,
            child: Text('确定 (${_draft.length})'),
          ),
      ],
    );
  }
}
