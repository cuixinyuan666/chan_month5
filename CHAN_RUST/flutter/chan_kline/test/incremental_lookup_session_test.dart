import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/class1_bs_compute.dart';
import 'package:chan_kline/compute/class2_bs_compute.dart';
import 'package:chan_kline/compute/class_n_bs_compute.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/buy2_frame.dart';
import 'package:chan_kline/models/buy_n_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:chan_kline/models/sell2_frame.dart';
import 'package:chan_kline/models/sell_n_frame.dart';
import 'package:flutter_test/flutter_test.dart';

List<KlineBar> _load002003() {
  final bridge = ChanBridge.instance;
  return bridge.loadKlines(
    dataRoot: bridge.defaultDataRoot(),
    code: '002003',
    beginDate: '2004/07/19 10:47:00',
    endDate: '2004/07/20 13:09:00',
    period: '1m',
  );
}

Set<SubChartIndicator> _subs(KlineCombineBundle b) => buildSubIndicatorCatalog(
      chartMaxKn(levels: b.levels, k0Lines: b.k0Lines),
    ).toSet();

BarFeatureLookup _full(
  List<KlineBar> bars,
  KlineCombineBundle b, {
  Map<int, List<Buy1Frame>> buy1 = const {},
  Map<int, List<Sell1Frame>> sell1 = const {},
  Map<int, List<Buy2Frame>> buy2 = const {},
  Map<int, List<Sell2Frame>> sell2 = const {},
  Map<int, List<BuyNFrame>> buyN = const {},
  Map<int, List<SellNFrame>> sellN = const {},
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
    buy1HistoryByKn: buy1,
    sell1HistoryByKn: sell1,
    buy2HistoryByKn: buy2,
    sell2HistoryByKn: sell2,
    buyNHistoryByKn: buyN,
    sellNHistoryByKn: sellN,
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

Object? _norm(Object? v) {
  if (v is Map) {
    final items = v.entries
        .map((e) => MapEntry(e.key.toString(), e.value))
        .toList()
      ..sort((a, b) => a.key.compareTo(b.key));
    return {for (final e in items) e.key: _norm(e.value)};
  }
  if (v is List) return [for (final e in v) _norm(e)];
  if (v is LevelSnap) {
    return 'L${v.level}|${v.unitIdx}|${v.combineX1}|${v.unitHigh}|${v.unitLow}';
  }
  if (v is LevelConfirm) {
    return 'C${v.x}|${v.fx}|${v.value}|${v.poleX}';
  }
  if (v is double) return v.toStringAsFixed(6);
  return v;
}

String _rowSig(Map<String, dynamic>? row) => '${_norm(row)}';

void _expectRowsEq(
  Map<String, dynamic>? a,
  Map<String, dynamic>? b,
  String tag,
) {
  expect(_rowSig(a), _rowSig(b), reason: tag);
}

void main() {
  late List<KlineBar> bars;

  setUpAll(() {
    bars = _load002003();
    expect(bars.length, greaterThan(28));
    expect(ChanBridge.instance.supportsAppendDelta, isTrue);
  });

  test('Incremental Lookup == Full Lookup · 002003 step24–28', () {
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    final buy1 = <int, List<Buy1Frame>>{};
    final sell1 = <int, List<Sell1Frame>>{};
    final buy2 = <int, List<Buy2Frame>>{};
    final sell2 = <int, List<Sell2Frame>>{};
    final buyN = <int, List<BuyNFrame>>{};
    final sellN = <int, List<SellNFrame>>{};
    Map<String, dynamic>? frozen24;

    for (var step = 0; step <= 28; step++) {
      final visible = bars.sublist(0, step + 1);
      final bundle = sess.syncTo(visible);
      for (final e in collectBuy1EventsByKn(bundle).entries) {
        mergeBuy1EventLog(buy1.putIfAbsent(e.key, () => []), e.value,
            discoveryX: step);
      }
      for (final e in collectSell1EventsByKn(bundle).entries) {
        mergeSell1EventLog(sell1.putIfAbsent(e.key, () => []), e.value,
            discoveryX: step);
      }
      for (final e in collectBuy2EventsByKn(bundle).entries) {
        mergeBuy2EventLog(buy2.putIfAbsent(e.key, () => []), e.value,
            discoveryX: step);
      }
      for (final e in collectSell2EventsByKn(bundle).entries) {
        mergeSell2EventLog(sell2.putIfAbsent(e.key, () => []), e.value,
            discoveryX: step);
      }
      for (final e in collectBuyNEventsByKn(bundle).entries) {
        mergeBuyNEventLog(buyN.putIfAbsent(e.key, () => []), e.value,
            discoveryX: step);
      }
      for (final e in collectSellNEventsByKn(bundle).entries) {
        mergeSellNEventLog(sellN.putIfAbsent(e.key, () => []), e.value,
            discoveryX: step);
      }
      sess.cache.syncLookup(
        bars: visible,
        buy1HistoryByKn: buy1,
        sell1HistoryByKn: sell1,
        buy2HistoryByKn: buy2,
        sell2HistoryByKn: sell2,
        buyNHistoryByKn: buyN,
        sellNHistoryByKn: sellN,
        subIndicators: _subs(bundle),
      );
      if (step < 24) continue;
      final inc = sess.cache.lookup;
      final full = _full(
        visible,
        bundle,
        buy1: buy1,
        sell1: sell1,
        buy2: buy2,
        sell2: sell2,
        buyN: buyN,
        sellN: sellN,
      );
      _expectRowsEq(inc.at(step), full.at(step), 'step$step current');
      _expectRowsEq(inc.at(5), full.at(5), 'step$step frozen idx=5');
      final mlI = MlFeatureFlat.flattenRow(inc.at(step) ?? const {});
      final mlF = MlFeatureFlat.flattenRow(full.at(step) ?? const {});
      expect(mlI.keys.toList()..sort(), mlF.keys.toList()..sort(),
          reason: 'step$step ML keys');
      for (final k in mlF.keys) {
        expect(mlI[k], mlF[k], reason: 'step$step ML $k');
      }
      if (step == 24) {
        frozen24 = Map<String, dynamic>.from(inc.at(24) ?? const {});
        final sub = frozen24['sub'];
        if (sub is Map) {
          frozen24['sub'] = Map<String, dynamic>.from(sub);
        }
      }
      if (step == 28 && frozen24 != null) {
        // 旧行冻结：weekday/OHLC/当步 feature 不得被 25–28 回写
        expect(inc.at(24)?['weekday'], frozen24['weekday']);
        expect(inc.at(24)?['open'], frozen24['open']);
        expect(inc.at(24)?['close'], frozen24['close']);
      }
    }
  });

  test('步退后 Incremental 不 Full 种仓，asOfView == Full', () {
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    sess.syncTo(bars.sublist(0, 29));
    sess.cache.syncLookup(bars: bars.sublist(0, 29), subIndicators: _subs(sess.cachedBundle));
    expect(sess.cache.lookupEngine.step, 28);
    final shortened = sess.syncTo(bars.sublist(0, 28));
    sess.cache.syncLookup(bars: bars.sublist(0, 28), subIndicators: _subs(shortened));
    expect(sess.cache.lookupEngine.step, 28);
    final inc = sess.cache.lookupEngine.asOfView(
      asOf: 27,
      asOfBundle: shortened,
      prefixBars: bars.sublist(0, 28),
    );
    final full = _full(bars.sublist(0, 28), shortened, asOf: 27);
    _expectRowsEq(inc.at(27), full.at(27), 'asof_keep current');
    _expectRowsEq(inc.at(5), full.at(5), 'asof_keep frozen');
  });

  test('asOf 24–28 不跑全表 build：冻结格 + 结构覆盖 == Full', () {
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    for (var step = 0; step <= 28; step++) {
      final visible = bars.sublist(0, step + 1);
      sess.syncTo(visible);
      sess.cache.syncLookup(bars: visible, subIndicators: _subs(sess.cachedBundle));
    }
    for (final asOf in [24, 25, 26, 27, 28]) {
      final prefix = bars.sublist(0, asOf + 1);
      final asOfBundle = ChanBridge.instance.buildKlineCombineBundle(prefix);
      final inc = sess.cache.lookupEngine.asOfView(
        asOf: asOf,
        asOfBundle: asOfBundle,
        prefixBars: prefix,
      );
      final full = _full(prefix, asOfBundle, asOf: asOf);
      expect(inc.at(asOf + 1), isNull, reason: 'asOf=$asOf 未来格不得泄漏');
      _expectRowsEq(inc.at(asOf), full.at(asOf), 'asOf=$asOf current');
      expect(inc.at(5)?['weekday'], full.at(5)?['weekday'],
          reason: 'asOf=$asOf frozen weekday');
    }
  });
}
