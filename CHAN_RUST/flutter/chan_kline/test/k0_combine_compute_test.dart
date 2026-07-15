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
  test('K0合并：包含吸收后框覆盖多根', () {
    // 第二根被第一根包含 → 合并为一框 count=2；非 DOWN 向 absorb 取高高/高低
    final bars = [
      _bar(0, 20, 10),
      _bar(1, 18, 12), // 被包含
      _bar(2, 25, 15), // 向上突破 → 新组
    ];
    final frames = computeK0CombineFrames(bars, truncationCheck: false);
    expect(frames.length, greaterThanOrEqualTo(2));
    expect(frames.first.count, 2);
    expect(frames.first.x1, 0);
    expect(frames.first.x2, 1);
    expect(frames.first.high, 20);
    expect(frames.first.low, 12); // Up 向 absorb：low=max
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
