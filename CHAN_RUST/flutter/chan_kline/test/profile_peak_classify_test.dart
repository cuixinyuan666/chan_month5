import 'package:chan_kline/compute/profile_peak_classify.dart';
import 'package:chan_kline/models/peak_rank_config.dart';
import 'package:chan_kline/widgets/kline_chip.dart';
import 'package:flutter_test/flutter_test.dart';

ChipProfileData _profile(List<double> prices, List<double> totals) {
  return ChipProfileData(
    profileId: 't',
    cutoffX: 0,
    bucketStep: 0.1,
    prices: prices,
    s: totals,
    b: List.filled(totals.length, 0),
    w: List.filled(totals.length, 0),
    total: totals,
    maxTotal: totals.fold(0.0, (a, b) => a > b ? a : b),
  );
}

void main() {
  test('峰编号：框内 IN1，下侧-1/-2，上侧+1', () {
    final prices = [
      9.5,
      10.0,
      10.3,
      10.5,
      10.7,
      11.0,
      11.5,
      12.0,
      12.5,
      13.0,
      13.5,
    ];
    final totals = [1.0, 5.0, 1.0, 6.0, 1.0, 7.0, 1.0, 8.0, 1.0, 9.0, 1.0];
    final rows = classifyProfilePeaks(
      profile: _profile(prices, totals),
      low: 10.4,
      high: 11.2,
      close: 11.0,
      rank: PeakRankConfig.defaults,
    );
    final labels = rows.map((e) => e.label('K0筹码峰')).toList();
    expect(labels.contains('K0筹码峰-1'), isTrue);
    expect(labels.any((l) => l.contains('框内')), isTrue);
    expect(labels.contains('K0筹码峰+1'), isTrue);
    expect(labels.contains('K0筹码峰+2'), isTrue);
    final r = rows.firstWhere((e) => e.nameSuffix == '-1');
    expect(r.valueText(), contains('【10】'));
    expect(r.valueText(), contains('B：【'));
  });

  test('纯量级：忽略 OHLC 区间，全局按筹码量取前 N 并按价格升序', () {
    const prices = [
      9.5,
      10.0,
      10.3,
      10.5,
      10.7,
      11.0,
      11.5,
      12.0,
      12.5,
      13.0,
      13.5,
    ];
    const totals = [
      1.0,
      5.0,
      1.0,
      6.0,
      1.0,
      7.0,
      1.0,
      8.0,
      1.0,
      9.0,
      1.0,
    ];
    // low/high/close 全部落在价区之外：若为空间序会几乎不入选，纯量级不受影响。
    const low = 99.0, high = 0.0, close = 50.0;

    final rows = classifyProfilePeaks(
      profile: _profile(prices, totals),
      low: low,
      high: high,
      close: close,
      rank: PeakRankConfig(mode: PeakRankMode.pure, maxPureRank: 7),
    );
    expect(rows.length, 5);
    // 后缀集合恰为 PURE1..PURE5（价区仅 5 个局部极大峰，N=7 时全部入选）
    final suffixes = rows.map((e) => e.nameSuffix).toSet();
    for (var i = 1; i <= 5; i++) {
      expect(suffixes.contains('PURE$i'), isTrue);
    }
    // 按价格升序排列
    for (var i = 1; i < rows.length; i++) {
      expect(rows[i].price >= rows[i - 1].price, isTrue);
    }
    // 全局最大筹码量的峰（price 13.0, total 9.0）必为 PURE1，证明忽略 OHLC 区间
    expect(
      rows.firstWhere((e) => e.price == 13.0).nameSuffix,
      'PURE1',
    );
    // 最大的 5 个峰（9/8/7/6/5）必须全部入选
    final selected = rows.map((e) => e.price).toSet();
    for (final p in const [13.0, 12.0, 11.0, 10.5, 10.0]) {
      expect(selected.contains(p), isTrue);
    }

    // 缩小 N=3：只取前 3（9/8/7），且无 OHLC 区间排除
    final rows3 = classifyProfilePeaks(
      profile: _profile(prices, totals),
      low: low,
      high: high,
      close: close,
      rank: PeakRankConfig(mode: PeakRankMode.pure, maxPureRank: 3),
    );
    expect(rows3.length, 3);
    expect(rows3.map((e) => e.price).toSet(), {11.0, 12.0, 13.0});
  });
}
