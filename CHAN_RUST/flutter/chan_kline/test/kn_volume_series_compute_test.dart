import 'package:chan_kline/compute/kn_volume_series_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int i, {double vol = 10}) => KlineBar(
      idx: i,
      timeMs: i * 60000,
      timeText: 't$i',
      open: 10,
      high: 11,
      low: 9,
      close: 10.5,
      volume: vol,
      amount: 1000,
    );

void main() {
  test('K0 volume equals native', () {
    expect(computeK0VolumeSeries([_bar(0, vol: 7), _bar(1, vol: 8)]), [7.0, 8.0]);
  });

  test('pole落位: dynamic excludes shared end_pole x2', () {
    // u0: pole x2=6, confirmX=8; shared=6; dynamic sum from 7
    final bars = [
      _bar(0, vol: 10),
      _bar(1, vol: 20),
      _bar(2, vol: 30),
      _bar(3, vol: 40),
      _bar(4, vol: 25),
      _bar(5, vol: 27),
      _bar(6, vol: 18), // shared pole
      _bar(7, vol: 15),
      _bar(8, vol: 8),
      _bar(9, vol: 40),
    ];
    final bundle = LevelBundle(
      level: 1,
      unitBars: [
        const LevelUnitBar(idx: 0, dir: 1, x1: 0, x2: 6, confirmX: 8, volume: 170),
        const LevelUnitBar(idx: 1, dir: -1, x1: 6, x2: 14, confirmX: 17, volume: 208),
      ],
    );
    final s = computeKnVolumeSeries(bars: bars, bundle: bundle);
    expect(s[6], 170);
    expect(s[7], 185); // still old unit display through confirmX-1
    expect(s[8], 23); // 15+8, excludes pole vol 18
    expect(s[9], 63);
  });

  test('confirm right after pole: exclude x2 not confirmX-1', () {
    // confirmX = x2+1 → old bug used sumStart=x2 (included shared)
    final bars = [
      _bar(0, vol: 10),
      _bar(1, vol: 20),
      _bar(2, vol: 30), // pole
      _bar(3, vol: 40), // confirm
      _bar(4, vol: 5),
    ];
    final bundle = LevelBundle(
      level: 1,
      unitBars: [
        const LevelUnitBar(idx: 0, dir: 1, x1: 0, x2: 2, confirmX: 3, volume: 60),
        const LevelUnitBar(idx: 1, dir: -1, x1: 2, x2: 10, confirmX: 12, volume: 100),
      ],
    );
    final s = computeKnVolumeSeries(bars: bars, bundle: bundle);
    expect(s[2], 60); // 10+20+30
    // display through confirmX-1=2 only for u0 end write... endX=2
    // u1 displayStart=3, sumStart=3 (x2+1)
    expect(s[3], 40); // excludes shared pole 30
    expect(s[4], 45);
  });
}