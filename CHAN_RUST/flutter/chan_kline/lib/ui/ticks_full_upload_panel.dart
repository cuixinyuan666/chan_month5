import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';

import '../settings/telegram_settings_store.dart';
import 'settings_panel_widgets.dart';

/// 局域网默认共享进度目录：PCA 本机优先走本地盘，别的机器走共享。
const String kTicksShareDirLocal = r'D:\chan_ticks_share\live';
const String kTicksShareDirUnc = r'\\192.168.1.5\chan_ticks_state\live';

/// 共享进度目录的默认值。两台机器指向同一个目录，只是路径写法不同。
String defaultTicksShareDir() {
  try {
    if (Directory(kTicksShareDirLocal).existsSync()) return kTicksShareDirLocal;
  } catch (_) {}
  return kTicksShareDirUnc;
}

/// 一台机器在「全市场分笔上传」里的状态。
class TicksUploadMachineStatus {
  const TicksUploadMachineStatus({
    required this.machine,
    required this.isLocal,
    required this.alive,
    required this.current,
    required this.done,
    required this.total,
    required this.ratePerMin,
    required this.pid,
    required this.updatedAt,
    required this.heartbeatAt,
    required this.sessionDone,
  });

  final String machine;
  final bool isLocal;
  final bool alive;
  final String current;
  final int? done;
  final int? total;
  final double? ratePerMin;
  final int? pid;
  final DateTime? updatedAt;
  final DateTime? heartbeatAt;

  /// 这台机器本次进程启动后自己传完的只数（不是两台合计）。
  final int? sessionDone;

  String get label => isLocal ? '$machine（本机）' : machine;

  String get stateText => alive ? '在跑' : '停了';

  Duration? get age {
    final t = heartbeatAt ?? updatedAt;
    if (t == null) return null;
    return DateTime.now().difference(t);
  }

  String get ageText {
    final d = age;
    if (d == null) return '时间未知';
    final s = d.inSeconds;
    if (s < 0) return '0 秒前';
    if (s < 60) return '$s 秒前';
    if (s < 3600) return '${s ~/ 60} 分钟前';
    return '${s ~/ 3600} 小时前';
  }
}

/// 最近完成的一只股票。
class TicksUploadRecentDone {
  const TicksUploadRecentDone({
    required this.code,
    required this.machine,
    required this.at,
  });

  final String code;
  final String machine;
  final String at;
}

/// 全市场分笔上传在设置里看到的进度（本机 + 各机 + 汇总）。
class TicksUploadSnapshot {
  const TicksUploadSnapshot({
    required this.taskRegistered,
    required this.supervisorAlive,
    required this.done,
    required this.total,
    required this.skipped,
    required this.machines,
    required this.recent,
    required this.logLine,
    required this.shareNote,
    required this.shareOk,
    required this.sampledAt,
  });

  final bool taskRegistered;
  final bool supervisorAlive;
  final int? done;
  final int? total;
  final int skipped;
  final List<TicksUploadMachineStatus> machines;
  final List<TicksUploadRecentDone> recent;
  final String logLine;
  final String shareNote;
  final bool shareOk;
  final DateTime sampledAt;

  /// 本机那台的状态（找不到时按注册/存活兜底）。
  TicksUploadMachineStatus? get local {
    for (final m in machines) {
      if (m.isLocal) return m;
    }
    return null;
  }

  /// 别的机器。
  List<TicksUploadMachineStatus> get peers =>
      machines.where((m) => !m.isLocal).toList();

  int get runningCount => machines.where((m) => m.alive).length;

  double get totalRate {
    var v = 0.0;
    for (final m in machines) {
      v += m.ratePerMin ?? 0;
    }
    return v;
  }

  String get headline {
    final running = runningCount;
    if (running >= 1) {
      return running > 1 ? '正在下载（$running 台并行）' : '正在下载';
    }
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

/// 读 JSON：进度文件由两台机器轮流写，撞上写入途中会解析失败，这里重试几次。
Future<Map<String, dynamic>?> _readJsonRetry(File f, {int tries = 4}) async {
  for (var i = 0; i < tries; i++) {
    try {
      if (!await f.exists()) return null;
      final raw = await f.readAsString();
      final v = jsonDecode(raw);
      if (v is Map) return v.map((k, val) => MapEntry('$k', val));
      return null;
    } catch (_) {
      await Future<void>.delayed(Duration(milliseconds: 120 + i * 160));
    }
  }
  return null;
}

int? _asInt(dynamic v) {
  if (v is int) return v;
  if (v is num) return v.toInt();
  final s = '$v'.trim();
  return int.tryParse(s);
}

double? _asDouble(dynamic v) {
  if (v is num) return v.toDouble();
  return double.tryParse('$v'.trim());
}

DateTime? _asTime(Map<String, dynamic> obj) {
  final ep = _asDouble(obj['updated_epoch']) ?? _asDouble(obj['heartbeat_at']);
  if (ep != null && ep > 0) {
    return DateTime.fromMillisecondsSinceEpoch((ep * 1000).round());
  }
  final s = '${obj['updated_at'] ?? ''}'.trim();
  if (s.isEmpty) return null;
  return DateTime.tryParse(s.replaceFirst(' ', 'T'));
}

TicksUploadMachineStatus _machineFromJson(
  Map<String, dynamic> obj, {
  required bool isLocal,
  DateTime? heartbeatAt,
  bool? aliveOverride,
}) {
  final machine = '${obj['machine'] ?? (isLocal ? Platform.localHostname : '')}'
      .trim();
  final updated = _asTime(obj);
  final ageSeconds = updated == null
      ? null
      : DateTime.now().difference(updated).inSeconds;
  final alive = aliveOverride ??
      (ageSeconds != null && ageSeconds >= 0 && ageSeconds < 120);
  return TicksUploadMachineStatus(
    machine: machine.isEmpty ? (isLocal ? Platform.localHostname : '?') : machine,
    isLocal: isLocal,
    alive: alive,
    current: '${obj['current'] ?? ''}'.trim(),
    done: _asInt(obj['done']),
    total: _asInt(obj['total']),
    ratePerMin: _asDouble(obj['rate_per_min']),
    pid: _asInt(obj['pid']),
    updatedAt: updated,
    heartbeatAt: heartbeatAt,
    sessionDone: _asInt(obj['session_done']),
  );
}

Future<TicksUploadSnapshot> loadTicksUploadSnapshot({
  required String shareDir,
  required String dataRoot,
}) async {
  var registered = false;
  if (Platform.isWindows) {
    try {
      final q = await Process.run('schtasks', [
        '/Query',
        '/TN',
        r'Chan\TicksFullUpload',
      ]);
      registered = q.exitCode == 0;
    } catch (_) {}
  }
  final localAlive = await ticksUploadSupervisorAlive(dataRoot);
  final machines = <String, TicksUploadMachineStatus>{};
  final claimsByMachine = <String, Map<String, dynamic>>{};
  var done = <int>[]; // 用列表只是为了让后面能判「读没读到」
  var doneValue = 0;
  var skipped = 0;
  var shareOk = false;
  var shareNote = '';
  final recent = <TicksUploadRecentDone>[];

  // 1) 本机自己的 status（即使共享读不到也要能显示本机）
  final localStatus = await _readJsonRetry(
    File('$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}status.json'),
  );
  if (localStatus != null) {
    final m = _machineFromJson(
      localStatus,
      isLocal: true,
      aliveOverride: localAlive,
    );
    machines[m.machine] = m;
  } else if (localAlive) {
    var current = '';
    try {
      current = (await File(
        '$dataRoot${Platform.pathSeparator}local${Platform.pathSeparator}current_code.txt',
      ).readAsString()).trim();
    } catch (_) {}
    machines[Platform.localHostname] = TicksUploadMachineStatus(
      machine: Platform.localHostname,
      isLocal: true,
      alive: true,
      current: current,
      done: null,
      total: null,
      ratePerMin: null,
      pid: null,
      updatedAt: DateTime.now(),
      heartbeatAt: DateTime.now(),
      sessionDone: null,
    );
  }

  final text = shareDir.trim();
  if (text.isEmpty) {
    shareNote = '共享进度目录为空，默认用 $kTicksShareDirUnc';
  } else {
    final dir = Directory(text);
    if (!await dir.exists()) {
      shareNote = '共享进度目录读不到：$text';
    } else {
      shareOk = true;
      shareNote = '共享进度目录可读取';

      // 2) 汇总进度（两台机器共写的同一个状态文件）
      final st = await _readJsonRetry(
        File('$text${Platform.pathSeparator}ticks_stream_state.json'),
        tries: 5,
      );
      if (st == null) {
        shareNote = '状态文件读不到（可能另一台正在写），会自动重试';
      } else {
        final files = st['files'];
        if (files is Map) {
          doneValue = files.length;
          done.add(doneValue);
          for (final e in files.entries) {
            final v = e.value;
            if (v is! Map) continue;
            final at = '${v['at'] ?? ''}'.trim();
            if (at.isEmpty) continue;
            recent.add(TicksUploadRecentDone(
              code: '${e.key}',
              machine: '${v['machine'] ?? ''}'.trim(),
              at: at,
            ));
          }
          recent.sort((a, b) => b.at.compareTo(a.at));
          if (recent.length > 10) recent.removeRange(10, recent.length);
        } else {
          shareNote = '状态文件结构异常：files 不是对象';
        }
        final sk = st['skipped'];
        if (sk is Map) skipped = sk.length;
      }

      // 3) 每台机器自己上报的进度与速率
      final statusDir = Directory('$text${Platform.pathSeparator}status');
      if (await statusDir.exists()) {
        await for (final ent in statusDir.list()) {
          if (ent is! File || !ent.path.toLowerCase().endsWith('.json')) {
            continue;
          }
          final obj = await _readJsonRetry(ent);
          if (obj == null) continue;
          final isLocal = '${obj['machine'] ?? ''}'.trim() ==
              Platform.localHostname;
          final m = _machineFromJson(obj, isLocal: isLocal);
          machines[m.machine] = m;
        }
      }

      // 4) 正在占用的股票（双机抢活时谁拿着哪只）
      final claims = Directory('$text${Platform.pathSeparator}claims');
      if (await claims.exists()) {
        await for (final ent in claims.list()) {
          if (ent is! File || !ent.path.toLowerCase().endsWith('.json')) {
            continue;
          }
          final obj = await _readJsonRetry(ent);
          if (obj == null) continue;
          final machine = '${obj['machine'] ?? ''}'.trim();
          final code = '${obj['code'] ?? ''}'.trim();
          if (machine.isEmpty) continue;
          final hb = _asDouble(obj['heartbeat_at']);
          final hbTime = hb == null || hb <= 0
              ? null
              : DateTime.fromMillisecondsSinceEpoch((hb * 1000).round());
          claimsByMachine[machine] = <String, dynamic>{
            'code': code,
            'heartbeat': hbTime,
          };
        }
      }
    }
  }

  // 5) 把 claims 合进来：正在传的代码以 claim 为准，速率缺省留空
  for (final entry in claimsByMachine.entries) {
    final machine = entry.key;
    final code = '${entry.value['code'] ?? ''}'.trim();
    final hbTime = entry.value['heartbeat'] as DateTime?;
    final old = machines[machine];
    if (old == null) {
      machines[machine] = TicksUploadMachineStatus(
        machine: machine,
        isLocal: machine == Platform.localHostname,
        alive: hbTime != null &&
            DateTime.now().difference(hbTime).inSeconds < 120,
        current: code,
        done: null,
        total: null,
        ratePerMin: null,
        pid: null,
        updatedAt: hbTime,
        heartbeatAt: hbTime,
        sessionDone: null,
      );
    } else if (code.isNotEmpty) {
      machines[machine] = TicksUploadMachineStatus(
        machine: old.machine,
        isLocal: old.isLocal,
        alive: old.alive || (hbTime != null &&
            DateTime.now().difference(hbTime).inSeconds < 120),
        current: code,
        done: old.done,
        total: old.total,
        ratePerMin: old.ratePerMin,
        pid: old.pid,
        updatedAt: old.updatedAt,
        heartbeatAt: hbTime ?? old.heartbeatAt,
        sessionDone: old.sessionDone,
      );
    }
  }

  // 本机那台补上存活标记（lock 在、进程在，但 status 没写全时也要算「在跑」）
  final localKey = Platform.localHostname;
  final localNow = machines[localKey];
  if (localNow != null && localAlive && !localNow.alive) {
    machines[localKey] = TicksUploadMachineStatus(
      machine: localNow.machine,
      isLocal: true,
      alive: true,
      current: localNow.current,
      done: localNow.done,
      total: localNow.total,
      ratePerMin: localNow.ratePerMin,
      pid: localNow.pid,
      updatedAt: localNow.updatedAt,
      heartbeatAt: localNow.heartbeatAt ?? DateTime.now(),
      sessionDone: localNow.sessionDone,
    );
  }

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

  int? total;
  for (final m in machines.values) {
    final t = m.total;
    if (t != null && t > 0 && (total == null || t > total)) total = t;
  }

  final list = machines.values.toList()
    ..sort((a, b) {
      if (a.isLocal != b.isLocal) return a.isLocal ? -1 : 1;
      if (a.alive != b.alive) return a.alive ? -1 : 1;
      return a.machine.compareTo(b.machine);
    });

  return TicksUploadSnapshot(
    taskRegistered: registered,
    supervisorAlive: localAlive,
    done: done.isEmpty ? null : doneValue,
    total: total,
    skipped: skipped,
    machines: list,
    recent: recent,
    logLine: logLine,
    shareNote: shareNote,
    shareOk: shareOk,
    sampledAt: DateTime.now(),
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
    final configured = widget.settings.shareDir.trim();
    final initial = configured.isEmpty ? defaultTicksShareDir() : configured;
    _shareCtrl = TextEditingController(text: initial);
    if (configured.isEmpty) {
      // 之前没填过：把默认目录落到设置里，两台机器从此指向同一个目录
      unawaited(widget.onShareDir(initial));
    }
    _reload();
    _timer = Timer.periodic(const Duration(seconds: 5), (_) => _reload());
  }

  @override
  void didUpdateWidget(covariant TicksFullUploadPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.settings.shareDir != widget.settings.shareDir &&
        _shareCtrl.text != widget.settings.shareDir &&
        widget.settings.shareDir.trim().isNotEmpty) {
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
      final share = _shareCtrl.text.trim().isEmpty
          ? defaultTicksShareDir()
          : _shareCtrl.text.trim();
      if (_shareCtrl.text.trim().isEmpty) {
        _shareCtrl.text = share;
      }
      await widget.onShareDir(share);
      final msg = await widget.onCreateTask(
        widget.settings.copyWith(shareDir: share),
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
          '1. 在常开的那台电脑上把进度文件夹共享成读写；本工程默认用 '
          r'\\192.168.1.5\chan_ticks_state\live（PCA 本机可直接用 '
          r'D:\chan_ticks_share\live）。'
          '\n2. 两台电脑填同一个共享进度目录；留空会自动填默认值。'
          '\n3. 先在「Telegram 数据源」里保存机器人令牌、聊天号和代理。'
          '\n4. 点「生成本机上传任务」。按钮上方会写出正在登记、成功，或失败原因。成功后本机会登记登录后自动跑的任务，并在任务栏托盘显示。'
          '\n5. 这里的进度块会逐项写明：总进度与百分比、两台各自的速率、每台正在传的代码与心跳、最近完成的股票、跳过统计、以及本机日志末行。'
          '\n6. 关闭主图时，可以选择让下载留在托盘里继续。',
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

  String _progressText(TicksUploadSnapshot snap) {
    final done = snap.done;
    final total = snap.total;
    if (done == null) return '进度：还没读到（${snap.shareNote}）';
    if (total == null || total <= 0) return '进度：已完成 $done 只（总数未知）';
    final pct = (done * 100 / total);
    final pctText = pct >= 100 ? '100%' : '${pct.toStringAsFixed(1)}%';
    return '进度：$done/$total（$pctText）· 跳过 ${snap.skipped}';
  }

  String _rateText(TicksUploadSnapshot snap) {
    final local = snap.local?.ratePerMin;
    final peerRates = snap.peers
        .where((m) => m.ratePerMin != null)
        .map((m) => '${m.machine} ${(m.ratePerMin!).toStringAsFixed(1)}')
        .toList();
    final parts = <String>[
      '本机 ${local == null ? '未上报' : local.toStringAsFixed(1)}',
      ...peerRates,
      '合计 ${snap.totalRate.toStringAsFixed(1)}/分',
    ];
    return '速率：${parts.join(' · ')}';
  }

  List<String> _machineLines(TicksUploadSnapshot snap) {
    if (snap.machines.isEmpty) return const ['（还没有任何机器上报进度）'];
    final out = <String>[];
    for (final m in snap.machines) {
      out.add(
        '${m.alive ? '●' : '○'} ${m.label}  ${m.stateText}  上报 ${m.ageText}',
      );
      final bits = <String>[
        if (m.current.isNotEmpty) '传 ${m.current}',
        if (m.sessionDone != null) '本轮 +${m.sessionDone}',
        if (m.ratePerMin != null) '${m.ratePerMin!.toStringAsFixed(1)}/分',
      ];
      out.add('    ${bits.isEmpty ? '暂无明细（等它上报）' : bits.join(' · ')}');
    }
    return out;
  }

  List<String> _recentLines(TicksUploadSnapshot snap) {
    if (snap.recent.isEmpty) {
      return const ['（状态文件里还没有「完成时间」，跑完下一只就会出现）'];
    }
    return [
      for (final r in snap.recent)
        '${r.at.substring(r.at.length > 8 ? r.at.length - 8 : 0)}  '
            '${r.code}  ${r.machine.isEmpty ? '机器未记录' : r.machine}',
    ];
  }

  Widget _logBox(TicksUploadSnapshot snap) {
    final lines = <String>[
      '${snap.headline}（${snap.runningCount} 台在跑）',
      _progressText(snap),
      _rateText(snap),
      '── 机器 ──',
      ..._machineLines(snap),
      '── 最近完成 ──',
      ..._recentLines(snap),
      '── 共享目录 ──',
      '${snap.shareOk ? '可读' : '不可读'}　${snap.shareNote}',
      if (snap.logLine.isNotEmpty) '── 本机日志 ──',
      if (snap.logLine.isNotEmpty) snap.logLine,
    ];
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF0B1220),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF1E293B)),
      ),
      child: SelectableText(
        lines.join('\n'),
        style: const TextStyle(
          fontSize: 12,
          height: 1.45,
          color: Color(0xFFCBD5E1),
          fontFamily: 'Consolas',
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final snap = _snap;
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
              final share = v.trim().isEmpty ? defaultTicksShareDir() : v.trim();
              if (v.trim().isEmpty) _shareCtrl.text = share;
              await widget.onShareDir(share);
              await _reload();
            }();
          },
        ),
        if (_shareCtrl.text.trim().isEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              '留空会用默认：$kTicksShareDirUnc',
              style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
            ),
          ),
        const SizedBox(height: 6),
        if (snap == null)
          const Text(
            '进度读取中…',
            style: TextStyle(fontSize: 12, color: Color(0xFFCBD5E1)),
          )
        else
          _logBox(snap),
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
