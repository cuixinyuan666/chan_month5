/// @file lib/agent_api/agent_data_export_runner.dart
/// @brief 通过 Agent API 启动 Rust 全市场数据导出子进程（日线/分笔），
/// 状态供 GET /export_task 与 /state.tasks 查询；异常写入任务 error 字段。
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../robot_verify/robot_verify_paths.dart';

/// 单条导出任务（子进程 + 日志 + manifest 摘要）。
class AgentExportTask {
  AgentExportTask({
    required this.id,
    required this.kind,
    required this.startedAt,
    required this.logPath,
    required this.outDir,
  });

  final String id;

  /// `ticks` | `daily`。
  final String kind;
  final DateTime startedAt;
  final String logPath;
  final String outDir;

  Process? process;
  DateTime? finishedAt;
  String phase = 'running';
  String detail = '启动中…';
  double? fraction;
  int done = 0;
  int total = 0;
  String? error;
  Map<String, dynamic>? summary;

  bool get running => phase == 'running';

  Duration get elapsed => (finishedAt ?? DateTime.now()).difference(startedAt);

  Map<String, dynamic> toJson() => {
        'task_id': id,
        'kind': kind,
        'phase': phase,
        'running': running,
        'detail': detail,
        'fraction': fraction,
        'done': done,
        'total': total,
        'elapsed_seconds': elapsed.inSeconds,
        'log_path': logPath,
        'out_dir': outDir,
        if (error != null) 'error': error,
        if (summary != null) 'summary': summary,
      };
}

/// 全局导出任务管理（单 App 进程内）。
class AgentDataExportRunner {
  AgentDataExportRunner._();

  static final AgentDataExportRunner instance = AgentDataExportRunner._();

  int _seq = 0;
  final Map<String, AgentExportTask> _tasks = {};

  List<Map<String, dynamic>> listTasksJson() => _tasks.values
      .map((t) => t.toJson())
      .toList()
    ..sort((a, b) => (b['elapsed_seconds'] as int? ?? 0)
        .compareTo(a['elapsed_seconds'] as int? ?? 0));

  AgentExportTask? task(String id) => _tasks[id];

  bool cancel(String taskId) {
    final t = _tasks[taskId];
    if (t == null || !t.running) return false;
    t.process?.kill(ProcessSignal.sigterm);
    t.phase = 'cancelled';
    t.finishedAt = DateTime.now();
    t.detail = '已取消';
    return true;
  }

  /// 启动「每日分笔增量更新」Python 脚本（手动/自动共用）。
  Future<AgentExportTask> startTicksDaily({String? date, int limit = 0}) async {
    final repo = RobotVerifyPaths.resolveRepoRoot(klineRoot: null);
    if (repo == null || repo.isEmpty) throw StateError('无法解析仓库根目录');
    final script = File(
      '$repo${Platform.pathSeparator}CHAN_RUST${Platform.pathSeparator}scripts'
      '${Platform.pathSeparator}update_ticks_daily.py',
    );
    if (!script.existsSync()) {
      throw StateError('找不到脚本：${script.path}');
    }
    final liveDir = Directory(
      '$repo${Platform.pathSeparator}a_Data${Platform.pathSeparator}agent_live',
    );
    if (!liveDir.existsSync()) liveDir.createSync(recursive: true);

    final id = 'daily_ticks_${++_seq}';
    final logPath = '${liveDir.path}${Platform.pathSeparator}export_$id.log';
    final task = AgentExportTask(
      id: id,
      kind: 'ticks_daily',
      startedAt: DateTime.now(),
      logPath: logPath,
      outDir: '$repo${Platform.pathSeparator}exports',
    );
    _tasks[id] = task;

    final args = <String>[script.path];
    if (date != null && date.trim().isNotEmpty) {
      args.addAll(['--date', date.trim()]);
    }
    if (limit > 0) {
      args.addAll(['--limit', '$limit']);
    }
    task.detail = '分笔日更启动：${args.join(' ')}';
    final logFile = File(logPath);
    final sink = logFile.openWrite(mode: FileMode.write);
    sink.writeln('# ticks daily ${DateTime.now()}');

    final proc = await Process.start(
      'python',
      args,
      workingDirectory: '$repo${Platform.pathSeparator}CHAN_RUST'
          '${Platform.pathSeparator}scripts',
      runInShell: false,
    );
    task.process = proc;
    proc.stdout.listen((d) {
      sink.write(utf8.decode(d, allowMalformed: true));
    });
    proc.stderr.listen((d) {
      sink.write(utf8.decode(d, allowMalformed: true));
    });
    unawaited(proc.exitCode.then((code) async {
      await sink.flush();
      await sink.close();
      task.finishedAt = DateTime.now();
      if (task.phase == 'cancelled') return;
      if (code != 0) {
        task.phase = 'failed';
        task.error = '退出码 $code（详见 log_path）';
        task.detail = task.error!;
        return;
      }
      task.phase = 'done';
      task.detail = '分笔日更完成';
      task.fraction = 1.0;
    }));
    return task;
  }

  /// 启动导出。 [kind] = ticks | daily。
  Future<AgentExportTask> start({
    required String kind,
    String? codes,
    String? begin,
    String? end,
    int threads = 12,
    String? outDir,
    String? cacheRoot,
  }) async {
    final repo = RobotVerifyPaths.resolveRepoRoot(klineRoot: null);
    if (repo == null || repo.isEmpty) {
      throw StateError('无法解析仓库根目录');
    }
    final exeName = kind == 'daily'
        ? 'export_all_a_shares.exe'
        : 'export_all_ticks.exe';
    final exe = File(
      '$repo${Platform.pathSeparator}CHAN_RUST${Platform.pathSeparator}rust'
      '${Platform.pathSeparator}target${Platform.pathSeparator}release'
      '${Platform.pathSeparator}examples${Platform.pathSeparator}$exeName',
    );
    if (!exe.existsSync()) {
      throw StateError(
        '找不到导出程序：${exe.path}\n'
        '请先在 CHAN_RUST/rust 下执行：\n'
        '  cargo build --release -p chan_data --example ${kind == 'daily' ? 'export_all_a_shares' : 'export_all_ticks'}',
      );
    }

    final defaultOut = kind == 'daily'
        ? '$repo${Platform.pathSeparator}exports${Platform.pathSeparator}a_shares_daily'
        : '$repo${Platform.pathSeparator}exports${Platform.pathSeparator}a_shares_ticks';
    final out = outDir ?? defaultOut;
    Directory(out).createSync(recursive: true);

    final liveDir = Directory(
      '$repo${Platform.pathSeparator}a_Data${Platform.pathSeparator}agent_live',
    );
    if (!liveDir.existsSync()) liveDir.createSync(recursive: true);

    final id = 'export_${kind}_${++_seq}';
    final logPath =
        '${liveDir.path}${Platform.pathSeparator}export_${id}.log';
    final task = AgentExportTask(
      id: id,
      kind: kind,
      startedAt: DateTime.now(),
      logPath: logPath,
      outDir: out,
    );
    _tasks[id] = task;
    while (_tasks.length > 10) {
      final finished =
          _tasks.values.where((t) => !t.running).toList()
            ..sort((a, b) => a.startedAt.compareTo(b.startedAt));
      if (finished.isEmpty) break;
      _tasks.remove(finished.first.id);
    }

    final args = <String>[
      '--threads',
      '$threads',
      '--out',
      out,
    ];
    if (codes != null && codes.trim().isNotEmpty) {
      args.addAll(['--codes', codes.trim()]);
    }
    if (kind == 'ticks') {
      if (begin != null && begin.trim().isNotEmpty) {
        args.addAll(['--begin', begin.trim()]);
      }
      if (end != null && end.trim().isNotEmpty) {
        args.addAll(['--end', end.trim()]);
      }
      if (cacheRoot != null && cacheRoot.trim().isNotEmpty) {
        args.addAll(['--cache-root', cacheRoot.trim()]);
      }
    }

    final rustDir =
        '$repo${Platform.pathSeparator}CHAN_RUST${Platform.pathSeparator}rust';
    task.detail = '子进程启动：${exe.path}';

    final logFile = File(logPath);
    final sink = logFile.openWrite(mode: FileMode.write);
    sink.writeln('# export $kind $id');
    sink.writeln('# cmd: ${exe.path} ${args.join(' ')}');
    await sink.flush();

    final proc = await Process.start(
      exe.path,
      args,
      workingDirectory: rustDir,
      runInShell: false,
    );
    task.process = proc;

    proc.stdout.listen((data) {
      final text = utf8.decode(data, allowMalformed: true);
      sink.write(text);
      _parseProgress(task, text);
    });
    proc.stderr.listen((data) {
      final text = utf8.decode(data, allowMalformed: true);
      sink.write(text);
      _parseProgress(task, text);
    });

    unawaited(proc.exitCode.then((code) async {
      await sink.flush();
      await sink.close();
      task.finishedAt = DateTime.now();
      if (task.phase == 'cancelled') return;
      if (code != 0) {
        task.phase = 'failed';
        task.error = '退出码 $code（详见 log_path）';
        task.detail = task.error!;
        final tail = await _tailLog(logPath, 2000);
        if (tail.isNotEmpty) task.error = '$code: $tail';
        return;
      }
      task.phase = 'done';
      task.detail = '完成';
      task.fraction = 1.0;
      task.summary = await _readManifest(out);
      if (task.summary == null) {
        task.error = '未找到 manifest.json';
      }
    }));

    return task;
  }

  static void _parseProgress(AgentExportTask task, String chunk) {
    // Rust 导出器打印：进度 120/5225（…）
    final re = RegExp(r'进度\s+(\d+)\/(\d+)');
    for (final m in re.allMatches(chunk)) {
      task.done = int.tryParse(m.group(1) ?? '') ?? task.done;
      task.total = int.tryParse(m.group(2) ?? '') ?? task.total;
      if (task.total > 0) {
        task.fraction = task.done / task.total;
      }
      task.detail = '进度 ${task.done}/${task.total}';
    }
  }

  static Future<String> _tailLog(String path, int maxChars) async {
    final f = File(path);
    if (!f.existsSync()) return '';
    final text = await f.readAsString();
    if (text.length <= maxChars) return text.trim();
    return text.substring(text.length - maxChars).trim();
  }

  static Future<Map<String, dynamic>?> _readManifest(String outDir) async {
    final f = File(
      '$outDir${Platform.pathSeparator}manifest.json',
    );
    if (!f.existsSync()) return null;
    try {
      final j = jsonDecode(await f.readAsString());
      if (j is Map<String, dynamic>) return j;
      if (j is Map) return Map<String, dynamic>.from(j);
    } catch (_) {}
    return null;
  }
}
