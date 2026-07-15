import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/kuaduan_compute.dart';
import 'package:chan_kline/models/level_models.dart';

LevelSegmentN _seg(int idx, double high, double low, {int pole1 = 0, int pole2 = 0}) {
  return LevelSegmentN(
    idx: idx,
    dir: 1,
    beginConfirmX: 0,
    endConfirmX: 0,
    beginPoleX: pole1 == 0 ? idx : pole1,
    endPoleX: pole2 == 0 ? idx : pole2,
    high: high,
    low: low,
  );
}

void main() {
  test('两组分离跨段中枢', () {
    final segs = [
      _seg(0, 20, 10, pole1: 0, pole2: 1),
      _seg(1, 22, 12, pole1: 2, pole2: 3),
      _seg(2, 21, 11, pole1: 4, pole2: 5),
      _seg(3, 35, 25, pole1: 6, pole2: 7), // 不重叠 → 闭合第一组
      _seg(4, 40, 30, pole1: 8, pole2: 9),
      _seg(5, 42, 32, pole1: 10, pole2: 11),
      _seg(6, 41, 31, pole1: 12, pole2: 13),
    ];
    final frames = computeKuaduanFrames(segs, 1);
    expect(frames.length, 2);
    expect(frames[0].low, 12.0); // ZG=max(low)
    expect(frames[0].high, 20.0); // ZD=min(high)
    expect(frames[0].count, 3);
    expect(frames[0].seq, 1);
    expect(frames[1].seq, 2);
    expect(frames[1].count, 4); // segs 3..6
  });

  test('延伸计入 count', () {
    final segs = [
      _seg(0, 20, 10),
      _seg(1, 22, 12),
      _seg(2, 21, 11),
      _seg(3, 25, 11), // 重叠 → 延伸
      _seg(4, 26, 10), // 重叠 → 延伸
      _seg(5, 40, 30), // 脱离
    ];
    final frames = computeKuaduanFrames(segs, 1);
    expect(frames.length, 1);
    expect(frames[0].count, 5);
    expect(frames[0].low, 12.0);
    expect(frames[0].high, 20.0);
  });

  test('部分相交应延伸不拆', () {
    final segs = [
      _seg(11, 12.25, 12.13),
      _seg(12, 12.33, 12.13),
      _seg(13, 12.33, 12.08),
      _seg(14, 12.18, 12.08), // 部分相交
      _seg(15, 12.18, 12.10),
      _seg(16, 12.17, 12.10),
      _seg(17, 12.17, 11.98),
      _seg(18, 12.08, 11.98), // 脱离
    ];
    final frames = computeKuaduanFrames(segs, 1);
    expect(frames.length, 1, reason: '部分相交应并成一个跨段中枢');
    expect(frames[0].count, 7);
    expect(frames[0].seq, 1);
  });

  test('不足三段返回空', () {
    expect(
      computeKuaduanFrames([
        _seg(0, 20, 10),
        _seg(1, 22, 12),
      ], 1),
      isEmpty,
    );
  });
}
