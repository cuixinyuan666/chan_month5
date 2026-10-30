/// @file test/agent_api/agent_api_search_test.dart
/// @brief P1-1：`run_search` 启动 / `GET /search_task` 轮询分页 / `cancel_search`。
import 'package:flutter_test/flutter_test.dart';

import 'agent_api_http_helper.dart';
import 'mock_agent_host.dart';

void main() {
  group('寻优任务端点', () {
    late MockAgentHost host;
    late AgentApiTestHarness h;

    setUp(() async {
      host = MockAgentHost();
      h = await AgentApiTestHarness.start(host);
    });

    tearDown(() async => h.close());

    test('run_search 返回 task_id，并把参数原样透传', () async {
      final r = await h.postCommand({
        'type': 'run_search',
        'code': '002003',
        'period': '1m',
        'begin': '2024/01/02 09:30:00',
        'end': '2024/01/05 15:00:00',
        'max_candidates': 200,
        'in_ratio': 0.6,
      });
      expect(r.body['ok'], true);
      final taskId = (r.body['data'] as Map)['task_id'] as String;
      expect(taskId, startsWith('search_'));
      expect(
        host.log.last,
        'start_search:002003:1m:2024/01/02 09:30:00:2024/01/05 15:00:00:200:0.6',
      );
    });

    test('in_ratio 缺省 = 0.7', () async {
      final r = await h.postCommand({'type': 'run_search'});
      expect(r.body['ok'], true);
      expect(host.log.last, endsWith(':0.7'));
    });

    test('GET /search_task 返回进度与分页 verdicts', () async {
      final start = await h.postCommand({'type': 'run_search'});
      final taskId = (start.body['data'] as Map)['task_id'] as String;

      final all = await h.getJson('/search_task?task_id=$taskId',
          token: h.server.token);
      expect(all.body['ok'], true);
      expect(all.body['phase'], 'running');
      expect(all.body['verdicts_total'], 3);
      expect((all.body['verdicts'] as List).length, 3);

      final page = await h.getJson(
        '/search_task?task_id=$taskId&offset=1&limit=1',
        token: h.server.token,
      );
      expect(page.body['ok'], true);
      expect(page.body['offset'], 1);
      expect(page.body['limit'], 1);
      final rows = (page.body['verdicts'] as List).cast<Map>();
      expect(rows.length, 1);
      expect(rows.single['name'], '事件｜候选1');
      expect(rows.single['inSample'], isNotNull);
      expect(rows.single['splitX'], 7);
    });

    test('缺 task_id / 未知 task_id → ok:false', () async {
      final missing = await h.getJson('/search_task', token: h.server.token);
      expect(missing.body['ok'], false);
      expect('${missing.body['message']}', contains('task_id'));

      final unknown = await h.getJson('/search_task?task_id=search_999',
          token: h.server.token);
      expect(unknown.body['ok'], false);
      expect('${unknown.body['message']}', contains('search_999'));
    });

    test('offset/limit 非法 → ok:false', () async {
      final start = await h.postCommand({'type': 'run_search'});
      final taskId = (start.body['data'] as Map)['task_id'] as String;
      for (final q in ['offset=-1', 'limit=0', 'limit=abc']) {
        final r = await h.getJson('/search_task?task_id=$taskId&$q',
            token: h.server.token);
        expect(r.body['ok'], false, reason: q);
      }
    });

    test('cancel_search 生效，重复取消返回 ok:false', () async {
      final start = await h.postCommand({'type': 'run_search'});
      final taskId = (start.body['data'] as Map)['task_id'] as String;

      final c1 = await h.postCommand({
        'type': 'cancel_search',
        'task_id': taskId,
      });
      expect(c1.body['ok'], true);
      expect(host.log.last, 'cancel_search:$taskId');

      final status = await h.getJson('/search_task?task_id=$taskId',
          token: h.server.token);
      expect(status.body['phase'], 'cancelled');
      expect(status.body['running'], false);

      final c2 = await h.postCommand({
        'type': 'cancel_search',
        'task_id': taskId,
      });
      expect(c2.body['ok'], false);
      expect('${c2.body['message']}', contains('不存在或已结束'));
    });

    test('cancel_search 缺 task_id → ok:false', () async {
      final r = await h.postCommand({'type': 'cancel_search'});
      expect(r.body['ok'], false);
      expect('${r.body['message']}', contains('task_id'));
    });

    test('/state 的 tasks 能看到任务摘要', () async {
      final start = await h.postCommand({'type': 'run_search'});
      final taskId = (start.body['data'] as Map)['task_id'] as String;
      final s = await h.getJson('/state', token: h.server.token);
      final tasks = (s.body['tasks'] as List).cast<Map>();
      expect(tasks.map((e) => e['task_id']), contains(taskId));
      expect(tasks.first['kind'], 'search');
    });
  });
}
