import 'package:flutter/material.dart';

import '../models/kline_bar.dart';

/// 自定义 OHLC 编辑结果。
class TestOhlcEditorResult {
  final List<KlineBar> bars;
  final bool loadAfterSave;

  const TestOhlcEditorResult({
    required this.bars,
    required this.loadAfterSave,
  });
}

class _RowDraft {
  final TextEditingController time;
  final TextEditingController open;
  final TextEditingController high;
  final TextEditingController low;
  final TextEditingController close;
  final TextEditingController volume;

  _RowDraft({
    String time = '',
    String open = '',
    String high = '',
    String low = '',
    String close = '',
    String volume = '0',
  })  : time = TextEditingController(text: time),
        open = TextEditingController(text: open),
        high = TextEditingController(text: high),
        low = TextEditingController(text: low),
        close = TextEditingController(text: close),
        volume = TextEditingController(text: volume);

  factory _RowDraft.fromBar(KlineBar b) {
    var t = b.timeText.trim();
    // 展示到秒，缺秒补 :00
    if (RegExp(r'^\d{4}/\d{2}/\d{2} \d{2}:\d{2}$').hasMatch(t)) {
      t = '$t:00';
    }
    return _RowDraft(
      time: t,
      open: _num(b.open),
      high: _num(b.high),
      low: _num(b.low),
      close: _num(b.close),
      volume: _num(b.volume),
    );
  }

  static String _num(double v) {
    if (v == v.roundToDouble()) return v.toInt().toString();
    return v.toString();
  }

  void dispose() {
    time.dispose();
    open.dispose();
    high.dispose();
    low.dispose();
    close.dispose();
    volume.dispose();
  }
}

/// test 自定义 OHLC 表格弹窗：编辑 → 保存到 custom.ohlc.csv。
Future<TestOhlcEditorResult?> showTestOhlcEditorDialog({
  required BuildContext context,
  required List<KlineBar> initialBars,
}) {
  return showDialog<TestOhlcEditorResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _TestOhlcEditorDialog(initialBars: initialBars),
  );
}

class _TestOhlcEditorDialog extends StatefulWidget {
  const _TestOhlcEditorDialog({required this.initialBars});

  final List<KlineBar> initialBars;

  @override
  State<_TestOhlcEditorDialog> createState() => _TestOhlcEditorDialogState();
}

class _TestOhlcEditorDialogState extends State<_TestOhlcEditorDialog> {
  late List<_RowDraft> _rows;
  String? _error;

  @override
  void initState() {
    super.initState();
    if (widget.initialBars.isEmpty) {
      _rows = [
        _RowDraft(
          time: '2026/07/10 09:30:00',
          open: '3',
          high: '4',
          low: '3',
          close: '4',
          volume: '0',
        ),
      ];
    } else {
      _rows = widget.initialBars.map(_RowDraft.fromBar).toList();
    }
  }

  @override
  void dispose() {
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  void _addRow() {
    setState(() {
      _rows.add(_RowDraft());
      _error = null;
    });
  }

  void _removeRow(int i) {
    if (_rows.length <= 1) {
      setState(() => _error = '至少保留一行');
      return;
    }
    setState(() {
      _rows.removeAt(i).dispose();
      _error = null;
    });
  }

  /// 解析并校验表格 → KlineBar 列表；失败写 _error。
  List<KlineBar>? _parseBars() {
    final out = <KlineBar>[];
    DateTime? prev;
    for (var i = 0; i < _rows.length; i++) {
      final r = _rows[i];
      final timeRaw = r.time.text.trim().replaceAll('-', '/');
      if (timeRaw.isEmpty) {
        setState(() => _error = '第${i + 1}行：时间不能为空');
        return null;
      }
      final dt = _parseTime(timeRaw);
      if (dt == null) {
        setState(() => _error = '第${i + 1}行：时间格式应为 YYYY/MM/DD HH:MM:SS');
        return null;
      }
      final open = double.tryParse(r.open.text.trim());
      final high = double.tryParse(r.high.text.trim());
      final low = double.tryParse(r.low.text.trim());
      final close = double.tryParse(r.close.text.trim());
      final volText = r.volume.text.trim();
      final volume = volText.isEmpty ? 0.0 : double.tryParse(volText);
      if (open == null || high == null || low == null || close == null || volume == null) {
        setState(() => _error = '第${i + 1}行：OHLC/量须为数字');
        return null;
      }
      final bodyHi = open > close ? open : close;
      final bodyLo = open < close ? open : close;
      if (high < bodyHi) {
        setState(() => _error = '第${i + 1}行：high 必须 >= max(open,close)');
        return null;
      }
      if (low > bodyLo) {
        setState(() => _error = '第${i + 1}行：low 必须 <= min(open,close)');
        return null;
      }
      if (prev != null && !dt.isAfter(prev)) {
        setState(() => _error = '第${i + 1}行：时间必须严格晚于前一行');
        return null;
      }
      prev = dt;
      final t = _fmt(dt);
      out.add(
        KlineBar(
          idx: i,
          timeMs: dt.millisecondsSinceEpoch,
          timeText: t,
          open: open,
          high: high,
          low: low,
          close: close,
          volume: volume,
          amount: 0,
        ),
      );
    }
    if (out.isEmpty) {
      setState(() => _error = '自定义 OHLC 不能为空');
      return null;
    }
    setState(() => _error = null);
    return out;
  }

  DateTime? _parseTime(String raw) {
    final s = raw.trim();
    for (final fmt in [
      RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2}):(\d{2})$'),
      RegExp(r'^(\d{4})/(\d{2})/(\d{2}) (\d{2}):(\d{2})$'),
    ]) {
      final m = fmt.firstMatch(s);
      if (m == null) continue;
      final y = int.parse(m.group(1)!);
      final mo = int.parse(m.group(2)!);
      final d = int.parse(m.group(3)!);
      final h = int.parse(m.group(4)!);
      final mi = int.parse(m.group(5)!);
      final sec = m.group(6) != null ? int.parse(m.group(6)!) : 0;
      return DateTime(y, mo, d, h, mi, sec);
    }
    return null;
  }

  String _fmt(DateTime d) {
    String two(int n) => n.toString().padLeft(2, '0');
    return '${d.year}/${two(d.month)}/${two(d.day)} '
        '${two(d.hour)}:${two(d.minute)}:${two(d.second)}';
  }

  void _submit({required bool loadAfterSave}) {
    final bars = _parseBars();
    if (bars == null) return;
    Navigator.of(context).pop(
      TestOhlcEditorResult(bars: bars, loadAfterSave: loadAfterSave),
    );
  }

  Future<void> _showHelp() async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('自定义 OHLC 说明'),
        content: const SingleChildScrollView(
          child: Text(
            '操作步骤：\n'
            '1. 股票选择 test 后点「编辑/加载自定义 OHLC」。\n'
            '2. 按行填写时间、开高低收、量（量可空=0）。\n'
            '3. 「仅保存」写入 a_Data/test/custom.ohlc.csv；\n'
            '   「保存并加载」写盘后立刻上图。\n'
            '\n'
            '口径：\n'
            '· 每一行就是最终 K 线，不做周期聚合。\n'
            '· high≥max(开,收)，low≤min(开,收)，时间严格递增。\n'
            '· 有 CSV 时优先直读；无 CSV 时回退 test 分笔文件。',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      title: Row(
        children: [
          const Expanded(child: Text('编辑 test 自定义 OHLC')),
          IconButton(
            tooltip: '说明',
            onPressed: _showHelp,
            icon: const Icon(Icons.help_outline, size: 20),
          ),
        ],
      ),
      content: SizedBox(
        width: 720,
        height: 420,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: const TextStyle(color: Color(0xFFEF5350), fontSize: 13),
                ),
              ),
            Expanded(
              child: SingleChildScrollView(
                child: Table(
                  columnWidths: const {
                    0: FixedColumnWidth(28),
                    1: FlexColumnWidth(2.4),
                    2: FlexColumnWidth(1),
                    3: FlexColumnWidth(1),
                    4: FlexColumnWidth(1),
                    5: FlexColumnWidth(1),
                    6: FlexColumnWidth(1),
                    7: FixedColumnWidth(36),
                  },
                  defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                  children: [
                    const TableRow(
                      children: [
                        Text('#'),
                        Text('时间'),
                        Text('开'),
                        Text('高'),
                        Text('低'),
                        Text('收'),
                        Text('量'),
                        SizedBox.shrink(),
                      ],
                    ),
                    for (var i = 0; i < _rows.length; i++)
                      TableRow(
                        children: [
                          Text('${i + 1}', style: const TextStyle(fontSize: 12)),
                          _cell(_rows[i].time),
                          _cell(_rows[i].open),
                          _cell(_rows[i].high),
                          _cell(_rows[i].low),
                          _cell(_rows[i].close),
                          _cell(_rows[i].volume),
                          IconButton(
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints.tightFor(
                              width: 32,
                              height: 32,
                            ),
                            icon: const Icon(Icons.remove_circle_outline, size: 18),
                            onPressed: () => _removeRow(i),
                          ),
                        ],
                      ),
                  ],
                ),
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton.icon(
                onPressed: _addRow,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('添加一行'),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: const Text('取消'),
        ),
        OutlinedButton(
          onPressed: () => _submit(loadAfterSave: false),
          child: const Text('仅保存'),
        ),
        FilledButton(
          onPressed: () => _submit(loadAfterSave: true),
          child: const Text('保存并加载'),
        ),
      ],
    );
  }

  Widget _cell(TextEditingController c) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2, horizontal: 2),
      child: TextField(
        controller: c,
        style: const TextStyle(fontSize: 12),
        decoration: const InputDecoration(
          isDense: true,
          border: OutlineInputBorder(),
          contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        ),
      ),
    );
  }
}
