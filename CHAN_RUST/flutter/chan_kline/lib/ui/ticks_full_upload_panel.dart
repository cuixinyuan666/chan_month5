import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../settings/telegram_settings_store.dart';
import 'settings_panel_widgets.dart';

/// 全市场分笔上传在设置里看到的进度。
class TicksUploadSnapshot {
  const TicksUploadSnapshot({
    required this.taskRegistered,
    required this.supervisorAlive,
    required this.done,
    required this.localCode,
    required this.others,
    required this.logLine,
    required this.shareNote,
  });

  final bool taskRegistered;
  final bool supervisorAlive;
  final int? done;
  final String localCode;
  final List<String> others;
  final String logLine;
  final String shareNote;

  String get headline {
    if (supervisorAlive) return '正在下载';
    if (taskRegistered) return '任务已登记，当前没在下载';
    return '尚未生成本机任务';
  }
}

/// 本机监视进程是否还在（看锁文件里的进程号）。
Future<bool> ticksUploadSupervisorAlive(String dataRoot) async {
  if (!Platform.isWindows || dataRoot.trim().isEmpty) return false;
  final lock = File(
    '$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}supervisor.lock',
  );
  if (!await lock.exists()) return false;
  try {
    final obj = jsonDecode(await lock.readAsString());
    final pid = obj is Map ? obj['pid'] : null;
    final id = pid is int ? pid : int.tryParse('$pid');
    if (id == null || id <= 0) return false;
    final q = await Process.run('tasklist', ['/FI', 'PID eq $id']);
    return q.exitCode == 0 && '${q.stdout}'.contains('$id');
  } catch (_) {
    return false;
  }
}

Future<TicksUploadSnapshot> loadTicksUploadSnapshot({
  required String shareDir,
  required String dataRoot,
}) async {
  var registered = false;
  if (Platform.isWindows) {
    try {
      final q = await Process.run(
        'schtasks',
        ['/Query', '/TN', r'Chan\TicksFullUpload'],
      );
      registered = q.exitCode == 0;
    } catch (_) {}
  }
  final alive = await ticksUploadSupervisorAlive(dataRoot);
  int? done;
  var shareNote = shareDir.trim().isEmpty ? '请先填写共享进度目录' : '';
  final others = <String>[];
  if (shareDir.trim().isNotEmpty) {
    try {
      final stateFile = File(
        '$shareDir${Platform.pathSeparator}ticks_stream_state.json',
      );
      if (await stateFile.exists()) {
        final obj = jsonDecode(await stateFile.readAsString());
        if (obj is Map && obj['files'] is Map) {
          done = (obj['files'] as Map).length;
        }
      } else {
        done = 0;
      }
      final claims = Directory(
        '$shareDir${Platform.pathSeparator}claims',
      );
      if (await claims.exists()) {
        await for (final ent in claims.list()) {
          if (ent is! File || !ent.path.toLowerCase().endsWith('.json')) {
            continue;
          }
          try {
            final meta = jsonDecode(await ent.readAsString());
            if (meta is Map) {
              final machine = '${meta['machine'] ?? ''}'.trim();
              final code = '${meta['code'] ?? ''}'.trim();
              if (machine.isNotEmpty || code.isNotEmpty) {
                others.add('$machine $code'.trim());
              }
            }
          } catch (_) {}
        }
      }
      if (shareNote.isEmpty) shareNote = '进度目录可读取';
    } catch (_) {
      shareNote = '进度目录读不到';
    }
  }
  var localCode = '';
  final current = File(
    '$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}current_code.txt',
  );
  try {
    if (await current.exists()) {
      localCode = (await current.readAsString()).trim();
    }
  } catch (_) {}
  var logLine = '';
  final log = File(
    '$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}supervisor.log',
  );
  try {
    if (await log.exists()) {
      final lines = (await log.readAsString())
          .split(RegExp(r'\r?\n'))
          .where((e) => e.trim().isNotEmpty)
          .toList();
      if (lines.isNotEmpty) logLine = lines.last.trim();
    }
  } catch (_) {}
  return TicksUploadSnapshot(
    taskRegistered: registered,
    supervisorAlive: alive,
    done: done,
    localCode: localCode,
    others: others,
    logLine: logLine,
    shareNote: shareNote,
  );
}

/// 让正在跑的本机下载退出。托盘进程看到停止标记后会自己结束。
Future<void> stopTicksUploadTask({
  required String dataRoot,
  required String jobDir,
}) async {
  for (final path in [
    '$jobDir${Platform.pathSeparator}stop.flag',
    '$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}stop.flag',
  ]) {
    try {
      final f = File(path);
      await f.parent.create(recursive: true);
      await f.writeAsString('1');
    } catch (_) {}
  }
  if (Platform.isWindows) {
    try {
      await Process.run('schtasks', ['/End', '/TN', r'Chan\TicksFullUpload']);
    } catch (_) {}
  }
}

/// 设置面板里的全市场分笔上传。
class TicksFullUploadPanel extends StatefulWidget {
  const TicksFullUploadPanel({
    super.key,
    required this.settings,
    required this.dataRoot,
    required this.onCreateTask,
    required this.onShareDir,
  });

  final TelegramSettings settings;
  final String dataRoot;
  final Future<String> Function(TelegramSettings draft) onCreateTask;
  final Future<void> Function(String shareDir) onShareDir;

  @override
  State<TicksFullUploadPanel> createState() => _TicksFullUploadPanelState();
}

class _TicksFullUploadPanelState extends State<TicksFullUploadPanel> {
  late final TextEditingController _shareCtrl;
  TicksUploadSnapshot? _snap;
  Timer? _timer;
  String _actionNote = '';
  bool _creating = false;

  @override
  void initState() {
    super.initState();
    _shareCtrl = TextEditingController(text: widget.settings.shareDir);
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _reload());
  }

  @override
  void didUpdateWidget(covariant TicksFullUploadPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.shareDir != widget.settings.shareDir &&
        _shareCtrl.text != widget.settings.shareDir) {
      _shareCtrl.text = widget.settings.shareDir;
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    _shareCtrl.dispose();
    super.dispose();
  }

  Future<void> _reload() async {
    final snap = await loadTicksUploadSnapshot(
      shareDir: _shareCtrl.text.trim(),
      dataRoot: widget.dataRoot,
    );
    if (!mounted) return;
    setState(() => _snap = snap);
  }

  Color _noteColor(String note) {
    if (note.startsWith('正在')) return const Color(0xFF93C5FD);
    if (note.contains('失败') ||
        note.contains('请先') ||
        note.contains('找不到') ||
        note.contains('读不到') ||
        note.contains('没有找到') ||
        note.contains('没有留住') ||
        note.contains('超时')) {
      return const Color(0xFFFCA5A5);
    }
    return const Color(0xFF86EFAC);
  }

  void _onCreatePressed() {
    setState(() {
      _creating = true;
      _actionNote = '正在登记本机上传任务…';
    });
    unawaited(_runCreate());
  }

  Future<void> _runCreate() async {
    try {
      await widget.onShareDir(_shareCtrl.text.trim());
      final msg = await widget.onCreateTask(
        widget.settings.copyWith(shareDir: _shareCtrl.text.trim()),
      );
      if (!mounted) return;
      final text = msg.trim().isEmpty ? '登记结束，但没有返回说明' : msg.trim();
      setState(() => _actionNote = text);
    } catch (e) {
      if (!mounted) return;
      setState(() => _actionNote = '登记失败：$e');
    } finally {
      if (mounted) setState(() => _creating = false);
      await _reload();
    }
  }

  Future<void> _help() {
    return showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('全市场分笔上传'),
        content: const Text(
          '1. 在常开的那台电脑上把进度文件夹共享成读写。\n'
          '2. 两台电脑填同一个共享进度目录。\n'
          '3. 先在「Telegram 数据源」里保存机器人令牌、聊天号和代理。\n'
          '4. 点「生成本机上传任务」。按钮上方会写出正在登记、成功，或失败原因。成功后本机会登记登录后自动跑的任务，并在任务栏托盘显示。\n'
          '5. 这里能看到已完成只数、本机正在传的代码，以及其他电脑正在传的代码。\n'
          '6. 关闭主图时，可以选择让下载留在托盘里继续。',
          style: TextStyle(fontSize: 13, height: 1.4),
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
    final snap = _snap;
    final doneText = snap == null
        ? '进度读取中…'
        : snap.done == null
            ? '已完成：还不知道'
            : '已完成：${snap.done} 只';
    final local = (snap?.localCode ?? '').isEmpty ? '无' : snap!.localCode;
    final others = (snap?.others ?? const <String>[]).isEmpty
        ? '无'
        : snap!.others.join('；');
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const SizedBox(height: SettingsPanelTheme.sectionGap),
        Row(
          children: [
            const Expanded(
              child: Text(
                '全市场分笔上传',
                style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600),
              ),
            ),
            IconButton(
              tooltip: '操作说明',
              onPressed: _help,
              icon: const Icon(Icons.help_outline, size: 18),
            ),
          ],
        ),
        TextFormField(
          controller: _shareCtrl,
          decoration: const InputDecoration(
            labelText: '共享进度目录',
            hintText: r'\\电脑名\共享名',
            isDense: true,
            border: OutlineInputBorder(),
          ),
          onFieldSubmitted: (v) {
            () async {
              await widget.onShareDir(v.trim());
              await _reload();
            }();
          },
        ),
        const SizedBox(height: 6),
        Text(
          snap == null
              ? '进度读取中…'
              : '${snap.headline}\n$doneText\n本机正在传：$local\n各机占用：$others\n${snap.shareNote}'
                  '${snap.logLine.isEmpty ? '' : '\n最近：${snap.logLine}'}',
          style: const TextStyle(fontSize: 12, height: 1.35, color: Color(0xFFCBD5E1)),
        ),
        const SizedBox(height: 8),
        SettingsOutlinedButton(
          label: '刷新进度',
          icon: Icons.refresh,
          onPressed: () {
            _reload();
          },
        ),
        if (_actionNote.isNotEmpty) ...[
          const SizedBox(height: 8),
          DecoratedBox(
            decoration: BoxDecoration(
              color: const Color(0xFF0F172A),
              borderRadius: BorderRadius.circular(6),
              border: Border.all(color: _noteColor(_actionNote)),
            ),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Text(
                _actionNote,
                style: TextStyle(
                  fontSize: 13,
                  height: 1.35,
                  color: _noteColor(_actionNote),
                ),
              ),
            ),
          ),
        ],
        const SizedBox(height: 6),
        SettingsFilledButton(
          label: _creating ? '正在登记…' : '生成本机上传任务',
          icon: Icons.playlist_add_check,
          onPressed: _creating ? null : _onCreatePressed,
        ),
      ],
    );
  }
}
