/// @file test/agent_api/mock_agent_host.dart
/// @brief Agent API 路由测试用的假主界面（纯 Dart，不挂 Widget）。
///
/// 只实现契约里的「状态读取 + 命令落地」，用于断言端点返回结构与参数生效；
/// 真实计算语义由主界面接线测试覆盖。
import 'package:chan_kline/agent_api/agent_api_host.dart';
import 'package:chan_kline/agent_api/agent_backtest_json.dart';
import 'package:chan_kline/agent_api/agent_config_key.dart';
import 'package:chan_kline/agent_api/agent_task.dart';
import 'package:chan_kline/backtest/backtest_metrics.dart';
import 'package:chan_kline/backtest/order_models.dart';
import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/models/tick_dist_config.dart';

/// 造 [count] 根 1 分钟递增 K 线（时间从 2024-01-02 09:30 起，每分钟一根）。
List<KlineBar> synthAgentBars(int count) {
  final base = DateTime(2024, 1, 2, 9, 30).millisecondsSinceEpoch;
  return [
    for (var i = 0; i < count; i++)
      KlineBar(
        idx: i,
        timeMs: base + i * 60 * 1000,
        timeText: '2024/01/02 09:${(30 + i).toString().padLeft(2, '0')}:00',
        open: 10.0 + i * 0.01,
        high: 10.05 + i * 0.01,
        low: 9.95 + i * 0.01,
        close: 10.0 + i * 0.01,
        volume: 1000 + i.toDouble(),
        amount: 10000 + i.toDouble(),
        metrics: {'tick_count': i + 1},
      ),
  ];
}

class MockAgentHost implements AgentApiHost {
  MockAgentHost({List<KlineBar>? barList, this.code = '002003'})
      : _bars = barList ?? synthAgentBars(20);

  final List<KlineBar> _bars;
  final String code;

  int stepToCalls = 0;
  int lastStepTo = -1;
  final List<String> log = [];

  Set<MainChartIndicator> _main = {const MainChartIndicator.kn(0)};
  Set<SubChartIndicator> _sub = {const SubChartIndicator.volume(0)};
  ChipConfig _chip = const ChipConfig(enabled: true, bucketStep: 0.05);
  TickDistConfig _tick = const TickDistConfig(enabled: true, bucketStep: 0.05);
  MathIndicatorConfig _math =
      const MathIndicatorConfig(bollN: 20, donchianN: 20, regressK: 2.0);
  bool _trunc = true;

  @override
  Future<String> setIndicators({
    Set<String>? mainLabels,
    Set<String>? subLabels,
  }) async {
    if (mainLabels != null) {
      _main = {
        for (final l in mainLabels)
          if (l == 'K0') const MainChartIndicator.kn(0),
      };
    }
    if (subLabels != null) {
      _sub = {
        for (final l in subLabels)
          if (l == 'K0成交量') const SubChartIndicator.volume(0),
      };
    }
    log.add('set_indicators:${mainLabels ?? '-'}:${subLabels ?? '-'}');
    return 'mock set_indicators ok';
  }

  @override
  Future<String> updateConfig(String key, String value) async {
    // 复用真实校验器：本 mock 只负责落地，不重写口径。
    final change = parseAgentConfigChange(key, value);
    switch (change.key) {
      case AgentConfigKey.chipEnabled:
        _chip = _chip.copyWith(enabled: change.asBool);
      case AgentConfigKey.tickEnabled:
        _tick = _tick.copyWith(enabled: change.asBool);
      case AgentConfigKey.chipBucket:
        _chip = _chip.copyWith(bucketStep: change.asNum);
      case AgentConfigKey.tickBucket:
        _tick = _tick.copyWith(bucketStep: change.asNum);
      case AgentConfigKey.truncationCheck:
        _trunc = change.asBool!;
      case AgentConfigKey.bollN:
        _math = _math.copyWith(bollN: change.asInt);
      case AgentConfigKey.donchianN:
        _math = _math.copyWith(donchianN: change.asInt);
      case AgentConfigKey.regressK:
        _math = _math.copyWith(regressK: change.asNum);
    }
    log.add('set_config:$key:$value');
    return 'mock set_config $key=$value';
  }

  /// 测试可预置的消息历史（按时间正序）。
  final List<AgentMessageRow> messages = [];

  @override
  List<AgentMessageRow> historyMessages({int limit = 50}) {
    if (limit <= 0) return const [];
    final begin = messages.length > limit ? messages.length - limit : 0;
    return messages.sublist(begin);
  }

  /// ---------------- 寻优任务（假实现，只验路由/分页/取消口径） ----------------

  final Map<String, AgentTask> tasks = {};
  final Map<String, List<ComboVerdict>> taskVerdicts = {};
  int _taskSeq = 0;

  @override
  Future<String> startSearch({
    String? code,
    String? period,
    String? begin,
    String? end,
    int? maxCandidates,
    double inRatio = 0.7,
  }) async {
    final t = AgentTask(
      id: 'search_${++_taskSeq}',
      kind: 'search',
      startedAt: DateTime(2024),
    )
      ..detail = '回测扫描：0/3'
      ..done = 0
      ..total = 3
      ..fraction = 0;
    tasks[t.id] = t;
    taskVerdicts[t.id] = [
      for (var i = 0; i < 3; i++)
        ComboVerdict(
          name: '事件｜候选$i',
          buyText: '买$i',
          sellText: '卖$i',
          inSample: SegmentMetrics.empty,
          outSample: SegmentMetrics.empty,
          splitX: 7,
        ),
    ];
    log.add(
      'start_search:${code ?? '-'}:${period ?? '-'}:'
      '${begin ?? '-'}:${end ?? '-'}:${maxCandidates ?? 0}:$inRatio',
    );
    return t.id;
  }

  @override
  Map<String, dynamic> searchTaskStatus(
    String taskId, {
    int offset = 0,
    int limit = 200,
  }) {
    final t = tasks[taskId];
    if (t == null) throw AgentApiError('未知 task_id：$taskId');
    final all = taskVerdicts[taskId] ?? const <ComboVerdict>[];
    final begin = offset.clamp(0, all.length);
    final end = (begin + limit).clamp(begin, all.length);
    return {
      ...t.toJson(),
      'verdicts_total': all.length,
      'offset': begin,
      'limit': limit,
      'verdicts': [for (var i = begin; i < end; i++) all[i].toJson()],
    };
  }

  @override
  bool cancelSearch(String taskId) {
    final t = tasks[taskId];
    if (t == null || !t.running) return false;
    t
      ..phase = 'cancelled'
      ..finishedAt = DateTime(2024)
      ..detail = '已请求取消';
    log.add('cancel_search:$taskId');
    return true;
  }

  @override
  List<Map<String, dynamic>> agentTasks() => [
        for (final t in tasks.values) t.toJson(),
      ];

  /// ---------------- 回测任务（假实现，只验路由/分页/取消口径） ----------------

  final Map<String, List<TradeRecord>> taskTrades = {};

  @override
  Future<String> runBacktest({
    required Map<String, dynamic> buyAst,
    required Map<String, dynamic> sellAst,
    String? code,
    String? period,
    String? begin,
    String? end,
    int? quantity,
    double? commissionRate,
    double? slippageAmount,
    String? fillPriceMode,
  }) async {
    final t = AgentTask(
      id: 'backtest_${++_taskSeq}',
      kind: 'backtest',
      startedAt: DateTime(2024),
    )
      ..detail = '回测计算中…'
      ..done = 0
      ..total = 1
      ..fraction = 0;
    tasks[t.id] = t;
    taskTrades[t.id] = [
      TradeRecord(
        tradeId: 'tr1',
        entrySignalId: 's1',
        exitSignalId: 's2',
        entryX: 1,
        exitX: 3,
        entryPrice: 10.0,
        exitPrice: 11.0,
        quantity: quantity ?? 100,
        grossPnL: 100.0,
        commission: commissionRate ?? 0,
        slippage: slippageAmount ?? 0,
      ),
    ];
    log.add(
      'run_backtest:${buyAst['t']}:${sellAst['t']}:${code ?? '-'}:'
      '${period ?? '-'}:${begin ?? '-'}:${end ?? '-'}:'
      '${quantity ?? 0}:${commissionRate ?? 0}:${slippageAmount ?? 0}:'
      '${fillPriceMode ?? '-'}',
    );
    return t.id;
  }

  @override
  Map<String, dynamic> backtestTaskStatus(
    String taskId, {
    int offset = 0,
    int limit = 200,
  }) {
    final t = tasks[taskId];
    if (t == null) throw AgentApiError('未知 task_id：$taskId');
    final all = taskTrades[taskId] ?? const <TradeRecord>[];
    final begin = offset.clamp(0, all.length);
    final end = (begin + limit).clamp(begin, all.length);
    return {
      ...t.toJson(),
      'summary': {
        'signals': all.length,
        'orders': all.length,
        'fills': all.length,
        'trades': all.length,
        'equity_points': all.length,
      },
      'trades_total': all.length,
      'offset': begin,
      'limit': limit,
      'trades': [
        for (var i = begin; i < end; i++) agentTradeJson(all[i]),
      ],
    };
  }

  @override
  bool cancelBacktest(String taskId) {
    final t = tasks[taskId];
    if (t == null || !t.running) return false;
    t
      ..phase = 'cancelled'
      ..finishedAt = DateTime(2024)
      ..detail = '已请求取消';
    log.add('cancel_backtest:$taskId');
    return true;
  }

  @override
  List<KlineBar> get bars => List<KlineBar>.unmodifiable(_bars);

  @override
  bool get hasSession => _bars.isNotEmpty;

  @override
  String? get selectedCode => code;

  @override
  String get period => '1m';

  @override
  String get periodLabel => '1分';

  @override
  String get dataRoot => 'D:/fake_root';

  @override
  int get stepIdx => 5;

  @override
  int get totalBars => _bars.length;

  @override
  bool get isPlaying => false;

  @override
  Set<MainChartIndicator> get mainIndicators => _main;

  @override
  Set<SubChartIndicator> get subIndicators => _sub;

  @override
  ChipConfig get chipConfig => _chip;

  @override
  TickDistConfig get tickDistConfig => _tick;

  @override
  MathIndicatorConfig get mathIndicatorConfig => _math;

  @override
  bool get truncationCheck => _trunc;

  @override
  void stepTo(int idx) {
    stepToCalls++;
    lastStepTo = idx;
    log.add('step_to:$idx');
  }

  @override
  void stepRelative(int dir) => log.add('step:$dir');

  @override
  void togglePlay() => log.add('toggle_play');

  @override
  Future<void> runToEnd() async => log.add('run_to_end');

  @override
  void stop() => log.add('stop');

  @override
  Future<void> loadCode({required String code, String? period}) async =>
      log.add('load_code:$code:${period ?? ''}');

  @override
  Future<void> setPeriod(String period) async => log.add('set_period:$period');

  @override
  List<AgentTooltipRow> tooltipRowsAt(int idx) =>
      [AgentTooltipRow(label: 'idx', value: '$idx')];

  @override
  AgentSnapshot snapshot() => AgentSnapshot(
        code: code,
        period: period,
        periodLabel: periodLabel,
        stepIdx: stepIdx,
        totalBars: _bars.length,
        isPlaying: false,
        maxKn: 1,
        levels: const [],
        zsK0Frames: const [],
        buy1K0Frames: const [],
        sell1K0Frames: const [],
        buy2K0Frames: const [],
        sell2K0Frames: const [],
        buyNK0Frames: const [],
        sellNK0Frames: const [],
        k0Confirms: const [],
        k0Lines: const [],
        tailBarFeature: null,
      );

  @override
  AgentHealth health() => AgentHealth(
        appVersion: 'test',
        ffiAbiVersion: 1,
        pid: 0,
        dataRoot: dataRoot,
        uptime: const Duration(seconds: 1),
      );

  @override
  DateTime get startedAt => DateTime(2024);

  @override
  String get appVersion => 'test';

  @override
  int get ffiAbiVersion => 1;
}
