// 回归通道槽位自包含测试：不依赖离线分笔文件（002003 已从仓库移除）。
//
// 目的：验证增量 Lookup 的 `regress_mid/up/down_k{n}` 槽位与全量 build 完全一致，
// 覆盖「父层换段后旧段清空」与「asOf 视图只修当前柱」两条口径。
//
// 关键设计：合成 K0 折线（`synth_bars.dart`）只到「笔」，长期不出「线段」，
// 因此**手工注入**父层（level==1 = K1连线/线段）的合成段，让回归通道确定性出线。
// 每 [segLen] 根 K0 为一段、首尾相接，随 asOf 推进自然发生「父层换段」。
import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/incremental_lookup.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'synth_bars.dart';

const int kSegLen = 20;

/// 把 [base] 的父层（level==1 = K1连线）替换为按 [kSegLen] 首尾相接的合成段。
KlineCombineBundle _withSynthParent(KlineCombineBundle base, int visibleLen) {
  final segs = <LevelSegmentN>[];
  for (var x1 = 0; x1 + kSegLen <= visibleLen; x1 += kSegLen) {
    final x2 = x1 + kSegLen - 1;
    segs.add(
      LevelSegmentN(
        idx: x1 ~/ kSegLen,
        dir: 1,
        beginConfirmX: x1,
        endConfirmX: x2,
        beginPoleX: x1,
        endPoleX: x2,
      ),
    );
  }
  final levels = <LevelBundle>[];
  var replaced = false;
  for (final lv in base.levels) {
    if (lv.level == 1) {
      levels.add(LevelBundle(level: 1, segments: segs));
      replaced = true;
    } else {
      levels.add(lv);
    }
  }
  if (!replaced) levels.add(LevelBundle(level: 1, segments: segs));
  return KlineCombineBundle(
    frames: base.frames,
    k0Confirms: base.k0Confirms,
    barFeatures: base.barFeatures,
    k0Lines: base.k0Lines,
    k1Analysis: base.k1Analysis,
    k1Bars: base.k1Bars,
    k1CombineFrames: base.k1CombineFrames,
    defaultK0Policy: base.defaultK0Policy,
    defaultSegmentPolicies: base.defaultSegmentPolicies,
    levelSegments: base.levelSegments,
    levelVirtualUnits: base.levelVirtualUnits,
    levels: levels,
    zsK0Frames: base.zsK0Frames,
    buy1K0Frames: base.buy1K0Frames,
    sell1K0Frames: base.sell1K0Frames,
    buy2K0Frames: base.buy2K0Frames,
    sell2K0Frames: base.sell2K0Frames,
    buyNK0Frames: base.buyNK0Frames,
    sellNK0Frames: base.sellNK0Frames,
    bsVerdictK0Frames: base.bsVerdictK0Frames,
  );
}

Set<SubChartIndicator> _subs(KlineCombineBundle b) => buildSubIndicatorCatalog(
      chartMaxKn(levels: b.levels, k0Lines: b.k0Lines),
    ).toSet();

BarFeatureLookup _full(
  List<KlineBar> bars,
  KlineCombineBundle b, {
  int? asOf,
}) {
  return BarFeatureLookup.build(
    bars: bars,
    combineFrames: b.frames,
    k0Confirms: b.k0Confirms,
    barFeatures: b.barFeatures,
    k0Lines: b.k0Lines,
    k1Analysis: b.k1Analysis,
    levels: b.levels,
    k1CombineFrames: b.k1CombineFrames,
    buy1K0Frames: b.buy1K0Frames,
    sell1K0Frames: b.sell1K0Frames,
    buy2K0Frames: b.buy2K0Frames,
    sell2K0Frames: b.sell2K0Frames,
    buyNK0Frames: b.buyNK0Frames,
    sellNK0Frames: b.sellNK0Frames,
    subIndicators: _subs(b),
    asOf: asOf ?? (bars.isEmpty ? null : bars.last.idx),
    zsK0Frames: b.zsK0Frames,
  );
}

const List<int> _dknList = [0, 1, 2];
const List<String> _regressKeys = ['regress_mid', 'regress_up', 'regress_down'];

Object? _regressOf(BarFeatureLookup lk, int x, int dkn, String key) =>
    lk.at(x)?['sub']?['${key}_$dkn'];

void main() {
  final bars = synthZigzag(legs: 30, legLen: 6, step: 0.5); // 180 根

  KlineCombineBundle bundleAt(int n) => _withSynthParent(
        ChanBridge.instance.buildKlineCombineBundle(bars.sublist(0, n)),
        n,
      );

  test('合成父段能让回归通道出线（前置条件）', () {
    final n = 130;
    final full = _full(bars.sublist(0, n), bundleAt(n));
    final hits = <int>[];
    for (var x = 0; x < n; x++) {
      if (_regressOf(full, x, 0, 'regress_mid') != null) hits.add(x);
    }
    // 父段 [120,139] 尚未确认（endConfirmX=139>129），最后冻结段为 [100,119]
    expect(hits, isNotEmpty, reason: '合成父段未触发回归通道，测试将失去意义');
    expect(hits.first, 100, reason: '通道应起于最后冻结段起点 100');
    expect(hits.last, 129, reason: '通道应外推到 asOf=129');
  });

  test('逐格步进：增量回归通道槽位 == Full（含父层换段后旧段清空）', () {
    final seedN = 110;
    final inc = IncrementalBarFeatureLookup();
    inc.seedFromFull(
      bars: bars.sublist(0, seedN),
      bundle: bundleAt(seedN),
      subIndicators: _subs(bundleAt(seedN)),
    );

    var sawShrink = false;
    var sawNonEmpty = false;
    Set<int>? prevHits;

    for (var n = seedN + 1; n <= 178; n++) {
      final visible = bars.sublist(0, n);
      final bundle = bundleAt(n);
      inc.applyStep(bars: visible, bundle: bundle, subIndicators: _subs(bundle));

      final full = _full(visible, bundle);
      final hits = <int>{};

      for (var x = 0; x < n; x++) {
        for (final dkn in _dknList) {
          for (final key in _regressKeys) {
            expect(
              _regressOf(inc.toLookup(), x, dkn, key),
              _regressOf(full, x, dkn, key),
              reason: 'n=$n x=$x ${key}_$dkn',
            );
          }
        }
        if (_regressOf(full, x, 0, 'regress_mid') != null) hits.add(x);
      }

      if (hits.isNotEmpty) sawNonEmpty = true;
      if (prevHits != null && prevHits.isNotEmpty) {
        final lost = prevHits.difference(hits);
        if (lost.isNotEmpty) {
          sawShrink = true;
          // 旧段被清空的格子：增量必须也是 null（不能残留上一段的旧值）
          for (final x in lost) {
            expect(
              _regressOf(inc.toLookup(), x, 0, 'regress_mid'),
              isNull,
              reason: 'n=$n 旧段 x=$x 未清空',
            );
          }
        }
      }
      prevHits = hits;
    }

    expect(sawNonEmpty, isTrue, reason: '整轮步进中回归通道从未出现');
    expect(sawShrink, isTrue, reason: '整轮步进中未发生父层换段，未覆盖旧段清空');
  });

  test('asOf 视图：只修当前柱（== Full(asOf)），历史格不被改写', () {
    final seedN = 140;
    final inc = IncrementalBarFeatureLookup();
    inc.seedFromFull(
      bars: bars.sublist(0, seedN),
      bundle: bundleAt(seedN),
      subIndicators: _subs(bundleAt(seedN)),
    );
    // 引擎自身仓（步进态）——历史格必须保持它，asOf 视图不得整表回写
    final stepped = inc.toLookup();

    for (final asOf in [131, 139, 140, 141, 159, 160]) {
      final prefix = bars.sublist(0, asOf + 1);
      final asOfBundle = bundleAt(asOf + 1);
      final view = inc.asOfView(
        asOf: asOf,
        asOfBundle: asOfBundle,
        prefixBars: prefix,
      );
      final full = _full(prefix, asOfBundle, asOf: asOf);
      expect(view.at(asOf + 1), isNull, reason: 'asOf=$asOf 未来格泄漏');

      // 当前柱：回归通道三键 × 各层必须与按 asOf 重算的 Full 同
      for (final dkn in _dknList) {
        for (final key in _regressKeys) {
          expect(
            _regressOf(view, asOf, dkn, key),
            _regressOf(full, asOf, dkn, key),
            reason: 'asOf=$asOf 当前柱 ${key}_$dkn',
          );
        }
      }

      // 历史格（x<asOf）：不得被 asOf 视图改写，应保持引擎步进态
      for (var x = 0; x < asOf; x++) {
        for (final key in _regressKeys) {
          expect(
            _regressOf(view, x, 0, key),
            _regressOf(stepped, x, 0, key),
            reason: 'asOf=$asOf 历史 x=$x ${key}_0 被改写',
          );
        }
      }
    }
  });
}
