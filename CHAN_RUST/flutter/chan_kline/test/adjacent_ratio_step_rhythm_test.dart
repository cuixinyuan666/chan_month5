import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/adjacent_ratio_compute.dart';
import 'package:chan_kline/compute/step_rhythm_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/level_models.dart';

LevelSegmentN _seg({
  required int idx,
  required int dir,
  required int endConfirmX,
  required double begin,
  required double end,
  bool bootstrap = false,
}) {
  // 上：begin=低 end=高；下：begin=高 end=低
  final lo = begin < end ? begin : end;
  final hi = begin < end ? end : begin;
  return LevelSegmentN(
    idx: idx,
    dir: dir,
    beginConfirmX: endConfirmX - 1,
    endConfirmX: endConfirmX,
    beginPoleX: endConfirmX - 1,
    endPoleX: endConfirmX,
    open: begin,
    high: hi,
    low: lo,
    close: end,
    beginFractalHigh: dir < 0 ? begin : hi,
    beginFractalLow: dir > 0 ? begin : lo,
    endFractalHigh: dir > 0 ? end : hi,
    endFractalLow: dir < 0 ? end : lo,
    isBootstrap: bootstrap,
  );
}

LevelBundle _lv(int level, List<LevelSegmentN> segs, {LevelUnitBar? active}) {
  return LevelBundle(
    level: level,
    segments: segs,
    activeUnit: active,
  );
}

void main() {
  group('adjacent_ratio_compute', () {
    test('不足 2 段 → null', () {
      final levels = [
        _lv(0, [_seg(idx: 0, dir: 1, endConfirmX: 5, begin: 10, end: 12)]),
      ];
      expect(
        calcAdjacentRatioForStep(
          levels: levels,
          displayKn: 0,
          displayX: 5,
        ),
        isNull,
      );
    });

    test('仅一根进行中 → 不足 2 线 null', () {
      final levels = [
        _lv(
          0,
          const [],
          active: const LevelUnitBar(
            idx: 0,
            dir: 1,
            x1: 0,
            x2: 3,
            open: 10,
            high: 12,
            low: 10,
            close: 12,
          ),
        ),
      ];
      expect(
        calcAdjacentRatioForStep(
          levels: levels,
          displayKn: 0,
          displayX: 3,
        ),
        isNull,
      );
    });

    test('动态：prev 未确认亦可作分母（两根 active 形段）', () {
      // 无冻段：用两根虚拟——这里用已确认+进行中模拟动态对；
      // prev 不再要求 isSure（进行中/虚线可作分母）
      final levels = [
        _lv(
          0,
          [_seg(idx: 0, dir: 1, endConfirmX: 4, begin: 10, end: 12)],
          active: const LevelUnitBar(
            idx: 1,
            dir: -1,
            x1: 5,
            x2: 8,
            open: 12,
            high: 12,
            low: 9,
            close: 9,
          ),
        ),
      ];
      // 把 seg#0 当「动态」：把 isSure 路径绕开——用两根 Display 等价：
      // 直接测 addPair 语义：cur 为进行中时 prev 可为 sure 或动态
      final p = calcAdjacentRatioForStep(
        levels: levels,
        displayKn: 0,
        displayX: 8,
      );
      expect(p, isNotNull);
      expect(p!.ratio, closeTo(3 / 2, 1e-9));
    });

    test('出现链末两根 → 比值（虚实不论）', () {
      // 冻段 + active：按 beginX 取末两根
      final levels2 = [
        _lv(
          0,
          [_seg(idx: 0, dir: 1, endConfirmX: 4, begin: 10, end: 12)],
          active: const LevelUnitBar(
            idx: 1,
            dir: -1,
            x1: 5,
            x2: 8,
            open: 12,
            high: 12,
            low: 9,
            close: 9,
          ),
        ),
      ];
      final p = calcAdjacentRatioForStep(
        levels: levels2,
        displayKn: 0,
        displayX: 8,
      );
      expect(p, isNotNull);
      expect(p!.ratio, closeTo(3 / 2, 1e-9));
      expect(p.childDir, 'down');
    });

    test('分母为 0 跳过', () {
      final levels = [
        _lv(
          0,
          [_seg(idx: 0, dir: 1, endConfirmX: 4, begin: 10, end: 10)],
          active: const LevelUnitBar(
            idx: 1,
            dir: -1,
            x1: 5,
            x2: 6,
            open: 10,
            high: 11,
            low: 9,
            close: 9,
          ),
        ),
      ];
      expect(
        calcAdjacentRatioForStep(
          levels: levels,
          displayKn: 0,
          displayX: 6,
        ),
        isNull,
      );
    });

    test('末两根按 beginX：新开口为 cur', () {
      final levels = [
        _lv(0, [
          _seg(idx: 0, dir: 1, endConfirmX: 3, begin: 10, end: 12), // amp2
          _seg(idx: 1, dir: -1, endConfirmX: 8, begin: 12, end: 10), // amp2
        ], active: const LevelUnitBar(
          idx: 2,
          dir: 1,
          x1: 8,
          x2: 8,
          open: 10,
          high: 11,
          low: 10,
          close: 11,
        )),
      ];
      final p = calcAdjacentRatioForStep(
        levels: levels,
        displayKn: 0,
        displayX: 8,
      );
      expect(p, isNotNull);
      // 末两根：#1 amp2 与 #2 amp1 → 0.5
      expect(p!.ratio, closeTo(0.5, 1e-9));
      expect(p.curIdx, 2);
    });
  });

  group('step_rhythm_compute', () {
    test('不足交替序列 → null', () {
      final state = StepRhythmState();
      final levels = [
        _lv(0, [
          _seg(idx: 0, dir: 1, endConfirmX: 2, begin: 10, end: 12),
          _seg(idx: 1, dir: -1, endConfirmX: 4, begin: 12, end: 11),
        ]),
      ];
      expect(
        calcStepRhythmForStep(
          levels: levels,
          displayKn: 0,
          displayX: 4,
          state: state,
        ),
        isNull,
      );
    });

    test('normal 公式抽样（上升）标签从 0-0', () {
      final state = StepRhythmState()
        ..activeDir = 1
        ..a0 = 10
        ..anchorPoleX = 0
        ..windowOpen = true
        ..groupId = 0;
      final levels = [
        _lv(0, [
          _seg(idx: 0, dir: 1, endConfirmX: 2, begin: 10, end: 14),
          _seg(idx: 1, dir: -1, endConfirmX: 4, begin: 14, end: 12),
          _seg(idx: 2, dir: 1, endConfirmX: 6, begin: 12, end: 16),
        ]),
      ];
      final r = calcStepRhythmForStep(
        levels: levels,
        displayKn: 0,
        displayX: 6,
        state: state,
      );
      expect(r, isNotNull);
      expect(r!.lines, isNotEmpty);
      expect(r.lines.first.label, '0-0');
      // ratio = (14-12)/(14-10)=0.5；rhythm = 16-(16-10)*0.5=13
      expect(r.lines.first.ratio, closeTo(0.5, 1e-9));
      expect(r.lines.first.value, closeTo(13.0, 1e-9));
      expect(r.dir, 'up');
    });

    test('子顶分型确认后窗口关闭，本步不再产出', () {
      final state = StepRhythmState()
        ..activeDir = 1
        ..a0 = 10
        ..anchorPoleX = 0
        ..windowOpen = true
        ..groupId = 0;
      final levels = [
        _lv(
          0,
          [
            _seg(idx: 0, dir: 1, endConfirmX: 2, begin: 10, end: 14),
            _seg(idx: 1, dir: -1, endConfirmX: 4, begin: 14, end: 12),
            _seg(idx: 2, dir: 1, endConfirmX: 6, begin: 12, end: 16),
          ],
          // level1 本步顶分型 → 升组关窗
        ),
      ];
      // 注入 confirms：LevelBundle 需要带 confirms
      final levelsWithFx = [
        LevelBundle(
          level: 0,
          segments: levels.first.segments,
          confirms: const [
            LevelConfirm(x: 6, fx: 'TOP', value: -1, poleX: 5),
          ],
        ),
      ];
      final r = calcStepRhythmForStep(
        levels: levelsWithFx,
        displayKn: 0,
        displayX: 6,
        state: state,
      );
      expect(r, isNull);
      expect(state.windowOpen, isFalse);
    });

    test('父顶分型切降组，a0=极高，自本步开窗', () {
      final state = StepRhythmState()
        ..activeDir = 1
        ..a0 = 10
        ..windowOpen = false
        ..groupId = 0;
      final levels = [
        LevelBundle(
          level: 0,
          segments: [
            _seg(idx: 0, dir: -1, endConfirmX: 3, begin: 14, end: 12),
            _seg(idx: 1, dir: 1, endConfirmX: 5, begin: 12, end: 13),
            _seg(idx: 2, dir: -1, endConfirmX: 8, begin: 13, end: 11),
          ],
        ),
        LevelBundle(
          level: 1,
          segments: const [],
          confirms: const [
            LevelConfirm(
              x: 8,
              fx: 'TOP',
              value: -1,
              poleX: 0,
              fractalHigh: 14,
              fractalLow: 12,
            ),
          ],
        ),
      ];
      final r = calcStepRhythmForStep(
        levels: levels,
        displayKn: 0,
        displayX: 8,
        state: state,
      );
      expect(state.activeDir, -1);
      expect(state.a0, closeTo(14, 1e-9));
      expect(state.windowOpen, isTrue);
      expect(state.groupId, 1);
      expect(r, isNotNull);
      expect(r!.dir, 'down');
      expect(r.lines.first.label, '0-0');
    });
  });

  group('catalog', () {
    test('副图含 adjacentRatio；主图含 stepRhythm 且 displayLevel 正确', () {
      final subCat = buildSubIndicatorCatalog(2);
      final mainCat = buildMainIndicatorCatalog(2);
      final ratios =
          subCat.where((e) => e.kind == SubIndicatorKind.adjacentRatio);
      final rhythms =
          mainCat.where((e) => e.kind == MainIndicatorKind.stepRhythm);
      expect(ratios.map((e) => e.kn), [0, 1]);
      expect(rhythms.map((e) => e.kn), [0, 1]);
      expect(ratios.every((e) => e.displayLevel == e.kn), isTrue);
      expect(rhythms.every((e) => e.label.contains('节奏')), isTrue);
      expect(ratios.every((e) => e.label.contains('比例')), isTrue);
      expect(subCat.any((e) => e.label.contains('节奏')), isFalse);
    });

    test('默认 K0：副图含比例；主图含节奏（进 Kn指标层全选）', () {
      final dSub = defaultSubIndicatorsK0();
      final dMain = defaultMainIndicatorsK0();
      expect(dSub.any((e) => e.kind == SubIndicatorKind.adjacentRatio), isTrue);
      expect(dMain.any((e) => e.kind == MainIndicatorKind.stepRhythm), isTrue);
      final subLv0 = subIndicatorsForLevel(0, buildSubIndicatorCatalog(1));
      final mainLv0 = mainIndicatorsForLevel(0, buildMainIndicatorCatalog(1));
      expect(
          subLv0.any((e) => e.kind == SubIndicatorKind.adjacentRatio), isTrue);
      expect(
          mainLv0.any((e) => e.kind == MainIndicatorKind.stepRhythm), isTrue);
      expect(subLv0.any((e) => e.label.contains('节奏')), isFalse);
      expect(isDefaultDrawnMain(const MainChartIndicator.stepRhythm(0)),
          isFalse);
    });
  });
}
