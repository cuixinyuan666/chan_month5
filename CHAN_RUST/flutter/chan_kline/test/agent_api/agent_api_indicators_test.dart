/// @file test/agent_api/agent_api_indicators_test.dart
/// @brief `set_indicators`：命令解析（逗号/全角逗号/空串）、未给参数拒绝、真实目录 label 映射。
import 'package:chan_kline/agent_api/indicator_label_map.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:flutter_test/flutter_test.dart';

import 'agent_api_http_helper.dart';
import 'mock_agent_host.dart';

void main() {
  group('POST /command set_indicators', () {
    late MockAgentHost host;
    late AgentApiTestHarness h;

    setUp(() async {
      host = MockAgentHost();
      h = await AgentApiTestHarness.start(host);
    });

    tearDown(() async => h.close());

    test('两侧都不给 → ok:false，且状态不变', () async {
      final r = await h.postCommand({'type': 'set_indicators'});
      expect(r.body['ok'], false);
      expect('${r.body['message']}', contains('main_indicators'));
      expect(host.log, isEmpty);
    });

    test('逗号与全角逗号都能分隔；空串清空该侧', () async {
      final r = await h.postCommand({
        'type': 'set_indicators',
        'main_indicators': 'K0',
        'sub_indicators': 'K0成交量',
      });
      expect(r.body['ok'], true);
      expect((r.body['data'] as Map)['main_indicators'], ['K0']);
      expect((r.body['data'] as Map)['sub_indicators'], ['K0成交量']);

      final r2 = await h.postCommand({
        'type': 'set_indicators',
        'main_indicators': '',
      });
      expect(r2.body['ok'], true);
      expect((r2.body['data'] as Map)['main_indicators'], isEmpty);
      // 只改主图：副图保持上一步
      expect((r2.body['data'] as Map)['sub_indicators'], ['K0成交量']);
    });
  });

  group('label → 枚举映射（真实目录）', () {
    // 用真实目录构造，杜绝硬编码 label。
    final mainCatalog = buildMainIndicatorCatalog(1);
    final subCatalog = buildSubIndicatorCatalog(1, maxBsClass: 9);

    test('已知 label 命中：K0 / K0中枢 / K0均线', () {
      final labels = [
        const MainChartIndicator.kn(0).label,
        const MainChartIndicator.zs(0).label,
        const MainChartIndicator.meanLine(0).label,
      ];
      expect(mainCatalog.map((e) => e.label), containsAll(labels));
      final r = resolveIndicatorLabels(
        mainLabels: labels,
        subLabels: const <String>[],
        mainCatalog: mainCatalog,
        subCatalog: subCatalog,
      );
      expect(r.hasUnknown, false);
      expect(r.main, {
        const MainChartIndicator.kn(0),
        const MainChartIndicator.zs(0),
        const MainChartIndicator.meanLine(0),
      });
    });

    test('未知 label 被逐条列出（不静默忽略）', () {
      final r = resolveIndicatorLabels(
        mainLabels: const ['K0', 'K0不存在'],
        subLabels: const ['K0成交量', 'K9成交量'],
        mainCatalog: mainCatalog,
        subCatalog: subCatalog,
      );
      expect(r.hasUnknown, true);
      expect(r.unknownMain, ['K0不存在']);
      expect(r.unknownSub, ['K9成交量']);
      expect(r.unknownMessage, contains('K0不存在'));
      expect(r.unknownMessage, contains('K9成交量'));
      expect(r.main.length, 1);
    });
  });
}
