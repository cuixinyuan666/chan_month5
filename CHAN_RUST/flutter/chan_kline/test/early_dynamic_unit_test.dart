import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/adjacent_ratio_compute.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/k1_bar.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

/// 层级早生成动态单元（预锚）回归：
/// - 窗口可用数（chartMaxKn）只按“有单元”的最高结构层扩展，且夹到 16；
/// - K0 首根：K1 窗口有 idx=0 预锚动态单元；
/// - 父层首确认当根：本层 idx=0 冻结，下一层 idx=0 预锚动态；
/// - 开关关闭：以上全部回到经典口径。
void main() {
  const code = '002003';
  const period = '1m';
  const begin = '2025/09/29 09:30:00';
  const end = '2025/09/29 10:30:00';

  late List<KlineBar> bars;

  LevelUnitBar unit(int idx, {int x1 = 0, int x2 = 1, int confirmX = -1}) =>
      LevelUnitBar(
        idx: idx,
        dir: 1,
        x1: x1,
        x2: x2,
        high: 10,
        low: 9,
        confirmX: confirmX,
      );

  LevelBundle level(
    int lv, {
    List<LevelUnitBar> units = const [],
    LevelUnitBar? active,
  }) =>
      LevelBundle(
        level: lv,
        unitBars: units,
        activeUnit: active,
      );

  setUpAll(() async {
    final bridge = ChanBridge.instance;
    bridge.ensureInitialized();
    bars = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: code,
          beginDate: begin,
          endDate: end,
          period: period,
          tickSource: 'protocol',
        )
        .bars;
    expect(bars.length, greaterThan(10), reason: '测试窗口数据不足');
  });

  KlineCombineBundle bundleOfPrefix(int count, {bool earlyDynamicUnit = true}) =>
      ChanBridge.instance.buildKlineCombineBundle(
        bars.sublist(0, count),
        earlyDynamicUnit: earlyDynamicUnit,
      );

  /// 预锚动态单元的真实高低：
  /// high 取父层输入区间最高 high，low 取父层输入区间最低 low。
  /// 动态 K 的 x1 是分型极点，OHLC 输入起点则是父层首组 x1，两者不能混用。
  void expectRealRange(
    LevelUnitBar u,
    List<KlineBar> source, {
    int? inputStart,
  }) {
    final start = (inputStart ?? u.x1).clamp(0, source.length - 1);
    final end = u.x2.clamp(0, source.length - 1);
    var hi = double.negativeInfinity;
    var lo = double.infinity;
    for (var i = start; i <= end; i++) {
      if (source[i].high > hi) hi = source[i].high;
      if (source[i].low < lo) lo = source[i].low;
    }
    expect(u.high, closeTo(hi, 1e-9), reason: 'high 取区间最高');
    expect(u.low, closeTo(lo, 1e-9), reason: 'low 取区间最低');
    expect(u.close, closeTo(source[end].close, 1e-9));
  }

  test('chartMaxKn：有单元的最高层 +2，夹到 16；无单元退回经典', () {
    // 只有 level0 动态预锚 → K1 窗口可用（2）
    expect(
      chartMaxKn(levels: [level(0, active: unit(0, x2: 0))]),
      2,
    );
    // level0 确认单元 + level1 预锚 → K2 窗口可用（3）
    expect(
      chartMaxKn(levels: [
        level(0, units: [unit(0, confirmX: 2)]),
        level(1, active: unit(0, x2: 2)),
      ]),
      3,
    );
    // level1 已建但无任何单元（关闭开关/经典路径）→ 仍是 classic=2
    expect(
      chartMaxKn(levels: [
        level(0, units: [unit(0, confirmX: 2)]),
        level(1),
      ]),
      2,
    );
    // 多层有单元：仍受 16 上限保护
    final many = [
      for (var i = 0; i < 20; i++) level(i, units: [unit(0, confirmX: i + 1)]),
    ];
    expect(chartMaxKn(levels: many), 16);
    // 全空
    expect(chartMaxKn(levels: const []), 0);
  });

  test('K0 首根：K1 不出生；第 2 根起 K1 单元 idx=0 动态；关闭开关回到经典', () {
    // 2026-11-28 出生门槛（全层同构）：K0 合并框 idx=0 只有 1 根、未盖章 → K1 不出生。
    final on1 = bundleOfPrefix(1);
    expect(on1.levels, isNotEmpty);
    expect(on1.levels[0].segments, isEmpty);
    expect(on1.levels[0].unitBars, isEmpty);
    expect(on1.levels[0].activeUnit, isNull, reason: 'K1 单元 idx=0 不出生');
    expect(chartMaxKn(levels: on1.levels), 1, reason: 'K1 窗口不可用');
    expect(
      asOfLevelVirtualK1Bars(
        levels: on1.levels,
        barFeatures: on1.barFeatures,
        level: 0,
        asOf: 0,
      ),
      isEmpty,
    );

    final on = bundleOfPrefix(2);
    final l0 = on.levels[0];
    expect(l0.segments, isEmpty, reason: '尚无确认段');
    expect(l0.unitBars, isEmpty, reason: '尚无冻结单元');
    expect(l0.activeUnit, isNotNull, reason: 'K0 合并框 idx=0 含 2 根 → K1 单元 idx=0 动态出生');
    expect(l0.activeUnit!.idx, 0);
    expect(l0.activeUnit!.x1, 0);
    expect(l0.activeUnit!.x2, 1, reason: '动态单元末端=当步K0');
    expectRealRange(l0.activeUnit!, bars);
    expect(chartMaxKn(levels: on.levels), 2, reason: 'K1 窗口应可用');

    final k1Units = asOfLevelVirtualK1Bars(
      levels: on.levels,
      barFeatures: on.barFeatures,
      level: 0,
      asOf: 1,
    );
    expect(k1Units.length, 1);
    expect(k1Units.single.idx, 0);
    expect(k1Units.single.x2, 1);

    final off = bundleOfPrefix(1, earlyDynamicUnit: false);
    expect(off.levels[0].activeUnit, isNull, reason: '关闭后首根无动态单元');
    expect(chartMaxKn(levels: off.levels), 1, reason: 'K1 窗口应不可用');
    expect(
      asOfLevelVirtualK1Bars(
        levels: off.levels,
        barFeatures: off.barFeatures,
        level: 0,
        asOf: 0,
      ),
      isEmpty,
    );
  });

  test('父层首确认当根：本层 idx=0 冻结 + 下一层预锚 idx=0；关闭时无', () {
    final full = bundleOfPrefix(bars.length);
    expect(full.levels, isNotEmpty);
    expect(full.levels[0].segments, isNotEmpty, reason: '全量应有K0连线');
    final first = full.levels[0].segments.first;
    final fx = first.endConfirmX;
    expect(fx, greaterThan(0));

    // 确认前一根：下一层尚未懒创建；本层预锚单元取真实高低。
    final before = bundleOfPrefix(fx); // 取 [0, fx)，不含确认当根
    expect(before.levels.length, 1, reason: '首确认前不应创建结构层1');
    final preA = before.levels[0].activeUnit!;
    expect(preA.x2, fx - 1);
    expectRealRange(
      preA,
      bars,
      inputStart: before.levels[0].combineFrames.first.x1,
    );

    // K0 首确认前：只有一条构建中虚线。
    // 升段两端取区间内首次最低 low → 首次最高 high（与首个分型后的开口虚线同口径）。
    final preBars = bars.sublist(0, fx);
    final k1Units = asOfK1Bars(
      bars: preBars,
      levels: before.levels,
      barFeatures: before.barFeatures,
      defaultK0Policy: 'pending',
      asOf: fx - 1,
      includeBuilding: true,
    );
    expect(k1Units.length, 1, reason: 'K0 首确认前只有预锚单元这一条');
    final k0Lines = computeDisplayBuildingLines(
      bars: preBars,
      asOf: fx - 1,
      virtualUnits: k1Units,
      frozenIdx: const {},
    );
    expect(k0Lines.length, 1, reason: '十字线回看不得多出第二条线');
    final pre = k1Units.single;
    var trough = double.infinity;
    var peak = double.negativeInfinity;
    final lo = pre.x1.clamp(0, preBars.length - 1);
    final hi = pre.x2.clamp(0, preBars.length - 1);
    for (var i = lo; i <= hi; i++) {
      if (preBars[i].low < trough) trough = preBars[i].low;
      if (preBars[i].high > peak) peak = preBars[i].high;
    }
    final up = pre.dir > 0;
    expect(k0Lines.single.begin.price, closeTo(up ? trough : peak, 1e-9),
        reason: '起点取区间内方向出发极值');
    expect(k0Lines.single.end.price, closeTo(up ? peak : trough, 1e-9),
        reason: '终点取区间内方向到达极值');
    expect(k0Lines.single.asSolid, isFalse);

    final on = bundleOfPrefix(fx + 1);
    expect(on.levels.length, greaterThanOrEqualTo(2));
    final l0 = on.levels[0];
    expect(l0.unitBars.first.idx, 0);
    expect(l0.unitBars.first.confirmX, fx, reason: '首确认当根冻结 idx=0');
    final l1 = on.levels[1];
    expect(l1.segments, isEmpty, reason: '结构层1自己的首分型尚未确认');
    // 2026-11-28 出生门槛：K1 合并框 idx=0 只有 1 个 K1 单元、未盖章 → K2 不出生。
    expect(l1.activeUnit, isNull, reason: 'K2 单元 idx=0 不出生');
    expect(chartMaxKn(levels: on.levels), 2, reason: 'K2 窗口不可用');
    final k2Units = asOfLevelVirtualK1Bars(
      levels: on.levels,
      barFeatures: on.barFeatures,
      level: 1,
      asOf: fx,
    );
    expect(k2Units, isEmpty);

    // 转正不重复：冻结单元 idx=0 只出现一次
    expect(l0.unitBars.where((u) => u.idx == 0).length, 1);

    // 确认当根恢复经典真实 OHLC（不是动态期的高高）
    final u0 = l0.unitBars.first;
    final s0 = l0.segments.first;
    expect(u0.high, closeTo(s0.high, 1e-9));
    expect(u0.low, closeTo(s0.low, 1e-9));
    var bodyLow = double.infinity;
    for (var i = s0.beginPoleX + 1; i <= s0.endPoleX; i++) {
      if (bars[i].low < bodyLow) bodyLow = bars[i].low;
    }
    final beginOpen = s0.dir > 0 ? s0.beginFractalLow : s0.beginFractalHigh;
    final expectedLow = bodyLow < beginOpen ? bodyLow : beginOpen;
    expect(u0.low, closeTo(expectedLow, 1e-9),
        reason: '确认段 low=min(段身最低, open)');

    // 无未来：前缀快照与长前缀同 bar 快照逐字段一致
    final long = full;
    // n=0：K1 未出生，前缀与长前缀快照都没有单元。
    expect(bundleOfPrefix(1).levels[0].activeUnit, isNull);
    expect(
      long.barFeatures
          .firstWhere((f) => f.idx == 0)
          .levels
          .firstWhere((s) => s.level == 0)
          .unitIdx,
      isNull,
    );
    for (final n in {1, fx - 1}) {
      final short = bundleOfPrefix(n + 1);
      final u = short.levels[0].activeUnit!;
      final snap = long.barFeatures
          .firstWhere((f) => f.idx == n)
          .levels
          .firstWhere((s) => s.level == 0);
      expect(snap.unitX2, u.x2);
      expect(snap.unitOpen, closeTo(u.open, 1e-9));
      expect(snap.unitHigh, closeTo(u.high, 1e-9));
      expect(snap.unitLow, closeTo(u.low, 1e-9));
      expect(snap.unitClose, closeTo(u.close, 1e-9));
      expect(snap.unitVolume, closeTo(u.volume, 1e-9));
    }

    final off = bundleOfPrefix(fx + 1, earlyDynamicUnit: false);
    expect(off.levels.length, greaterThanOrEqualTo(2));
    expect(off.levels[1].activeUnit, isNull, reason: '关闭后不得出现预锚单元');
    expect(chartMaxKn(levels: off.levels), 2, reason: '关闭后 K2 窗口应不可用');
  });

  test('预锚单元：蜡烛/合并框保留；相邻比例与经典连线口径不受影响', () {
    final full = bundleOfPrefix(bars.length);
    final fx = full.levels[0].segments.first.endConfirmX;
    final on = bundleOfPrefix(fx + 1);

    // 蜡烛路径：K2 窗口仍能看到 idx=0 预锚单元
    final candle = asOfLevelVirtualK1Bars(
      levels: on.levels,
      barFeatures: on.barFeatures,
      level: 1,
      asOf: fx,
    );
    expect(candle, isEmpty,
        reason: '2026-11-28 出生门槛：K1 首框只有 1 个单元、未盖章 → K2 不出生');

    // 经典连线口径（includePreAnchor=false）：同一时点不接收预锚单元
    final lineUnits = asOfLevelVirtualK1Bars(
      levels: on.levels,
      barFeatures: on.barFeatures,
      level: 1,
      asOf: fx,
      includePreAnchor: false,
    );
    expect(lineUnits, isEmpty, reason: '该层无确认段时不得把预锚单元当构建中段');

    final lines = computeDisplayBuildingLines(
      bars: bars.sublist(0, fx + 1),
      asOf: fx,
      virtualUnits: lineUnits,
      frozenIdx: const {},
    );
    expect(lines, isEmpty, reason: '没有连线单元就不应有构建中连线');

    // 相邻比例同源：不得出现预锚产生的虚线子线
    final ratio = buildRatioChildren(
      levels: on.levels,
      displayKn: 1,
      bars: bars.sublist(0, fx + 1),
      barFeatures: on.barFeatures,
      displayX: fx,
    );
    expect(ratio, isEmpty, reason: '相邻比例不得凭空多出预锚子线');

    // 有确认段后：连线单元与蜡烛单元一致，构建中段照常保留
    if (full.levels.length > 1 && full.levels[1].segments.isNotEmpty) {
      final fx2 = full.levels[1].segments.first.endConfirmX;
      final later = bundleOfPrefix(fx2 + 1);
      List<int> idxOf({required bool preAnchor}) => asOfLevelVirtualK1Bars(
            levels: later.levels,
            barFeatures: later.barFeatures,
            level: 1,
            asOf: fx2,
            includePreAnchor: preAnchor,
          ).map((e) => e.idx).toList();
      expect(idxOf(preAnchor: false), idxOf(preAnchor: true),
          reason: '有确认段后，预锚开关不应影响连线单元');
    }
  });

  test('种子相绘制开关：仅层级早生成开启时隐藏', () {
    expect(seedPhaseVisible(earlyDynamicUnit: true), isFalse,
        reason: '开关开：种子框/开口/ABC 不画');
    expect(seedPhaseVisible(earlyDynamicUnit: false), isTrue,
        reason: '开关关：经典种子绘制照旧');
  });

  /// 本轮口径（2026-11-06）：首个分型确认前，本层构建中虚线由预锚动态单元接管。
  /// 升段两端取区间内首次最低 low → 首次最高 high，与首个分型之后的开口虚线同一套扫价；
  /// 开关关时保持经典口径（不补线）。
  test('层级早生成：K0 首确认当根 K2 不出生，K1 首分型前无构建中虚线（2026-11-28）', () {
    final full = bundleOfPrefix(bars.length);
    final fx = full.levels[0].segments.first.endConfirmX;
    final on = bundleOfPrefix(fx + 1);
    expect(on.levels[1].confirms, isEmpty);
    for (final pre in [true, false]) {
      final units = asOfLevelVirtualK1Bars(
        levels: on.levels,
        barFeatures: on.barFeatures,
        level: 1,
        asOf: fx,
        includeBuilding: true,
        includePreAnchor: pre,
      );
      expect(units, isEmpty, reason: 'K1 合并框 idx=0 只有 1 个单元、未盖章 → K2 不出生');
      final lines = computeDisplayBuildingLines(
        bars: bars.sublist(0, fx + 1),
        asOf: fx,
        virtualUnits: units,
        frozenIdx: const {},
        levelConfirms: on.levels[1].confirms,
      );
      expect(lines, isEmpty);
    }
  });

  test('层级早生成：K0 idx=32 时 K2 单元 idx=0 = K1 合并框 idx=0 合成（2026-11-28）', () {
    final bridge = ChanBridge.instance;
    final wide = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: '002003',
          beginDate: '2004/07/19 10:47:00',
          endDate: '2004/07/20 13:09:00',
          period: '1m',
          tickSource: 'file',
        )
        .bars;
    const asOf = 32;
    final b = bridge.buildKlineCombineBundle(wide.sublist(0, asOf + 1),
        earlyDynamicUnit: true);
    final lv1 = b.levels.firstWhere((l) => l.level == 1);
    expect(lv1.combineFrames, hasLength(1));
    expect([lv1.combineFrames.first.x1, lv1.combineFrames.first.x2], [0, 21]);
    expect(lv1.combineFrames.first.fx, 'UNKNOWN');
    expect(lv1.segments, isEmpty);
    expect(lv1.confirms, isEmpty);
    final units = asOfLevelVirtualK1Bars(
      levels: b.levels,
      barFeatures: b.barFeatures,
      level: 1,
      asOf: asOf,
      includeBuilding: true,
      includePreAnchor: true,
    );
    expect(units, hasLength(1));
    final u = units.single;
    expect([u.idx, u.dir, u.x1, u.x2], [0, 1, 0, 21], reason: '首框合成：时间 = 框左端到右端');
    expect([u.open, u.high, u.low, u.close], [11.66, 11.89, 11.66, 11.89]);
    final lines = computeDisplayBuildingLines(
      bars: wide,
      asOf: asOf,
      virtualUnits: units,
      frozenIdx: const {},
      levelConfirms: lv1.confirms,
    );
    expect(lines, hasLength(1));
    expect([lines.single.begin.barIdx, lines.single.end.barIdx], [0, 21]);
    expect(lines.single.begin.price, closeTo(11.66, 1e-9));
    expect(lines.single.end.price, closeTo(11.89, 1e-9));
    expect(lines.single.asSolid, isFalse);
  });

  test('层级早生成：首个分型判断不再带截断伪点（2004 数据）', () {
    final bridge = ChanBridge.instance;
    final wide = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: '002003',
          beginDate: '2004/07/19 10:47:00',
          endDate: '2004/07/20 13:09:00',
          period: '1m',
          tickSource: 'file',
        )
        .bars;
    const asOf = 58;
    final sub = wide.sublist(0, asOf + 1);
    final b = bridge.buildKlineCombineBundle(sub, earlyDynamicUnit: true);
    final units = asOfLevelVirtualK1Bars(
      levels: b.levels,
      barFeatures: b.barFeatures,
      level: 1,
      asOf: asOf,
      includeBuilding: true,
      includePreAnchor: true,
    );
    final js = collectFractalJudgmentEvents(
      kn: 1,
      bars: wide,
      levels: b.levels,
      barFeatures: b.barFeatures,
      asOf: asOf,
      truncationCheck: true,
    );
    expect(js, isNotEmpty, reason: '第 58 根应出现首个分型判断');
    // 2026-11-28：动态单元给 K1 合并框 idx=0（K0 idx 0..55）盖顶章即冻结 → K1 连线 idx=0 = 0→44。
    final seg0 = asOfLevelSegments(levels: b.levels, level: 1, asOf: asOf);
    expect(seg0.map((x) => [x.beginPoleX, x.endPoleX]).toList(), [[0, 44]]);
    // 2026-11-18（与 Rust `feed_guarded` 对齐）：首分型前禁用截断。
    // 旧实现在首两单元会盖一个 `truncated BOTTOM`（x=6），并据此画出
    // 「判断→判断」0→44 的实线；该伪分型已删除，首个真实判断在 x58。
    expect(js.any((e) => e.truncated), isFalse, reason: '首分型前不再有截断伪分型');
    expect(js, hasLength(1));
    expect(js.first.x, 58);
    expect(js.first.fx, 'TOP');
    final lines = computeDisplayBuildingLines(
      bars: wide,
      asOf: asOf,
      virtualUnits: units,
      frozenIdx: {for (final x in seg0) x.idx},
      levelConfirms: b.levels[1].confirms,
      liveJudgments: js,
    );
    final solid = lines.where((l) => l.asSolid).toList();
    final dash = lines.where((l) => !l.asSolid).toList();
    expect(solid, isEmpty, reason: '只有一个真实判断（当步开尖），还不是判断→判断实线');
    expect(dash, hasLength(1), reason: '开口仍是虚线');
    expect(dash.single.begin.barIdx, 44);
    expect(dash.single.begin.price, closeTo(11.97, 1e-9));
    // 开口端点：从末极点 K0 idx=44 扫到 asOf，取方向极值首次出现根（11.92@46）。
    expect(dash.single.end.barIdx, 46);
    expect(dash.single.end.price, closeTo(11.92, 1e-9));
  });

  test('层级早生成：K1 合并帧跳过本层种子框首组', () {
    final on = bundleOfPrefix(bars.length);
    final asOf = bars.length - 1;
    final snap = levelSnapAt(on.barFeatures, level: 1, asOf: asOf);
    expect(snap, isNotNull);
    expect(snap!.seedBoxSeq, 0, reason: 'K1 种子框应存在');

    final frames = on.k1CombineFrames;
    expect(frames, isNotEmpty);
    final first = frames.first;
    expect(first.x1, snap.seedBoxX1);
    expect(first.x2, snap.seedBoxX2);
    expect(first.high, closeTo(snap.seedBoxHigh, 1e-9));
    expect(first.low, closeTo(snap.seedBoxLow, 1e-9));

    final kept = combineFramesWithoutSeed(
      frames: frames,
      snap: snap,
      earlyDynamicUnit: true,
    );
    expect(kept.length, frames.length - 1, reason: '开关开：种子框首组被跳过');
    expect(kept.first.x1, frames[1].x1);
    expect(
      combineFramesWithoutSeed(
        frames: frames,
        snap: snap,
        earlyDynamicUnit: false,
      ),
      same(frames),
      reason: '开关关：经典种子口径保留原合并帧',
    );
  });

  test('层级早生成：K2 合并帧同样跳过二级种子框首组', () {
    // combineFramesWithoutSeed 全层同构：首帧与种子框同矩形 → 开关开跳过；
    // 高高扩框后不同矩形 → 保留；开关关 → 原样。
    // 展示轨首帧由 widget 内动态链/开口跨度单元管线生成，单测无法复刻，
    // 端到端覆盖由 inprocess_early_dynamic_unit 的 level2_seed_frame_skipped 承担。
    const snap = LevelSnap(
      level: 2,
      seedBoxSeq: 0,
      seedBoxX1: 10,
      seedBoxX2: 20,
      seedBoxHigh: 9.97,
      seedBoxLow: 9.50,
    );
    KlineCombineFrame frame(int x1, int x2, double h, double l) =>
        KlineCombineFrame(
          x1: x1,
          x2: x2,
          t1: '',
          t2: '',
          high: h,
          low: l,
          fx: 'UNKNOWN',
          count: x2 - x1 + 1,
        );

    final seedFirst =
        frame(snap.seedBoxX1, snap.seedBoxX2, snap.seedBoxHigh, snap.seedBoxLow);
    final next = frame(21, 24, 10.1, 9.4);

    // 同矩形 → 跳过首组
    final keptSame = combineFramesWithoutSeed(
      frames: [seedFirst, next],
      snap: snap,
      earlyDynamicUnit: true,
    );
    expect(keptSame, hasLength(1), reason: '同矩形种子首组应被跳过');
    expect(keptSame.single.x1, next.x1);

    // 高高扩框后与种子框不同矩形 → 保留（2026-11-19 新口径）
    final expanded = frame(0, 22, 10.2, 9.6);
    final keptDiff = combineFramesWithoutSeed(
      frames: [expanded, next],
      snap: snap,
      earlyDynamicUnit: true,
    );
    expect(keptDiff, hasLength(2), reason: '扩框后不同矩形，不再跳过');
    expect(keptDiff.first.x1, 0);

    // 开关关 → 原样保留
    final keptOff = combineFramesWithoutSeed(
      frames: [seedFirst, next],
      snap: snap,
      earlyDynamicUnit: false,
    );
    expect(keptOff, hasLength(2), reason: '开关关：经典种子口径保留原合并帧');
  });
}
