import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/adjacent_ratio_compute.dart';
import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/compute/k1_combine_compute.dart';
import 'package:chan_kline/compute/kn_clock_timeline.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';

import '../continuous_step_verify.dart';
import '../robot_verify_data.dart';
import '../robot_verify_flutter_test.dart';
import '../robot_verify_model.dart';
import '../robot_verify_suite_meta.dart';

const String kEarlyDynamic20261105SuiteId = 'early_dynamic_20261105';

/// 层级早生成动态单元（预锚）验收套件（2026-11-05）。
///
/// 验的是用户确认的时间线：
///  - K0 idx=0：K1 idx=0 以**动态态**存在（尚无任何确认段）。
///  - K0 首分型确认当根：K1 idx=0 确认、K1 idx=1 动态；
///    同一根 K2 idx=0 以动态态初生成。
///  - 递归：K1 首分型确认当根，K2 确认 + K3 idx=0 动态。
///  - 关闭开关：以上全部回到经典口径（bar0 无动态单元、首确认不提前给上层单元）。
///
/// 阶段：
///  1. `flutter_test_early_dynamic` —— 本轮新增/改写的单测。
///  2. `inprocess_early_dynamic_unit` —— 用主图同源管道逐前缀构建，
///     在真实 002003 数据上钉死上述时点；并做开关关闭对照。
///  3. `continuous_step_freeze` —— 自动挂载（逐根单步 vs 走完瘦包）。
Future<RobotVerifyPhase> runEarlyDynamicFlutterTestPhase({
  required String klineRoot,
}) {
  return runFlutterTestJsonPhase(
    phaseId: 'flutter_test_early_dynamic',
    workingDirectory: klineRoot,
    testPathArgs: [
      'test/early_dynamic_unit_test.dart',
      'test/k0_building_line_same_price_test.dart',
      'test/kn_clock_causality_test.dart',
    ],
  );
}

/// 阶段：预锚动态单元时间线（前缀构建 + 采样钟增量 + 开关对照）。
Future<RobotVerifyPhase> runEarlyDynamicInProcessPhase({String? klineRoot}) async {
  const phaseId = 'inprocess_early_dynamic_unit';

  try {
    ChanBridge.instance.ensureInitialized();
  } catch (e) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'ffi_init_failed', 'message': '$e'},
    );
  }
  final bridge = ChanBridge.instance;
  if (bridge.loadedFfiAbiVersion != kChanFfiAbiVersion) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {
        'error': 'ffi_abi_mismatch',
        'loaded': bridge.loadedFfiAbiVersion,
        'expected': kChanFfiAbiVersion,
      },
    );
  }

  final plan = await resolveRobotVerify002003LoadPlan(klineRoot: klineRoot);
  if (plan == null) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: true,
      skipped: true,
      skipReason: 'no_verify_data',
      details: {'attempts': lastRobotVerifyDataResolveAttempts()},
    );
  }

  final bars = loadRobotVerifyBars(plan: plan, period: '1m');
  if (bars.length < 60) {
    return RobotVerifyPhase(
      id: phaseId,
      ok: false,
      details: {'error': 'insufficient_bars', 'bars': bars.length},
    );
  }

  final checks = <RobotVerifyCheck>[];
  void add(String id, bool ok, [Map<String, Object?> data = const {}]) =>
      checks.add(RobotVerifyCheck(id: id, ok: ok, data: data));

  // 前缀构建与主图 `_bundleForVisible` 同源：只喂 [0, count)。
  KlineCombineBundle bundleOf(int count, {bool early = true}) =>
      bridge.buildKlineCombineBundle(
        bars.sublist(0, count),
        earlyDynamicUnit: early,
      );

  bool near(double a, double b) => (a - b).abs() <= 1e-9;

  /// 预锚「高高」：区间 [x1,x2] 内 high 取最高 high，low 取最高 low；
  /// close 取区间末根收盘（与 Rust `pre_anchor_unit_ohlcv` 同口径）。
  (bool, Map<String, Object?>) checkHighHigh(LevelUnitBar? u, {int? wantX2}) {
    if (u == null) return (false, {'error': 'no_unit'});
    final x1 = u.x1.clamp(0, bars.length - 1);
    final x2 = u.x2.clamp(0, bars.length - 1);
    var hi = double.negativeInfinity;
    var lo = double.negativeInfinity;
    for (var i = x1; i <= x2; i++) {
      if (bars[i].high > hi) hi = bars[i].high;
      if (bars[i].low > lo) lo = bars[i].low;
    }
    final ok = (wantX2 == null || u.x2 == wantX2) &&
        near(u.high, hi) &&
        near(u.low, lo) &&
        near(u.close, bars[x2].close);
    return (
      ok,
      {
        'x1': u.x1,
        'x2': u.x2,
        'wantX2': wantX2,
        'high': u.high,
        'maxHigh': hi,
        'low': u.low,
        'maxLow': lo,
        'close': u.close,
        'barClose': bars[x2].close,
      },
    );
  }

  // --- ① bar 0：K1 idx=0 动态存在 ---
  final on0 = bundleOf(1);
  final l0 = on0.levels.isEmpty ? null : on0.levels[0];
  final a0 = l0?.activeUnit;
  add(
    'bar0_pre_anchor_present',
    l0 != null &&
        l0.segments.isEmpty &&
        l0.unitBars.isEmpty &&
        a0 != null &&
        a0.idx == 0 &&
        a0.x1 == 0 &&
        a0.x2 == 0,
    {
      'segments': l0?.segments.length,
      'unitBars': l0?.unitBars.length,
      'activeIdx': a0?.idx,
      'activeX1': a0?.x1,
      'activeX2': a0?.x2,
      'activeDir': a0?.dir,
    },
  );
  add(
    'bar0_k1_window_available',
    chartMaxKn(levels: on0.levels) == 2,
    {'chartMaxKn': chartMaxKn(levels: on0.levels)},
  );
  final k1At0 = asOfLevelVirtualK1Bars(
    levels: on0.levels,
    barFeatures: on0.barFeatures,
    level: 0,
    asOf: 0,
  );
  add(
    'bar0_virtual_k1_has_pre_anchor',
    k1At0.length == 1 && k1At0.single.idx == 0 && k1At0.single.x2 == 0,
    {
      'count': k1At0.length,
      'idx': k1At0.isEmpty ? null : k1At0.single.idx,
      'x2': k1At0.isEmpty ? null : k1At0.single.x2,
    },
  );

  // --- ② 首确认当根：本层 idx=0 冻结、idx=1 动态，同时下一层 idx=0 预锚 ---
  final full = bundleOf(bars.length);
  final firstSeg = full.levels.isEmpty || full.levels[0].segments.isEmpty
      ? null
      : full.levels[0].segments.first;
  final fx = firstSeg?.endConfirmX ?? -1;
  add('first_confirm_probe_available', firstSeg != null && fx > 0,
      {'bars': bars.length, 'firstConfirmX': fx});
  if (firstSeg != null && fx > 0 && fx + 1 <= bars.length) {
    final before = bundleOf(fx);
    add(
      'before_first_confirm_no_next_level',
      before.levels.length == 1,
      {'levels': before.levels.length, 'prefix': fx},
    );
    final preA = before.levels.isEmpty ? null : before.levels[0].activeUnit;
    final (hh0, hh0Data) = checkHighHigh(preA, wantX2: fx - 1);
    add('pre_anchor_high_high_level0', hh0, hh0Data);

    final at = bundleOf(fx + 1);
    final al0 = at.levels.isEmpty ? null : at.levels[0];
    final al1 = at.levels.length < 2 ? null : at.levels[1];
    final au0 = al0?.activeUnit;
    final au1 = al1?.activeUnit;
    add(
      'first_confirm_unit0_frozen_once',
      al0 != null &&
          al0.unitBars.isNotEmpty &&
          al0.unitBars.first.idx == 0 &&
          al0.unitBars.first.confirmX == fx &&
          al0.unitBars.where((u) => u.idx == 0).length == 1,
      {
        'unitBars': al0?.unitBars.length,
        'firstConfirmX': al0 == null || al0.unitBars.isEmpty
            ? null
            : al0.unitBars.first.confirmX,
        'idx0Count':
            al0?.unitBars.where((u) => u.idx == 0).length,
      },
    );
    add(
      'first_confirm_next_unit_dynamic',
      au0 != null && au0.idx == 1,
      {'activeIdx': au0?.idx},
    );
    add(
      'first_confirm_next_level_pre_anchor',
      al1 != null &&
          al1.segments.isEmpty &&
          au1 != null &&
          au1.idx == 0 &&
          au1.x2 == fx,
      {
        'levels': at.levels.length,
        'segments': al1?.segments.length,
        'activeIdx': au1?.idx,
        'activeX2': au1?.x2,
      },
    );
    final (hh1, hh1Data) = checkHighHigh(au1, wantX2: fx);
    add('pre_anchor_high_high_level1', hh1, hh1Data);

    // 首确认当根起恢复确认段真实 OHLC（不是动态期的「高高」）。
    final u0 = al0 == null || al0.unitBars.isEmpty ? null : al0.unitBars.first;
    final s0 = al0 == null || al0.segments.isEmpty ? null : al0.segments.first;
    var handoffOk = u0 != null && s0 != null &&
        near(u0.high, s0.high) && near(u0.low, s0.low);
    var expectedLow = double.nan;
    if (s0 != null) {
      var bodyLow = double.infinity;
      for (var i = s0.beginPoleX + 1; i <= s0.endPoleX; i++) {
        if (bars[i].low < bodyLow) bodyLow = bars[i].low;
      }
      final open = s0.dir > 0 ? s0.beginFractalLow : s0.beginFractalHigh;
      expectedLow = bodyLow < open ? bodyLow : open;
      handoffOk = handoffOk && near(u0.low, expectedLow);
    }
    add('confirmed_handoff_real_ohlc', handoffOk, {
      'unitHigh': u0?.high,
      'segHigh': s0?.high,
      'unitLow': u0?.low,
      'segLow': s0?.low,
      'expectedLow': expectedLow,
      'preAnchorLow': preA?.low,
    });
    add(
      'first_confirm_k2_window_available',
      chartMaxKn(levels: at.levels) == 3,
      {'chartMaxKn': chartMaxKn(levels: at.levels)},
    );
    final k2AtFx = asOfLevelVirtualK1Bars(
      levels: at.levels,
      barFeatures: at.barFeatures,
      level: 1,
      asOf: fx,
    );
    add(
      'first_confirm_virtual_k2_has_pre_anchor',
      k2AtFx.length == 1 && k2AtFx.single.idx == 0 && k2AtFx.single.x2 == fx,
      {
        'count': k2AtFx.length,
        'idx': k2AtFx.isEmpty ? null : k2AtFx.single.idx,
        'x2': k2AtFx.isEmpty ? null : k2AtFx.single.x2,
      },
    );

    // 2026-11-06 口径：开关开时，本层首分型前由预锚单元补一条
    // open→close 构建中虚线；相邻比例仍不得凭空多出子线。
    final lineUnitsOn = asOfLevelVirtualK1Bars(
      levels: at.levels,
      barFeatures: at.barFeatures,
      level: 1,
      asOf: fx,
      includeBuilding: true,
      includePreAnchor: true,
    );
    final k1LinesOn = computeDisplayBuildingLines(
      bars: bars,
      asOf: fx,
      virtualUnits: lineUnitsOn,
      frozenIdx: const {},
      levelConfirms: al1?.confirms ?? const [],
    );
    final preUnit = lineUnitsOn.length == 1 ? lineUnitsOn.single : null;
    add(
      'first_confirm_line_units_with_pre_anchor',
      preUnit != null &&
          k1LinesOn.length == 1 &&
          k1LinesOn.single.begin.barIdx == preUnit.x1 &&
          near(k1LinesOn.single.begin.price, preUnit.open) &&
          k1LinesOn.single.end.barIdx == preUnit.x2 &&
          near(k1LinesOn.single.end.price, preUnit.close) &&
          !k1LinesOn.single.asSolid,
      {
        'units': lineUnitsOn.length,
        'lines': k1LinesOn.length,
        'unitOpen': preUnit?.open,
        'unitClose': preUnit?.close,
        'beginX': k1LinesOn.isEmpty ? null : k1LinesOn.single.begin.barIdx,
        'endX': k1LinesOn.isEmpty ? null : k1LinesOn.single.end.barIdx,
        'beginPrice': k1LinesOn.isEmpty ? null : k1LinesOn.single.begin.price,
        'endPrice': k1LinesOn.isEmpty ? null : k1LinesOn.single.end.price,
        'solid': k1LinesOn.isEmpty ? null : k1LinesOn.single.asSolid,
      },
    );
    // 开关关闭：经典口径不得补这条线。
    final lineUnitsOff = asOfLevelVirtualK1Bars(
      levels: at.levels,
      barFeatures: at.barFeatures,
      level: 1,
      asOf: fx,
      includeBuilding: true,
      includePreAnchor: false,
    );
    final k1LinesOff = computeDisplayBuildingLines(
      bars: bars,
      asOf: fx,
      virtualUnits: lineUnitsOff,
      frozenIdx: const {},
      levelConfirms: al1?.confirms ?? const [],
    );
    add('first_confirm_line_units_no_pre_anchor', k1LinesOff.isEmpty,
        {'units': lineUnitsOff.length, 'lines': k1LinesOff.length});
    final ratioAtFx = buildRatioChildren(
      levels: at.levels,
      displayKn: 1,
      bars: bars.sublist(0, fx + 1),
      barFeatures: at.barFeatures,
      displayX: fx,
    );
    add('first_confirm_ratio_no_pre_anchor', ratioAtFx.isEmpty,
        {'children': ratioAtFx.length});

    // 2026-11-06 口径：开关开时，合并帧首组与本层种子框同矩形 → 跳过；
    // 开关关时保留原样（经典种子口径）。
    final seed1 = levelSnapAt(at.barFeatures, level: 1, asOf: fx);
    final frames1 = at.k1CombineFrames;
    final firstFrame1 = frames1.isEmpty ? null : frames1.first;
    final seed1Matched = seed1 != null &&
        seed1.seedBoxSeq >= 0 &&
        firstFrame1 != null &&
        firstFrame1.x1 == seed1.seedBoxX1 &&
        firstFrame1.x2 == seed1.seedBoxX2 &&
        near(firstFrame1.high, seed1.seedBoxHigh) &&
        near(firstFrame1.low, seed1.seedBoxLow);
    final kept1 = combineFramesWithoutSeed(
      frames: frames1,
      snap: seed1,
      earlyDynamicUnit: true,
    );
    add(
      'first_confirm_seed_frame_skipped_level1',
      seed1Matched && kept1.length == frames1.length - 1,
      {
        'seedSeq': seed1?.seedBoxSeq,
        'seedX1': seed1?.seedBoxX1,
        'seedX2': seed1?.seedBoxX2,
        'frames': frames1.length,
        'kept': kept1.length,
        'matched': seed1Matched,
      },
    );
    final kept1Off = combineFramesWithoutSeed(
      frames: frames1,
      snap: seed1,
      earlyDynamicUnit: false,
    );
    add(
      'first_confirm_seed_frame_kept_when_off',
      kept1Off.length == frames1.length,
      {'frames': frames1.length, 'kept': kept1Off.length},
    );

    // 全层同构：K2 首组种子框同样跳过，且首分型前同样有预锚构建中虚线。
    BarCrosshairFeature? k2SeedFeat;
    for (final f in full.barFeatures) {
      for (final s in f.levels) {
        if (s.level == 2 && s.seedBoxSeq >= 0) {
          k2SeedFeat = f;
          break;
        }
      }
      if (k2SeedFeat != null) break;
    }
    var k2SeedSkipped = false;
    var k2LineBuilt = false;
    final k2Data = <String, Object?>{'found': k2SeedFeat != null};
    if (k2SeedFeat != null) {
      final asOf2 = k2SeedFeat.idx;
      final at2seed = bundleOf(asOf2 + 1);
      final snap2 = levelSnapAt(at2seed.barFeatures, level: 2, asOf: asOf2);
      final vu2 = asOfLevelVirtualK1Bars(
        levels: at2seed.levels,
        barFeatures: at2seed.barFeatures,
        level: 1,
        asOf: asOf2,
        includeBuilding: true,
      );
      final frames2 = computeK1CombineFrames(
        bars.sublist(0, asOf2 + 1),
        vu2,
      );
      final firstFrame2 = frames2.isEmpty ? null : frames2.first;
      final matched2 = snap2 != null &&
          snap2.seedBoxSeq >= 0 &&
          firstFrame2 != null &&
          firstFrame2.x1 == snap2.seedBoxX1 &&
          firstFrame2.x2 == snap2.seedBoxX2 &&
          near(firstFrame2.high, snap2.seedBoxHigh) &&
          near(firstFrame2.low, snap2.seedBoxLow);
      final kept2 = combineFramesWithoutSeed(
        frames: frames2,
        snap: snap2,
        earlyDynamicUnit: true,
      );
      k2SeedSkipped = matched2 && kept2.length == frames2.length - 1;

      final lv2 = at2seed.levels.where((l) => l.level == 2).toList();
      final units2 = asOfLevelVirtualK1Bars(
        levels: at2seed.levels,
        barFeatures: at2seed.barFeatures,
        level: 2,
        asOf: asOf2,
        includeBuilding: true,
        includePreAnchor: true,
      );
      final lines2 = computeDisplayBuildingLines(
        bars: bars,
        asOf: asOf2,
        virtualUnits: units2,
        frozenIdx: const {},
        levelConfirms: lv2.isEmpty ? const [] : lv2.first.confirms,
      );
      final pre2 = units2.length == 1 ? units2.single : null;
      k2LineBuilt = pre2 != null &&
          lines2.length == 1 &&
          lines2.single.begin.barIdx == pre2.x1 &&
          near(lines2.single.begin.price, pre2.open) &&
          lines2.single.end.barIdx == pre2.x2 &&
          near(lines2.single.end.price, pre2.close) &&
          !lines2.single.asSolid;
      k2Data.addAll({
        'asOf': asOf2,
        'seedSeq': snap2?.seedBoxSeq,
        'seedX1': snap2?.seedBoxX1,
        'seedX2': snap2?.seedBoxX2,
        'frames': frames2.length,
        'kept': kept2.length,
        'matched': matched2,
        'units': units2.length,
        'lines': lines2.length,
        'lineSolid': lines2.isEmpty ? null : lines2.single.asSolid,
        'lineBegin': lines2.isEmpty ? null : lines2.single.begin.price,
        'lineEnd': lines2.isEmpty ? null : lines2.single.end.price,
      });
    }
    add('level2_seed_frame_skipped', k2SeedSkipped, k2Data);
    add('level2_pre_confirm_building_line', k2LineBuilt, k2Data);

    // 无未来：短前缀的预锚单元与长前缀同 bar 快照逐字段一致。
    final noFutureDiffs = <String>[];
    for (final n in {0, 1, fx - 1}) {
      final short = n == fx - 1 ? before : bundleOf(n + 1);
      final u = short.levels.isEmpty ? null : short.levels[0].activeUnit;
      LevelSnap? snap;
      for (final f in full.barFeatures) {
        if (f.idx != n) continue;
        for (final s in f.levels) {
          if (s.level == 0) {
            snap = s;
            break;
          }
        }
        break;
      }
      if (u == null || snap == null) {
        noFutureDiffs.add('n=$n missing');
        continue;
      }
      if (snap.unitX1 != u.x1 ||
          snap.unitX2 != u.x2 ||
          !near(snap.unitOpen, u.open) ||
          !near(snap.unitHigh, u.high) ||
          !near(snap.unitLow, u.low) ||
          !near(snap.unitClose, u.close) ||
          !near(snap.unitVolume, u.volume)) {
        noFutureDiffs.add('n=$n fields');
      }
    }
    add('pre_anchor_no_future_snapshot', noFutureDiffs.isEmpty,
        {'diffs': noFutureDiffs});

    // --- ③ 递归：K1 首分型确认当根 → K2 确认 + K3 idx=0 预锚 ---
    final l1Seg = full.levels.length < 2 || full.levels[1].segments.isEmpty
        ? null
        : full.levels[1].segments.first;
    final fx2 = l1Seg?.endConfirmX ?? -1;
    add('second_level_confirm_probe_available', l1Seg != null && fx2 > fx,
        {'firstConfirmX': fx, 'secondLevelConfirmX': fx2});
    if (l1Seg != null && fx2 > 0 && fx2 + 1 <= bars.length) {
      final at2 = bundleOf(fx2 + 1);
      final bl1 = at2.levels.length < 2 ? null : at2.levels[1];
      final bl2 = at2.levels.length < 3 ? null : at2.levels[2];
      add(
        'second_confirm_unit0_frozen_once',
        bl1 != null &&
            bl1.unitBars.isNotEmpty &&
            bl1.unitBars.first.idx == 0 &&
            bl1.unitBars.first.confirmX == fx2 &&
            bl1.unitBars.where((u) => u.idx == 0).length == 1,
        {
          'unitBars': bl1?.unitBars.length,
          'firstConfirmX': bl1 == null || bl1.unitBars.isEmpty
              ? null
              : bl1.unitBars.first.confirmX,
        },
      );
      add(
        'second_confirm_level2_pre_anchor',
        bl2 != null &&
            bl2.segments.isEmpty &&
            bl2.activeUnit != null &&
            bl2.activeUnit!.idx == 0 &&
            bl2.activeUnit!.x2 == fx2,
        {
          'levels': at2.levels.length,
          'activeIdx': bl2?.activeUnit?.idx,
          'activeX2': bl2?.activeUnit?.x2,
        },
      );
      // 有确认段后：连线单元与蜡烛单元一致，构建中段照常保留。
      List<int> lineIdx() => asOfLevelVirtualK1Bars(
            levels: at2.levels,
            barFeatures: at2.barFeatures,
            level: 1,
            asOf: fx2,
            includePreAnchor: false,
          ).map((e) => e.idx).toList();
      List<int> candleIdx() => asOfLevelVirtualK1Bars(
            levels: at2.levels,
            barFeatures: at2.barFeatures,
            level: 1,
            asOf: fx2,
          ).map((e) => e.idx).toList();
      add(
        'second_confirm_line_keeps_building_unit',
        lineIdx().join(',') == candleIdx().join(','),
        {'line': lineIdx(), 'candle': candleIdx()},
      );
    }

    // --- ④ 开关关闭：经典口径零差异 ---
    final off0 = bundleOf(1, early: false);
    final offL0 = off0.levels.isEmpty ? null : off0.levels[0];
    add(
      'off_bar0_no_pre_anchor',
      offL0 != null && offL0.activeUnit == null,
      {'active': offL0?.activeUnit != null},
    );
    add(
      'off_bar0_window_classic',
      chartMaxKn(levels: off0.levels) == 1,
      {'chartMaxKn': chartMaxKn(levels: off0.levels)},
    );
    final offK1At0 = asOfLevelVirtualK1Bars(
      levels: off0.levels,
      barFeatures: off0.barFeatures,
      level: 0,
      asOf: 0,
    );
    add('off_bar0_no_virtual_k1', offK1At0.isEmpty,
        {'count': offK1At0.length});

    final offAt = bundleOf(fx + 1, early: false);
    final offL1 = offAt.levels.length < 2 ? null : offAt.levels[1];
    add(
      'off_first_confirm_no_next_level_active',
      offAt.levels.length >= 2 && offL1?.activeUnit == null,
      {
        'levels': offAt.levels.length,
        'active': offL1?.activeUnit != null,
      },
    );
    add(
      'off_first_confirm_window_classic',
      chartMaxKn(levels: offAt.levels) == 2,
      {'chartMaxKn': chartMaxKn(levels: offAt.levels)},
    );

    // 冻结结构（segments/unitBars）逐层同构：开关只影响 activeUnit，不得改确认结果
    final structDiffs = <String>[];
    if (at.levels.length != offAt.levels.length) {
      structDiffs.add('levels ${at.levels.length}/${offAt.levels.length}');
    }
    for (var i = 0; i < at.levels.length && i < offAt.levels.length; i++) {
      final a = at.levels[i];
      final b = offAt.levels[i];
      if (a.segments.length != b.segments.length) {
        structDiffs.add('L$i segN ${a.segments.length}/${b.segments.length}');
      }
      if (a.unitBars.length != b.unitBars.length) {
        structDiffs.add('L$i unitN ${a.unitBars.length}/${b.unitBars.length}');
      }
      final n = a.segments.length < b.segments.length
          ? a.segments.length
          : b.segments.length;
      for (var j = 0; j < n; j++) {
        final sa = a.segments[j];
        final sb = b.segments[j];
        if (sa.idx != sb.idx ||
            sa.beginPoleX != sb.beginPoleX ||
            sa.endPoleX != sb.endPoleX ||
            sa.dir != sb.dir) {
          structDiffs.add('L$i seg$j');
          break;
        }
      }
    }
    add('off_confirmed_structure_identical', structDiffs.isEmpty,
        {'diffs': structDiffs});
  }

  // --- ⑤ 采样钟：bar0 记到动态单元；首确认只记一次 idx=0，无重复 ---
  final sess = ChanPipelineSession.create(earlyDynamicUnit: true);
  final recorder = KnClockTimelineRecorder();
  final growing = <KlineBar>[];
  var walked = 0;
  try {
    for (var i = 0; i < bars.length; i++) {
      growing.add(bars[i]);
      final b = sess.syncTo(growing);
      recorder.record(i, b.levels);
      walked++;
    }
  } finally {
    sess.dispose();
  }
  final clock = recorder.timeline;
  final s0 = clock.at(0, 0);
  add(
    'clock_bar0_active_idx0',
    walked == bars.length &&
        s0.unitBars.isEmpty &&
        s0.activeUnit != null &&
        s0.activeUnit!.idx == 0 &&
        s0.activeUnit!.x2 == 0,
    {
      'walked': walked,
      'unitBars': s0.unitBars.length,
      'activeIdx': s0.activeUnit?.idx,
      'activeX2': s0.activeUnit?.x2,
    },
  );
  if (fx > 0) {
    final sf = clock.at(0, fx);
    add(
      'clock_first_confirm_once',
      sf.unitBars.where((u) => u.idx == 0).length == 1 &&
          sf.unitBars.isNotEmpty &&
          sf.unitBars.first.confirmX == fx,
      {
        'idx0Count': sf.unitBars.where((u) => u.idx == 0).length,
        'firstConfirmX':
            sf.unitBars.isEmpty ? null : sf.unitBars.first.confirmX,
      },
    );
    add(
      'clock_first_confirm_next_active',
      sf.activeUnit != null && sf.activeUnit!.idx == 1,
      {'activeIdx': sf.activeUnit?.idx},
    );
    final s1 = clock.at(1, fx);
    add(
      'clock_next_level_pre_anchor',
      s1.unitBars.isEmpty &&
          s1.activeUnit != null &&
          s1.activeUnit!.idx == 0 &&
          s1.activeUnit!.x2 == fx,
      {
        'unitBars': s1.unitBars.length,
        'activeIdx': s1.activeUnit?.idx,
        'activeX2': s1.activeUnit?.x2,
      },
    );
  }

  return RobotVerifyPhase(
    id: phaseId,
    ok: checks.every((c) => c.ok),
    details: {
      'bars': bars.length,
      'firstConfirmX': fx,
      'dataRoot': plan.dataRoot,
      'checks': checks.map((c) => c.toJson()).toList(),
    },
  );
}

/// 套件编排。
Future<List<RobotVerifyPhase>> runEarlyDynamic20261105Phases({
  required String klineRoot,
  bool runFlutterTest = true,
}) async {
  final phases = <RobotVerifyPhase>[];
  if (runFlutterTest) {
    phases.add(await runEarlyDynamicFlutterTestPhase(klineRoot: klineRoot));
  }
  phases.add(await runEarlyDynamicInProcessPhase(klineRoot: klineRoot));

  final meta = metaForSuite(kEarlyDynamic20261105SuiteId);
  if (meta?.continuousStepFreeze == true) {
    phases.add(await runContinuousStepFreezePhase(klineRoot: klineRoot));
  }
  return phases;
}
