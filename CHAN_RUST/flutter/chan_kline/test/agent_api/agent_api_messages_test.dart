/// @file test/agent_api/agent_api_messages_test.dart
/// @brief P0-4：`GET /messages` 返回运行消息历史（末 N 条，时间正序）。
import 'package:chan_kline/agent_api/agent_api_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_api_http_helper.dart';
import 'mock_agent_host.dart';

void main() {
  group('GET /messages', () {
    late MockAgentHost host;
    late AgentApiTestHarness h;

    setUp(() async {
      host = MockAgentHost();
      for (var i = 1; i <= 10; i++) {
        host.messages.add(AgentMessageRow(
          time: DateTime(2024, 1, 2, 9, 30).add(Duration(minutes: i)),
          text: '消息$i',
        ));
      }
      h = await AgentApiTestHarness.start(host);
    });

    tearDown(() async => h.close());

    test('缺省 limit=50：全量返回且时间正序', () async {
      final r = await h.getJson('/messages', token: h.server.token);
      expect(r.status, 200);
      expect(r.body['ok'], true);
      expect(r.body['limit'], 50);
      expect(r.body['returned'], 10);
      final rows = (r.body['rows'] as List).cast<Map>();
      expect(rows.first['text'], '消息1');
      expect(rows.last['text'], '消息10');
      expect(rows.first['time_text'], '2024/01/02 09:31:00');
      expect(rows.first['ts'], isA<int>());
    });

    test('limit=3 只回末 3 条（仍按时间正序）', () async {
      final r = await h.getJson('/messages?limit=3', token: h.server.token);
      expect(r.body['ok'], true);
      expect(r.body['limit'], 3);
      final rows = (r.body['rows'] as List).cast<Map>();
      expect(rows.map((e) => e['text']).toList(), ['消息8', '消息9', '消息10']);
    });

    test('limit 超硬上限被夹到 500', () async {
      final r = await h.getJson('/messages?limit=9999', token: h.server.token);
      expect(r.body['ok'], true);
      expect(r.body['limit'], 500);
      expect(r.body['returned'], 10);
    });

    test('limit 非法 → ok:false，不是 500 错误', () async {
      for (final bad in ['0', '-1', 'abc']) {
        final r = await h.getJson('/messages?limit=$bad', token: h.server.token);
        expect(r.status, 200, reason: bad);
        expect(r.body['ok'], false, reason: bad);
        expect('${r.body['message']}', contains('limit'));
      }
    });

    test('无令牌 → 401', () async {
      final r = await h.getJson('/messages');
      expect(r.status, 401);
    });
  });
}
