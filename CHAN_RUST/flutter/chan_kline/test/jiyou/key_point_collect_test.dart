import 'package:chan_kline/key_point_stats/key_point.dart';
import 'package:chan_kline/key_point_stats/key_point_collect.dart';
import 'package:chan_kline/models/k0_confirm_signal.dart';
import 'package:chan_kline/models/k0_line.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 造一段 K：highs / lows 给定，idx 从 0 递增。
List<KlineBar> _bars(List<double> highs, List<double> lows) {
  return [
    for (var i = 0; i < highs.length; i++)
      KlineBar(
        idx: i,
        timeMs: i * 60000,
        timeText: '2004/07/19 09:${(30 + i).toString().padLeft(2, '0')}:00',
        open: (highs[i] + lows[i]) / 2,
        high: highs[i],
        low: lows[i],
        close: (highs[i] + lows[i]) / 2,
        volume: 100 + i.toDouble(),
        amount: 1000 + i.toDouble(),
      ),
  ];
}

LevelBundle _level({
  required int level,
  List<LevelSegmentN> segments = const [],
  List<LevelConfirm> confirms = const [],
}) =>
    LevelBundle(level: level, segments: segments, confirms: confirms);

LevelSegmentN _seg({
  required int idx,
  required int dir,
  required int beginConfirmX,
  required int endConfirmX,
  required int beginPoleX,
  required int endPoleX,
}) =>
    LevelSegmentN(
      idx: idx,
      dir: dir,
      beginConfirmX: beginConfirmX,
      endConfirmX: endConfirmX,
      beginPoleX: beginPoleX,
      endPoleX: endPoleX,
    );

void main() {
  // highs: 1,5,9,7,3,2,6,10,4 → 最高在 idx2(9) 与 idx7(10)
// lows : 2,4,8,6,3,1,5,9,3 → 最低在 idx5(1)
  final bars = _bars([1, 5, 9, 7, 3, 2, 6, 10, 4], [2, 4, 8, 6, 3, 1, 5, 9, 3]);

  group('K0 连线转折点', () {
    test('TOP 取分型组内首个最高 high 所在 K', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: const [],
        k0Confirms: [
          K0ConfirmSignal(
            x: 5,
            fx: 'TOP',
            value: 1,
            fractalX1: 1,
            fractalX2: 7,
          ),
        ],
        asOf: bars.length - 1,
      );
      expect(r.keyPoints.length, 1);
      final p = r.keyPoints.first;
      expect(p.level, 0);
      expect(p.fx, 'TOP');
      expect(p.poleX, 7); // 10 > 9，取更高的那根
      expect(p.confirmX, 5);
      expect(p.source, 'k0_confirm');
    });

    test('BOTTOM 取分型组内首个最低 low 所在 K', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: const [],
        k0Confirms: [
          K0ConfirmSignal(
            x: 4,
            fx: 'BOTTOM',
            value: -1,
            fractalX1: 0,
            fractalX2: 5,
          ),
        ],
        asOf: bars.length - 1,
      );
      final p = r.keyPoints.first;
      expect(p.fx, 'BOTTOM');
      expect(p.poleX, 5); // low=1 是全局最低
    });

    test('确认当步在 asOf 之后 → 排除（进行中不算转折点）', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: const [],
        k0Confirms: [
          K0ConfirmSignal(x: 20, fx: 'TOP', value: 1, fractalX1: 6, fractalX2: 7),
        ],
        asOf: bars.length - 1,
      );
      expect(r.keyPoints, isEmpty);
      expect(r.skippedUnconfirmed, greaterThanOrEqualTo(1));
    });

    test('同层同 x 同方向去重（确认信号与连线端点指向同一点只留一条）', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: const [],
        k0Confirms: [
          K0ConfirmSignal(x: 5, fx: 'TOP', value: 1, fractalX1: 1, fractalX2: 7),
        ],
        k0Lines: [
          K0Line(
            idx: 0,
            dir: 1,
            beginConfirmX: 0,
            endConfirmX: 5,
            beginFractalX1: 0,
            beginFractalX2: 5,
            endFractalX1: 6,
            endFractalX2: 7,
          ),
        ],
        asOf: bars.length - 1,
      );
      final tops = r.keyPoints.where((e) => e.fx == 'TOP').toList();
      expect(tops.length, 1);
      expect(tops.first.poleX, 7);
      // 起点底是另一条，不参与去重
      final bottoms = r.keyPoints.where((e) => e.fx == 'BOTTOM').toList();
      expect(bottoms.length, 1);
      expect(bottoms.first.source, 'k0_line');
    });

    test('分型组越界找不到极值 → 跳过并计数', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: const [],
        k0Confirms: [
          K0ConfirmSignal(
            x: 3,
            fx: 'TOP',
            value: 1,
            fractalX1: 50,
            fractalX2: 60,
          ),
        ],
        asOf: bars.length - 1,
      );
      expect(r.keyPoints, isEmpty);
      expect(r.skippedNoPole, 1);
    });
  });
group('K{n} 连线转折点', () {
    test('向上段：起点为底、终点为顶', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 1,
            segments: [
              _seg(
                idx: 0,
                dir: 1,
                beginConfirmX: 0,
                endConfirmX: 5,
                beginPoleX: 0,
                endPoleX: 2,
              ),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      final p = r.keyPoints.where((e) => e.level == 1).toList();
      expect(p.length, 2);
      expect(p.first.fx, 'BOTTOM');
      expect(p.first.poleX, 0);
      expect(p.last.fx, 'TOP');
      expect(p.last.poleX, 2);
      expect(p.last.source, 'kn_segment');
    });

    test('向下段：起点为顶、终点为底', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 1,
            segments: [
              _seg(
                idx: 0,
                dir: -1,
                beginConfirmX: 3,
                endConfirmX: 6,
                beginPoleX: 2,
                endPoleX: 5,
              ),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      final p = r.keyPoints.where((e) => e.level == 1).toList();
      expect(p.first.fx, 'TOP');
      expect(p.last.fx, 'BOTTOM');
    });

    test('本层确认分型的 fx 优先于 dir 推断（交叉校验）', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 1,
            segments: [
              _seg(
                idx: 0,
                dir: 1,
                beginConfirmX: 0,
                endConfirmX: 5,
                beginPoleX: 0,
                endPoleX: 2,
              ),
            ],
            // 确认表说 endPoleX=2 是底（value=1），与 dir 推断的顶相反
            confirms: [
              LevelConfirm(x: 5, fx: 'BOTTOM', value: 1, poleX: 2),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      final endPoint =
          r.keyPoints.firstWhere((e) => e.level == 1 && e.poleX == 2);
      expect(endPoint.fx, 'BOTTOM');
    });

    test('进行中的段（endConfirmX > asOf）整段排除', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 1,
            segments: [
              _seg(
                idx: 0,
                dir: 1,
                beginConfirmX: 0,
                endConfirmX: 99,
                beginPoleX: 0,
                endPoleX: 2,
              ),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      expect(r.keyPoints.where((e) => e.level == 1), isEmpty);
      expect(r.skippedUnconfirmed, greaterThanOrEqualTo(1));
    });

    test('已确认但未成段的端点由 confirms 补进来', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 2,
            confirms: [
              LevelConfirm(x: 6, fx: 'TOP', value: -1, poleX: 7),
              LevelConfirm(x: 7, fx: 'BOTTOM', value: 1, poleX: 5),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      final p = r.keyPoints.where((e) => e.level == 2).toList();
      expect(p.length, 2);
      expect(p.every((e) => e.source == 'kn_confirm'), isTrue);
      expect(p.map((e) => e.poleX).toSet(), {5, 7});
    });

    test('confirms 无 poleX 时退回分型组扫极值', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 1,
            confirms: [
              LevelConfirm(
                x: 6,
                fx: 'TOP',
                value: -1,
                fractalX1: 5,
                fractalX2: 8,
              ),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      expect(r.keyPoints.single.poleX, 7);
    });

    test('多级别各自成组，输出按级别再按 x 升序', () {
      final r = collectKeyPoints(
        bars: bars,
        levels: [
          _level(
            level: 2,
            segments: [
              _seg(
                idx: 0,
                dir: 1,
                beginConfirmX: 0,
                endConfirmX: 5,
                beginPoleX: 4,
                endPoleX: 7,
              ),
            ],
          ),
          _level(
            level: 1,
            segments: [
              _seg(
                idx: 0,
                dir: 1,
                beginConfirmX: 0,
                endConfirmX: 5,
                beginPoleX: 0,
                endPoleX: 2,
              ),
            ],
          ),
        ],
        asOf: bars.length - 1,
      );
      expect(r.keyPoints.map((e) => e.level).toList(), [1, 1, 2, 2]);
      final lv2 = r.keyPoints.where((e) => e.level == 2).toList();
      expect(lv2.first.poleX < lv2.last.poleX, isTrue);
    });

    test('去重键：同层同 x 同方向视为同一点', () {
      const a = KeyPoint(level: 1, fx: 'TOP', poleX: 5, confirmX: 6, source: 'x');
      const b = KeyPoint(level: 1, fx: 'TOP', poleX: 5, confirmX: 7, source: 'y');
      const c = KeyPoint(level: 1, fx: 'BOTTOM', poleX: 5, confirmX: 6, source: 'x');
      const d = KeyPoint(level: 2, fx: 'TOP', poleX: 5, confirmX: 6, source: 'x');
      expect({a.dedupKey, b.dedupKey}.length, 1);
      expect({a.dedupKey, c.dedupKey}.length, 2);
      expect({a.dedupKey, d.dedupKey}.length, 2);
    });

    test('toJson 带 level/fx/pole_x/confirm_x/source', () {
      const p = KeyPoint(
        level: 1,
        fx: 'TOP',
        poleX: 5,
        confirmX: 6,
        source: 'kn_segment',
      );
      expect(p.toJson(), {
        'level': 1,
        'fx': 'TOP',
        'pole_x': 5,
        'confirm_x': 6,
        'source': 'kn_segment',
      });
      expect(p.sideLabel, 'K1 顶');
      expect(p.levelLabel, 'K1 连线');
      expect(p.isTop, isTrue);
    });
  });
}