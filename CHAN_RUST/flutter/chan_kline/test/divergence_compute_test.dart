import 'package:chan_kline/compute/divergence_compute.dart';
import 'package:chan_kline/compute/divergence_freeze_store.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/divergence_algo.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/models/zs_frame.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int i, {double c = 10, double h = 11, double l = 9, double v = 100}) {
  return KlineBar(
    idx: i,
    timeMs: i * 60000,
    timeText: 't$i',
    open: c,
    high: h,
    low: l,
    close: c,
    volume: v,
    amount: v * c,
  );
}

List<KlineBar> _bars(int n) => [for (var i = 0; i < n; i++) _bar(i)];

/// K0：确认上枢 + 两未确认 → 离开窗本枢=倒数第二未确认。
({List<KlineBar> bars, List<ZSFrame> zs}) _k0TwoZsLeaveWindow() {
  final bars = _bars(8);
  // unsure=[x1=1,x1=2] → 本=x1=1 endIdx=5；上=x1=0 endIdx=3
  final zs = [
    const ZSFrame(
      x1: 0,
      x2: 3,
      high: 11,
      low: 9,
      level: 0,
      isSure: true,
      endIdx: 3,
    ),
    const ZSFrame(
      x1: 1,
      x2: 5,
      high: 12,
      low: 8,
      level: 0,
      isSure: false,
      endIdx: 5,
    ),
    const ZSFrame(
      x1: 2,
      x2: 6,
      high: 12.5,
      low: 7.5,
      level: 0,
      isSure: false,
      endIdx: 6,
    ),
  ];
  return (bars: bars, zs: zs);
}

/// K1：可配置 active 包中/破枢；末段 idx 与 zs endIdx 对齐。
({List<KlineBar> bars, List<LevelBundle> levels}) _kn1Dyn({
  required int activeX2,
  required List<ZSFrame> zsFrames,
  double activeHigh = 9.5,
  double activeLow = 8.0,
  int activeIdx = 12,
  List<LevelSegmentN> extraSegs = const [],
}) {
  final bars = _bars(activeX2 + 1);
  final segs = <LevelSegmentN>[
    const LevelSegmentN(
      idx: 10,
      dir: -1,
      beginConfirmX: 0,
      endConfirmX: 2,
      beginPoleX: 0,
      endPoleX: 2,
      high: 11.0,
      low: 9.0,
    ),
    const LevelSegmentN(
      idx: 11,
      dir: 1,
      beginConfirmX: 2,
      endConfirmX: 3,
      beginPoleX: 2,
      endPoleX: 3,
      high: 10.5,
      low: 9.2,
    ),
    ...extraSegs,
  ];
  final active = LevelUnitBar(
    idx: activeIdx,
    dir: -1,
    x1: 3,
    x2: activeX2,
    high: activeHigh,
    low: activeLow,
  );
  final lv = LevelBundle(
    level: 1,
    segments: segs,
    zsFrames: zsFrames,
    activeUnit: active,
  );
  return (bars: bars, levels: [lv]);
}

void main() {
  test('副图 catalog 含 12 背驰算法×层；主图无背驰；无 turnrate', () {
    final sub = buildSubIndicatorCatalog(1);
    final divers = sub.where((e) => e.kind == SubIndicatorKind.divergence);
    expect(divers.length, DivergenceAlgoMeta.all.length * 2);
    expect(DivergenceAlgoMeta.all.length, 12);
    expect(
      divers.any((e) => e.diverAlgo == DivergenceAlgo.peak && e.kn == 0),
      isTrue,
    );
    expect(divers.any((e) => e.label.contains('turnrate')), isFalse);
    expect(divers.any((e) => e.label == 'K1背驰_斜率'), isTrue);
    expect(
      SubIndicatorKind.divergence.categoryLabel,
      '背驰',
    );

    final main = buildMainIndicatorCatalog(1);
    expect(
      main.any((e) => e.label.contains('背驰')),
      isFalse,
    );
  });

  test('默认 K0 副图层全选不含背驰', () {
    final def = defaultSubIndicatorsK0();
    expect(
      def.any((e) => e.kind == SubIndicatorKind.divergence),
      isFalse,
    );
  });

  test('单开放（无中枢判断）不启动背驰', () {
    final bars = _bars(6);
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 4,
        high: 11,
        low: 9,
        level: 0,
        isSure: false,
        endIdx: 4,
      ),
    ];
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zs,
      asOf: 4,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[4], 0);
    expect(amp.ratioAt[4], isNull);
  });

  test('离开窗激活后：包中则上/上上末有 diver/ratio', () {
    final f = _k0TwoZsLeaveWindow();
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: f.bars,
      zsK0Frames: f.zs,
      asOf: 5,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[5], isNot(0));
    expect(amp.inAt[5], isNotNull);
    expect(amp.outAt[5], isNotNull);
    expect(amp.ratioAt[5], isNotNull);
  });

  test('严格背驰率：力度不弱 → diver=-1', () {
    final f = _k0TwoZsLeaveWindow();
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: f.bars,
      zsK0Frames: f.zs,
      asOf: 5,
      config: const MathIndicatorConfig(divergenceRate: 0.0001),
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[5], -1);
    expect(amp.ratioAt[5], isNotNull);
  });

  test('asOf 早于事件步：无值', () {
    final f = _k0TwoZsLeaveWindow();
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: f.bars,
      zsK0Frames: f.zs,
      asOf: 2,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
    );
    // 离开窗仍可激活，但 endIdx=5 > asOf=2 → 本枢末段不可解析 → 无值
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[2], 0);
    expect(amp.ratioAt[2], isNull);
  });

  test('12 算法均有序列', () {
    final f = _k0TwoZsLeaveWindow();
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: f.bars,
      zsK0Frames: f.zs,
      asOf: 5,
    );
    expect(map.length, DivergenceAlgoMeta.all.length);
    for (final a in DivergenceAlgoMeta.all) {
      expect(map[a], isNotNull);
      expect(map[a]!.diverAt.length, f.bars.length);
    }
  });

  test('选段：包中→上/上上 endIdx；突破→本/上 endIdx', () {
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 4,
        high: 10,
        low: 8,
        level: 1,
        isSure: true,
        endIdx: 11,
      ),
      const ZSFrame(
        x1: 5,
        x2: 6,
        high: 9.5,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    final contained = selectDivergenceEndPair(
      zsList: zs,
      dynZs: zs.last,
      knHigh: 9.5,
      knLow: 8.0,
      dynKnEndIdx: 12,
    );
    expect(contained?.mode, 'contained');
    expect(contained?.inEnd, 10);
    expect(contained?.outEnd, 11);

    final broke = selectDivergenceEndPair(
      zsList: zs,
      dynZs: zs.last,
      knHigh: 11.0,
      knLow: 8.0,
      dynKnEndIdx: 12,
    );
    expect(broke?.mode, 'broke');
    expect(broke?.inEnd, 11);
    expect(broke?.outEnd, 12);
  });

  test('Kn≥1 包中：比较上枢末 vs 上上枢末（不用动态中枢末）', () {
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 4,
        high: 10,
        low: 8,
        level: 1,
        isSure: false,
        endIdx: 11,
      ),
      const ZSFrame(
        x1: 5,
        x2: 6,
        high: 9.5,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    // active 包在 dynZs 内 → pair 10 vs 11
    final fixture = _kn1Dyn(
      activeX2: 4,
      zsFrames: zs,
      activeHigh: 9.5,
      activeLow: 8.0,
      activeIdx: 12,
    );
    final map = computeDivergenceForLevel(
      displayKn: 1,
      bars: fixture.bars,
      levels: fixture.levels,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      asOf: 4,
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[4], isNot(0));
    expect(amp.inAt[4], isNotNull);
    expect(amp.outAt[4], isNotNull);
  });

  test('Kn≥1 突破：比较动态中枢末(active) vs 上枢末', () {
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 4,
        high: 10,
        low: 8,
        level: 1,
        isSure: false,
        endIdx: 11,
      ),
      const ZSFrame(
        x1: 5,
        x2: 6,
        high: 9.5,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    // active 上破 dynZs → pair 11 vs 12
    final fixture = _kn1Dyn(
      activeX2: 4,
      zsFrames: zs,
      activeHigh: 11.0,
      activeLow: 8.0,
      activeIdx: 12,
    );
    final map = computeDivergenceForLevel(
      displayKn: 1,
      bars: fixture.bars,
      levels: fixture.levels,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      asOf: 4,
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[4], isNot(0));
    expect(amp.inAt[4], isNotNull);
    expect(amp.outAt[4], isNotNull);
  });

  test('背驰冻结：包中态步进旧点仍在、新 x 追加', () {
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 4,
        high: 10,
        low: 8,
        level: 1,
        isSure: false,
        endIdx: 11,
      ),
      const ZSFrame(
        x1: 5,
        x2: 6,
        high: 9.5,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    final store = DivergenceFreezeStore();
    final step4 = _kn1Dyn(
      activeX2: 4,
      zsFrames: zs,
      activeHigh: 9.5,
      activeLow: 8.0,
    );
    mergeDivergenceForStep(
      store: store,
      mathStore: null,
      bars: step4.bars,
      levels: step4.levels,
      zsK0Frames: const [],
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      maxDisplayKn: 1,
      asOf: 4,
    );
    final s4 = store.series(1, DivergenceAlgo.amp)!;
    expect(s4.diverAt[4], isNot(0));
    final ratioAt4 = s4.ratioAt[4];
    expect(ratioAt4, isNotNull);

    final step5 = _kn1Dyn(
      activeX2: 5,
      zsFrames: zs,
      activeHigh: 9.5,
      activeLow: 8.0,
    );
    mergeDivergenceForStep(
      store: store,
      mathStore: null,
      bars: step5.bars,
      levels: step5.levels,
      zsK0Frames: const [],
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      maxDisplayKn: 1,
      asOf: 5,
    );
    final s5 = store.series(1, DivergenceAlgo.amp)!;
    expect(s5.diverAt[4], isNot(0));
    expect(s5.ratioAt[4], ratioAt4);
    expect(s5.diverAt[5], isNot(0));
    expect(s5.ratioAt[5], isNotNull);
  });

  test('两动态枢合并：本枢重映射后仍可算；历史格不变', () {
    final store = DivergenceFreezeStore();
    final zsBefore = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 4,
        high: 10,
        low: 8,
        level: 1,
        isSure: false,
        endIdx: 11,
      ),
      const ZSFrame(
        x1: 5,
        x2: 6,
        high: 9.5,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    final step4 = _kn1Dyn(
      activeX2: 4,
      zsFrames: zsBefore,
      activeHigh: 9.5,
      activeLow: 8.0,
    );
    mergeDivergenceForStep(
      store: store,
      mathStore: null,
      bars: step4.bars,
      levels: step4.levels,
      zsK0Frames: const [],
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      maxDisplayKn: 1,
      asOf: 4,
    );
    expect(store.ownSession(1).activeOwnX1, 3);
    final ratioAt4 = store.series(1, DivergenceAlgo.amp)!.ratioAt[4];

    store.setOwnSession(
      1,
      DivergenceOwnSession(
        activeOwnX1: 5,
        activeOwnRangeX1: 5,
        activeOwnRangeX2: 6,
      ),
    );
    final zsMerged = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 6,
        high: 10,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    // 合并后仅两框：包中需要上上 → dynIdx<2 无对；改用突破
    final step6 = _kn1Dyn(
      activeX2: 6,
      zsFrames: zsMerged,
      activeHigh: 11.0,
      activeLow: 8.0,
      activeIdx: 12,
    );
    mergeDivergenceForStep(
      store: store,
      mathStore: null,
      bars: step6.bars,
      levels: step6.levels,
      zsK0Frames: const [],
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      maxDisplayKn: 1,
      asOf: 6,
    );
    expect(store.ownSession(1).activeOwnX1, 3);
    final s6 = store.series(1, DivergenceAlgo.amp)!;
    expect(s6.ratioAt[4], ratioAt4);
    expect(s6.diverAt[6], isNot(0));
    expect(s6.inAt[6], isNotNull);
  });

  test('确认同拍可启动本枢（突破态）', () {
    final bars = _bars(6);
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 0,
        isSure: true,
        endIdx: 2,
      ),
      const ZSFrame(
        x1: 1,
        x2: 3,
        high: 10.5,
        low: 8.5,
        level: 0,
        isSure: true,
        endIdx: 3,
      ),
      const ZSFrame(
        x1: 3,
        x2: 5,
        high: 10,
        low: 9.5,
        level: 0,
        isSure: true,
        endIdx: 5,
      ),
    ];
    // K0 末 bar high=11 > dynZs high=10 → 突破；pair end 3 vs 5
    final map = computeDivergenceForLevel(
      displayKn: 0,
      bars: bars,
      zsK0Frames: zs,
      asOf: 5,
      confirmedX1ThisStep: {3},
      config: const MathIndicatorConfig(divergenceRate: 1e9),
    );
    final amp = map[DivergenceAlgo.amp]!;
    expect(amp.diverAt[5], isNot(0));
  });

  test('asOf 截断仓视图：右侧无未来读数', () {
    final store = DivergenceFreezeStore();
    final f = _k0TwoZsLeaveWindow();
    mergeDivergenceForStep(
      store: store,
      mathStore: null,
      bars: f.bars,
      levels: const [],
      zsK0Frames: f.zs,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      maxDisplayKn: 0,
      asOf: 5,
    );
    final truncated = truncateDivergenceMap(
      store.level(0)!,
      f.bars.length,
      asOf: 3,
    );
    final amp = truncated[DivergenceAlgo.amp]!;
    expect(amp.diverAt[3], 0);
    expect(amp.ratioAt[3], isNull);
    expect(amp.diverAt[5], 0);
    expect(amp.ratioAt[5], isNull);
  });

  /// MACD：+ + 0 - - + + -；in 段 [0,4] dir↑；out 段 [5,7] dir↓
  group('buildDivergenceMacdHighlight 四算法差异', () {
    const span = DivergenceCompareSpan(
      inSegIdx: 0,
      outSegIdx: 1,
      inLoX: 0,
      inHiX: 4,
      outLoX: 5,
      outHiX: 7,
      inBeginX: 0,
      inEndX: 4,
      outBeginX: 5,
      outEndX: 7,
      inDir: 1,
      outDir: -1,
      mode: 'broke',
    );
    // index: 0:+2, 1:+1, 2:0, 3:-1, 4:-2, 5:+3, 6:+1, 7:-4
    final macd = <double?>[2, 1, 0, -1, -2, 3, 1, -4];

    test('area：从端点同号连续，短于整段', () {
      final hl = buildDivergenceMacdHighlight(
        algo: DivergenceAlgo.area,
        span: span,
        macdHist: macd,
      )!;
      // in 从 begin=0 向右：2,1 同号后遇 0 断
      expect(hl.inXs, [0, 1]);
      // out 从 end=7 向左：-4 同号后遇 +1 断
      expect(hl.outXs, [7]);
      expect(hl.inPeakX, isNull);
      expect(hl.outPeakX, isNull);
    });

    test('peak：整段同向柱 + 峰值 x', () {
      final hl = buildDivergenceMacdHighlight(
        algo: DivergenceAlgo.peak,
        span: span,
        macdHist: macd,
      )!;
      expect(hl.inXs, [0, 1]); // dir↑ 只要 >0
      expect(hl.outXs, [7]); // dir↓ 只要 <0
      expect(hl.inPeakX, 0); // |2| 最大
      expect(hl.outPeakX, 7);
    });

    test('full_area：整段同向柱（可有空隙）', () {
      final hl = buildDivergenceMacdHighlight(
        algo: DivergenceAlgo.fullArea,
        span: span,
        macdHist: macd,
      )!;
      expect(hl.inXs, [0, 1]);
      expect(hl.outXs, [7]);
      expect(hl.inPeakX, isNull);
    });

    test('diff：整段全部非空柱', () {
      final hl = buildDivergenceMacdHighlight(
        algo: DivergenceAlgo.diff,
        span: span,
        macdHist: macd,
      )!;
      expect(hl.inXs, [0, 1, 2, 3, 4]);
      expect(hl.outXs, [5, 6, 7]);
      expect(hl.inPeakX, isNull);
    });
  });

  test('背驰_斜率：与连线斜率公式同源（取绝对值）', () {
    // 突破：in=上枢末#11 |slope|=|(10.5-9.2)/(3-2)|=1.3
    // out=active#12 |slope|=|(8-11)/(4-3)|=3
    final zs = [
      const ZSFrame(
        x1: 0,
        x2: 2,
        high: 11,
        low: 9,
        level: 1,
        isSure: true,
        endIdx: 10,
      ),
      const ZSFrame(
        x1: 3,
        x2: 4,
        high: 10,
        low: 8,
        level: 1,
        isSure: false,
        endIdx: 11,
      ),
      const ZSFrame(
        x1: 5,
        x2: 6,
        high: 9.5,
        low: 7.5,
        level: 1,
        isSure: false,
        endIdx: 12,
      ),
    ];
    final fixture = _kn1Dyn(
      activeX2: 4,
      zsFrames: zs,
      activeHigh: 11.0,
      activeLow: 8.0,
      activeIdx: 12,
    );
    final map = computeDivergenceForLevel(
      displayKn: 1,
      bars: fixture.bars,
      levels: fixture.levels,
      config: const MathIndicatorConfig(divergenceRate: 1e9),
      asOf: 4,
    );
    final s = map[DivergenceAlgo.lineSlope]!;
    expect(s.diverAt[4], isNot(0));
    expect(s.inAt[4], closeTo(1.3, 1e-9));
    expect(s.outAt[4], closeTo(3.0, 1e-9));
    expect(s.ratioAt[4], closeTo(3.0 / 1.3, 1e-9));
  });
}
