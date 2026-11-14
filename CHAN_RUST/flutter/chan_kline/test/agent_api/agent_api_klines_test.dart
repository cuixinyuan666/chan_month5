/// @file test/agent_api/agent_api_klines_test.dart
/// @brief `/klines` 原始 K 线导出：根数、字段、days 过滤、limit 截断、越界拒绝、401。
import 'package:chan_kline/agent_api/agent_api_host.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_api_http_helper.dart';
import 'mock_agent_host.dart';

void main() {
  group('GET /klines', () {
    late MockAgentHost host;
    late AgentApiTestHarness h;

    setUp(() async {
      host = MockAgentHost();
      h = await AgentApiTestHarness.start(host);
    });

    tearDown(() async => h.close());

    test('无令牌 401', () async {
      final r = await h.getJson('/klines');
      expect(r.status, 401);
    });

    test('缺省返回全部 K 线，字段与主图同源', () async {
      final r = await h.getJson('/klines', token: h.server.token);
      expect(r.status, 200);
      final b = r.body;
      expect(b['ok'], true);
      expect(b['code'], '002003');
      expect(b['period'], '1m');
      expect(b['total'], 20);
      expect(b['returned'], 20);
      final bars = (b['bars'] as List).cast<Map<String, dynamic>>();
      expect(bars.length, 20);
      final last = bars.last;
      expect(last['idx'], 19);
      expect(last['ts'], host.bars.last.timeMs);
      expect(last['close'], host.bars.last.close);
      expect(last['volume'], host.bars.last.volume);
      expect(last['tick_count'], 20); // metrics.tick_count 同源
      expect(last['time_text'], host.bars.last.timeText);
    });

    test('days 过滤按末根往前推自然日', () async {
      final r = await h.getJson('/klines?days=1', token: h.server.token);
      expect(r.body['ok'], true);
      // 20 根 1 分钟线都在同一天内 → 全部命中
      expect(r.body['filtered'], 20);
      final r1 = await h.getJson('/klines?days=0', token: h.server.token);
      expect(r1.body['ok'], false);
      expect('${r1.body['message']}', contains('days'));
    });

    test('limit 截断保留末 N 根', () async {
      final r = await h.getJson('/klines?limit=5', token: h.server.token);
      expect(r.body['ok'], true);
      expect(r.body['returned'], 5);
      expect(r.body['filtered'], 20);
      expect(r.body['truncated'], true);
      final bars = (r.body['bars'] as List).cast<Map<String, dynamic>>();
      expect(bars.first['idx'], 15);
      expect(bars.last['idx'], 19);
    });

    test('period 与会话不一致时拒绝', () async {
      final r = await h.getJson('/klines?period=5m', token: h.server.token);
      expect(r.body['ok'], false);
      expect('${r.body['message']}', contains('5m'));
    });

    test('无会话时返回可读提示', () async {
      final empty = MockAgentHost(barList: <KlineBar>[]);
      final h2 = await AgentApiTestHarness.start(empty);
      addTearDown(h2.close);
      final r = await h2.getJson('/klines', token: h2.server.token);
      expect(r.body['ok'], false);
      expect('${r.body['message']}', contains('load_code'));
    });
  });

  group('agentBarJson', () {
    test('tickCount 优先用传入序列值，缺省读 metrics', () {
      final bar = synthAgentBars(1).first;
      expect(agentBarJson(bar)['tick_count'], 1);
      expect(agentBarJson(bar, tickCount: 7.5)['tick_count'], 7.5);
    });
  });
}
