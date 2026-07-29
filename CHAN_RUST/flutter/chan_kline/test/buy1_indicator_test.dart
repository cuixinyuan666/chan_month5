import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';

void main() {
  test('Buy1Frame fromJson', () {
    final f = Buy1Frame.fromJson({
      'seq': 1,
      'zs_seq': 2,
      'x': 10,
      'price': 11.5,
      'label': '1b',
      'seg_idx': 3,
      'level': 0,
    });
    expect(f.seq, 1);
    expect(f.zsSeq, 2);
    expect(f.x, 10);
    expect(f.price, 11.5);
    expect(f.label, '1b');
    expect(f.segIdx, 3);
    expect(f.level, 0);
  });

  test('sub catalog includes Kn buy1 same layer as ZS', () {
    final catalog = buildSubIndicatorCatalog(2);
    expect(catalog.any((e) => e.kind == SubIndicatorKind.buy1 && e.kn == 0), isTrue);
    expect(catalog.any((e) => e.kind == SubIndicatorKind.buy1 && e.kn == 2), isTrue);
    expect(const SubChartIndicator.buy1(0).label, 'K0一买');
    expect(const SubChartIndicator.buy1(1).label, 'K1一买');
    expect(const SubChartIndicator.buy1(0).displayLevel, 0);

    final level0 = subIndicatorsForLevel(0, catalog);
    expect(level0.any((e) => e.kind == SubIndicatorKind.buy1 && e.kn == 0), isTrue);
  });
}