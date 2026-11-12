import 'package:flutter/material.dart';
import 'package:flutter/gestures.dart';

import '../models/kline_bar.dart';
import 'package:chan_kline/theme/app_palette.dart';

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

  /// 复制另一行的纯文本数据（新 controller，与源行无共享状态）。
  factory _RowDraft.copyOf(_RowDraft src) => _RowDraft(
        time: src.time.text,
        open: src.open.text,
        high: src.high.text,
        low: src.low.text,
        close: src.close.text,
        volume: src.volume.text,
      );

  void dispose() {
    time.dispose();
    open.dispose();
    high.dispose();
    low.dispose();
    close.dispose();
    volume.dispose();
  }
}

/// 单元格数据类型：决定步长（价格 0.01 / 量 1 / 时间 1 分钟）。
enum _CellKind { time, price, volume }

/// 微型图标按钮：绕开 IconButton 的 48 最小点击尺寸，按给定约束渲染。
class _MiniIconButton extends StatelessWidget {
  const _MiniIconButton({
    required this.icon,
    required this.tooltip,
    required this.size,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final double size;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkResponse(
          radius: 14,
          onTap: onTap,
          child: SizedBox(
            width: size,
            height: size,
            child: Icon(icon, size: 18),
          ),
        ),
      );
}

/// 可步进单元格：右侧 ▲/▼ 按钮调值；鼠标悬停时滚轮调值（劫持表格滚动）。
/// [readOnly] 时不显示步进按钮、不响应滚轮（分笔模板下的自动时间格用）。
class _AdjustableCell extends StatefulWidget {
  const _AdjustableCell({
    required this.controller,
    required this.kind,
    required this.onStep,
    this.readOnly = false,
    this.onChanged,
  });

  final TextEditingController controller;
  final _CellKind kind;
  final void Function(_CellKind kind, int dir) onStep;
  final bool readOnly;
  final ValueChanged<String>? onChanged;

  @override
  State<_AdjustableCell> createState() => _AdjustableCellState();
}

class _AdjustableCellState extends State<_AdjustableCell> {
  bool _hovered = false;

  String _stepTooltip(int dir) {
    final unit = widget.kind == _CellKind.time
        ? '1 分钟'
        : widget.kind == _CellKind.price
            ? '0.01'
            : '1';
    return dir > 0 ? '加 $unit' : '减 $unit';
  }

  void _onPointerSignal(PointerSignalEvent event) {
    if (widget.readOnly ||
        event is! PointerScrollEvent ||
        event.kind != PointerDeviceKind.mouse ||
        !_hovered ||
        event.scrollDelta.dy == 0) {
      return;
    }
    final dir = event.scrollDelta.dy < 0 ? 1 : -1;
    // 抢占信号避免外层面板再滚动：resolver 只回调最先注册者，内层优先。
    GestureBinding.instance.pointerSignalResolver.register(event, (e) {
      widget.onStep(widget.kind, dir);
    });
  }

  Widget _cell(TextEditingController c) => Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
        child: TextField(
          controller: c,
          readOnly: widget.readOnly,
          onChanged: widget.onChanged,
          style: TextStyle(
            fontSize: 12,
            color: widget.readOnly ? const Color(0xFF9E9E9E) : null,
          ),
          decoration: const InputDecoration(
            isDense: true,
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
          ),
        ),
      );

  Widget _stepBtn(int dir) => _MiniIconButton(
        size: 18,
        tooltip: _stepTooltip(dir),
        icon: dir > 0 ? Icons.keyboard_arrow_up : Icons.keyboard_arrow_down,
        onTap: () => widget.onStep(widget.kind, dir),
      );

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      onEnter: (_) => setState(() => _hovered = true),
      onExit: (_) => setState(() => _hovered = false),
      child: Listener(
        onPointerSignal: _onPointerSignal,
        child: Container(
          decoration: _hovered && !widget.readOnly
              ? BoxDecoration(
                  border: Border.all(
                    color: Theme.of(context)
                        .colorScheme
                        .primary
                        .withValues(alpha: 0.5),
                  ),
                  borderRadius: BorderRadius.circular(4),
                )
              : null,
          child: Row(
            children: [
              Expanded(child: _cell(widget.controller)),
              if (!widget.readOnly) ...[
                _stepBtn(1),
                _stepBtn(-1),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// test 自定义 OHLC 表格弹窗：编辑 → 保存到 custom.ohlc.csv。
///
/// [tickTemplate]：分笔模板，默认开启。开启后：
/// · 开高低收同一价位，改任一价其余三价联动；
/// · 时间由系统按「每 3 秒一笔（约 20 笔/分钟）」自动生成，仅保留起始时间可填；
/// · 成交量仍可自由修改。
Future<TestOhlcEditorResult?> showTestOhlcEditorDialog({
  required BuildContext context,
  required List<KlineBar> initialBars,
  bool tickTemplate = true,
}) {
  return showDialog<TestOhlcEditorResult>(
    context: context,
    barrierDismissible: false,
    builder: (ctx) => _TestOhlcEditorDialog(
      initialBars: initialBars,
      tickTemplate: tickTemplate,
    ),
  );
}

class _TestOhlcEditorDialog extends StatefulWidget {
  const _TestOhlcEditorDialog({
    required this.initialBars,
    required this.tickTemplate,
  });

  final List<KlineBar> initialBars;
  final bool tickTemplate;

  @override
  State<_TestOhlcEditorDialog> createState() => _TestOhlcEditorDialogState();
}

class _TestOhlcEditorDialogState extends State<_TestOhlcEditorDialog> {
  late List<_RowDraft> _rows;
  String? _error;
  final ScrollController _tableScroll = ScrollController();

  /// 分笔模板（默认开）：开高低收联动 + 时间自动 3 秒一笔。
  late bool _tickTemplate = widget.tickTemplate;
  /// 分笔模板下的起始时间（首行时间，其余行自动 +3 秒）。
  final TextEditingController _tickStart = TextEditingController();
  /// 联动回写开关：改任一二场价时向其它三格回写，避免回写再触发联动死循环。
  bool _syncingPrices = false;

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
    final t0 = _rows.isEmpty ? null : _parseTime(_rows.first.time.text);
    _tickStart.text = _fmt(
      t0 ?? DateTime(2026, 7, 10, 9, 30, 0),
    );
    if (_tickTemplate) {
      _applyTickTemplate();
    }
  }

  @override
  void dispose() {
    _tableScroll.dispose();
    _tickStart.dispose();
    for (final r in _rows) {
      r.dispose();
    }
    super.dispose();
  }

  /// 联动某一行的四个价格格均为同一价位文本；回写期间不再触发联动。
  void _setRowPrice(_RowDraft row, String text) {
    if (_syncingPrices) return;
    _syncingPrices = true;
    row.open.text = text;
    row.high.text = text;
    row.low.text = text;
    row.close.text = text;
    _syncingPrices = false;
  }

  /// 分笔模板下用户改任一二场价 → 其余三格联动。
  void _onPriceChanged(_RowDraft row, String text) {
    if (!_tickTemplate || _syncingPrices) return;
    _setRowPrice(row, text);
    setState(() => _error = null);
  }

  /// 生成第 i 行的时间：起始时间 + i×3s。
  String _tickTimeText(int i) {
    final base = _parseTime(_tickStart.text);
    final dt = (base ?? DateTime(2026, 7, 10, 9, 30, 0))
        .add(Duration(seconds: 3 * i));
    return _fmt(dt);
  }

  /// 分笔模板：开高低收都取开价格式，时间按 3 秒一笔自动生成。
  void _applyTickTemplate() {
    setState(() {
      for (final r in _rows) {
        final openText = r.open.text.trim().isEmpty ? '3' : r.open.text.trim();
        _setRowPrice(r, openText);
        _error = null;
      }
      _regenerateTickTimes();
    });
  }

  /// 按起始时间重排全部时间格（严格递增 3 秒）。
  void _regenerateTickTimes() {
    for (var i = 0; i < _rows.length; i++) {
      _rows[i].time.text = _tickTimeText(i);
    }
  }

  void _removeRow(int i) {
    if (_rows.length <= 1) {
      setState(() => _error = '至少保留一行');
      return;
    }
    setState(() {
      _rows.removeAt(i).dispose();
      _error = null;
      if (_tickTemplate) _regenerateTickTimes();
    });
  }

  /// 行 i 的「+」：在 i+1 插入本行数据的纯文本副本。
  /// 分笔模板下时间由系统重排（3 秒一笔），严格递增由保存时 _parseBars 兜底。
  void _duplicateRow(int i) {
    setState(() {
      _rows.insert(i + 1, _RowDraft.copyOf(_rows[i]));
      _error = null;
      if (_tickTemplate) _regenerateTickTimes();
    });
  }

  /// 步进后格式化价格：先 fixed(2) 消除浮点伪影，再剥尾零。
  static String _priceText(double v) {
    var t = v.toStringAsFixed(2);
    if (t.endsWith('.00')) {
      t = t.substring(0, t.length - 3);
    } else if (t.endsWith('0')) {
      t = t.substring(0, t.length - 1);
    }
    return t;
  }

  /// 步进一格：时间 ±1 分钟 / 价格 ±0.01 / 量 ±1；文本不完整时静默跳过。
  /// 分笔模板下价格联动整行四价。
  void _step(_CellKind kind, _RowDraft row, TextEditingController c, int dir) {
    if (kind == _CellKind.time) {
      final dt = _parseTime(c.text);
      if (dt == null) return;
      c.text = _fmt(dt.add(Duration(minutes: dir)));
    } else if (kind == _CellKind.price) {
      final v = double.tryParse(c.text.trim());
      if (v == null) return;
      final text = _priceText(v + 0.01 * dir);
      if (_tickTemplate) {
        _setRowPrice(row, text);
      } else {
        c.text = text;
      }
    } else {
      final raw = c.text.trim();
      final v = raw.isEmpty ? 0.0 : double.tryParse(raw);
      if (v == null) return;
      c.text = _RowDraft._num(v + 1 * dir);
    }
    setState(() => _error = null);
  }

  /// 解析并校验表格 → KlineBar 列表；失败写 _error。
  List<KlineBar>? _parseBars() {
    if (_tickTemplate && _parseTime(_tickStart.text) == null) {
      setState(() => _error = '起始时间格式应为 YYYY/MM/DD HH:MM:SS');
      return null;
    }
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
            '2. 默认启用「分笔模板」：按行填价格与量，时间自动按\n'
            '   每 3 秒一笔（约 20 笔/分钟）从「起始时间」生成；\n'
            '   改任一价格（开/高/低/收）四格联动为同一价位。\n'
            '   关掉模板即为自由编辑，时间/开高低收逐格可改。\n'
            '3. 「仅保存」写入 a_Data/test/custom.ohlc.csv（即分笔数据源）；\n'
            '   「保存并加载」写盘后立刻上图。其它周期（1m/5m/…/日）\n'
            '   会由这些分笔自动聚合生成，无需另行选择模板。\n'
            '\n'
            '微调：\n'
            '· 每格右侧 ▲/▼ 按钮，或鼠标悬停该格后滚动滚轮：\n'
            '  价格 ±0.01、量 ±1、时间 ±1 分钟。\n'
            '· 悬停格内时滚轮不再滚动表格，请用右侧滚动条或\n'
            '  悬停表头/序号/操作列滚轮翻页。\n'
            '· 正在输入的格文本不完整时，悬停滚轮不生效（安全忽略）。\n'
            '· 行尾「+」复制本行数据插入到本行下方。\n'
            '\n'
            '口径：\n'
            '· 表格每一行即一笔分笔数据（一字线：开=高=低=收）。\n'
            '· 选周期分笔(tick)：一行一笔直读；选其它周期：\n'
            '  由这些分笔按规则聚合（1m → 目标周期）自动生成。\n'
            '· high≥max(开,收)，low≤min(开,收)，时间严格递增\n'
            '  （模板下时间由系统保证，无需手动）。\n'
            '· 无 CSV 时回退 test 分笔文件。',
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
        width: 880,
        height: 470,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 8),
                child: Text(
                  _error!,
                  style: TextStyle(color: AppPalette.rgb(0xFFEF5350), fontSize: 13),
                ),
              ),
            // 分笔模板栏：默认启用；起始时间可改，其余时间自动 3 秒一笔。
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: [
                  Switch(
                    value: _tickTemplate,
                    onChanged: (v) {
                      setState(() => _tickTemplate = v);
                      if (v) _applyTickTemplate();
                    },
                  ),
                  const SizedBox(width: 4),
                  const Text('分笔模板', style: TextStyle(fontSize: 13)),
                  const SizedBox(width: 12),
                  if (_tickTemplate) ...[
                    SizedBox(
                      width: 190,
                      child: TextField(
                        controller: _tickStart,
                        style: const TextStyle(fontSize: 12),
                        decoration: const InputDecoration(
                          isDense: true,
                          labelText: '起始时间',
                          border: OutlineInputBorder(),
                          contentPadding:
                              EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                        ),
                        onChanged: (_) {
                          if (_parseTime(_tickStart.text) != null) {
                            setState(_regenerateTickTimes);
                          }
                        },
                      ),
                    ),
                    const SizedBox(width: 10),
                    const Expanded(
                      child: Text(
                        '每 3 秒一笔 · 约 20 笔/分钟 · 开高低收联动 · 量可改',
                        style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ] else
                    const Expanded(
                      child: Text(
                        '自由编辑：时间/开高低收均可逐格修改',
                        style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
              ),
            ),
            Expanded(
              child: Scrollbar(
                controller: _tableScroll,
                thumbVisibility: true,
                child: SingleChildScrollView(
                  controller: _tableScroll,
                  child: Table(
                    columnWidths: const {
                      0: FixedColumnWidth(28),
                      1: FlexColumnWidth(2.4),
                      2: FlexColumnWidth(1),
                      3: FlexColumnWidth(1),
                      4: FlexColumnWidth(1),
                      5: FlexColumnWidth(1),
                      6: FlexColumnWidth(1),
                      7: FixedColumnWidth(68),
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
                            Text('${i + 1}',
                                style: const TextStyle(fontSize: 12)),
                            _AdjustableCell(
                              controller: _rows[i].time,
                              kind: _CellKind.time,
                              readOnly: _tickTemplate,
                              onStep: (k, dir) =>
                                  _step(k, _rows[i], _rows[i].time, dir),
                            ),
                            _AdjustableCell(
                              controller: _rows[i].open,
                              kind: _CellKind.price,
                              onStep: (k, dir) =>
                                  _step(k, _rows[i], _rows[i].open, dir),
                              onChanged: _tickTemplate
                                  ? (t) => _onPriceChanged(_rows[i], t)
                                  : null,
                            ),
                            _AdjustableCell(
                              controller: _rows[i].high,
                              kind: _CellKind.price,
                              onStep: (k, dir) =>
                                  _step(k, _rows[i], _rows[i].high, dir),
                              onChanged: _tickTemplate
                                  ? (t) => _onPriceChanged(_rows[i], t)
                                  : null,
                            ),
                            _AdjustableCell(
                              controller: _rows[i].low,
                              kind: _CellKind.price,
                              onStep: (k, dir) =>
                                  _step(k, _rows[i], _rows[i].low, dir),
                              onChanged: _tickTemplate
                                  ? (t) => _onPriceChanged(_rows[i], t)
                                  : null,
                            ),
                            _AdjustableCell(
                              controller: _rows[i].close,
                              kind: _CellKind.price,
                              onStep: (k, dir) =>
                                  _step(k, _rows[i], _rows[i].close, dir),
                              onChanged: _tickTemplate
                                  ? (t) => _onPriceChanged(_rows[i], t)
                                  : null,
                            ),
                            _AdjustableCell(
                              controller: _rows[i].volume,
                              kind: _CellKind.volume,
                              onStep: (k, dir) =>
                                  _step(k, _rows[i], _rows[i].volume, dir),
                            ),
                            Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                _MiniIconButton(
                                  size: 32,
                                  tooltip: '复制本行插入到下方',
                                  icon: Icons.add_circle_outline,
                                  onTap: () => _duplicateRow(i),
                                ),
                                const SizedBox(width: 4),
                                _MiniIconButton(
                                  size: 32,
                                  tooltip: '删除本行',
                                  icon: Icons.remove_circle_outline,
                                  onTap: () => _removeRow(i),
                                ),
                              ],
                            ),
                          ],
                        ),
                    ],
                  ),
                ),
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
}
