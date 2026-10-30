/// @file test/agent_api/agent_api_backtest_test.dart
/// @brief P1-2：`run_backtest` 启动 / `GET /backtest_task` 轮询分页 / `cancel_backtest`。
import 'package:flutter_test/flutter_test.dart';

import 'agent_api_http_helper.dart';
import 'mock_agent_host.dart';

void main() {
  group('回测任务端点', () {
    late MockAgentHost host;
    late AgentApiTestHarness h;

    const buyAst = {'t': 'ev', 'var': 'STRUCTURE.K0.BUY1'};
    const sellAst = {'t': 'ev', 'var': 'STRUCTURE.K0.SELL1'};

    setUp(() async {
      host = MockAgentHost();
      h = await AgentApiTestHarness.start(host);
    });

    tearDown(() async => h.close());

    test('run_backtest 返回 task_id，并把参数原样透传', () async {
      final r = await h.postCommand({
        'type': 'run_backtest',
        'buy_ast': buyAst,
        'sell_ast': sellAst,
        'code': '002003',
        'period': '1m',
        'begin': '2024/01/02 09:30:00',
        'end': '2024/01/05 15:00:00',
        'quantity': 200,
        'commission_rate': 0.0003,
        'slippage_amount': 0.01,
        'fill_price_mode': 'nextBarOpen',
      });
      expect(r.body['ok'], true);
      final taskId = (r.body['data'] as Map)['task_id'] as String;
      expect(taskId, startsWith('backtest_'));
      expect(
        host.log.last,
        'run_backtest:ev:ev:002003:1m:2024/01/02 09:30:00:'
        '2024/01/05 15:00:00:200:0.0003:0.01:nextBarOpen',
      );
    });

    test('run_backtest 缺买卖条件 → ok:false', () async {
      final noBuy = await h.postCommand({
        'type': 'run_backtest',
        'sell_ast': sellAst,
      });
      expect(noBuy.body['ok'], false);
      expect('${noBuy.body['message']}', contains('buy_ast'));

      final noSell = await h.postCommand({
        'type': 'run_backtest',
        'buy_ast': buyAst,
      });
      expect(noSell.body['ok'], false);
      expect('${noSell.body['message']}', contains('sell_ast'));
    });

    test('GET /backtest_task 返回进度与分页 trades', () async {
      final start = await h.postCommand({
        'type': 'run_backtest',
        'buy_ast': buyAst,
        'sell_ast': sellAst,
      });
      final taskId = (start.body['data'] as Map)['task_id'] as String;

      final all = await h.getJson('/backtest_task?task_id=$taskId',
          token: h.server.token);
      expect(all.body['ok'], true);
      expect(all.body['phase'], 'running');
      expect(all.body['kind'], 'backtest');
      expect(all.body['trades_total'], 1);
      final rows = (all.body['trades'] as List).cast<Map>();
      expect(rows.length, 1);
      expect(rows.single['entry_x'], 1);
      expect(rows.single['exit_x'], 3);
      expect(rows.single['net_pnl'], 100.0);

      final page = await h.getJson(
        '/backtest_task?task_id=$taskId&offset=1&limit=1',
        token: h.server.token,
      );
      expect(page.body['ok'], true);
      expect(page.body['offset'], 1);
      expect(page.body['limit'], 1);
      expect((page.body['trades'] as List).length, 0);
    });

    test('缺 task_id / 未知 task_id → ok:false', () async {
      final missing = await h.getJson('/backtest_task', token: h.server.token);
      expect(missing.body['ok'], false);
      expect('${missing.body['message']}', contains('task_id'));

      final unknown = await h.getJson('/backtest_task?task_id=backtest_999',
          token: h.server.token);
      expect(unknown.body['ok'], false);
      expect('${unknown.body['message']}', contains('backtest_999'));
    });

    test('offset/limit 非法 → ok:false', () async {
      final start = await h.postCommand({
        'type': 'run_backtest',
        'buy_ast': buyAst,
        'sell_ast': sellAst,
      });
      final taskId = (start.body['data'] as Map)['task_id'] as String;
      for (final q in ['offset=-1', 'limit=0', 'limit=abc']) {
        final r = await h.getJson('/backtest_task?task_id=$taskId&$q',
            token: h.server.token);
        expect(r.body['ok'], false, reason: q);
      }
    });

    test('cancel_backtest 生效，重复取消返回 ok:false', () async {
      final start = await h.postCommand({
        'type': 'run_backtest',
        'buy_ast': buyAst,
        'sell_ast': sellAst,
      });
      final taskId = (start.body['data'] as Map)['task_id'] as String;

      final c1 = await h.postCommand({
        'type': 'cancel_backtest',
        'task_id': taskId,
      });
      expect(c1.body['ok'], true);
      expect(host.log.last, 'cancel_backtest:$taskId');

      final status = await h.getJson('/backtest_task?task_id=$taskId',
          token: h.server.token);
      expect(status.body['phase'], 'cancelled');
      expect(status.body['running'], false);

      final c2 = await h.postCommand({
        'type': 'cancel_backtest',
        'task_id': taskId,
      });
      expect(c2.body['ok'], false);
      expect('${c2.body['message']}', contains('不存在或已结束'));
    });

    test('cancel_backtest 缺 task_id → ok:false', () async {
      final r = await h.postCommand({'type': 'cancel_backtest'});
      expect(r.body['ok'], false);
      expect('${r.body['message']}', contains('task_id'));
    });

    test('/state 的 tasks 能看到回测任务摘要', () async {
      final start = await h.postCommand({
        'type': 'run_backtest',
        'buy_ast': buyAst,
        'sell_ast': sellAst,
      });
      final taskId = (start.body['data'] as Map)['task_id'] as String;
      final s = await h.getJson('/state', token: h.server.token);
      final tasks = (s.body['tasks'] as List).cast<Map>();
      expect(tasks.map((e) => e['task_id']), contains(taskId));
      expect(tasks.first['kind'], 'backtest');
    });
  });
}
