import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/class1_bs_compute.dart';
import 'package:chan_kline/compute/class2_bs_compute.dart';
import 'package:chan_kline/compute/class_n_bs_compute.dart';
import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/compute/zs_signal_compute.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/models/bar_crosshair_feature.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/pipeline_delta.dart';
import 'package:chan_kline/models/presentation_cache.dart';
import 'package:flutter_test/flutter_test.dart';

List<KlineBar> _load002003() {
  final bridge = ChanBridge.instance;
  final root = bridge.defaultDataRoot();
  return bridge.loadKlines(
    dataRoot: root,
    code: '002003',
    beginDate: '2004/07/19 10:47:00',
    endDate: '2004/07/20 13:09:00',
    period: '1m',
  );
}

String _featSig(BarCrosshairFeature f) =>
    '${f.idx}|${f.weekday}|${f.mergeInnerSeq}|${f.mergeCount}|${f.mergeBoxSeq}|'
    '${f.combineFx}|${f.combineHigh}|${f.combineLow}|${f.fractalPeakDist}|'
    '${f.k1Idx}|${f.levels.length}|${f.zsHits.length}|'
    '${f.bs1Hits.map((h) => '${h.kn}${h.side}${h.label}@${h.x}').join(',')}';

String _bundleSig(KlineCombineBundle b) {
  final buy1 = collectBuy1EventsByKn(b)
      .entries
      .map((e) => '${e.key}:${e.value.map((p) => '${p.label}@${p.x}').join(',')}')
      .join(';');
  final sell1 = collectSell1EventsByKn(b)
      .entries
      .map((e) => '${e.key}:${e.value.map((p) => '${p.label}@${p.x}').join(',')}')
      .join(';');
  final buy2 = collectBuy2EventsByKn(b)
      .entries
      .map((e) => '${e.key}:${e.value.map((p) => '${p.label}@${p.x}').join(',')}')
      .join(';');
  final sell2 = collectSell2EventsByKn(b)
      .entries
      .map((e) => '${e.key}:${e.value.map((p) => '${p.label}@${p.x}').join(',')}')
      .join(';');
  final buyN = collectBuyNEventsByKn(b)
      .entries
      .map((e) => '${e.key}:${e.value.map((p) => '${p.label}@${p.x}').join(',')}')
      .join(';');
  final zs = collectZsFramesByKn(b)
      .entries
      .map((e) =>
          '${e.key}:${e.value.map((f) => '${f.x1}-${f.x2}/${f.isSure}').join(',')}')
      .join(';');
  final feats = b.barFeatures.map(_featSig).join('/');
  return 'n=${b.barFeatures.length}|k0c=${b.k0Confirms.length}|'
      'lv=${b.levels.length}|fr=${b.frames.length}|'
      'buy1=$buy1|sell1=$sell1|buy2=$buy2|sell2=$sell2|buyN=$buyN|'
      'zs=$zs|feats=$feats';
}

BarFeatureLookup _lookup(List<KlineBar> bars, KlineCombineBundle b) {
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
    zsK0Frames: b.zsK0Frames,
    subIndicators: buildSubIndicatorCatalog(
      chartMaxKn(levels: b.levels, k0Lines: b.k0Lines),
    ).toSet(),
  );
}

String _structSig(KlineCombineBundle b) {
  final zs = collectZsFramesByKn(b)
      .entries
      .map((e) =>
          '${e.key}:${e.value.map((f) => '${f.x1}-${f.x2}/${f.isSure}').join(',')}')
      .join(';');
  return 'k0c=${b.k0Confirms.length}|lv=${b.levels.length}|fr=${b.frames.length}|'
      'k1c=${b.k1CombineFrames.length}|zs=$zs';
}

void _assertBundlesEq(
  KlineCombineBundle a,
  KlineCombineBundle b,
  String tag,
) {
  expect(_bundleSig(a), _bundleSig(b), reason: tag);
}

void main() {
  late List<KlineBar> bars;

  setUpAll(() {
    bars = _load002003();
    expect(bars.length, greaterThan(28), reason: '检查 a_Data/002003');
    expect(
      ChanBridge.instance.supportsAppendDelta,
      isTrue,
      reason: '须重编并复制 chan_ffi.dll（chan_pipeline_append_delta）',
    );
  });

  test('Full Path == Delta Path · 002003 step24–28 + History/BS/副图/十字/ML', () {
    final fullSess = ChanPipelineSession.create(preferDelta: false);
    final deltaSess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(() {
      fullSess.dispose();
      deltaSess.dispose();
    });

    final buyHistF = <int, List<Buy1Frame>>{};
    final buyHistD = <int, List<Buy1Frame>>{};

    for (var step = 0; step <= 28; step++) {
      final visible = bars.sublist(0, step + 1);
      final fullB = fullSess.syncTo(visible);
      final deltaB = deltaSess.syncTo(visible);
      if (step < 24) continue;

      _assertBundlesEq(fullB, deltaB, 'step$step Full!=Delta');
      final golden = ChanBridge.instance.buildKlineCombineBundle(visible);
      _assertBundlesEq(deltaB, golden, 'step$step Delta!=golden Full');

      // History：一类 BS 会话追加（稳定键+x）两边应同序
      final liveF = collectBuy1EventsByKn(fullB)[0] ?? const [];
      final liveD = collectBuy1EventsByKn(deltaB)[0] ?? const [];
      final hf = buyHistF.putIfAbsent(0, () => <Buy1Frame>[]);
      final hd = buyHistD.putIfAbsent(0, () => <Buy1Frame>[]);
      mergeBuy1EventLog(hf, liveF, discoveryX: step);
      mergeBuy1EventLog(hd, liveD, discoveryX: step);
      expect(
        hf.map((e) => '${e.label}@${e.x}').join(','),
        hd.map((e) => '${e.label}@${e.x}').join(','),
        reason: 'step$step History buy1',
      );

      // 副图：K0 分型判断事件
      final jF = collectFractalJudgmentEvents(
        kn: 0,
        bars: visible,
        levels: fullB.levels,
        barFeatures: fullB.barFeatures,
      );
      final jD = collectFractalJudgmentEvents(
        kn: 0,
        bars: visible,
        levels: deltaB.levels,
        barFeatures: deltaB.barFeatures,
      );
      expect(
        jF.map((e) => '${e.x}|${e.fx}|${e.fractalX1}-${e.fractalX2}').join(','),
        jD.map((e) => '${e.x}|${e.fx}|${e.fractalX1}-${e.fractalX2}').join(','),
        reason: 'step$step 副图分型判断',
      );

      // 十字 + ML：Lookup 消费 cache.barFeatures
      final lookF = _lookup(visible, fullB);
      final lookD = _lookup(visible, deltaB);
      final rowF = lookF.at(step);
      final rowD = lookD.at(step);
      expect(rowF?['weekday'], rowD?['weekday'], reason: 'step$step 十字 weekday');
      expect(rowF?['combine_fx'], rowD?['combine_fx'], reason: 'step$step 十字 fx');
      expect(
        rowF?['merge_inner_seq'],
        rowD?['merge_inner_seq'],
        reason: 'step$step 十字 merge',
      );
      final mlF = MlFeatureFlat.flattenRow(rowF ?? const {});
      final mlD = MlFeatureFlat.flattenRow(rowD ?? const {});
      expect(mlF.keys.toList()..sort(), mlD.keys.toList()..sort(),
          reason: 'step$step ML keys');
      for (final k in mlF.keys) {
        expect(mlF[k], mlD[k], reason: 'step$step ML $k');
      }
    }
  });

  test('缩短可见前缀用当步仓，不 reset+replay', () {
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    sess.syncTo(bars.sublist(0, 29));
    expect(sess.cachedBundle.barFeatures.length, 29);
    final shortened = sess.syncTo(bars.sublist(0, 28));
    expect(shortened.barFeatures.length, 28);
    // Rust 仓保持最长前缀，再前进不必整段重放
    expect(sess.cachedBundle.barFeatures.length, 29);
    final golden = ChanBridge.instance.buildKlineCombineBundle(
      bars.sublist(0, 28),
    );
    expect(
      _structSig(shortened),
      _structSig(golden),
      reason: 'asof_keep step27 struct',
    );
    expect(shortened.barFeatures.last.idx, 27);
    final again = sess.syncTo(bars.sublist(0, 29));
    expect(again.barFeatures.length, 29);
  });

  test('asOf 无状态 Full 前缀 == 会话 Delta 仓', () {
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    for (final asOf in [24, 25, 26, 27, 28]) {
      final visible = bars.sublist(0, asOf + 1);
      final live = sess.syncTo(visible);
      final asOfBundle = ChanBridge.instance.buildKlineCombineBundle(visible);
      _assertBundlesEq(live, asOfBundle, 'asOf=$asOf');
    }
  });

  test('走完后 snapshotAt 历史步仍等于当时 Full asOf', () {
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    sess.syncTo(bars.sublist(0, 29));
    expect(sess.cache.asOfSnapshotCount, greaterThanOrEqualTo(29));
    for (final asOf in [24, 25, 26, 27, 28]) {
      final snap = sess.cache.snapshotAt(asOf);
      expect(snap, isNotNull, reason: 'snapshot asOf=$asOf');
      final golden = ChanBridge.instance.buildKlineCombineBundle(
        bars.sublist(0, asOf + 1),
      );
      // 历史当步仓只钉结构（不钉 bar_features）；末根 snapshotAt 仍是完整仓。
      if (asOf == 28) {
        _assertBundlesEq(snap!, golden, 'snapshot asOf=$asOf after live=28');
      } else {
        expect(
          _structSig(snap!),
          _structSig(golden),
          reason: 'snapshot struct asOf=$asOf after live=28',
        );
      }
    }
  });

  test('mergeDelta 拒绝错序（不改 Delta 语义）', () {
    final cache = PresentationCache();
    expect(
      () => cache.mergeDelta(
        PipelineDelta.fromJson({
          'idx': 1,
          'bar_feature': {'idx': 1, 'weekday': '周一'},
          'frames': [],
        }),
      ),
      throwsStateError,
    );
  });

  test('UI profiling：Delta vs Full decode/Lookup（002003 step28）', () {
    final prefix27 = bars.sublist(0, 28);
    final visible = bars.sublist(0, 29);
    final fullSess = ChanPipelineSession.create(preferDelta: false);
    final deltaSess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(() {
      fullSess.dispose();
      deltaSess.dispose();
    });

    final sw = Stopwatch()..start();
    fullSess.syncTo(visible);
    final tFullSync = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    deltaSess.syncTo(visible);
    final tDeltaSync = sw.elapsedMilliseconds;

    // 真实 UI：reset 回到 step27 后再点一步（只测单步 append，非整段 replay）
    fullSess.syncTo(prefix27);
    deltaSess.syncTo(prefix27);
    sw
      ..reset()
      ..start();
    fullSess.syncTo(visible);
    final tFullStep28 = sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    deltaSess.syncTo(visible);
    final tDeltaStep28 = sw.elapsedMicroseconds;

    sw
      ..reset()
      ..start();
    final look = _lookup(visible, deltaSess.cachedBundle);
    final tLookup = sw.elapsedMilliseconds;
    expect(look.at(28), isNotNull);
    expect(look.at(28)?['weekday'], isNotNull);

    // ignore: avoid_print
    print(
      'UI profile 002003: FullSync0..28=${tFullSync}ms '
      'DeltaSync0..28=${tDeltaSync}ms '
      'FullStep27→28=${tFullStep28}us DeltaStep27→28=${tDeltaStep28}us '
      'Lookup.build=${tLookup}ms feats=${deltaSess.cachedBundle.barFeatures.length}',
    );
  });

  test('UI profiling 较长前缀（002003 最多200根，真实步进）', () {
    final longBars = ChanBridge.instance.loadKlines(
      dataRoot: ChanBridge.instance.defaultDataRoot(),
      code: '002003',
      beginDate: '2004/07/19 10:47:00',
      endDate: '2004/08/19 15:00:00',
      period: '1m',
    );
    final n = longBars.length < 200 ? longBars.length : 200;
    expect(n, greaterThan(28));
    final visible = longBars.sublist(0, n);
    final prefix = longBars.sublist(0, n - 1);
    final fullSess = ChanPipelineSession.create(preferDelta: false);
    final deltaSess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(() {
      fullSess.dispose();
      deltaSess.dispose();
    });

    final sw = Stopwatch()..start();
    fullSess.syncTo(visible);
    final tFull = sw.elapsedMilliseconds;
    sw
      ..reset()
      ..start();
    deltaSess.syncTo(visible);
    final tDelta = sw.elapsedMilliseconds;
    _assertBundlesEq(
      fullSess.cachedBundle,
      deltaSess.cachedBundle,
      'long N=$n Full!=Delta',
    );

    fullSess.syncTo(prefix);
    deltaSess.syncTo(prefix);
    sw
      ..reset()
      ..start();
    fullSess.syncTo(visible);
    final tFullStep = sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    deltaSess.syncTo(visible);
    final tDeltaStep = sw.elapsedMicroseconds;

    sw
      ..reset()
      ..start();
    final look = _lookup(visible, deltaSess.cachedBundle);
    final tLookup = sw.elapsedMilliseconds;
    expect(look.at(n - 1), isNotNull);

    // ignore: avoid_print
    print(
      'UI profile 002003 N=$n: FullSync=${tFull}ms DeltaSync=${tDelta}ms '
      'FullLastStep=${tFullStep}us DeltaLastStep=${tDeltaStep}us '
      'Lookup.build=${tLookup}ms',
    );
  });
}
