import 'package:chan_kline/ml/ml_feature_export.dart';
import 'package:chan_kline/ml/ml_feature_schema.dart';
import 'package:chan_kline/ml/ml_session_controller.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MlSessionController', () {
    test('enter/exit 交接图面占用标志', () {
      final c = MlSessionController();
      expect(c.isActive, isFalse);
      c.enter();
      expect(c.isActive, isTrue);
      c.exit();
      expect(c.isActive, isFalse);
    });
  });

  group('MlFeatureExport', () {
    test('JSONL meta schema_version=1 且无禁止键', () {
      final bars = [
        const KlineBar(
          idx: 0,
          timeMs: 0,
          timeText: '2024/01/02 09:31',
          open: 10,
          high: 11,
          low: 9,
          close: 10.5,
          volume: 100,
          amount: 1000,
        ),
        const KlineBar(
          idx: 1,
          timeMs: 60000,
          timeText: '2024/01/02 09:32',
          open: 10.5,
          high: 11.2,
          low: 10.4,
          close: 11,
          volume: 120,
          amount: 1200,
        ),
      ];
      final lookup = BarFeatureLookup.build(
        bars: bars,
        combineFrames: const [],
        k0Confirms: const <K0ConfirmSignal>[],
        barFeatures: const [],
      );
      // 故意写入禁止键，导出应剔除
      lookup.byIdx[0]!['K0筹码峰-1'] = 'should_strip';
      lookup.byIdx[0]!['sub'] = <String, dynamic>{
        'volume_0': 100.0,
        'buy_volume_0': 40.0,
        'sell_volume_0': 50.0,
        'gray_volume_0': 10.0,
      };

      final jsonl = MlFeatureExport.buildJsonl(
        lookup: lookup,
        code: '000001',
        period: '1m',
        beginDate: '2024-01-02',
        endDate: '2024-01-02',
        stepIdx: 1,
        dataRoot: r'D:\tmp',
      );
      final errs = MlFeatureExport.validateJsonl(jsonl);
      expect(errs, isEmpty);
      expect(jsonl.contains('"schema_version":${MlFeatureSchema.schemaVersion}'),
          isTrue);
      expect(jsonl.contains('ml_feature_meta'), isTrue);
      expect(jsonl.contains('K0筹码峰-1'), isFalse);
      expect(jsonl.contains('volume_0'), isTrue);
    });

    test('forbidden key 检测', () {
      expect(MlFeatureSchema.isForbiddenKey('K0筹码峰-1'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('K0笔数峰+2'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('volume_0'), isFalse);
      expect(MlFeatureSchema.isForbiddenKey('demark_text_0'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('mean_text_0'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('buy1_0'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('buy1_0_code'), isFalse);
    });
  });
}
