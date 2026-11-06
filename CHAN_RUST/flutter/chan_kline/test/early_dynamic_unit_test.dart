import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/adjacent_ratio_compute.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/compute/k1_combine_compute.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/k1_bar.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
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

  /// 预锚动态单元的「高高」：区间 [x1,x2] 内 high 取最高 high，low 取最高 low。
  void expectHighHigh(LevelUnitBar u, List<KlineBar> bars) {
    final x1 = u.x1.clamp(0, bars.length - 1);
    final x2 = u.x2.clamp(0, bars.length - 1);
    var hi = double.negativeInfinity;
    var lo = double.negativeInfinity;
    for (var i = x1; i <= x2; i++) {
      if (bars[i].high > hi) hi = bars[i].high;
      if (bars[i].low > lo) lo = bars[i].low;
    }
    expect(u.high, closeTo(hi, 1e-9), reason: 'high 取区间最高');
    expect(u.low, closeTo(lo, 1e-9), reason: 'low 取区间最高的低');
    expect(u.close, closeTo(bars[x2].close, 1e-9));
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

  test('K0 首根：K1 有预锚 idx=0；关闭开关回到经典', () {
    final on = bundleOfPrefix(1);
    expect(on.levels, isNotEmpty);
    final l0 = on.levels[0];
    expect(l0.segments, isEmpty, reason: '首根尚无确认段');
    expect(l0.unitBars, isEmpty, reason: '首根尚无冻结单元');
    expect(l0.activeUnit, isNotNull, reason: '默认应出现预锚动态单元');
    expect(l0.activeUnit!.idx, 0);
    expect(l0.activeUnit!.x1, 0);
    expect(l0.activeUnit!.x2, 0, reason: '动态单元末端=当步K0');
    expectHighHigh(l0.activeUnit!, bars);
    expect(chartMaxKn(levels: on.levels), 2, reason: 'K1 窗口应可用');

    final k1Units = asOfLevelVirtualK1Bars(
      levels: on.levels,
      barFeatures: on.barFeatures,
      level: 0,
      asOf: 0,
    );
    expect(k1Units.length, 1);
    expect(k1Units.single.idx, 0);
    expect(k1Units.single.x2, 0);

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

    // 确认前一根：下一层尚未懒创建；本层预锚单元取「高高」
    final before = bundleOfPrefix(fx); // 取 [0, fx)，不含确认当根
    expect(before.levels.length, 1, reason: '首确认前不应创建结构层1');
    final preA = before.levels[0].activeUnit!;
    expect(preA.x2, fx - 1);
    expectHighHigh(preA, bars);

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
    expect(l1.activeUnit, isNotNull, reason: '首确认同根应出现 K2 预锚单元');
    expect(l1.activeUnit!.idx, 0);
    expect(l1.activeUnit!.x2, fx, reason: 'K2 动态单元末端=当根');
    expectHighHigh(l1.activeUnit!, bars);
    expect(chartMaxKn(levels: on.levels), 3, reason: 'K2 窗口应可用');

    final k2Units = asOfLevelVirtualK1Bars(
      levels: on.levels,
      barFeatures: on.barFeatures,
      level: 1,
      asOf: fx,
    );
    expect(k2Units.length, 1);
    expect(k2Units.single.idx, 0);
    expect(k2Units.single.x2, fx);

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
    for (final n in {0, 1, fx - 1}) {
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
    expect(candle.length, 1);
    expect(candle.single.idx, 0);

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
  test('层级早生成：K1 首分型前用预锚单元补一条构建中虚线', () {
    final full = bundleOfPrefix(bars.length);
    final fx = full.levels[0].segments.first.endConfirmX;
    final on = bundleOfPrefix(fx + 1);
    expect(on.levels[1].confirms, isEmpty, reason: '此刻 K1 尚未有确认段');

    List<K1Bar> unitsOf({required bool preAnchor}) => asOfLevelVirtualK1Bars(
          levels: on.levels,
          barFeatures: on.barFeatures,
          level: 1,
          asOf: fx,
          includeBuilding: true,
          includePreAnchor: preAnchor,
        );

    final unitsOn = unitsOf(preAnchor: true);
    expect(unitsOn, hasLength(1), reason: 'K1 此刻只有预锚动态单元');
    final linesOn = computeDisplayBuildingLines(
      bars: bars.sublist(0, fx + 1),
      asOf: fx,
      virtualUnits: unitsOn,
      frozenIdx: const {},
      levelConfirms: on.levels[1].confirms,
    );
    expect(linesOn, hasLength(1), reason: '开关开：首分型前应有一条构建中虚线');
    final line = linesOn.single;
    final pre = unitsOn.single;
    final lo = pre.x1.clamp(0, bars.length - 1);
    final hi = pre.x2.clamp(0, bars.length - 1);
    var trough = double.infinity;
    var peak = double.negativeInfinity;
    var troughX = lo;
    var peakX = lo;
    for (var i = lo; i <= hi; i++) {
      if (bars[i].low < trough) {
        trough = bars[i].low;
        troughX = i;
      }
      if (bars[i].high > peak) {
        peak = bars[i].high;
        peakX = i;
      }
    }
    final up = pre.dir > 0;
    expect(line.begin.barIdx, up ? troughX : peakX,
        reason: '起点钉在区间内方向出发极值（升=首次最低 low，降=首次最高 high）');
    expect(line.begin.price, closeTo(up ? trough : peak, 1e-9));
    expect(line.end.barIdx, up ? peakX : troughX,
        reason: '终点钉在区间内方向到达极值，不跟当根收盘');
    expect(line.end.price, closeTo(up ? peak : trough, 1e-9));
    expect(line.asSolid, isFalse, reason: '未确认段必须是虚线');

    final linesOff = computeDisplayBuildingLines(
      bars: bars.sublist(0, fx + 1),
      asOf: fx,
      virtualUnits: unitsOf(preAnchor: false),
      frozenIdx: const {},
      levelConfirms: on.levels[1].confirms,
    );
    expect(linesOff, isEmpty, reason: '开关关：经典口径不补首分型前虚线');
  });

  test('层级早生成：K1 步进到第 32 根时首条虚线仍钉在高高极值', () {
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
    expect(units, hasLength(1));
    final lines = computeDisplayBuildingLines(
      bars: wide,
      asOf: asOf,
      virtualUnits: units,
      frozenIdx: const {},
      levelConfirms: b.levels[1].confirms,
    );
    expect(lines, hasLength(1), reason: '第 32 根时首条虚线不得消失');
    final line = lines.single;
    expect(line.begin.barIdx, 0);
    expect(line.begin.price, closeTo(11.66, 1e-9));
    expect(line.end.barIdx, 21, reason: '终点钉在区间内首次最高 high 那根');
    expect(line.end.price, closeTo(11.89, 1e-9));
    expect(line.end.price, isNot(closeTo(wide[asOf].low, 1e-9)),
        reason: '不得落到当根最低价');
    expect(line.asSolid, isFalse);
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

  test('层级早生成：K2 合并帧同样跳过二级种子框首组', () async {
    final bridge = ChanBridge.instance;
    final wide = bridge
        .loadKlinesEx(
          dataRoot: bridge.defaultDataRoot(),
          code: code,
          beginDate: begin,
          endDate: '2025/09/30 15:00:00',
          period: period,
          tickSource: 'protocol',
        )
        .bars;
    const n = 136;
    const asOf = n - 1;
    final sub = wide.sublist(0, n);
    final b = bridge.buildKlineCombineBundle(sub, earlyDynamicUnit: true);
    final snap = levelSnapAt(b.barFeatures, level: 2, asOf: asOf);
    expect(snap, isNotNull, reason: 'K2 种子快照应已出现');
    expect(snap!.seedBoxSeq, 0);

    final vu = asOfLevelVirtualK1Bars(
      levels: b.levels,
      barFeatures: b.barFeatures,
      level: 1,
      asOf: asOf,
      includeBuilding: true,
    );
    final frames = computeK1CombineFrames(sub, vu);
    expect(frames, isNotEmpty);
    expect(frames.first.x1, snap.seedBoxX1);
    expect(frames.first.x2, snap.seedBoxX2);
    expect(frames.first.high, closeTo(snap.seedBoxHigh, 1e-9));
    expect(frames.first.low, closeTo(snap.seedBoxLow, 1e-9));

    final kept = combineFramesWithoutSeed(
      frames: frames,
      snap: snap,
      earlyDynamicUnit: true,
    );
    expect(kept.length, frames.length - 1,
        reason: 'K2 种子框首组同样跳过（全层同构）');
  });
}
