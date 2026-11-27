import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/wnmr_segment_compute.dart';
import 'package:chan_kline/models/level_models.dart';

LevelSegmentN _seg({
  required int idx,
  required int dir,
  required int beginConfirmX,
  required int endConfirmX,
  required double high,
  required double low,
}) {
  return LevelSegmentN(
    idx: idx,
    dir: dir,
    beginConfirmX: beginConfirmX,
    endConfirmX: endConfirmX,
    beginPoleX: beginConfirmX,
    endPoleX: endConfirmX,
    high: high,
    low: low,
  );
}

void main() {
  group('wnmrSegmentMarks', () {
    test('向上缺口 buy：前段 high < 后段 low', () {
      final marks = wnmrSegmentMarks([
        _seg(
          idx: 0,
          dir: -1,
          beginConfirmX: 0,
          endConfirmX: 4,
          high: 10,
          low: 8,
        ),
        _seg(
          idx: 1,
          dir: 1,
          beginConfirmX: 4,
          endConfirmX: 8,
          high: 16,
          low: 12,
        ),
      ]);

      expect(marks, hasLength(1));
      expect(marks.single.barIndex, 4);
      expect(marks.single.side, 'buy');
      expect(marks.single.price, 12);
    });

    test('向下缺口 sell：前段 low > 后段 high', () {
      final marks = wnmrSegmentMarks([
        _seg(
          idx: 0,
          dir: 1,
          beginConfirmX: 0,
          endConfirmX: 5,
          high: 20,
          low: 15,
        ),
        _seg(
          idx: 1,
          dir: -1,
          beginConfirmX: 5,
          endConfirmX: 9,
          high: 12,
          low: 7,
        ),
      ]);

      expect(marks, hasLength(1));
      expect(marks.single.barIndex, 5);
      expect(marks.single.side, 'sell');
      expect(marks.single.price, 12);
    });

    test('端点相接无信号：前段 high == 后段 low', () {
      final marks = wnmrSegmentMarks([
        _seg(
          idx: 0,
          dir: -1,
          beginConfirmX: 0,
          endConfirmX: 3,
          high: 10,
          low: 8,
        ),
        _seg(
          idx: 1,
          dir: 1,
          beginConfirmX: 3,
          endConfirmX: 7,
          high: 14,
          low: 10,
        ),
      ]);

      expect(marks, isEmpty);
    });

    test('区间重叠无信号', () {
      final marks = wnmrSegmentMarks([
        _seg(
          idx: 0,
          dir: 1,
          beginConfirmX: 0,
          endConfirmX: 6,
          high: 18,
          low: 10,
        ),
        _seg(
          idx: 1,
          dir: -1,
          beginConfirmX: 6,
          endConfirmX: 11,
          high: 16,
          low: 12,
        ),
      ]);

      expect(marks, isEmpty);
    });

    test('barIndex 等于前段 endConfirmX，不用极点或后段确认位', () {
      final marks = wnmrSegmentMarks([
        _seg(
          idx: 2,
          dir: 1,
          beginConfirmX: 1,
          endConfirmX: 6,
          high: 9,
          low: 4,
        ),
        _seg(
          idx: 3,
          dir: -1,
          beginConfirmX: 7,
          endConfirmX: 13,
          high: 3,
          low: 1,
        ),
      ]);

      expect(marks.single.barIndex, 6);
      expect(marks.single.side, 'sell');
      expect(marks.single.price, 3);
    });

    test('只传入当前已完成线段时，不会出现未来线段信号', () {
      final completed = [
        _seg(
          idx: 0,
          dir: -1,
          beginConfirmX: 0,
          endConfirmX: 4,
          high: 10,
          low: 8,
        ),
        _seg(
          idx: 1,
          dir: 1,
          beginConfirmX: 4,
          endConfirmX: 8,
          high: 16,
          low: 12,
        ),
      ];
      final future = _seg(
        idx: 2,
        dir: -1,
        beginConfirmX: 8,
        endConfirmX: 14,
        high: 11,
        low: 6,
      );

      final now = wnmrSegmentMarks(completed);
      final later = wnmrSegmentMarks([...completed, future]);

      expect(now, hasLength(1));
      expect(now.single.barIndex, 4);
      expect(now.map((m) => m.barIndex), isNot(contains(8)));
      expect(now.map((m) => m.barIndex), isNot(contains(future.endConfirmX)));
      expect(later, hasLength(2));
      expect(later.last.barIndex, 8);
      expect(later.last.side, 'sell');
    });
  });
}
