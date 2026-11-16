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

  group('首框与生长框比包含（2026-11-16 用户最终口径）', () {
    // 用户当前默认画板 5 根 1 分钟 K（a_Data/test/custom.1m.csv）：
    // K0 10.2/9.73、K1 10.0/9.91、K2 10.1/10.02、K3 10.13/10.06、K4 10.11/10.05。
    // 高高口径下首框应把与它含融的 K 全吃进去 = 前 4 根一框；K4 双低止步。
    List<KlineCombineFrame> fiveBars() => [
          _f(0, 0, 10.2, 9.73),
          _f(1, 1, 10.0, 9.91),
          _f(2, 2, 10.1, 10.02),
          _f(3, 3, 10.13, 10.06, fx: 'TOP'),
          _f(4, 4, 10.11, 10.05),
        ];

    test('高高：首框迭代并到前 4 根（x0..3，high=10.2，low=10.06）', () {
      final out = applyFirstPairFractalToFrames(
        fiveBars(),
        mergeMode: PreFirstFractalMode.highHigh,
      );
      expect(out.first.x1, 0);
      expect(out.first.x2, 3);
      expect(out.first.high, 10.2);
      expect(out.first.low, 10.06);
      expect(out.first.count, 4);
      // K4 双低止步，独立成框
      expect(out[1].x1, 4);
      expect(out.length, 2);
    });

    test('低低：首框按 min 口径生长，仍与相邻逐对语义一致', () {
      final out = applyFirstPairFractalToFrames(
        fiveBars(),
        mergeMode: PreFirstFractalMode.lowLow,
      );
      // 低低：框 high/low 都取最小 → 框收窄，K2 双高不再含融，首框仅前 2 根
      expect(out.first.x1, 0);
      expect(out.first.x2, 1);
      expect(out.first.high, 10.0);
      expect(out.first.low, 9.73);
    });

    test('含融链：第三根与前框含融时也一并并入（非仅相邻两两）', () {
      // 单调内缩三根，旧实现只并前两根，新实现应三根一框。
      final frames = [
        _f(0, 0, 10.0, 9.0),
        _f(1, 1, 9.8, 9.2),
        _f(2, 2, 9.6, 9.4),
        _f(3, 3, 8.0, 8.0),
      ];
      final out = applyFirstPairFractalToFrames(
        frames,
        mergeMode: PreFirstFractalMode.highHigh,
      );
      expect(out.first.x2, 2);
      expect(out.first.count, 3);
      expect(out.first.high, 10.0);
      expect(out.first.low, 9.4);
    });
  });
}
