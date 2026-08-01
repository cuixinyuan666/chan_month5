import 'dart:isolate';

import '../bridge/chan_bridge.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import '../widgets/kline_chip.dart';

/// 单根 K 的筹码分摊增量（稀疏桶）。
/// 踩坑：toWire/fromWire 用 List<int>/List<double> 而非 Map，
/// 因为 Isolate 传输只支持基本类型的深拷贝，KlineBar 等对象不能跨 Isolate 边界。
class _BarChipDelta {
  _BarChipDelta(this.idx, this.keys, this.s, this.b, this.w);
  final int idx;
  final List<int> keys;
  final List<double> s;
  final List<double> b;
  /// 灰度（无方向分笔）
  final List<double> w;

  List<Object?> toWire() => [idx, keys, s, b, w];

  static _BarChipDelta fromWire(List<Object?> w) {
    return _BarChipDelta(
      w[0] as int,
      List<int>.from(w[1] as List),
      List<double>.from((w[2] as List).map((e) => (e as num).toDouble())),
      List<double>.from((w[3] as List).map((e) => (e as num).toDouble())),
      List<double>.from((w[4] as List).map((e) => (e as num).toDouble())),
    );
  }
}

/// 前缀筹码：步进可增量追加；十字 as-of 按 cutoff 秒查（口径同 Dart 直加/三角）。
/// 设计：每 256 根 K 打一次快照查表，profileAt(cutoffX) 二分定位→从最近快照重算至 cutoff，
/// 避免每次从头累加。append/truncateTo 支持步进逐 K 追加/回落。
/// 踩坑：Isolate 里 buildFromCompact 必须用 Map<String,Object?>+基本类型，
/// 因为 dart:isolate 的 SendPort 不支持传递非原生类型。
class _ChipPrefixIndex {
  _ChipPrefixIndex({
    required this.seriesKey,
    required this.step,
    required this.deltas,
    required this.checkS,
    required this.checkB,
    required this.checkW,
  });

  static const checkpointEvery = 256;

  final String seriesKey;
  final double step;
  final List<_BarChipDelta> deltas;
  final List<Map<int, double>> checkS;
  final List<Map<int, double>> checkB;
  final List<Map<int, double>> checkW;

  int get n => deltas.length;

  static String seriesKeyOf(List<KlineBar> bars, double step) {
    if (bars.isEmpty) return '0|$step';
    final a = bars.first;
    return '${a.idx}|${a.timeMs}|$step';
  }

  static _BarChipDelta deltaOf(KlineBar bar, double step) {
    return deltaOfFields(
      idx: bar.idx,
      open: bar.open,
      high: bar.high,
      low: bar.low,
      close: bar.close,
      volume: bar.volume,
      bins: bar.metrics['chip_tick_bins'],
      step: step,
    );
  }

  static _BarChipDelta deltaOfFields({
    required int idx,
    required double open,
    required double high,
    required double low,
    required double close,
    required double volume,
    required Object? bins,
    required double step,
  }) {
    final keys = <int>[];
    final s = <double>[];
    final b = <double>[];
    final w = <double>[];
    if (bins is Map) {
      final p = (bins['p'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final sv = (bins['s'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final bv = (bins['b'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      final wv = (bins['w'] as List?)
              ?.map((e) => (e as num).toDouble())
              .toList() ??
          const <double>[];
      if (p.isEmpty) {
        if ((high - low).abs() < 1e-12) {
          _pointInto(
            price: close,
            volume: volume,
            step: step,
            keys: keys,
            s: s,
            b: b,
            w: w,
          );
        } else {
          _triangleInto(
            low: low,
            high: high,
            close: close,
            volume: volume,
            step: step,
            keys: keys,
            s: s,
            b: b,
            w: w,
          );
        }
      } else {
        for (var i = 0; i < p.length; i++) {
          final price = p[i];
          if (!price.isFinite) continue;
          final key = (price / step).floor();
          final ss = i < sv.length ? sv[i] : 0.0;
          final bb = i < bv.length ? bv[i] : 0.0;
          // 灰度独立分量；删除旧「b 空则用 w 当买」兜底
          final ww = i < wv.length ? wv[i] : 0.0;
          if (ss <= 0 && bb <= 0 && ww <= 0) continue;
          keys.add(key);
          s.add(ss > 0 ? ss : 0.0);
          b.add(bb > 0 ? bb : 0.0);
          w.add(ww > 0 ? ww : 0.0);
        }
      }
    } else if ((high - low).abs() < 1e-12) {
      // 一字线/tick：单点落量，禁止三角
      _pointInto(
        price: close,
        volume: volume,
        step: step,
        keys: keys,
        s: s,
        b: b,
        w: w,
      );
    } else {
      _triangleInto(
        low: low,
        high: high,
        close: close,
        volume: volume,
        step: step,
        keys: keys,
        s: s,
        b: b,
        w: w,
      );
    }
    return _BarChipDelta(idx, keys, s, b, w);
  }

  static void _pointInto({
    required double price,
    required double volume,
    required double step,
    required List<int> keys,
    required List<double> s,
    required List<double> b,
    required List<double> w,
  }) {
    final vol = volume < 0 ? 0.0 : volume;
    if (!price.isFinite || vol <= 0) return;
    keys.add((price / step).floor());
    s.add(0);
    b.add(vol);
    w.add(0);
  }

  static void _triangleInto({
    required double low,
    required double high,
    required double close,
    required double volume,
    required double step,
    required List<int> keys,
    required List<double> s,
    required List<double> b,
    required List<double> w,
  }) {
    final lo = low < high ? low : high;
    final hi = low > high ? low : high;
    final mode = close.clamp(lo, hi);
    final vol = volume < 0 ? 0.0 : volume;
    if (hi < lo || vol <= 0) return;
    final i0 = (lo / step).floor();
    final i1 = (hi / step).ceil();
    if (i1 < i0) return;
    if ((hi - lo).abs() < 1e-12) {
      keys.add(i0);
      s.add(0);
      b.add(vol);
      w.add(0);
      return;
    }
    final weights = <MapEntry<int, double>>[];
    var totalW = 0.0;
    for (var key = i0; key <= i1; key++) {
      final price = key * step;
      double w;
      if ((mode - lo).abs() < 1e-12) {
        w = (hi - price) / (hi - lo);
      } else if ((hi - mode).abs() < 1e-12) {
        w = (price - lo) / (hi - lo);
      } else if (price <= mode) {
        w = (price - lo) / (mode - lo);
      } else {
        w = (hi - price) / (hi - mode);
      }
      if (w < 0) w = 0;
      weights.add(MapEntry(key, w));
      totalW += w;
    }
    if (totalW <= 1e-12) return;
    for (final e in weights) {
      if (e.value <= 0) continue;
      keys.add(e.key);
      s.add(0);
      b.add(e.value / totalW * vol);
      w.add(0);
    }
  }

  static _ChipPrefixIndex build(List<KlineBar> bars, double step) {
    final deltas = <_BarChipDelta>[
      for (final bar in bars) deltaOf(bar, step),
    ];
    return _fromDeltas(seriesKeyOf(bars, step), step, deltas);
  }

  /// Isolate 可序列化构建（仅基本类型）。
  /// 踩坑：传入的 bars 必须用 compact 格式（o/h/l/c/v 等基本类型），
  /// 不可直接传 KlineBar 对象（Isolate 无法序列化）。
  static _ChipPrefixIndex buildFromCompact(
    List<Map<String, Object?>> bars,
    double step,
    String seriesKey,
  ) {
    final deltas = <_BarChipDelta>[
      for (final m in bars)
        deltaOfFields(
          idx: m['idx'] as int,
          open: (m['o'] as num).toDouble(),
          high: (m['h'] as num).toDouble(),
          low: (m['l'] as num).toDouble(),
          close: (m['c'] as num).toDouble(),
          volume: (m['v'] as num).toDouble(),
          bins: m['bins'],
          step: step,
        ),
    ];
    return _fromDeltas(seriesKey, step, deltas);
  }

  static _ChipPrefixIndex _fromDeltas(
    String seriesKey,
    double step,
    List<_BarChipDelta> deltas,
  ) {
    final checkS = <Map<int, double>>[{}];
    final checkB = <Map<int, double>>[{}];
    final checkW = <Map<int, double>>[{}];
    final runS = <int, double>{};
    final runB = <int, double>{};
    final runW = <int, double>{};
    for (var i = 0; i < deltas.length; i++) {
      _apply(deltas[i], runS, runB, runW);
      if ((i + 1) % checkpointEvery == 0) {
        checkS.add(Map<int, double>.from(runS));
        checkB.add(Map<int, double>.from(runB));
        checkW.add(Map<int, double>.from(runW));
      }
    }
    return _ChipPrefixIndex(
      seriesKey: seriesKey,
      step: step,
      deltas: deltas,
      checkS: checkS,
      checkB: checkB,
      checkW: checkW,
    );
  }

  Map<String, Object?> toWire() => {
        'seriesKey': seriesKey,
        'step': step,
        'deltas': [for (final d in deltas) d.toWire()],
        'checkS': checkS,
        'checkB': checkB,
        'checkW': checkW,
      };

  static _ChipPrefixIndex fromWire(Map<String, Object?> w) {
    final rawD = (w['deltas'] as List)
        .map((e) => _BarChipDelta.fromWire(List<Object?>.from(e as List)))
        .toList();
    // 踩坑：JSON 序列化会把 Map<int,double> 的 key 变 String；
    // 反序列时必须 int.parse(k.toString()) 转回 int。
    List<Map<int, double>> parseChecks(dynamic raw) => (raw as List)
        .map((e) => Map<int, double>.from(
              (e as Map).map((k, v) => MapEntry(
                    k is int ? k : int.parse(k.toString()),
                    (v as num).toDouble(),
                  )),
            ))
        .toList();
    return _ChipPrefixIndex(
      seriesKey: w['seriesKey'] as String,
      step: (w['step'] as num).toDouble(),
      deltas: rawD,
      checkS: parseChecks(w['checkS']),
      checkB: parseChecks(w['checkB']),
      checkW: parseChecks(w['checkW']),
    );
  }

  static void _apply(
      _BarChipDelta d, Map<int, double> runS, Map<int, double> runB,
      Map<int, double> runW) {
    for (var i = 0; i < d.keys.length; i++) {
      final k = d.keys[i];
      final sv = d.s[i];
      final bv = d.b[i];
      final wv = d.w[i];
      if (sv > 0) runS[k] = (runS[k] ?? 0) + sv;
      if (bv > 0) runB[k] = (runB[k] ?? 0) + bv;
      if (wv > 0) runW[k] = (runW[k] ?? 0) + wv;
    }
  }

  void append(List<KlineBar> more) {
    for (final bar in more) {
      final d = deltaOf(bar, step);
      deltas.add(d);
      if (deltas.length % checkpointEvery == 0) {
        final runS = Map<int, double>.from(checkS.last);
        final runB = Map<int, double>.from(checkB.last);
        final runW = Map<int, double>.from(checkW.last);
        final from = (checkS.length - 1) * checkpointEvery;
        for (var i = from; i < deltas.length; i++) {
          _apply(deltas[i], runS, runB, runW);
        }
        checkS.add(runS);
        checkB.add(runB);
        checkW.add(runW);
      }
    }
  }

  void truncateTo(int newN) {
    if (newN >= deltas.length) return;
    if (newN <= 0) {
      deltas.clear();
      checkS
        ..clear()
        ..add({});
      checkB
        ..clear()
        ..add({});
      checkW
        ..clear()
        ..add({});
      return;
    }
    deltas.removeRange(newN, deltas.length);
    final keepChecks = 1 + newN ~/ checkpointEvery;
    if (checkS.length > keepChecks) {
      checkS.removeRange(keepChecks, checkS.length);
      checkB.removeRange(keepChecks, checkB.length);
      checkW.removeRange(keepChecks, checkW.length);
    }
  }

  ChipProfileData profileAt(int cutoffX) {
    var lo = 0;
    var hi = deltas.length - 1;
    var end = -1;
    while (lo <= hi) {
      final mid = (lo + hi) >> 1;
      if (deltas[mid].idx <= cutoffX) {
        end = mid;
        lo = mid + 1;
      } else {
        hi = mid - 1;
      }
    }
    if (end < 0) {
      return ChipProfileData(
        profileId: 'prefix:empty:$cutoffX',
        cutoffX: cutoffX,
        bucketStep: step,
        prices: const [],
        s: const [],
        b: const [],
        w: const [],
        total: const [],
        maxTotal: 0,
        source: 'prefix',
      );
    }
    final cp = (end + 1) ~/ checkpointEvery;
    final safeCp = cp.clamp(0, checkS.length - 1);
    final runS = Map<int, double>.from(checkS[safeCp]);
    final runB = Map<int, double>.from(checkB[safeCp]);
    final runW = Map<int, double>.from(checkW[safeCp]);
    final from = safeCp * checkpointEvery;
    for (var i = from; i <= end; i++) {
      _apply(deltas[i], runS, runB, runW);
    }
    return _mapsToProfile(cutoffX, step, runS, runB, runW);
  }

  static ChipProfileData _mapsToProfile(
    int cutoffX,
    double step,
    Map<int, double> bucketsS,
    Map<int, double> bucketsB,
    Map<int, double> bucketsW,
  ) {
    final keys = {...bucketsS.keys, ...bucketsB.keys, ...bucketsW.keys}.toList()
      ..sort();
    final prices = <double>[];
    final sVals = <double>[];
    final bVals = <double>[];
    final wVals = <double>[];
    final totals = <double>[];
    var maxTotal = 0.0;
    for (final k in keys) {
      final sv = bucketsS[k] ?? 0.0;
      final bv = bucketsB[k] ?? 0.0;
      final wv = bucketsW[k] ?? 0.0;
      final t = sv + bv + wv;
      if (t > maxTotal) maxTotal = t;
      prices.add(k * step);
      sVals.add(sv);
      bVals.add(bv);
      wVals.add(wv);
      totals.add(t);
    }
    return ChipProfileData(
      profileId: 'prefix:$cutoffX:$step',
      cutoffX: cutoffX,
      bucketStep: step,
      prices: prices,
      s: sVals,
      b: bVals,
      w: wVals,
      total: totals,
      maxTotal: maxTotal,
      source: 'prefix',
    );
  }
}

/// Isolate 入口：返回可发送的 wire map。
Map<String, Object?> _isolateBuildPrefix(Map<String, Object?> req) {
  final step = (req['step'] as num).toDouble();
  final seriesKey = req['seriesKey'] as String;
  final bars = (req['bars'] as List)
      .map((e) => Map<String, Object?>.from(e as Map))
      .toList();
  final idx = _ChipPrefixIndex.buildFromCompact(bars, step, seriesKey);
  return idx.toWire();
}

/// 筹码 profile：前缀索引（步进增量 + 十字 as-of）；口径不变。
class ChipProfileCompute {
  static ChipProfileData? _cached;
  static String? _cachedKey;
  static _ChipPrefixIndex? _prefix;
  static int _warmGen = 0;

  static int cutoffForKn({
    required int kn,
    required int asOfK0,
    required List<LevelBundle> levels,
  }) {
    if (kn <= 0) return asOfK0;
    LevelBundle? lv;
    for (final e in levels) {
      if (e.level == kn) {
        lv = e;
        break;
      }
    }
    if (lv == null) return asOfK0;
    var maxX = -1;
    for (final u in lv.unitBars) {
      final x2 = u.x2;
      if (x2 <= asOfK0 && x2 > maxX) maxX = x2;
    }
    final active = lv.activeUnit;
    if (active != null) {
      if (active.x2 <= asOfK0 && active.x2 > maxX) {
        maxX = active.x2;
      }
      if (asOfK0 > maxX) maxX = asOfK0;
    }
    return maxX < 0 ? asOfK0 : maxX;
  }

  static String _cacheKey(List<KlineBar> bars, int cutoffX, double bucketStep) {
    if (bars.isEmpty) return '0|$cutoffX|$bucketStep';
    final a = bars.first;
    final b = bars.last;
    return '${bars.length}|${a.idx}|${a.timeMs}|${b.idx}|${b.timeMs}|$cutoffX|$bucketStep';
  }

  static void clearCache() {
    _warmGen++;
    _cached = null;
    _cachedKey = null;
    _prefix = null;
  }

  static bool hasPrefixFor(List<KlineBar> bars, double bucketStep) {
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    final p = _prefix;
    if (p == null) return false;
    return p.seriesKey == _ChipPrefixIndex.seriesKeyOf(bars, step) &&
        p.n == bars.length;
  }

  static void _ensurePrefix(List<KlineBar> bars, double step) {
    final sk = _ChipPrefixIndex.seriesKeyOf(bars, step);
    final p = _prefix;
    if (p == null || p.seriesKey != sk) {
      _prefix = _ChipPrefixIndex.build(bars, step);
      return;
    }
    if (bars.length > p.n) {
      p.append(bars.sublist(p.n));
    } else if (bars.length < p.n) {
      p.truncateTo(bars.length);
    }
  }

  /// 后台预热前缀（跳末/大序列）；计算口径与同步 build 相同。
  /// 踩坑：_warmGen 版本号是防止「慢 Isolate 的旧结果覆盖新股票的前缀」的关键。
  ///   warmUpInBackground 是异步不堵 UI 的，若用户快速换股，旧 Isolate 完成后
  ///   如果 gen 不匹配则丢弃结果，避免用 A 股数据覆盖 B 股前缀。
  static Future<void> warmUpInBackground(
    List<KlineBar> bars, {
    double bucketStep = 0.1,
  }) async {
    if (bars.isEmpty) return;
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    if (hasPrefixFor(bars, step)) return;
    final gen = ++_warmGen;
    final sk = _ChipPrefixIndex.seriesKeyOf(bars, step);
    final compact = <Map<String, Object?>>[
      for (final b in bars)
        {
          'idx': b.idx,
          't': b.timeMs,
          'o': b.open,
          'h': b.high,
          'l': b.low,
          'c': b.close,
          'v': b.volume,
          'bins': b.metrics['chip_tick_bins'],
        },
    ];
    try {
      final wire = await Isolate.run(
        () => _isolateBuildPrefix({
          'step': step,
          'seriesKey': sk,
          'bars': compact,
        }),
      );
      if (gen != _warmGen) return; // 已换股/清缓存
      _prefix = _ChipPrefixIndex.fromWire(Map<String, Object?>.from(wire));
      _cached = null;
      _cachedKey = null;
    } catch (_) {
      // Isolate 失败：保持懒构建（compute 时主线程 build）
    }
  }

  static ChipProfileData compute({
    required List<KlineBar> bars,
    required int cutoffX,
    double bucketStep = 0.1,
  }) {
    final step = bucketStep < 0.001 ? 0.001 : bucketStep;
    final key = _cacheKey(bars, cutoffX, step);
    if (_cached != null && _cachedKey == key) return _cached!;
    _ensurePrefix(bars, step);
    final out = _prefix!.profileAt(cutoffX);
    _cached = out;
    _cachedKey = key;
    return out;
  }

  static ChipProfileData computeViaFfi({
    required List<KlineBar> bars,
    required int cutoffX,
    double bucketStep = 0.1,
  }) {
    try {
      return ChanBridge.instance.chipProfile(
        bars: bars,
        cutoffX: cutoffX,
        bucketStep: bucketStep,
      );
    } catch (_) {
      _ensurePrefix(bars, bucketStep < 0.001 ? 0.001 : bucketStep);
      return _prefix!.profileAt(cutoffX);
    }
  }
}
