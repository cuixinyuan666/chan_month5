/// @file test/agent_api/agent_api_http_helper.dart
/// @brief 离线路由测试公共件：在临时目录 + 随机端口起一个 AgentApiServer，
/// 用 dart:io HttpClient 打真实 HTTP（不经 Flutter Widget）。
import 'dart:convert';
import 'dart:io';

import 'package:chan_kline/agent_api/agent_api_host.dart';
import 'package:chan_kline/agent_api/agent_api_server.dart';

class AgentApiTestHarness {
  AgentApiTestHarness._(this.server, this.root);

  final AgentApiServer server;
  final Directory root;

  static Future<AgentApiTestHarness> start(AgentApiHost host) async {
    final root = await Directory.systemTemp.createTemp('chan_agent_api_test_');
    final server = await AgentApiServer.start(
      host: host,
      startedAt: DateTime(2024),
      appVersion: 'test',
      port: 0,
      liveDirPath: root.path,
    );
    return AgentApiTestHarness._(server, root);
  }

  Future<void> close() async {
    await server.stop();
    try {
      await root.delete(recursive: true);
    } catch (_) {}
  }

  String get base => 'http://127.0.0.1:${server.port}';

  /// GET 并解析 JSON；[token] 为 null 时不带认证头。
  Future<({int status, Map<String, dynamic> body})> getJson(
    String path, {
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.getUrl(Uri.parse('$base$path'));
      if (token != null) req.headers.set('X-Agent-Token', token);
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      Map<String, dynamic> body;
      try {
        final decoded = jsonDecode(text);
        body = decoded is Map<String, dynamic> ? decoded : {'raw': text};
      } catch (_) {
        body = {'raw': text};
      }
      return (status: res.statusCode, body: body);
    } finally {
      client.close(force: true);
    }
  }

  /// POST /command 并解析 JSON。
  Future<({int status, Map<String, dynamic> body})> postCommand(
    Map<String, dynamic> body, {
    String? token,
  }) async {
    final client = HttpClient();
    try {
      final req = await client.postUrl(Uri.parse('$base/command'));
      final t = token ?? server.token;
      req.headers.set('X-Agent-Token', t);
      req.headers.contentType = ContentType.json;
      req.write(jsonEncode(body));
      final res = await req.close();
      final text = await utf8.decoder.bind(res).join();
      final decoded = jsonDecode(text);
      return (
        status: res.statusCode,
        body: decoded is Map<String, dynamic> ? decoded : {'raw': text},
      );
    } finally {
      client.close(force: true);
    }
  }
}
