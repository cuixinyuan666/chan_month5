import 'package:chan_kline/ml/ml_feature_label.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  group('MlFeatureLabel 背驰键', () {
    test('line_slope 与旧 slope 中文名不混', () {
      expect(
        MlFeatureLabel.toChinese('sub.diver_line_slope_flag_0'),
        'K0 背驰连线斜率 标志位',
      );
      expect(
        MlFeatureLabel.toChinese('sub.diver_slope_flag_0'),
        'K0 背驰振幅摊平 标志位',
      );
    });

    test('带下划线的算法名按整段认', () {
      expect(
        MlFeatureLabel.toChinese('sub.diver_full_area_flag_1'),
        'K1 背驰全面积 标志位',
      );
      expect(
        MlFeatureLabel.toChinese('sub.diver_amount_avg_ratio_2'),
        'K2 背驰均额 比值',
      );
      expect(
        MlFeatureLabel.toChinese('sub.diver_volumn_avg_in_0'),
        'K0 背驰均量 进量',
      );
    });

    test('MACD / BOLL 指标键有中文名，不再原样显示', () {
      expect(MlFeatureLabel.toChinese('sub.macd_dif_0'), 'K0 MACD-DIF');
      expect(MlFeatureLabel.toChinese('sub.macd_dea_2'), 'K2 MACD-DEA');
      expect(MlFeatureLabel.toChinese('sub.macd_hist_5'), 'K5 MACD-柱');
      expect(MlFeatureLabel.toChinese('sub.boll_mid_1'), 'K1 BOLL中轨');
      expect(MlFeatureLabel.toChinese('sub.boll_up_1'), 'K1 BOLL上轨');
      expect(MlFeatureLabel.toChinese('sub.boll_down_4'), 'K4 BOLL下轨');
    });

    test('旧导出中文键 斜率 仍映射为连线斜率', () {
      expect(
        MlFeatureLabel.toChinese('sub.diver_斜率_flag_0'),
        'K0 背驰连线斜率 标志位',
      );
    });
  });
}
