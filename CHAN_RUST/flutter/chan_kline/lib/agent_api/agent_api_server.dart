/// @file lib/agent_api/agent_api_server.dart
/// @brief 本地 Agent API：HTTP 服务器（127.0.0.1）+ 文件轮询（备选）。
/// 纯 Dart，无新依赖；不改 Rust、不改 FFI、不改缠论计算逻辑。
/// 默认关闭；CHAN_AGENT_API=1 时启用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../agent_api/agent_api_host.dart';
import '../robot_verify/robot_verify_paths.dart';
import '../robot_verify/robot_verify_runner.dart';

/// Agent API 端口（固定，agent 约定）。
const int _agentApiPort = 12321;

/// 令牌文件（启动时写入，agent 请求需带 `X-Agent-Token`）。
const String _tokenFileName = 'agent_api_token.txt';

/// 文件轮询目录（a_Data/agent_live/）。
/// agent 写 command.json，App 读取执行并写回 state.json / result.json。
const String _liveDirName = 'agent_live';
const String _stateFileName = 'state.json';
const String _commandFileName = 'command.json';
const String _resultFileName = 'result.json';

/// Agent API 服务器：持有 HttpServer 与文件轮询定时器。
class AgentApiServer {
  AgentApiServer._({
    required this.host,
    required this.token,
    required this.startedAt,
    required this.appVersion,
  });

  final AgentApiHost host;
  final String token;
  final DateTime startedAt;
  final String appVersion;

  HttpServer? _httpServer;
  Timer? _pollTimer;
  Directory? _liveDir;
  File? _stateFile;
  File? _commandFile;
  File? _resultFile;
  DateTime _commandMtime = DateTime.fromMillisecondsSinceEpoch(0);

  static final Random _secureRandom = Random.secure();

  /// 启动（仅在 agent 模式下调用）。
  static Future<AgentApiServer> start({
    required AgentApiHost host,
    required DateTime startedAt,
    required String appVersion,
  }) async {
    // 1) 令牌：随机，写入本地文件。
    final token = _generateToken();
    final repoRoot = RobotVerifyPaths.resolveRepoRoot(klineRoot: null);
    final liveDir = Directory(
      '${repoRoot ?? Directory.current.path}${Platform.pathSeparator}a_Data${Platform.pathSeparator}$_liveDirName',
    );
    if (!liveDir.existsSync()) liveDir.createSync(recursive: true);
    final tokenFile = File('${liveDir.path}${Platform.pathSeparator}$_tokenFileName');
    await tokenFile.writeAsString(token, flush: true);

    // 2) HTTP 服务器：只绑 127.0.0.1。
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      _agentApiPort,
    );

    final instance = AgentApiServer._(
      host: host,
      token: token,
      startedAt: startedAt,
      appVersion: appVersion,
    )
      .._httpServer = server
      .._liveDir = liveDir
      .._stateFile = File('${liveDir.path}${Platform.pathSeparator}$_stateFileName')
      .._commandFile = File('${liveDir.path}${Platform.pathSeparator}$_commandFileName')
      .._resultFile = File('${liveDir.path}${Platform.pathSeparator}$_resultFileName');

    // 3) HTTP 请求循环。
    unawaited(instance._serveLoop(server, instance));

    // 4) 文件轮询（备选，无 HTTP 客户端的 agent 可用）。
    instance._startFilePoller();

    // 5) 启动即写一次 state.json，方便文件轮询的 agent 立刻有读数。
    instance._writeState();

    return instance;
  }

  /// 停止。
  Future<void> stop() async {
    _pollTimer?.cancel();
    await _httpServer?.close(force: true);
    _httpServer = null;
  }

  /// 生成随机令牌。
  static String _generateToken() {
    final bytes = List<int>.generate(16, (_) => _secureRandom.nextInt(256));
    return base64Url.encode(bytes);
  }

  /// HTTP 请求循环。
  Future<void> _serveLoop(HttpServer server, AgentApiServer self) async {
    await for (final req in server) {
      try {
        final ok = _checkAuth(req);
        if (!ok) {
          req.response
            ..statusCode = HttpStatus.unauthorized
            ..write('unauthorized')
            ..close();
          continue;
        }

        final path = req.uri.path;
        final method = req.method;

        if (method == 'GET' && path == '/health') {
          await _respond(req, _healthJson(self));
        } else if (method == 'GET' && path == '/state') {
          await _respond(req, _stateJson(self.host));
        } else if (method == 'GET' && path == '/snapshot') {
          await _respond(req, _snapshotJson(self.host));
        } else if (method == 'GET' && path.startsWith('/tooltip')) {
          final idx = int.tryParse(req.uri.queryParameters['idx'] ?? '');
          if (idx == null) {
            await _errorJson(req, 'missing idx');
          } else {
            await _respond(req, _tooltipJson(self.host, idx));
          }
        } else if (method == 'GET' && path == '/screenshot') {
          await _screenshotJson(req, self);
        } else if (method == 'POST' && path == '/command') {
          await _commandPost(req, self);
        } else if (method == 'GET' && path == '/') {
          await _respond(req, {'ok': true, 'service': 'chan_kline_agent_api'});
        } else {
          req.response
            ..statusCode = HttpStatus.notFound
            ..write('not found')
            ..close();
        }
      } catch (e, st) {
        try {
          await _errorJson(req, '$e\n$st');
        } catch (_) {}
      }
    }
  }

  bool _checkAuth(HttpRequest req) {
    final header = req.headers.value('x-agent-token');
    return header == token;
  }

  Future<void> _respond(HttpRequest req, Object body) async {
    final text = body is String ? body : agentJsonEncode(body);
    req.response
      ..headers.contentType = ContentType.json
      ..write(text)
      ..close();
  }

  Future<void> _errorJson(HttpRequest req, String message) async {
    req.response
      ..statusCode = HttpStatus.internalServerError
      ..headers.contentType = ContentType.json
      ..write(agentJsonEncode({'ok': false, 'message': message}))
      ..close();
  }

  /// ---------------- JSON 构建 ----------------

  Map<String, dynamic> _healthJson(AgentApiServer self) {
    final h = self.host.health();
    return {
      'ok': true,
      'app_version': h.appVersion,
      'ffi_abi_version': h.ffiAbiVersion,
      'pid': h.pid,
      'data_root': h.dataRoot,
      'uptime_seconds': h.uptime.inSeconds,
      'token_file': '${_liveDir?.path}${Platform.pathSeparator}$_tokenFileName',
    };
  }

  Map<String, dynamic> _stateJson(AgentApiHost host) {
    return {
      'ok': true,
      'code': host.selectedCode,
      'period': host.period,
      'period_label': host.periodLabel,
      'step_idx': host.stepIdx,
      'total_bars': host.totalBars,
      'is_playing': host.isPlaying,
      'main_indicators': host.mainIndicators.map((e) => e.label).toList(),
      'sub_indicators': host.subIndicators.map((e) => e.label).toList(),
      'chip_config': {
        'enabled': host.chipConfig.enabled,
        'bucket_step': host.chipConfig.bucketStep,
      },
      'tick_dist_config': {
        'enabled': host.tickDistConfig.enabled,
        'bucket_step': host.tickDistConfig.bucketStep,
      },
      'truncation_check': host.truncationCheck,
    };
  }

  Map<String, dynamic> _snapshotJson(AgentApiHost host) {
    final snap = host.snapshot();
    return {'ok': true, ...snap.toJson()};
  }

  Map<String, dynamic> _tooltipJson(AgentApiHost host, int idx) {
    final rows = host.tooltipRowsAt(idx);
    return {
      'ok': true,
      'idx': idx,
      'rows': rows.map((e) => e.toJson()).toList(),
    };
  }

  Future<void> _screenshotJson(HttpRequest req, AgentApiServer self) async {
    // 截图由主界面通过 AgentApiServer.bindScreenshot 注入回调。
    final cb = _screenshotCallback;
    if (cb == null) {
      await _errorJson(req, 'screenshot not bound');
      return;
    }
    try {
      final bytes = await cb();
      req.response
        ..headers.contentType = ContentType('image', 'png')
        ..add(bytes)
        ..close();
    } catch (e) {
      await _errorJson(req, '$e');
    }
  }

  Future<void> _commandPost(HttpRequest req, AgentApiServer self) async {
    final body = await utf8.decoder.bind(req).join();
    final json = agentJsonDecode(body);
    if (json == null) {
      await _errorJson(req, 'invalid json');
      return;
    }
    final cmd = AgentCommand.fromJson(json);
    final result = _executeCommand(cmd, self.host);
    final data = await result;
    // 命令可能异步改变界面状态：执行后刷新 state.json（文件轮询通道可见）。
    self._writeState();
    await _respond(req, {'ok': data.ok, 'message': data.message, 'data': data.data});
  }

  Future<AgentCommandResult> _executeCommand(
    AgentCommand cmd,
    AgentApiHost host,
  ) async {
    switch (cmd.type) {
      case 'step_to':
        if (cmd.idx == null) {
          return AgentCommandResult(ok: false, message: 'step_to 需要 idx');
        }
        host.stepTo(cmd.idx!);
        return AgentCommandResult(ok: true, message: 'step_to ${cmd.idx}');
      case 'step':
        final dir = cmd.dir ?? 1;
        host.stepRelative(dir);
        return AgentCommandResult(ok: true, message: 'step $dir');
      case 'play':
        host.togglePlay();
        return AgentCommandResult(ok: true, message: 'toggle_play');
      case 'pause':
        host.stop();
        return AgentCommandResult(ok: true, message: 'pause');
      case 'stop':
        host.stop();
        return AgentCommandResult(ok: true, message: 'stop');
      case 'run_to_end':
        await host.runToEnd();
        return AgentCommandResult(ok: true, message: 'run_to_end');
      case 'load_code':
        if (cmd.code == null) {
          return AgentCommandResult(ok: false, message: 'load_code 需要 code');
        }
        await host.loadCode(code: cmd.code!, period: cmd.period);
        return AgentCommandResult(ok: true, message: 'load_code ${cmd.code}');
      case 'set_period':
        if (cmd.period == null) {
          return AgentCommandResult(ok: false, message: 'set_period 需要 period');
        }
        await host.setPeriod(cmd.period!);
        return AgentCommandResult(ok: true, message: 'set_period ${cmd.period}');
      case 'set_indicators':
        return AgentCommandResult(
          ok: false,
          message: 'set_indicators 需在主界面实现 label->类映射',
        );
      case 'run_robot_verify':
        final suiteId = cmd.period ?? 'jiyou_keypoint_20261001';
        final klineRoot = host.dataRoot.isEmpty
            ? RobotVerifyPaths.resolveRepoRoot(klineRoot: null)
            : host.dataRoot;
        if (klineRoot == null || klineRoot.isEmpty) {
          return AgentCommandResult(ok: false, message: '无法解析数据根目录');
        }
        try {
          final report = await runFullRobotVerify(
            suiteId: suiteId,
            klineRoot: klineRoot,
          );
          final data = <String, dynamic>{
            'suite_id': report.suiteId,
            'ok': report.ok,
            'phases': report.phases.map((p) => {
              'id': p.id,
              'ok': p.ok,
              'skipped': p.skipped,
              'skip_reason': p.skipReason,
            }).toList(),
          };
          return AgentCommandResult(
            ok: report.ok,
            message: report.ok ? '机器人验证全部通过' : '机器人验证存在未通过项',
            data: data,
          );
        } catch (e) {
          return AgentCommandResult(
            ok: false,
            message: '机器人验证异常：$e',
          );
        }
      default:
        return AgentCommandResult(ok: false, message: '未知命令 ${cmd.type}');
    }
  }

  /// ---------------- 文件轮询备选 ----------------

  void _startFilePoller() {
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      try {
        _pollOnce();
      } catch (_) {}
    });
  }

  void _pollOnce() {
    final cmdFile = _commandFile!;
    if (!cmdFile.existsSync()) return;
    final mtime = cmdFile.lastModifiedSync();
    // 只处理比上次已执行命令更新的文件。
    if (!mtime.isAfter(_commandMtime)) return;
    _commandMtime = mtime;

    final text = cmdFile.readAsStringSync();
    final json = agentJsonDecode(text);
    if (json == null) {
      _writeResult(AgentCommandResult(ok: false, message: 'invalid command.json'));
      return;
    }
    final cmd = AgentCommand.fromJson(json);
    unawaited(_executeCommand(cmd, host).then((r) => _writeResult(r)));
  }

  void _writeResult(AgentCommandResult result) {
    final f = _resultFile!;
    f.writeAsStringSync(agentJsonEncode(result.toJson()), flush: true);
    // 同时刷新 state。
    _writeState();
  }

  void _writeState() {
    final f = _stateFile!;
    f.writeAsStringSync(agentJsonEncode(_stateJson(host)), flush: true);
  }

  /// 主界面可调用：每次状态变更后刷新 state.json。
  void refreshStateFile() {
    _writeState();
  }

  /// ---------------- 截图回调（由主界面绑定） ----------------

  static Future<List<int>> Function()? _screenshotCallback;

  static void bindScreenshot(Future<List<int>> Function() cb) {
    _screenshotCallback = cb;
  }
}
