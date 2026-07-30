import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/class1_bs_compute.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';

void main() {
  test('Buy1Frame fromJson', () {
    final f = Buy1Frame.fromJson({
      'seq': 1, 'zs_seq': 2, 'x': 10, 'price': 11.5,
      'label': '1Bb', 'seg_idx': 3, 'level': 0,
    });
    expect(f.seq, 1);
    expect(f.label, '1Bb');
  });

  test('Sell1Frame fromJson', () {
    final f = Sell1Frame.fromJson({
      'seq': 1, 'zs_seq': 2, 'x': 10, 'price': 21.5,
      'label': '1Sb', 'seg_idx': 3, 'level': 0,
    });
    expect(f.label, '1Sb');
  });

  test('sub catalog includes Kn class1 BS same layer as ZS', () {
    final catalog = buildSubIndicatorCatalog(2);
    expect(catalog.any((e) => e.kind == SubIndicatorKind.buy1 && e.kn == 0), isTrue);
    expect(const SubChartIndicator.buy1(0).label, 'K0一类BS');
    expect(const SubChartIndicator.buy1(1).label, 'K1一类BS');
  });

  test('mergeBuy1EventLog freezes discovery x and never drops old', () {
    final hist = <Buy1Frame>[];
    mergeBuy1EventLog(
      hist,
      const [
        Buy1Frame(seq: 0, zsSeq: 1, x: 99, price: 11.89, label: '1Sa', segIdx: 3, level: 1),
      ],
      discoveryX: 24,
    );
    mergeBuy1EventLog(
      hist,
      const [
        Buy1Frame(seq: 0, zsSeq: 1, x: 100, price: 11.89, label: '1Sa', segIdx: 3, level: 1),
        Buy1Frame(seq: 1, zsSeq: 1, x: 101, price: 11.88, label: '1Sa', segIdx: 5, level: 1),
      ],
      discoveryX: 26,
    );
    expect(hist.length, 2);
    expect(hist[0].x, 24);
    expect(hist[0].segIdx, 3);
    expect(hist[1].x, 26);
    expect(hist[1].segIdx, 5);
  });

  test('mergeSell1EventLog active Kn appends K0 granular x', () {
    final hist = <Sell1Frame>[];
    // 旧点先发现
    mergeSell1EventLog(
      hist,
      const [
        Sell1Frame(seq: 0, zsSeq: 1, x: 24, price: 11.9, label: '1Sa', segIdx: 3, level: 1),
      ],
      discoveryX: 24,
    );
    mergeSell1EventLog(
      hist,
      const [
        Sell1Frame(seq: 1, zsSeq: 1, x: 99, price: 11.88, label: '1Sa', segIdx: 5, level: 1),
      ],
      discoveryX: 26,
      activeSegIdx: 5,
    );
    mergeSell1EventLog(
      hist,
      const [
        Sell1Frame(seq: 0, zsSeq: 1, x: 24, price: 11.9, label: '1Sa', segIdx: 3, level: 1),
        Sell1Frame(seq: 1, zsSeq: 1, x: 99, price: 11.88, label: '1Sa', segIdx: 5, level: 1),
      ],
      discoveryX: 27,
      activeSegIdx: 5,
    );
    expect(hist.length, 3);
    expect(hist.map((e) => e.x).toList(), [24, 26, 27]);
    expect(hist.map((e) => e.segIdx).toList(), [3, 5, 5]);
  });

  test('history lookup writes label only at discovery x', () {
    final bars = List.generate(
      30,
      (i) => KlineBar(
        idx: i, timeMs: i, timeText: 'T',
        open: 1, high: 1, low: 1, close: 1, volume: 0, amount: 0,
      ),
    );
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      sell1HistoryByKn: {
        1: const [
          Sell1Frame(
            seq: 0, zsSeq: 1, x: 26, price: 11.88,
            label: '1Sa', segIdx: 5, level: 1,
          ),
        ],
      },
      subIndicators: {const SubChartIndicator.buy1(1)},
    );
    expect(lookup.byIdx[26]?['sub']?['sell1_1'], '1Sa');
    expect(lookup.byIdx[27]?['sub']?['sell1_1'], isNull);
  });
}
