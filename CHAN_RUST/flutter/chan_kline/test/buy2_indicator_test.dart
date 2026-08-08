import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/class2_bs_compute.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy2_frame.dart';
import 'package:chan_kline/models/sell2_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';

void main() {
  test('Buy2Frame fromJson', () {
    final f = Buy2Frame.fromJson({
      'seq': 1,
      'zs_seq': 2,
      'x': 10,
      'price': 11.5,
      'label': '2Bb',
      'seg_idx': 3,
      'level': 0,
    });
    expect(f.seq, 1);
    expect(f.label, '2Bb');
  });

  test('Sell2Frame fromJson', () {
    final f = Sell2Frame.fromJson({
      'seq': 1,
      'zs_seq': 2,
      'x': 10,
      'price': 21.5,
      'label': '2Sb',
      'seg_idx': 3,
      'level': 0,
    });
    expect(f.label, '2Sb');
  });

  test('sub catalog includes Kn class2 BS same layer as ZS', () {
    final catalog = buildSubIndicatorCatalog(2);
    expect(
      catalog.any((e) => e.kind == SubIndicatorKind.buy2 && e.kn == 0),
      isTrue,
    );
    expect(const SubChartIndicator.buy2(0).label, 'K0二类BS');
    expect(const SubChartIndicator.buy2(1).label, 'K1二类BS');
  });

  test('mergeBuy2EventLog freezes discovery x and never drops old', () {
    final hist = <Buy2Frame>[];
    mergeBuy2EventLog(
      hist,
      const [
        Buy2Frame(
          seq: 0,
          zsSeq: 1,
          x: 99,
          price: 6.0,
          label: '2Ba',
          segIdx: 2,
          level: 1,
        ),
      ],
      discoveryX: 24,
    );
    mergeBuy2EventLog(
      hist,
      const [
        Buy2Frame(
          seq: 0,
          zsSeq: 1,
          x: 100,
          price: 6.0,
          label: '2Ba',
          segIdx: 2,
          level: 1,
        ),
        Buy2Frame(
          seq: 1,
          zsSeq: 1,
          x: 101,
          price: 5.5,
          label: '2Bb',
          segIdx: 3,
          level: 1,
        ),
      ],
      discoveryX: 26,
    );
    expect(hist.length, 2);
    expect(hist[0].x, 24);
    expect(hist[0].segIdx, 2);
    expect(hist[1].x, 26);
    expect(hist[1].segIdx, 3);
  });

  test('mergeSell2EventLog active Kn appends K0 granular x', () {
    final hist = <Sell2Frame>[];
    mergeSell2EventLog(
      hist,
      const [
        Sell2Frame(
          seq: 0,
          zsSeq: 1,
          x: 24,
          price: 18.0,
          label: '2Sa',
          segIdx: 2,
          level: 1,
        ),
      ],
      discoveryX: 24,
    );
    mergeSell2EventLog(
      hist,
      const [
        Sell2Frame(
          seq: 1,
          zsSeq: 1,
          x: 99,
          price: 17.0,
          label: '2Sb',
          segIdx: 5,
          level: 1,
        ),
      ],
      discoveryX: 26,
      activeSegIdx: 5,
    );
    mergeSell2EventLog(
      hist,
      const [
        Sell2Frame(
          seq: 0,
          zsSeq: 1,
          x: 24,
          price: 18.0,
          label: '2Sa',
          segIdx: 2,
          level: 1,
        ),
        Sell2Frame(
          seq: 1,
          zsSeq: 1,
          x: 99,
          price: 16.5,
          label: '2Sb',
          segIdx: 5,
          level: 1,
        ),
      ],
      discoveryX: 27,
      activeSegIdx: 5,
    );
    expect(hist.length, 3);
    expect(hist.where((e) => e.segIdx == 5).map((e) => e.x).toList(), [26, 27]);
  });

  test('bar feature lookup exposes buy2/sell2 from history', () {
    final bars = List.generate(
      6,
      (i) => KlineBar(
        idx: i,
        timeMs: i,
        timeText: 't$i',
        open: 1,
        high: 2,
        low: 0.5,
        close: 1.5,
        volume: 1,
        amount: 0,
      ),
    );
    // 方案B：挂 structure0 以出 K1 块（tooltip BS 在 Kn 块类别区）
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      levels: const [LevelBundle(level: 0)],
      buy2HistoryByKn: {
        1: const [
          Buy2Frame(
            seq: 0,
            zsSeq: 1,
            x: 3,
            price: 6,
            label: '2Ba',
            segIdx: 2,
            level: 1,
          ),
        ],
      },
      sell2HistoryByKn: {
        1: const [
          Sell2Frame(
            seq: 0,
            zsSeq: 1,
            x: 4,
            price: 18,
            label: '2Sa',
            segIdx: 3,
            level: 1,
          ),
        ],
      },
      subIndicators: {const SubChartIndicator.buy2(1)},
    );
    final rows = lookup.crosshairTooltipRows(
      3,
      timePart: 't',
      subIndicators: {const SubChartIndicator.buy2(1)},
    );
    expect(rows.any((r) => r.flat.contains('2Ba')), isTrue);
    final rows4 = lookup.crosshairTooltipRows(
      4,
      timePart: 't',
      subIndicators: {const SubChartIndicator.buy2(1)},
    );
    expect(rows4.any((r) => r.flat.contains('2Sa')), isTrue);
  });
}
