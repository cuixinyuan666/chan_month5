import 'package:chan_kline/compute/profile_peak_classify.dart';
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
  test('峰编号：框内无号，下侧-1/-2，上侧+1', () {
    // 峰价：10.0(下)、10.5(框内)、11.0(框内)、12.0(上)、13.0(更上)
    // totals 需形成局部峰：两侧低、中间高
    final prices = [9.5, 10.0, 10.3, 10.5, 10.7, 11.0, 11.5, 12.0, 12.5, 13.0, 13.5];
    final totals = [1.0, 5.0, 1.0, 6.0, 1.0, 7.0, 1.0, 8.0, 1.0, 9.0, 1.0];
    final rows = classifyProfilePeaks(
      profile: _profile(prices, totals),
      low: 10.4,
      high: 11.2,
    );
    final labels = rows.map((e) => e.label('K0筹码峰')).toList();
    expect(labels.contains('K0筹码峰-1'), isTrue); // 10.0 最近下
    expect(labels.contains('K0筹码峰'), isTrue); // 框内
    expect(labels.contains('K0筹码峰+1'), isTrue); // 12.0 最近上
    expect(labels.contains('K0筹码峰+2'), isTrue); // 13.0
    final r = rows.firstWhere((e) => e.nameSuffix == '-1');
    expect(r.valueText(), contains('【10】'));
    expect(r.valueText(), contains('B：【'));
  });
}
