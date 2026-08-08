import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/k0_combine_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';

KlineBar _bar(int idx, double high, double low) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: (high + low) / 2,
    high: high,
    low: low,
    close: (high + low) / 2,
    volume: 1,
    amount: 1,
  );
}

void main() {
  test('K0合并：三根可产出合并框序列', () {
    final bars = [
      _bar(0, 20, 10),
      _bar(1, 18, 12),
      _bar(2, 25, 15),
    ];
    final frames = computeK0CombineFrames(bars, truncationCheck: false);
    expect(frames, isNotEmpty);
    expect(frames.first.x1, 0);
    expect(frames.last.x2, lessThanOrEqualTo(2));
  });

  test('K0合并：半侧标志恒 false', () {
    final frames = computeK0CombineFrames([
      _bar(0, 10, 5),
      _bar(1, 12, 6),
    ]);
    for (final f in frames) {
      expect(f.endAtLeftHalf, isFalse);
      expect(f.startAtRightHalf, isFalse);
    }
  });

  test('空序列返回空', () {
    expect(computeK0CombineFrames(const []), isEmpty);
  });
}
