import 'dart:convert';

import 'package:chan_kline/indicator_search/search_core.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('RawScore ∞ 可 JSON 序列化', () {
    const s = RawScore(
      trades: 5,
      winRate: 1.0,
      payoff: double.infinity,
      profitFactor: double.infinity,
      netProfit: 1200,
    );
    final map = s.toJson();
    expect(map['payoff'], 'inf');
    expect(map['profitFactor'], 'inf');
    expect(() => jsonEncode(map), returnsNormally);

    final back = RawScore.fromJson(map);
    expect(back.payoff?.isInfinite, isTrue);
    expect(back.profitFactor?.isInfinite, isTrue);
  });
}
