/// @file test/agent_api/agent_api_config_test.dart
/// @brief P0-3：`GET /state` 的 math_config + `set_config` 键值校验与落地。
import 'package:chan_kline/agent_api/agent_config_key.dart';
import 'package:chan_kline/agent_api/agent_api_host.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_api_http_helper.dart';
import 'mock_agent_host.dart';

void main() {
  group('GET /state 配置读数', () {
    late AgentApiTestHarness h;

    setUp(() async => h = await AgentApiTestHarness.start(MockAgentHost()));
    tearDown(() async => h.close());

    test('/state 带 math_config 三项（boll_n/donchian_n/regress_k）', () async {
      final r = await h.getJson('/state', token: h.server.token);
      expect(r.status, 200);
      final m = r.body['math_config'] as Map;
      expect(m['boll_n'], 20);
      expect(m['donchian_n'], 20);
      expect(m['regress_k'], 2.0);
      expect(r.body['truncation_check'], true);
    });
  });

  group('POST /command set_config', () {
    late MockAgentHost host;
    late AgentApiTestHarness h;

    setUp(() async {
      host = MockAgentHost();
      h = await AgentApiTestHarness.start(host);
    });

    tearDown(() async => h.close());

    test('boll_n / donchian_n / regress_k 写入并回读', () async {
      final r1 = await h.postCommand({
        'type': 'set_config',
        'config_key': 'boll_n',
        'config_value': '10',
      });
      expect(r1.body['ok'], true);
      final r2 = await h.postCommand({
        'type': 'set_config',
        'config_key': 'donchian_n',
        'config_value': 25,
      });
      expect(r2.body['ok'], true);
      final r3 = await h.postCommand({
        'type': 'set_config',
        'config_key': 'regress_k',
        'config_value': '1.5',
      });
      expect(r3.body['ok'], true);

      final s = await h.getJson('/state', token: h.server.token);
      final m = s.body['math_config'] as Map;
      expect(m['boll_n'], 10);
      expect(m['donchian_n'], 25);
      expect(m['regress_k'], 1.5);
    });

    test('chip_enabled 与 tick_enabled 分开落地（不互相连带）', () async {
      final r = await h.postCommand({
        'type': 'set_config',
        'config_key': 'chip_enabled',
        'config_value': 'false',
      });
      expect(r.body['ok'], true);
      expect(host.chipConfig.enabled, false);
      // GUI 一个开关写两份；API 按 key 分开，笔数侧应保持原值。
      expect(host.tickDistConfig.enabled, true);
      expect((r.body['data'] as Map)['chip_enabled'], false);
      expect((r.body['data'] as Map)['tick_enabled'], true);
    });

    test('桶宽写入按两位小数、且最小 0.01', () async {
      final r = await h.postCommand({
        'type': 'set_config',
        'config_key': 'tick_bucket',
        'config_value': '0.123',
      });
      expect(r.body['ok'], true);
      expect(host.tickDistConfig.bucketStep, 0.12);
      expect(host.chipConfig.bucketStep, 0.05); // 另一侧不动
    });

    test('truncation_check 接受中文开/关', () async {
      final r = await h.postCommand({
        'type': 'set_config',
        'config_key': 'truncation_check',
        'config_value': '关',
      });
      expect(r.body['ok'], true);
      expect(host.truncationCheck, false);
    });

    test('缺 config_key → ok:false 并列出可用键', () async {
      final r = await h.postCommand({'type': 'set_config'});
      expect(r.body['ok'], false);
      expect('${r.body['message']}', contains('chip_enabled'));
      expect(host.log, isEmpty);
    });

    test('未知键 / 越界值 → ok:false，状态不变', () async {
      final badKey = await h.postCommand({
        'type': 'set_config',
        'config_key': 'no_such_key',
        'config_value': '1',
      });
      expect(badKey.body['ok'], false);
      expect('${badKey.body['message']}', contains('no_such_key'));

      final badBucket = await h.postCommand({
        'type': 'set_config',
        'config_key': 'chip_bucket',
        'config_value': '0.001',
      });
      expect(badBucket.body['ok'], false);
      expect('${badBucket.body['message']}', contains('0.01'));
      expect(host.chipConfig.bucketStep, 0.05);

      final badK = await h.postCommand({
        'type': 'set_config',
        'config_key': 'regress_k',
        'config_value': '0',
      });
      expect(badK.body['ok'], false);
      expect(host.mathIndicatorConfig.regressK, 2.0);

      final badPeriod = await h.postCommand({
        'type': 'set_config',
        'config_key': 'boll_n',
        'config_value': '0',
      });
      expect(badPeriod.body['ok'], false);
      expect(host.mathIndicatorConfig.bollN, 20);
      expect(host.log, isEmpty);
    });
  });

  group('parseAgentConfigChange（纯解析）', () {
    test('布尔接受 true/1/on/开 与 false/0/off/关', () {
      for (final t in ['true', '1', 'on', '开', 'TRUE']) {
        expect(parseAgentConfigChange('chip_enabled', t).asBool, true,
            reason: t);
      }
      for (final f in ['false', '0', 'off', '关']) {
        expect(parseAgentConfigChange('chip_enabled', f).asBool, false,
            reason: f);
      }
    });

    test('整数窗口拒绝小数与 0', () {
      expect(() => parseAgentConfigChange('donchian_n', '20.5'),
          throwsA(isA<AgentApiError>()));
      expect(() => parseAgentConfigChange('donchian_n', '0'),
          throwsA(isA<AgentApiError>()));
      expect(parseAgentConfigChange('donchian_n', ' 30 ').asInt, 30);
    });

    test('regress_k 拒绝 0、负数与非数字', () {
      for (final v in ['0', '-1', 'abc', 'NaN']) {
        expect(() => parseAgentConfigChange('regress_k', v),
            throwsA(isA<AgentApiError>()),
            reason: v);
      }
    });

    test('键名去空格；未知键报错含可用清单', () {
      expect(parseAgentConfigChange(' boll_n ', '15').asInt, 15);
      try {
        parseAgentConfigChange('boll', '15');
        fail('应抛 AgentApiError');
      } on AgentApiError catch (e) {
        expect(e.message, contains('boll_n'));
        expect(e.message, contains('regress_k'));
      }
    });
  });
}
