import 'package:chan_kline/ml/ml_bs_code.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/ml/ml_feature_schema.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MlBsCode', () {
    test('编码/解码可逆', () {
      expect(MlBsCode.encode('1Ba'), 101);
      expect(MlBsCode.encode('2Sc'), -203);
      expect(MlBsCode.encode('3Bb'), 302);
      expect(MlBsCode.encode(null), 0);
      expect(MlBsCode.encode(''), 0);
      expect(MlBsCode.encode('bad'), 0);
      expect(MlBsCode.decode(101), '1Ba');
      expect(MlBsCode.decode(-203), '2Sc');
      expect(MlBsCode.decode(302), '3Bb');
      expect(MlBsCode.decode(0), isNull);
    });
  });

  group('ML 数值特征 flatten', () {
    test('BS code / Demark marks 进 flatten；字符串汇总被禁', () {
      final row = <String, dynamic>{
        'idx': 10,
        'sub': <String, dynamic>{
          'buy1_0': '1Ba',
          'buy1_0_code': 101,
          'sell2_0': '2Sc',
          'sell2_0_code': -203,
          'mean_0_5': 10.1,
          'mean_text_0': '5:10.10',
          'channel_max_0_20': 11.0,
          'channel_text_0': '20:11.00/9.00',
          'demark_text_0': 'S1 C5 完成买',
          'demark_marks_0': [
            {'type': 0, 'dir': 1, 'idx': 1},
            {'type': 1, 'dir': -1, 'idx': 5},
            {'type': 2, 'dir': -1, 'idx': 9},
          ],
          'step_rhythm_lines_0': [
            {
              'label': '0-1',
              'labelInt': 1,
              'value': 10.5,
              'ratio': 1.2,
              'dir': 1,
            },
          ],
        },
      };

      final features = MlFeatureFlat.flattenRow(row);

      expect(features['sub.buy1_0_code'], 101);
      expect(features['sub.sell2_0_code'], -203);
      expect(features.containsKey('sub.buy1_0__has'), isFalse);
      expect(features.containsKey('sub.sell2_0__has'), isFalse);
      expect(features.containsKey('sub.mean_text_0__has'), isFalse);
      expect(features.containsKey('sub.channel_text_0__has'), isFalse);
      expect(features.containsKey('sub.demark_text_0__has'), isFalse);
      expect(features['sub.mean_0_5'], 10.1);
      expect(features['sub.demark_marks_0[0].type'], 0);
      expect(features['sub.demark_marks_0[1].dir'], -1);
      expect(features['sub.demark_marks_0[2].idx'], 9);
      expect(features['sub.step_rhythm_lines_0[0].labelInt'], 1);
      expect(features['sub.step_rhythm_lines_0[0].value'], 10.5);

      expect(MlFeatureSchema.isForbiddenKey('demark_text_0'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('mean_text_0'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('buy1_0'), isTrue);
      expect(MlFeatureSchema.isForbiddenKey('buy1_0_code'), isFalse);
    });
  });
}
