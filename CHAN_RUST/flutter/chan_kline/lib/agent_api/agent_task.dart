/// @file lib/agent_api/agent_task.dart
/// @brief Agent 异步任务（寻优 / 回测）的通用状态与 JSON 输出（纯 Dart）。
///
/// 任务由主界面持有并推进（寻优/回测都在主界面会话上跑），服务端只读状态。
/// 状态机：running → done | cancelled | failed（终态不再变）。
class AgentTask {
  AgentTask({
    required this.id,
    required this.kind,
    required this.startedAt,
  });

  /// 任务 ID（`search_1` / `backtest_2`）。
  final String id;

  /// 任务类型：`search` | `backtest`。
  final String kind;

  final DateTime startedAt;
  DateTime? finishedAt;

  /// `running` | `done` | `cancelled` | `failed`。
  String phase = 'running';

  /// 可读进度说明（阶段 + 计数）。
  String detail = '';

  /// 0..1 进度（null=不确定）。
  double? fraction;

  /// 已完成 / 总数（候选条数）。
  int done = 0;
  int total = 0;

  /// 失败原因（phase=failed 时非空）。
  String? error;

  /// 任务负载（寻优为 `List<ComboVerdict>`，回测为 `BacktestRun`）。
  Object? payload;

  /// 结果摘要（不含大数组；分页数据由宿主另行取）。
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
        if (error != null) 'error': error,
        if (summary != null) 'summary': summary,
      };
}
