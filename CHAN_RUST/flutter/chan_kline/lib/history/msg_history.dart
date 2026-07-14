import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

/// 消息历史（对齐 a_replay_trainer 的 appendMsgHistory / 一键复制）。
/// 常驻功能：放在 lib/history/，合并到 main / 清理 UI 时不得删除。
class MsgHistory {
  MsgHistory._();

  static final MsgHistory instance = MsgHistory._();

  static const int _maxRows = 500;

  /// 命名变更是否已记录（进程内只记一次，便于从历史记录追溯完整更名过程）
  static bool _namingRenameLogged = false;

  final List<MsgHistoryEntry> _rows = [];

  List<MsgHistoryEntry> get rows => List.unmodifiable(_rows);

  void append(String text) {
    final content = text.trim();
    if (content.isEmpty) return;
    if (_rows.isNotEmpty && _rows.last.text == content) return;
    _rows.add(MsgHistoryEntry(
      time: DateTime.now(),
      text: content,
    ));
    while (_rows.length > _maxRows) {
      _rows.removeAt(0);
    }
  }

  void clear({String? reason}) {
    _rows.clear();
    if (reason != null && reason.trim().isNotEmpty) {
      append('历史记录已清空：$reason');
    }
  }

  /// 记录「中枢(ZS) → 跨段中枢(KuaDuan)」命名变更（进程内去重一次），
  /// 便于调试时从历史记录追溯名称演进的完整过程。
  void appendNamingRename() {
    if (_namingRenameLogged) return;
    _namingRenameLogged = true;
    append(
      '【命名变更】中枢(ZS) → 跨段中枢(KuaDuan)：'
      'Rust 模块 zs→kuaduan（ZS→KuaDuan、ZSFrame→KuaDuanFrame、zs_frames→kuaduan_frames），'
      '已重建 chan_ffi.dll；主图指标展示名 K(n-1)跨段中枢（K0跨段中枢、K1跨段中枢）。',
    );
    append(
      '【命名变更】笔/线段 → K0连线/K1连线：代码取消「笔/线段」概念，统一 K0/K1/…/KN。'
      '笔=K0连线、线段=K1连线、笔虚拟K=K1；字段 bi_*→k0_*/k1_*、seg_*→k1_*'
      '（bi_segments→k0_lines、bi_combine_frames→k1_combine_frames、seg_lines→k1_lines）；'
      'Rust 类型 BiSegment→K0Line、BiVirtualBar→K1Bar、SegLine→K1Line、SegAnalysisBundle→K1AnalysisBundle；'
      '已重建 chan_ffi.dll；JSON key 同步变更。',
    );
  }

  String asText([List<MsgHistoryEntry>? source]) {
    final src = source ?? _rows;
    return src
        .map((e) => '[${_fmtTime(e.time)}] ${e.text}')
        .join('\n');
  }

  Future<bool> copyToClipboard({
    List<MsgHistoryEntry>? source,
    String okMsg = '历史记录已复制',
    BuildContext? context,
  }) async {
    final text = asText(source);
    if (text.trim().isEmpty) {
      _showSnack(context, '没有可复制的内容');
      return false;
    }
    await Clipboard.setData(ClipboardData(text: text));
    if (context != null && context.mounted) {
      _showSnack(context, okMsg);
    }
    return true;
  }

  Future<void> showDialog(BuildContext context, {String title = '历史记录'}) {
    return showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      backgroundColor: const Color(0xFF1E1E1E),
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(12)),
      ),
      builder: (ctx) {
        return _MsgHistorySheet(title: title);
      },
    );
  }

  static String _fmtTime(DateTime t) {
    final h = t.hour.toString().padLeft(2, '0');
    final m = t.minute.toString().padLeft(2, '0');
    final s = t.second.toString().padLeft(2, '0');
    return '$h:$m:$s';
  }

  static void _showSnack(BuildContext? context, String msg) {
    if (context == null || !context.mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(msg), duration: const Duration(seconds: 2)),
    );
  }
}

class MsgHistoryEntry {
  final DateTime time;
  final String text;

  const MsgHistoryEntry({required this.time, required this.text});
}

class _MsgHistorySheet extends StatefulWidget {
  const _MsgHistorySheet({required this.title});

  final String title;

  @override
  State<_MsgHistorySheet> createState() => _MsgHistorySheetState();
}

class _MsgHistorySheetState extends State<_MsgHistorySheet> {
  final _history = MsgHistory.instance;

  @override
  Widget build(BuildContext context) {
    final rows = _history.rows;
    final h = MediaQuery.sizeOf(context).height * 0.62;
    return SafeArea(
      child: SizedBox(
        height: h,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 8, 8),
              child: Row(
                children: [
                  Expanded(
                    child: Text(
                      widget.title,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
                  TextButton(
                    onPressed: rows.isEmpty
                        ? null
                        : () => _history.copyToClipboard(
                              context: context,
                              okMsg: '历史记录已复制',
                            ),
                    child: const Text('一键复制历史记录'),
                  ),
                  TextButton(
                    onPressed: () {
                      setState(() => _history.clear(reason: '用户手动清空'));
                    },
                    child: const Text('清空'),
                  ),
                  IconButton(
                    tooltip: '关闭',
                    onPressed: () => Navigator.pop(context),
                    icon: const Icon(Icons.close),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: rows.isEmpty
                  ? const Center(child: Text('暂无历史记录'))
                  : ListView.builder(
                      padding: const EdgeInsets.all(12),
                      itemCount: rows.length,
                      itemBuilder: (_, i) {
                        final e = rows[rows.length - 1 - i];
                        return Padding(
                          padding: const EdgeInsets.only(bottom: 8),
                          child: SelectableText(
                            '[${MsgHistory._fmtTime(e.time)}] ${e.text}',
                            style: const TextStyle(fontSize: 12, height: 1.35),
                          ),
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}
