/// @file lib/agent_api/agent_api_server.dart
/// @brief 本地 Agent API：HTTP 服务器（127.0.0.1）+ 文件轮询（备选）。
/// 纯 Dart，无新依赖；不改 Rust、不改 FFI、不改缠论计算逻辑。
/// 默认关闭；CHAN_AGENT_API=1 时启用。
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import '../agent_api/agent_api_host.dart';
import '../agent_api/agent_config_key.dart';
import '../compute/kn_volume_series_compute.dart';
import '../robot_verify/robot_verify_paths.dart';
import '../robot_verify/robot_verify_runner.dart';

/// Agent API 端口（固定，agent 约定）。
const int _agentApiPort = 12321;

/// `/klines` 默认返回根数上限与硬上限（R12：不一次塞爆内存）。
const int _kDefaultKlineLimit = 5000;
const int _kMaxKlineLimit = 50000;

/// `/messages` 默认条数与硬上限（MsgHistory 本身最多保留 500 条）。
const int _kDefaultMessageLimit = 50;
const int _kMaxMessageLimit = 500;

/// 任务查询的 verdicts 分页默认条数与硬上限（全量请读 TSV）。
const int _kDefaultTaskPage = 200;
const int _kMaxTaskPage = 2000;

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

  /// 实际监听端口（测试注入 `port: 0` 时用于取系统分配端口）。
  int get port => _httpServer?.port ?? 0;

  /// 运行时目录（测试注入时指向临时目录）。
  String get liveDirPath => _liveDir?.path ?? '';

  /// 启动（仅在 agent 模式下调用）。
  ///
  /// [port] / [liveDirPath] 仅供离线单测注入；生产一律用固定端口与仓库 `a_Data/agent_live/`。
  static Future<AgentApiServer> start({
    required AgentApiHost host,
    required DateTime startedAt,
    required String appVersion,
    int port = _agentApiPort,
    String? liveDirPath,
  }) async {
    // 1) 目录准备。
    final token = _generateToken();
    final liveDir = liveDirPath != null
        ? Directory(liveDirPath)
        : _defaultLiveDir();
    if (!liveDir.existsSync()) liveDir.createSync(recursive: true);

    // 2) HTTP 服务器：只绑 127.0.0.1。先 bind 成功再写令牌，
    //    避免第二个实例绑定失败时覆盖运行中实例的令牌文件。
    final server = await HttpServer.bind(
      InternetAddress.loopbackIPv4,
      port,
    );
    final tokenFile = File('${liveDir.path}${Platform.pathSeparator}$_tokenFileName');
    await tokenFile.writeAsString(token, flush: true);

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

  /// 生产运行时目录：仓库根下 `a_Data/agent_live/`。
  static Directory _defaultLiveDir() {
    final repoRoot = RobotVerifyPaths.resolveRepoRoot(klineRoot: null);
    return Directory(
      '${repoRoot ?? Directory.current.path}${Platform.pathSeparator}a_Data${Platform.pathSeparator}$_liveDirName',
    );
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
        } else if (method == 'GET' && path == '/klines') {
          await _respond(req, _klinesJson(self.host, req.uri.queryParameters));
        } else if (method == 'GET' && path == '/messages') {
          await _respond(req, _messagesJson(self.host, req.uri.queryParameters));
        } else if (method == 'GET' && path == '/search_task') {
          await _respond(
            req,
            _taskStatusJson(
              req.uri.queryParameters,
              (id, off, lim) => self.host.searchTaskStatus(
                id,
                offset: off,
                limit: lim,
              ),
            ),
          );
        } else if (method == 'GET' && path == '/backtest_task') {
          await _respond(
            req,
            _taskStatusJson(
              req.uri.queryParameters,
              (id, off, lim) => self.host.backtestTaskStatus(
                id,
                offset: off,
                limit: lim,
              ),
            ),
          );
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
      'math_config': {
        'boll_n': host.mathIndicatorConfig.bollN,
        'donchian_n': host.mathIndicatorConfig.donchianN,
        'regress_k': host.mathIndicatorConfig.regressK,
      },
      'tasks': host.agentTasks(),
    };
  }

  /// `GET /klines[?period=&days=&limit=]`：当前会话原始 K 线（OHLCV+笔数）。
  Map<String, dynamic> _klinesJson(AgentApiHost host, Map<String, String> q) {
    final bars = host.bars;
    if (bars.isEmpty) {
      return {
        'ok': false,
        'code': host.selectedCode,
        'period': host.period,
        'message': '当前无 K 线数据：请先 load_code（会按协议自动下载本地缓存）或 set_period',
      };
    }
    final wantPeriod = (q['period'] ?? '').trim();
    if (wantPeriod.isNotEmpty && wantPeriod != host.period) {
      return {
        'ok': false,
        'code': host.selectedCode,
        'period': host.period,
        'message': 'period=$wantPeriod 与当前会话不一致（当前 ${host.period}）：'
            '请先 set_period 或 load_code 后再取数',
      };
    }
    final daysRaw = (q['days'] ?? '').trim();
    int? days;
    if (daysRaw.isNotEmpty) {
      days = int.tryParse(daysRaw);
      if (days == null || days <= 0) {
        return {
          'ok': false,
          'message': 'days 必须为正整数（按自然日取末 N 天）',
        };
      }
    }
    final limitRaw = (q['limit'] ?? '').trim();
    final limitParsed = limitRaw.isEmpty ? null : int.tryParse(limitRaw);
    if (limitRaw.isNotEmpty && (limitParsed == null || limitParsed <= 0)) {
      return {'ok': false, 'message': 'limit 必须为正整数'};
    }
    final limit = min(limitParsed ?? _kDefaultKlineLimit, _kMaxKlineLimit);

    var view = bars;
    int? beginTs;
    if (days != null) {
      final endMs = bars.last.timeMs;
      final cut = endMs - Duration(days: days).inMilliseconds;
      beginTs = cut;
      view = bars.where((b) => b.timeMs >= cut).toList();
    }
    final truncated = view.length > limit;
    final outBars = truncated ? view.sublist(view.length - limit) : view;
    // 笔数口径与副图「笔数」同源（metrics.tick_count，旧数据回退 bins）。
    final ticks = computeK0TickCountSeries(outBars);
    return {
      'ok': true,
      'code': host.selectedCode,
      'period': host.period,
      'total': bars.length,
      'filtered': view.length,
      'returned': outBars.length,
      'truncated': truncated,
      'limit': limit,
      if (days != null) 'days': days,
      if (beginTs != null) 'begin_ts': beginTs,
      'bars': [
        for (var i = 0; i < outBars.length; i++)
          agentBarJson(outBars[i], tickCount: ticks[i]),
      ],
    };
  }

  /// `GET /messages[?limit=]`：运行消息历史末 N 条（与界面「历史记录」同源）。
  Map<String, dynamic> _messagesJson(AgentApiHost host, Map<String, String> q) {
    final raw = (q['limit'] ?? '').trim();
    var limit = _kDefaultMessageLimit;
    if (raw.isNotEmpty) {
      final parsed = int.tryParse(raw);
      if (parsed == null || parsed <= 0) {
        return {'ok': false, 'message': 'limit 必须为正整数'};
      }
      limit = min(parsed, _kMaxMessageLimit);
    }
    final rows = host.historyMessages(limit: limit);
    return {
      'ok': true,
      'limit': limit,
      'returned': rows.length,
      'rows': rows.map((e) => e.toJson()).toList(),
    };
  }

  /// 任务状态查询公共件：`task_id` 必填，`offset`/`limit` 控制 verdicts 分页。
  Map<String, dynamic> _taskStatusJson(
    Map<String, String> q,
    Map<String, dynamic> Function(String id, int offset, int limit) load,
  ) {
    final id = (q['task_id'] ?? '').trim();
    if (id.isEmpty) {
      return {'ok': false, 'message': '需要 task_id 参数'};
    }
    final offsetRaw = (q['offset'] ?? '').trim();
    final limitRaw = (q['limit'] ?? '').trim();
    final offset = offsetRaw.isEmpty ? 0 : int.tryParse(offsetRaw);
    final limit = limitRaw.isEmpty ? _kDefaultTaskPage : int.tryParse(limitRaw);
    if (offset == null || offset < 0) {
      return {'ok': false, 'message': 'offset 必须为非负整数'};
    }
    if (limit == null || limit <= 0) {
      return {'ok': false, 'message': 'limit 必须为正整数'};
    }
    try {
      return {
        'ok': true,
        ...load(id, offset, min(limit, _kMaxTaskPage)),
      };
    } on AgentApiError catch (e) {
      return {'ok': false, 'message': e.message};
    }
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
        final mainLabels = _splitIndicatorLabels(cmd.mainIndicators);
        final subLabels = _splitIndicatorLabels(cmd.subIndicators);
        if (mainLabels == null && subLabels == null) {
          return AgentCommandResult(
            ok: false,
            message: 'set_indicators 需要 main_indicators 和/或 sub_indicators'
                '（逗号分隔的目录 label，空字符串表示清空该侧）',
          );
        }
        try {
          final msg = await host.setIndicators(
            mainLabels: mainLabels,
            subLabels: subLabels,
          );
          return AgentCommandResult(
            ok: true,
            message: msg,
            data: {
              'main_indicators': host.mainIndicators.map((e) => e.label).toList(),
              'sub_indicators': host.subIndicators.map((e) => e.label).toList(),
            },
          );
        } on AgentApiError catch (e) {
          return AgentCommandResult(ok: false, message: e.message);
        }
      case 'set_config':
        final key = (cmd.configKey ?? '').trim();
        final value = cmd.configValue ?? '';
        if (key.isEmpty) {
          return AgentCommandResult(
            ok: false,
            message: 'set_config 需要 config_key（可用：$agentConfigKeyList）',
          );
        }
        try {
          final msg = await host.updateConfig(key, value);
          return AgentCommandResult(
            ok: true,
            message: msg,
            data: {
              'chip_enabled': host.chipConfig.enabled,
              'chip_bucket': host.chipConfig.bucketStep,
              'tick_enabled': host.tickDistConfig.enabled,
              'tick_bucket': host.tickDistConfig.bucketStep,
              'truncation_check': host.truncationCheck,
              'boll_n': host.mathIndicatorConfig.bollN,
              'donchian_n': host.mathIndicatorConfig.donchianN,
              'regress_k': host.mathIndicatorConfig.regressK,
            },
          );
        } on AgentApiError catch (e) {
          return AgentCommandResult(ok: false, message: e.message);
        }
      case 'run_search':
        try {
          final taskId = await host.startSearch(
            code: cmd.code,
            period: cmd.period,
            begin: cmd.begin,
            end: cmd.end,
            maxCandidates: cmd.maxCandidates,
            inRatio: cmd.inRatio ?? 0.7,
          );
          return AgentCommandResult(
            ok: true,
            message: '寻优已启动：$taskId（用 GET /search_task?task_id=$taskId 轮询）',
            data: {'task_id': taskId},
          );
        } on AgentApiError catch (e) {
          return AgentCommandResult(ok: false, message: e.message);
        }
      case 'cancel_search':
        final taskId = (cmd.taskId ?? '').trim();
        if (taskId.isEmpty) {
          return AgentCommandResult(ok: false, message: 'cancel_search 需要 task_id');
        }
        final accepted = host.cancelSearch(taskId);
        return AgentCommandResult(
          ok: accepted,
          message: accepted ? '已请求取消 $taskId' : '任务 $taskId 不存在或已结束',
          data: {'task_id': taskId},
        );
      case 'run_backtest':
        final buyAst = cmd.buyAst;
        final sellAst = cmd.sellAst;
        if (buyAst == null || sellAst == null) {
          return AgentCommandResult(
            ok: false,
            message: 'run_backtest 需要 buy_ast 和 sell_ast'
                '（TradeAst JSON，如 {"t":"ev","var":"STRUCTURE.K0.BUY1"}）',
          );
        }
        try {
          final taskId = await host.runBacktest(
            buyAst: buyAst,
            sellAst: sellAst,
            code: cmd.code,
            period: cmd.period,
            begin: cmd.begin,
            end: cmd.end,
            quantity: cmd.quantity,
            commissionRate: cmd.commissionRate,
            slippageAmount: cmd.slippageAmount,
            fillPriceMode: cmd.fillPriceMode,
          );
          return AgentCommandResult(
            ok: true,
            message: '回测已启动：$taskId'
                '（用 GET /backtest_task?task_id=$taskId 轮询）',
            data: {'task_id': taskId},
          );
        } on AgentApiError catch (e) {
          return AgentCommandResult(ok: false, message: e.message);
        }
      case 'cancel_backtest':
        final taskId = (cmd.taskId ?? '').trim();
        if (taskId.isEmpty) {
          return AgentCommandResult(
            ok: false,
            message: 'cancel_backtest 需要 task_id',
          );
        }
        final accepted = host.cancelBacktest(taskId);
        return AgentCommandResult(
          ok: accepted,
          message: accepted
              ? '已请求取消 $taskId（回测为同步计算，仅计算开始前生效）'
              : '任务 $taskId 不存在或已结束',
          data: {'task_id': taskId},
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

  /// 逗号分隔的 label 列表 → Set（null=该侧不改；空串=清空该侧）。
  /// label 里允许全角逗号，避免 agent 手打中文标点被判非法。
  static Set<String>? _splitIndicatorLabels(String? raw) {
    if (raw == null) return null;
    final s = raw.replaceAll('，', ',').trim();
    if (s.isEmpty) return const {};
    return {
      for (final part in s.split(','))
        if (part.trim().isNotEmpty) part.trim(),
    };
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
