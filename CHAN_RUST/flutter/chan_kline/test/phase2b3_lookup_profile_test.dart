import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/k1_bar_view_compute.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/pipeline_delta.dart';
import 'package:chan_kline/widgets/kline_chart.dart';
import 'package:ffi/ffi.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Phase 2B-3A：末步 Full Lookup vs Incremental Lookup。

class _DeltaFfi {
  _DeltaFfi() {
    final path =
        '${Directory.current.path}${Platform.pathSeparator}windows${Platform.pathSeparator}native${Platform.pathSeparator}chan_ffi.dll';
    _lib = DynamicLibrary.open(path);
    _appendDelta = _lib
        .lookup<NativeFunction<Pointer<Utf8> Function(Uint64, Pointer<Utf8>)>>(
          'chan_pipeline_append_delta',
        )
        .asFunction();
    _free = _lib
        .lookup<NativeFunction<Void Function(Pointer<Utf8>)>>(
          'chan_free_string',
        )
        .asFunction();
  }

  late final DynamicLibrary _lib;
  late final Pointer<Utf8> Function(int, Pointer<Utf8>) _appendDelta;
  late final void Function(Pointer<Utf8>) _free;

  String appendDeltaJson(int handle, KlineBar bar) {
    final ptr = jsonEncode(bar.toJson()).toNativeUtf8();
    try {
      final out = _appendDelta(handle, ptr);
      if (out == nullptr) {
        throw StateError('append_delta 空指针');
      }
      try {
        return out.toDartString();
      } finally {
        _free(out);
      }
    } finally {
      calloc.free(ptr);
    }
  }
}

List<KlineBar> _zigzag(int n) {
  return List.generate(n, (i) {
    final base = 10.0 + ((i ~/ 3) % 2) * 2.0 + (i % 3) * 0.7;
    final h = (i ~/ 3) % 2 == 0 ? base + 1.0 : 14.0 - base + 10.0;
    final l = h - 0.8;
    return KlineBar(
      idx: i,
      timeMs: 1087200000000 + i * 60000,
      timeText: 't$i',
      open: l,
      high: h,
      low: l,
      close: h,
      volume: 1,
      amount: 1,
    );
  });
}

List<KlineBar> _loadBars(int n) {
  final bridge = ChanBridge.instance;
  try {
    final real = bridge.loadKlines(
      dataRoot: bridge.defaultDataRoot(),
      code: '002003',
      beginDate: '2004/07/19 10:47:00',
      endDate: '2005/07/19 15:00:00',
      period: '1m',
    );
    if (real.length >= n) return real.sublist(0, n);
  } catch (_) {}
  return _zigzag(n);
}

BarFeatureLookup _buildLookup(List<KlineBar> bars, KlineCombineBundle b) {
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
    subIndicators: buildSubIndicatorCatalog(
      chartMaxKn(levels: b.levels, k0Lines: b.k0Lines),
    ).toSet(),
    zsK0Frames: b.zsK0Frames,
    asOf: bars.isEmpty ? null : bars.last.idx,
  );
}

class _Row {
  _Row(this.n);
  final int n;
  int ffiUs = 0;
  int decodeUs = 0;
  int fromJsonUs = 0;
  int mergeUs = 0;
  int fullLookupUs = 0;
  int incLookupUs = 0;
  int tooltipUs = 0;
  int flattenUs = 0;
  int jsonBytes = 0;

  int get deltaUs => ffiUs + decodeUs + fromJsonUs + mergeUs;
  int get stepUs => deltaUs + incLookupUs;
  double get speedup =>
      incLookupUs == 0 ? 0 : fullLookupUs / incLookupUs;

  String get line {
    int ms(int us) => (us / 1000).round();
    return 'N=$n json=${jsonBytes}B '
        'ffi=${ms(ffiUs)}ms decode=${ms(decodeUs)}ms fromJson=${ms(fromJsonUs)}ms '
        'merge=${ms(mergeUs)}ms '
        'FullLookup=${ms(fullLookupUs)}ms IncrementalLookup=${ms(incLookupUs)}ms '
        'speedup=${speedup.toStringAsFixed(1)}x '
        'tip=${ms(tooltipUs)}ms ml=${ms(flattenUs)}ms '
        'step=${ms(stepUs)}ms';
  }
}

_Row _profileLastStep(List<KlineBar> all, int n, _DeltaFfi ffi) {
  final bars = all.sublist(0, n);
  final prefix = bars.sublist(0, n - 1);
  final sess = ChanPipelineSession.create(preferDelta: true);
  try {
    sess.syncTo(prefix);
    final prefixBundle = sess.cache.bundle;
    final subs = buildSubIndicatorCatalog(
      chartMaxKn(levels: prefixBundle.levels, k0Lines: prefixBundle.k0Lines),
    ).toSet();
    sess.cache.syncLookup(bars: prefix, subIndicators: subs);

    final sw = Stopwatch();
    sw.start();
    final raw = ffi.appendDeltaJson(sess.handle, bars.last);
    final ffiUs = sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    final envelope = jsonDecode(raw);
    if (envelope is! Map || envelope['ok'] != true) {
      throw StateError(
          'append_delta 失败: ${envelope is Map ? envelope['error'] : raw}');
    }
    final data = Map<String, dynamic>.from(envelope['data'] as Map);
    final decodeUs = sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    final delta = PipelineDelta.fromJson(data);
    final fromJsonUs = sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    sess.cache.mergeDelta(delta);
    final mergeUs = sw.elapsedMicroseconds;
    final bundle = sess.cache.bundle;
    final lastSubs = buildSubIndicatorCatalog(
      chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines),
    ).toSet();

    sw
      ..reset()
      ..start();
    sess.cache.syncLookup(bars: bars, subIndicators: lastSubs);
    final incLookupUs = sw.elapsedMicroseconds;
    final look = sess.cache.lookup;

    sw
      ..reset()
      ..start();
    _buildLookup(bars, bundle);
    final fullLookupUs = sw.elapsedMicroseconds;

    sw
      ..reset()
      ..start();
    look.crosshairTooltipRows(bars.last.idx, timePart: 'p');
    final tipUs = sw.elapsedMicroseconds;
    sw
      ..reset()
      ..start();
    MlFeatureFlat.flattenRow(look.at(bars.last.idx) ?? const {});
    final flatUs = sw.elapsedMicroseconds;

    return _Row(n)
      ..ffiUs = ffiUs
      ..decodeUs = decodeUs
      ..fromJsonUs = fromJsonUs
      ..mergeUs = mergeUs
      ..fullLookupUs = fullLookupUs
      ..incLookupUs = incLookupUs
      ..tooltipUs = tipUs
      ..flattenUs = flatUs
      ..jsonBytes = raw.length;
  } finally {
    sess.dispose();
  }
}

void main() {
  late List<KlineBar> bars;
  late _DeltaFfi ffi;

  setUpAll(() {
    expect(ChanBridge.instance.supportsAppendDelta, isTrue);
    ffi = _DeltaFfi();
    bars = _loadBars(2000);
    expect(bars.length, 2000);
  });

  test('末步 Full vs Incremental Lookup N=200/500/1000/2000', () {
    final rows = <_Row>[];
    for (final n in [200, 500, 1000, 2000]) {
      rows.add(_profileLastStep(bars, n, ffi));
    }
    for (final r in rows) {
      // ignore: avoid_print
      print(r.line);
    }
    final n200 = rows.first;
    final n2000 = rows.last;
    expect(n2000.fullLookupUs, greaterThan(n2000.incLookupUs),
        reason: 'Incremental 应快于 Full');
    final incGrowth = n2000.incLookupUs / n200.incLookupUs;
    final fullGrowth = n2000.fullLookupUs / n200.fullLookupUs;
    // ignore: avoid_print
    print('growth Incremental x${incGrowth.toStringAsFixed(2)} '
        'Full x${fullGrowth.toStringAsFixed(2)} '
        'N2000 speedup=${n2000.speedup.toStringAsFixed(1)}x');
    expect(incGrowth, lessThan(fullGrowth),
        reason: 'Incremental 随 N 增长应明显慢于 Full');
  }, timeout: const Timeout(Duration(minutes: 12)));

  testWidgets('render pump N=200（复用 lookupEngine，禁止 Painter 再 build）',
      (tester) async {
    final n = 200;
    final sess = ChanPipelineSession.create(preferDelta: true);
    addTearDown(sess.dispose);
    final visible = bars.sublist(0, n);
    sess.syncTo(visible);
    final b = sess.cachedBundle;
    final maxKn = chartMaxKn(levels: b.levels, k0Lines: b.k0Lines);
    sess.cache.syncLookup(
      bars: visible,
      subIndicators: buildSubIndicatorCatalog(maxKn).toSet(),
    );
    final mains = buildMainIndicatorCatalog(maxKn)
        .where(isDefaultDrawnMain)
        .toSet();
    final subs =
        buildSubIndicatorCatalog(maxKn).where(isDefaultDrawnSub).toSet();
    final sw = Stopwatch()..start();
    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox(
          width: 1200,
          height: 800,
          child: KlineChart(
            bars: visible,
            period: '1m',
            combineFrames: b.frames,
            k0ConfirmSignals: b.k0Confirms,
            barFeatures: b.barFeatures,
            k0Lines: b.k0Lines,
            k1BarViews: buildK1BarViews(b.k1Bars),
            k1CombineFrames: b.k1CombineFrames,
            k1Analysis: b.k1Analysis,
            levels: b.levels,
            zsK0Frames: b.zsK0Frames,
            mainIndicators: mains,
            subIndicators: subs,
            lookupEngine: sess.cache.lookupEngine,
          ),
        ),
      ),
    );
    await tester.pump();
    final renderMs = sw.elapsedMilliseconds;
    // ignore: avoid_print
    print('render pump N=200: ${renderMs}ms (shared IncrementalLookup)');
    expect(find.byType(KlineChart), findsOneWidget);
  }, timeout: const Timeout(Duration(minutes: 3)));
}
