import 'dart:async';
import 'dart:convert';
import 'dart:io';

/// 双机同步的编排层：只负责「跑脚本 + 把输出逐行交给界面」，口径全在脚本里。
///
/// 为什么不在 Dart 里重写一遍 robocopy / 占用探测 / 指纹校验：
/// `CHAN_RUST/scripts/sync_to_remote.ps1` 已经在真机跑通过，白名单、让路、
/// BOM 重编码、指纹判据都在那儿；两套实现早晚会漂移。
abstract final class PeerSyncService {
  static String? _repoRootCache;

  /// 仓库根：`CHAN_REPO_ROOT` > `CHAN_DATA_ROOT` 的父目录 > 从当前目录向上找。
  static String get repoRoot {
    if (_repoRootCache != null) return _repoRootCache!;
    final env = Platform.environment['CHAN_REPO_ROOT']?.trim() ?? '';
    if (env.isNotEmpty && Directory(env).existsSync()) {
      return _repoRootCache = env;
    }
    final dataEnv = Platform.environment['CHAN_DATA_ROOT']?.trim() ?? '';
    if (dataEnv.isNotEmpty) {
      final p = Directory(dataEnv).parent.path;
      if (p.isNotEmpty && p != dataEnv) return _repoRootCache = p;
    }
    var dir = Directory.current;
    for (var i = 0; i < 12; i++) {
      final sep = Platform.pathSeparator;
      final hasRust = Directory('${dir.path}${sep}CHAN_RUST').existsSync();
      final hasData = Directory('${dir.path}${sep}a_Data').existsSync();
      if (hasRust && hasData) return _repoRootCache = dir.path;
      final parent = dir.parent;
      if (parent.path == dir.path) break;
      dir = parent;
    }
    return _repoRootCache = Directory.current.path;
  }

  static String get _sep => Platform.pathSeparator;
  static String get scriptsDir => '$repoRoot${_sep}CHAN_RUST${_sep}scripts';
  static String get syncScript => '$scriptsDir${_sep}sync_to_remote.ps1';
  static String get latestScript => '$scriptsDir${_sep}sync_latest.ps1';
  static String get ctlScript => '$scriptsDir${_sep}remote_ctl.ps1';
  static String get restoreScript => '$scriptsDir${_sep}sync_restore.ps1';

  static bool get scriptsReady => File(syncScript).existsSync();

  /// 本机主机名（决定默认对端填哪条路径）。
  static String get hostName => Platform.localHostname;

  /// 本机是 PCA 就默认指向 PCB，反之指向 PCA；认不出来就留空让用户填。
  static String defaultPeerPath() {
    final h = hostName.toLowerCase();
    if (h == 'laptop-na22ifpu') return r'\\192.168.1.6\D$\2\chan_month5';
    if (h == 'cxy') return r'\\192.168.1.5\chan_month5';
    return '';
  }

  static String get selfLabel => hostName.toLowerCase() == 'cxy' ? 'PCB' : 'PCA';

  static String _psExe() {
    for (final c in [
      r'C:\Program Files\PowerShell\7\pwsh.exe',
      r'C:\Program Files\PowerShell\7-preview\pwsh.exe',
    ]) {
      if (File(c).existsSync()) return c;
    }
    return 'powershell.exe'; // 5.1 兜底：脚本本身是 UTF-8 BOM，且末尾会强制 UTF-8 输出
  }

  /// 跑脚本并把 stdout 逐行回调出去；结尾 `===JSON=== {...} ===END===` 会被解析出来。
  static Future<PeerSyncOutcome> runScript({
    required String script,
    required List<String> args,
    void Function(String line)? onLine,
    Duration timeout = const Duration(minutes: 20),
  }) async {
    if (!File(script).existsSync()) {
      return PeerSyncOutcome(ok: false, error: '找不到脚本：$script');
    }
    Process? proc;
    try {
      proc = await Process.start(
        _psExe(),
        [
          '-NoProfile',
          '-ExecutionPolicy',
          'Bypass',
          '-File',
          script,
          ...args,
        ],
        runInShell: false,
      );
    } catch (e) {
      return PeerSyncOutcome(ok: false, error: '启动 PowerShell 失败：$e');
    }

    final stderrBuf = StringBuffer();
    final stderrSub = proc.stderr
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())
        .listen(stderrBuf.write);

    final jsonLines = <String>[];
    final allLines = <String>[];
    var inJson = false;
    String? jsonText;

    await for (final raw in proc.stdout
        .transform(const Utf8Decoder(allowMalformed: true))
        .transform(const LineSplitter())) {
      final line = raw.trimRight();
      if (line.trim() == '===JSON===') {
        inJson = true;
        jsonLines.clear();
        continue;
      }
      if (line.trim() == '===END===') {
        inJson = false;
        jsonText = jsonLines.join('\n');
        continue;
      }
      if (inJson) {
        jsonLines.add(line);
        continue;
      }
      allLines.add(line);
      onLine?.call(line);
    }

    int code;
    try {
      code = await proc.exitCode.timeout(timeout);
    } on TimeoutException {
      proc.kill();
      await stderrSub.cancel();
      return PeerSyncOutcome(ok: false, error: '脚本超时（${timeout.inMinutes} 分钟）已终止');
    }
    await stderrSub.cancel();
    final errText = stderrBuf.toString().trim();
    if (errText.isNotEmpty) {
      for (final l in const LineSplitter().convert(errText)) {
        onLine?.call('[stderr] $l');
      }
    }

    Map<String, dynamic>? json;
    if (jsonText != null && jsonText.trim().isNotEmpty) {
      try {
        final obj = jsonDecode(jsonText);
        if (obj is Map) json = Map<String, dynamic>.from(obj);
      } catch (_) {}
    }
    // 兜底：remote_ctl -Json 这类脚本直接吐一整段 JSON（没有 ===JSON=== 标记），
    // 这里从整段 stdout 里抠出来解析，免得界面只剩一句「对端已执行」。
    if (json == null) {
      final whole = allLines.join('\n').trim();
      if (whole.startsWith('{') && whole.endsWith('}')) {
        try {
          final obj = jsonDecode(whole);
          if (obj is Map) json = Map<String, dynamic>.from(obj);
        } catch (_) {}
      }
    }

    // 脚本自己写在 JSON 里的 ok 优先：退出码 7 = 同步成了、只是编译没出成品，
    // 那种情况不该把整轮报成失败（界面另有一行黄色提示）。
    final okFlag = json != null ? (json['ok'] == true) : (code == 0);
    final err = json != null
        ? ((json['error'] as String?) ?? '').trim()
        : (errText.isNotEmpty ? errText : '脚本退出码 $code');
    return PeerSyncOutcome(
      ok: okFlag,
      exitCode: code,
      json: json,
      error: err,
      rawError: errText,
    );
  }

  /// 判「哪台更新」并列出差异清单（不动任何文件）。
  ///
  /// `sync_latest.ps1` 的口径：逐文件比修改时间与内容，判定以哪一侧为准，
  /// 返回 direction = local-to-peer / peer-to-local / same。
  static Future<PeerSyncOutcome> latestPlan({required String peer}) {
    return runScript(
      script: latestScript,
      args: ['-PeerPath', peer, '-Json'],
      timeout: const Duration(minutes: 10),
    );
  }

  /// 按「最新一方」真同步：把旧的一侧对齐到新的一侧（方向由 plan 给出）。
  ///
  /// direction 取 plan 返回的 `direction`；'auto' 表示让脚本再判一次。
  /// build=true 时，同步完自动编译「刚被对齐的那一侧」（cargo 编 chan_ffi.dll →
  /// flutter build --debug → 重启那台的 App），本机就直接编，对端就走远端代理。
  static Future<PeerSyncOutcome> latestSync({
    required String peer,
    String direction = 'auto',
    bool build = true,
    void Function(String line)? onLine,
  }) {
    final d = switch (direction) {
      'local-to-peer' => 'toPeer',
      'peer-to-local' => 'toLocal',
      _ => 'auto',
    };
    return runScript(
      script: latestScript,
      args: [
        '-PeerPath',
        peer,
        '-Apply',
        '-Json',
        '-Direction',
        d,
        if (build) '-Build',
      ],
      onLine: onLine,
      timeout: const Duration(minutes: 40),
    );
  }

  /// 只算差异（不动任何文件），给确认弹窗用。
  static Future<PeerSyncOutcome> diff({
    required String peer,
    String include = 'all',
  }) {
    return runScript(
      script: syncScript,
      args: ['-SharePath', peer, '-DiffOnly', '-Json', '-Include', include],
      timeout: const Duration(minutes: 5),
    );
  }

  /// 真同步：备份被覆盖文件 + 关对端 App（必要时）+ 推 + 校验 + 重拉。
  static Future<PeerSyncOutcome> sync({
    required String peer,
    bool backup = true,
    bool restartPeerApp = true,
    String include = 'all',
    void Function(String line)? onLine,
  }) {
    return runScript(
      script: syncScript,
      args: [
        '-SharePath',
        peer,
        '-Apply',
        '-Json',
        '-Include',
        include,
        if (backup) '-Backup',
        if (restartPeerApp) '-RestartRemoteApp',
      ],
      onLine: onLine,
    );
  }

  /// 测试连接：共享可达 / 对端代理在不在 / 对端 App 是否占着产物。
  static Future<String> testConnection({required String peer}) async {
    final buf = StringBuffer();
    if (peer.trim().isEmpty) return '对端路径为空：先在输入框填对端共享路径（主机名 + 共享名）';
    final reachable = Directory(peer).existsSync();
    final reachText = reachable ? '可达' : '不可达';
    buf.writeln('共享：$reachText（$peer）');
    if (!reachable) {
      buf.writeln('→ 对端没开共享或路径写错；跨机器访问管理共享需要凭据，建议走专属共享。');
      return buf.toString().trimRight();
    }
    final ping = await runScript(
      script: ctlScript,
      args: ['-SharePath', peer, '-Action', 'ping', '-Json', '-TimeoutSec', '20'],
      timeout: const Duration(seconds: 40),
    );
    buf.writeln('对端代理：${ping.ok ? '在线' : '未响应'}');
    if (ping.ok && ping.json != null) {
      final v = ping.json!['agent_version'];
      final rid = ping.json!['session_id'];
      if (v != null) buf.write('  版本 $v');
      if (rid != null) buf.write('  session=$rid');
      buf.writeln();
    }
    final d = await diff(peer: peer, include: 'all');
    if (d.json != null) {
      buf.writeln(
          '差异：新增 ${d.json!['new']} / 覆盖 ${d.json!['overwrite']} / 相同 ${d.json!['same']} / 对端独有 ${d.json!['onlyInPeer']}');
      buf.writeln('对端 App 是否占着产物：${d.json!['peerAppWasLocked'] == true ? '是（同步时会自动关它）' : '否'}');
    } else if (!d.ok) {
      buf.writeln('差异统计失败：${d.error}');
    }
    return buf.toString().trimRight();
  }

  /// 按对端最近一份快照回退。
  static Future<PeerSyncOutcome> restore({
    required String peer,
    String stamp = '',
    void Function(String line)? onLine,
  }) {
    return runScript(
      script: restoreScript,
      args: ['-SharePath', peer, '-Json', if (stamp.isNotEmpty) '-Stamp', stamp],
      onLine: onLine,
    );
  }

  /// 拉起 / 关闭对端的 App（走对端常驻代理；代理不在线时明确报未响应）。
  static Future<PeerSyncOutcome> peerApp({required String peer, bool launch = true}) {
    return runScript(
      script: ctlScript,
      args: [
        '-SharePath',
        peer,
        '-Action',
        launch ? 'start' : 'stop',
        if (launch) ...['-Mode', 'ui'],
        '-Json',
        '-TimeoutSec',
        launch ? '120' : '30',
      ],
      timeout: Duration(seconds: launch ? 150 : 45),
    );
  }

  /// 拉起 / 停 / 查对端的「全市场分笔上传」。
  ///
  /// 对端代理只放行 `Chan\TicksFullUpload` 这一个计划任务名（它不是任意执行入口），
  /// 所以这里传的任务名是固定值，界面上没有可编辑的地方。
  static Future<PeerSyncOutcome> peerUpload({
    required String peer,
    String op = 'run',
  }) {
    return runScript(
      script: ctlScript,
      args: [
        '-SharePath',
        peer,
        '-Action',
        'task',
        '-TaskName',
        r'Chan\TicksFullUpload',
        '-TaskOp',
        op,
        '-Json',
      ],
      timeout: const Duration(seconds: 90),
    );
  }

  /// 设置面板那行「上次同步」用的文字（单行展示，过长截断，细则进对话框看）。
  static String lastSyncLine(String lastSyncAt, bool ok, String summary) {
    if (lastSyncAt.trim().isEmpty) return '上次同步：还没有记录';
    var s = summary.trim();
    if (s.length > 40) s = '${s.substring(0, 40)}…';
    final tail = s.isEmpty ? '' : '（$s）';
    return '上次同步：$lastSyncAt ${ok ? '成功' : '失败'}$tail';
  }

  /// 「以最新一侧为准」的结果摘要（单行）。
  static String latestSummaryLine(PeerSyncOutcome out) {
    final j = out.json;
    if (j == null) return out.ok ? '完成' : (out.error.isEmpty ? '失败' : out.error);
    final dir = (j['direction'] as String?) ?? '';
    final newer = (j['newerSide'] as String?) ?? '';
    if (dir == 'same') return '两台已经一致';
    if (!out.ok) {
      final e = (j['error'] as String?)?.trim() ?? '';
      final left = (j['verifyLeft'] as num?)?.toInt() ?? 0;
      if (e.isNotEmpty) return e;
      return left > 0 ? '仍有 $left 处差异' : '失败（退出码 ${out.exitCode}）';
    }
    final copied = (j['copied'] as num?)?.toInt() ?? 0;
    final moved = (j['movedAside'] as num?)?.toInt() ?? 0;
    final left = (j['verifyLeft'] as num?)?.toInt() ?? 0;
    final buildOk = j['buildOk'];
    final buildSide = (j['buildSide'] as String?) ?? '';
    final buildSec = (j['buildSec'] as num?)?.toInt() ?? 0;
    final buildNote = (j['buildNote'] as String?)?.trim() ?? '';
    final buildPart = buildOk == true && buildSide.isNotEmpty
        ? '已重编${buildSide == 'local' ? '本机' : '对端'}并重启 App'
            '${buildSec > 0 ? '（$buildSec 秒）' : ''}'
        : buildOk == false
            ? '重编没成功'
            : buildNote;
    final parts = <String>[
      '以 $newer 为准',
      '对齐 $copied 个文件',
      if (moved > 0) '移出 $moved 个到备份',
      if (left > 0) '仍有 $left 处差异' else '复核一致',
      if (buildPart.isNotEmpty) buildPart,
    ];
    return parts.join('，');
  }

  /// 方向的自然语言说明（给确认弹窗用）。
  static String directionText(String newerSide) =>
      newerSide == '本机' ? '本机 → 对端' : '对端 → 本机';
}

class PeerSyncOutcome {
  const PeerSyncOutcome({
    required this.ok,
    this.exitCode = -1,
    this.json,
    this.error = '',
    this.rawError = '',
  });

  final bool ok;
  final int exitCode;
  final Map<String, dynamic>? json;
  final String error;
  final String rawError;

  String get summaryLine {
    final j = json;
    if (j == null) return ok ? '完成' : (error.isEmpty ? '失败' : error);
    final added = j['new'];
    final over = j['overwrite'];
    final stopped = j['peerAppStopped'] == true;
    final restarted = j['peerAppRestarted'] == true;
    final hashes = (j['hashes'] as List?) ?? const [];
    final hashOk = hashes.isNotEmpty && hashes.every((h) => (h as Map)['ok'] == true);
    if (!ok) {
      final e = (j['error'] as String?)?.trim() ?? '';
      return e.isEmpty ? '失败（退出码 $exitCode）' : e;
    }
    final parts = <String>[
      '新增 $added / 覆盖 $over',
      if (hashOk) '指纹一致',
      if (stopped) '关了对方 App',
      if (restarted) '已把对方 App 拉回',
      if (j['backupFiles'] != null && (j['backupFiles'] as num).toInt() > 0)
        '快照 ${j['backupFiles']} 个文件',
    ];
    return parts.join('，');
  }
}
