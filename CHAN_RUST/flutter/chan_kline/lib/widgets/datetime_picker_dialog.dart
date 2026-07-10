import 'package:flutter/material.dart';

/// 日期时间选择弹窗，最小粒度到秒。
Future<DateTime?> showDateTimePickerDialog({
  required BuildContext context,
  required DateTime initial,
  required DateTime firstDate,
  required DateTime lastDate,
  required String title,
}) {
  return showDialog<DateTime>(
    context: context,
    builder: (ctx) => _DateTimePickerDialog(
      initial: initial,
      firstDate: firstDate,
      lastDate: lastDate,
      title: title,
    ),
  );
}

class _DateTimePickerDialog extends StatefulWidget {
  const _DateTimePickerDialog({
    required this.initial,
    required this.firstDate,
    required this.lastDate,
    required this.title,
  });

  final DateTime initial;
  final DateTime firstDate;
  final DateTime lastDate;
  final String title;

  @override
  State<_DateTimePickerDialog> createState() => _DateTimePickerDialogState();
}

class _DateTimePickerDialogState extends State<_DateTimePickerDialog> {
  late DateTime _selectedDate;
  late int _hour;
  late int _minute;
  late int _second;

  @override
  void initState() {
    super.initState();
    _selectedDate = DateTime(
      widget.initial.year,
      widget.initial.month,
      widget.initial.day,
    );
    _hour = widget.initial.hour;
    _minute = widget.initial.minute;
    _second = widget.initial.second;
  }

  DateTime get _result => DateTime(
        _selectedDate.year,
        _selectedDate.month,
        _selectedDate.day,
        _hour,
        _minute,
        _second,
      );

  bool get _inRange {
    final r = _result;
    return !r.isBefore(widget.firstDate) && !r.isAfter(widget.lastDate);
  }

  Widget _timeDropdown({
    required String label,
    required int value,
    required int max,
    required ValueChanged<int?> onChanged,
  }) {
    return Expanded(
      child: DropdownButtonFormField<int>(
        isExpanded: true,
        value: value,
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
        ),
        items: List.generate(
          max + 1,
          (i) => DropdownMenuItem(value: i, child: Text(i.toString().padLeft(2, '0'))),
        ),
        onChanged: onChanged,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 360,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            CalendarDatePicker(
              initialDate: _selectedDate,
              firstDate: DateTime(
                widget.firstDate.year,
                widget.firstDate.month,
                widget.firstDate.day,
              ),
              lastDate: DateTime(
                widget.lastDate.year,
                widget.lastDate.month,
                widget.lastDate.day,
              ),
              onDateChanged: (d) => setState(() => _selectedDate = d),
            ),
            const SizedBox(height: 8),
            Row(
              children: [
                _timeDropdown(
                  label: '时',
                  value: _hour,
                  max: 23,
                  onChanged: (v) => setState(() => _hour = v ?? _hour),
                ),
                const SizedBox(width: 8),
                _timeDropdown(
                  label: '分',
                  value: _minute,
                  max: 59,
                  onChanged: (v) => setState(() => _minute = v ?? _minute),
                ),
                const SizedBox(width: 8),
                _timeDropdown(
                  label: '秒',
                  value: _second,
                  max: 59,
                  onChanged: (v) => setState(() => _second = v ?? _second),
                ),
              ],
            ),
            if (!_inRange)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text(
                  '时间需在 ${widget.firstDate.year}/${widget.firstDate.month.toString().padLeft(2, '0')}/${widget.firstDate.day.toString().padLeft(2, '0')} '
                  '${widget.firstDate.hour.toString().padLeft(2, '0')}:${widget.firstDate.minute.toString().padLeft(2, '0')}:${widget.firstDate.second.toString().padLeft(2, '0')} '
                  '～ '
                  '${widget.lastDate.year}/${widget.lastDate.month.toString().padLeft(2, '0')}/${widget.lastDate.day.toString().padLeft(2, '0')} '
                  '${widget.lastDate.hour.toString().padLeft(2, '0')}:${widget.lastDate.minute.toString().padLeft(2, '0')}:${widget.lastDate.second.toString().padLeft(2, '0')} 之间',
                  style: TextStyle(color: Theme.of(context).colorScheme.error, fontSize: 12),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _inRange ? () => Navigator.of(context).pop(_result) : null,
          child: const Text('确定'),
        ),
      ],
    );
  }
}
