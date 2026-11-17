import 'package:chan_kline/compute/first_fractal_rule.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:flutter_test/flutter_test.dart';

KlineCombineFrame _f(
  int x1,
  int x2,
  double high,
  double low, {
  String fx = 'UNKNOWN',
  int count = 1,
}) {
  return KlineCombineFrame(
    x1: x1,
    x2: x2,
    t1: 't$x1',
    t2: 't$x2',
    high: high,
    low: low,
    fx: fx,
    count: count,
    endAtLeftHalf: false,
    startAtRightHalf: false,
  );
}

void main() {
  group('相邻关系判定', () {
    test('双低 / 双高 / 包含', () {
      expect(fractalPairRel(10, 9, 9.5, 8.5), FractalPairRel.bothLower);
      expect(fractalPairRel(9.5, 8.5, 10, 9), FractalPairRel.bothHigher);
      // 内包含 / 外包含
      expect(fractalPairRel(10, 9, 9.5, 9.5), FractalPairRel.contained);
      expect(fractalPairRel(10, 9, 11, 8), FractalPairRel.contained);
      // 高低交叉（如 h 更高但 l 更低）也归入包含 —— 与引擎
      // `test_combine_range`（engine.rs:242）同序：先判包含，再判双高/双低，
      // 兜底 Combine。故「交叉」在本口径下不可达。
      expect(fractalPairRel(10, 9, 11, 8.5), FractalPairRel.contained);
    });
  });

  group('首框口径：真分型前全并一框（2026-11-17 用户确认，取代逐对判定）', () {
    test('无真首分型：整个序列并一框，fx 保持 UNKNOWN（不提前裂框）', () {
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5),
        _f(2, 2, 9.1, 9.1),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out.length, 1);
      expect(out.first.x1, 0);
      expect(out.first.x2, 2);
      expect(out.first.count, 3);
      // 高高：high / low 都取最大
      expect(out.first.high, 10.0);
      expect(out.first.low, 10.0);
      expect(out.first.fx, 'UNKNOWN');
    });

    test('有真首分型：并到分型帧（含）为止，fx 取引擎分型', () {
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5, fx: 'TOP'),
        _f(2, 2, 9.1, 9.1),
        _f(3, 3, 9.6, 9.6),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out.length, 3);
      expect(out.first.x2, 1);
      expect(out.first.count, 2);
      expect(out.first.high, 10.0);
      expect(out.first.low, 10.0);
      expect(out.first.fx, 'TOP');
      // 分型帧之后原样保留
      expect(out[1].x1, 2);
      expect(out[2].x1, 3);
    });

    test('低低：并框 high / low 都取最小', () {
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5),
        _f(2, 2, 9.1, 9.1),
      ];
      final out = applyFirstPairFractalToFrames(
        frames,
        mergeMode: PreFirstFractalMode.lowLow,
      );
      expect(out.length, 1);
      expect(out.first.high, 9.1);
      expect(out.first.low, 9.1);
    });

    test('只有一帧 / 首帧即分型：原样返回（无可并）', () {
      final one = [_f(0, 0, 10.0, 9.0)];
      expect(identical(applyFirstPairFractalToFrames(one), one), isTrue);
      final head = [
        _f(0, 0, 10.0, 9.0, fx: 'TOP'),
        _f(1, 1, 9.5, 9.5),
      ];
      expect(identical(applyFirstPairFractalToFrames(head), head), isTrue);
    });

    test('2026-11-17 现场：K1 第 8 根（新高）不再把首框裂成两个', () {
      // 改前：x0..3(10.33/10.10) 与 x3..7(10.38/10.26) 双高 → 裂成两框，
      // 首框下沿 10.26→10.10 塌回、样式由虚线变实线。改后：继续并成一框。
      final frames = [
        _f(0, 3, 10.33, 10.10),
        _f(3, 7, 10.38, 10.26),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out.length, 1);
      expect(out.first.x1, 0);
      expect(out.first.x2, 7);
      expect(out.first.high, 10.38);
      expect(out.first.low, 10.26);
      expect(out.first.fx, 'UNKNOWN');
    });

    test('2026-11-17 现场：真分型出现后才定型（并到分型帧）', () {
      final frames = [
        _f(0, 3, 10.33, 10.10),
        _f(3, 8, 10.38, 10.26, fx: 'TOP'),
        _f(8, 11, 10.32, 10.24),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out.length, 2);
      expect(out.first.x2, 8);
      expect(out.first.high, 10.38);
      expect(out.first.low, 10.26);
      expect(out.first.fx, 'TOP');
      expect(out[1].x1, 8);
    });

    test('用户画板 5 根：高高并到分型帧 = 前 4 根一框', () {
      final frames = [
        _f(0, 0, 10.2, 9.73),
        _f(1, 1, 10.0, 9.91),
        _f(2, 2, 10.1, 10.02),
        _f(3, 3, 10.13, 10.06, fx: 'TOP'),
        _f(4, 4, 10.11, 10.05),
      ];
      final out = applyFirstPairFractalToFrames(
        frames,
        mergeMode: PreFirstFractalMode.highHigh,
      );
      expect(out.length, 2);
      expect(out.first.x2, 3);
      expect(out.first.high, 10.2);
      expect(out.first.low, 10.06);
      expect(out.first.count, 4);
      expect(out.first.fx, 'TOP');
      expect(out[1].x1, 4);
    });
  });
}
