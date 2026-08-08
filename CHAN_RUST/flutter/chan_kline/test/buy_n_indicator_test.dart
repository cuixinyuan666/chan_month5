import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/class_n_bs_compute.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy_n_frame.dart';
import 'package:chan_kline/models/sell_n_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';

void main() {
  test('BuyNFrame fromJson', () {
    final f = BuyNFrame.fromJson({
      'seq': 1,
      'zs_seq': 2,
      'cls': 3,
      'x': 10,
      'price': 11.5,
      'label': '3Bb',
      'seg_idx': 3,
      'level': 0,
    });
    expect(f.cls, 3);
    expect(f.label, '3Bb');
  });

  test('sub catalog includes Kn class3..9 BS', () {
    final catalog = buildSubIndicatorCatalog(1);
    expect(
      catalog.any(
        (e) => e.kind == SubIndicatorKind.buyN && e.kn == 0 && e.bsClass == 3,
      ),
      isTrue,
    );
    expect(
      catalog.any(
        (e) => e.kind == SubIndicatorKind.buyN && e.kn == 0 && e.bsClass == 9,
      ),
      isTrue,
    );
    expect(const SubChartIndicator.buyN(0, 3).label, 'K0三类BS');
    expect(const SubChartIndicator.buyN(1, 4).label, 'K1四类BS');
  });

  test('mergeBuyNEventLog freezes discovery x', () {
    final hist = <BuyNFrame>[];
    mergeBuyNEventLog(
      hist,
      const [
        BuyNFrame(
          seq: 0,
          zsSeq: 2,
          cls: 3,
          x: 99,
          price: 12.0,
          label: '3Ba',
          segIdx: 3,
          level: 1,
        ),
      ],
      discoveryX: 24,
    );
    mergeBuyNEventLog(
      hist,
      const [
        BuyNFrame(
          seq: 0,
          zsSeq: 2,
          cls: 3,
          x: 100,
          price: 12.0,
          label: '3Ba',
          segIdx: 3,
          level: 1,
        ),
        BuyNFrame(
          seq: 1,
          zsSeq: 2,
          cls: 3,
          x: 101,
          price: 13.0,
          label: '3Bb',
          segIdx: 4,
          level: 1,
        ),
      ],
      discoveryX: 26,
    );
    expect(hist.length, 2);
    expect(hist[0].x, 24);
    expect(hist[1].x, 26);
    expect(hist[1].label, '3Bb');
  });

  test('bar feature lookup exposes buyN/sellN by cls', () {
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
    // 方案B：挂 structure0 以出 K1 块
    final lookup = BarFeatureLookup.build(
      bars: bars,
      combineFrames: const [],
      k0Confirms: const [],
      levels: const [LevelBundle(level: 0)],
      buyNHistoryByKn: {
        1: const [
          BuyNFrame(
            seq: 0,
            zsSeq: 2,
            cls: 3,
            x: 3,
            price: 12,
            label: '3Ba',
            segIdx: 3,
            level: 1,
          ),
        ],
      },
      sellNHistoryByKn: {
        1: const [
          SellNFrame(
            seq: 0,
            zsSeq: 2,
            cls: 3,
            x: 4,
            price: 18,
            label: '3Sa',
            segIdx: 4,
            level: 1,
          ),
        ],
      },
      subIndicators: {const SubChartIndicator.buyN(1, 3)},
    );
    final rows = lookup.crosshairTooltipRows(
      3,
      timePart: 't',
      subIndicators: {const SubChartIndicator.buyN(1, 3)},
    );
    expect(rows.any((r) => r.flat.contains('3Ba')), isTrue);
    final rows4 = lookup.crosshairTooltipRows(
      4,
      timePart: 't',
      subIndicators: {const SubChartIndicator.buyN(1, 3)},
    );
    expect(rows4.any((r) => r.flat.contains('3Sa')), isTrue);
  });
}
