import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:flutter_test/flutter_test.dart';

int _countRewrites(
  Map<int, Map<int, double?>> byAsOf, {
  required int maxCompareX,
}) {
  final steps = byAsOf.keys.toList()..sort();
  var n = 0;
  for (var i = 0; i < steps.length; i++) {
    final t0 = steps[i];
    for (var j = i + 1; j < steps.length; j++) {
      final t1 = steps[j];
      final a = byAsOf[t0]!;
      final b = byAsOf[t1]!;
      for (final x in a.keys) {
        if (x > maxCompareX || x > t0) continue;
        final v0 = a[x];
        final v1 = b[x];
        if (v0 == null && v1 == null) continue;
        if (v0 != v1) n++;
      }
    }
  }
  return n;
}

void main() {
  test('MathSeriesFreezeStore：Kn1 步进格点不回写', () {
    final bridge = ChanBridge.instance;
    final bars = bridge.loadKlines(
      dataRoot: bridge.defaultDataRoot(),
      code: '002003',
      beginDate: '2004/07/19 10:47:00',
      endDate: '2004/07/20 13:09:00',
      period: 'tick',
    );
    final steps = [40, 50, 60, 70, 80];
    final cfg = const MathIndicatorConfig();
    final store = MathSeriesFreezeStore();

    final macdFrozen = <int, Map<int, double?>>{};
    final bollFrozen = <int, Map<int, double?>>{};
    final rsiFrozen = <int, Map<int, double?>>{};
    final kdjFrozen = <int, Map<int, double?>>{};
    final meanFrozen = <int, Map<int, double?>>{};
    final chanFrozen = <int, Map<int, double?>>{};
    final demarkFrozen = <int, Map<int, double?>>{};

    for (final asOf in steps) {
      final prefix = bars.where((b) => b.idx <= asOf).toList();
      final bundle = bridge.buildKlineCombineBundle(prefix);
      mergeMathSeriesForStep(
        store: store,
        bars: prefix,
        levels: bundle.levels,
        config: cfg,
        maxDisplayKn: 1,
        asOf: asOf,
      );

      Map<int, double?> snap(List<double?>? arr) {
        final m = <int, double?>{};
        if (arr == null) return m;
        for (var x = 0; x <= asOf && x < arr.length; x++) {
          m[x] = arr[x];
        }
        return m;
      }

      macdFrozen[asOf] = snap(store.macd(1)?.macd);
      bollFrozen[asOf] = snap(store.boll(1)?.mid);
      rsiFrozen[asOf] = snap(store.rsi(1));
      kdjFrozen[asOf] = snap(store.kdj(1)?.k);
      meanFrozen[asOf] = snap(store.mean(1)?[5]);
      chanFrozen[asOf] = snap(store.channel(1)?[5]?.max);
      demarkFrozen[asOf] = {
        for (var x = 0;
            x <= asOf && x < (store.demark(1)?.marksAt.length ?? 0);
            x++)
          x: store.demark(1)!.marksAt[x] == null
              ? null
              : store.demark(1)!.marksAt[x]!
                  .map((m) => '${m.type}:${m.dir}:${m.idx}')
                  .join('|')
                  .hashCode
                  .toDouble(),
      };
    }

    expect(_countRewrites(macdFrozen, maxCompareX: 70), 0);
    expect(_countRewrites(bollFrozen, maxCompareX: 70), 0);
    expect(_countRewrites(rsiFrozen, maxCompareX: 70), 0);
    expect(_countRewrites(kdjFrozen, maxCompareX: 70), 0);
    expect(_countRewrites(meanFrozen, maxCompareX: 70), 0);
    expect(_countRewrites(chanFrozen, maxCompareX: 70), 0);
    expect(_countRewrites(demarkFrozen, maxCompareX: 70), 0);

    // 首写后步进，历史格点值保持不变
    final v40 = macdFrozen[40]![40];
    expect(v40, isNotNull);
    expect(macdFrozen[80]![40], v40);
  });
}
