import 'package:chan_kline/compute/first_fractal_rule.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
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

  group('子窗口首分型逐对判定', () {
    test('双低 → 前一根判顶分型，不合并（顶点=前一根 high）', () {
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5),
        _f(2, 2, 9.1, 9.1),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out.length, 3);
      expect(out[0].fx, 'TOP');
      expect(out[0].high, 10.0);
      expect(out[0].x1, 0);
      expect(out[0].x2, 0);
      expect(out[0].count, 1);
      // 第二根不并入首框
      expect(out[1].x1, 1);
    });

    test('双高 → 前一根判底分型，不合并（顶点=前一根 low）', () {
      final frames = [
        _f(0, 0, 8.8, 8.8),
        _f(1, 1, 8.9, 8.9),
        _f(2, 2, 9.5, 9.5),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out[0].fx, 'BOTTOM');
      expect(out[0].low, 8.8);
      expect(out[0].count, 1);
    });

    test('包含关系 → 取高合并（high/low 各取 max）', () {
      final frames = [
        _f(0, 0, 10.0, 9.0),
        _f(1, 1, 9.5, 9.5),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      expect(out.length, 1);
      expect(out[0].high, 10.0);
      expect(out[0].low, 9.5);
      expect(out[0].count, 2);
      expect(out[0].x1, 0);
      expect(out[0].x2, 1);
    });

    test('顶底交替：idx=0 顶分型后，idx=1、idx=2 不再判分型', () {
      // 扁平分笔：10.0 9.5 9.1 8.8 8.9 9.5
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5),
        _f(2, 2, 9.1, 9.1),
        _f(3, 3, 8.8, 8.8),
        _f(4, 4, 8.9, 8.9),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      // idx0 → TOP；idx1 双低但同向丢弃；idx2 双低同向丢弃；
      // idx3 双高 → BOTTOM（与 TOP 交替）
      final tops = out.where((e) => e.fx == 'TOP').toList();
      final bottoms = out.where((e) => e.fx == 'BOTTOM').toList();
      expect(tops.length, 1);
      expect(bottoms.length, 1);
      expect(tops.first.x1, 0);
      expect(bottoms.first.x1, 3);
    });

    test('与标准首分型同向的候选被丢弃（交替铁律）', () {
      // 标准首分型已是 TOP（frames[1]），候选 idx0 也是 TOP → 丢弃
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5, fx: 'TOP'),
        _f(2, 2, 9.1, 9.1),
      ];
      final out = applyFirstPairFractalToFrames(
        frames,
        standardFirstFx: 'TOP',
      );
      expect(out.where((e) => e.fx == 'TOP').length, 1);
      expect(out[0].fx, 'UNKNOWN');
    });

    test('标准首分型之后的框原样保留', () {
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5),
        _f(2, 2, 9.1, 9.1, fx: 'BOTTOM'),
        _f(3, 3, 9.6, 9.6),
      ];
      final out = applyFirstPairFractalToFrames(frames);
      // idx0 判 TOP；idx1 与 TOP 同向丢弃；idx2 起为标准首分型段，原样
      expect(out[0].fx, 'TOP');
      final bottom = out.where((e) => e.fx == 'BOTTOM').toList();
      expect(bottom.length, 1);
      expect(bottom.first.x1, 2);
    });
  });
}
