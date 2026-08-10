import 'dart:math' as math;

import 'package:chan_kline/bridge/chan_bridge.dart';
import 'package:chan_kline/compute/class1_bs_compute.dart';
import 'package:chan_kline/compute/math_series_freeze_store.dart';
import 'package:chan_kline/ml/ml_bsp_labeler.dart';
import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_bsp_sampler.dart';
import 'package:chan_kline/ml/ml_dataset_split.dart';
import 'package:chan_kline/ml/ml_experience_trainer.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/ml/ml_label_config.dart';
import 'package:chan_kline/ml/ml_split_config.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// 真实数据评估：当前 tip 同源特征是否值得做。
void main() {
  test('特征价值评估（002003 1m）', () {
    final bridge = ChanBridge.instance;
    final root = bridge.defaultDataRoot();
    // 1m：比 tick 少一个数量级，可在几分钟内跑完全链路
    final bars = bridge.loadKlines(
      dataRoot: root,
      code: '002003',
      beginDate: '2004/07/19 09:30:00',
      endDate: '2004/07/20 15:00:00',
      period: '1m',
    );
    expect(bars.length, greaterThan(50), reason: '检查 a_Data/002003');
    // ignore: avoid_print
    print('加载完成: bars=${bars.length} root=$root');

    final sampler = MlBspSampler();
    final buy1Hist = <int, List<Buy1Frame>>{};
    final sell1Hist = <int, List<Sell1Frame>>{};
    final mathStore = MathSeriesFreezeStore();
    const labelCfg = MlLabelConfig(horizonBars: 64);
    const mathCfg = MathIndicatorConfig();
    final end = bars.length - 1;
    // 缓存逐步 bundle 的 live 帧，避免重复全量重算两次
    for (var i = 0; i <= end; i++) {
      if (i % 50 == 0 || i == end) {
        // ignore: avoid_print
        print('步进 $i/$end 样本=${sampler.samples.length}');
      }
      final visible = bars.sublist(0, i + 1);
      final bundle = bridge.buildKlineCombineBundle(visible);
      final liveBuy = collectBuy1EventsByKn(bundle)[0] ?? const <Buy1Frame>[];
      final liveSell = collectSell1EventsByKn(bundle)[0] ?? const <Sell1Frame>[];

      final buyLog = buy1Hist.putIfAbsent(0, () => <Buy1Frame>[]);
      final sellLog = sell1Hist.putIfAbsent(0, () => <Sell1Frame>[]);
      mergeBuy1EventLog(buyLog, liveBuy, discoveryX: i);
      mergeSell1EventLog(sellLog, liveSell, discoveryX: i);

      // 仅当本步有新一类 BS 时才建 lookup（与生产采样同触发）
      final hasNew = liveBuy.any((e) => e.x == i) || liveSell.any((e) => e.x == i);
      if (hasNew) {
        mergeMathSeriesForStep(
          store: mathStore,
          bars: visible,
          levels: bundle.levels,
          config: mathCfg,
          maxDisplayKn:
              chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines),
          asOf: i,
        );
        final maxKn =
            chartMaxKn(levels: bundle.levels, k0Lines: bundle.k0Lines);
        final subs = buildSubIndicatorCatalog(maxKn).toSet();
        sampler.onStep(
          stepIdx: i,
          visibleBars: visible,
          buy1K0: buyLog,
          sell1K0: sellLog,
          buildLookup: () => BarFeatureLookup.build(
            bars: visible,
            combineFrames: bundle.frames,
            k0Confirms: bundle.k0Confirms,
            barFeatures: bundle.barFeatures,
            k0Lines: bundle.k0Lines,
            k1Analysis: bundle.k1Analysis,
            levels: bundle.levels,
            k1CombineFrames: bundle.k1CombineFrames,
            buy1HistoryByKn: buy1Hist,
            sell1HistoryByKn: sell1Hist,
            buy1K0Frames: buyLog,
            sell1K0Frames: sellLog,
            subIndicators: subs,
            asOf: i,
            mathIndicatorConfig: mathCfg,
            mathFreezeStore: mathStore,
            zsK0Frames: bundle.zsK0Frames,
          ),
        );
      }

      MlBspLabeler.labelDueSamples(
        samples: sampler.samples,
        asOfIdx: i,
        horizonBars: labelCfg.horizonBars,
        isLastBar: i == end,
        liveBuy1: liveBuy,
        liveSell1: liveSell,
        k0LinesAsOf: bundle.k0Lines,
        barsAsOf: visible,
      );
    }

    final samples = List<MlBspSample>.from(sampler.samples);
    expect(samples.where((e) => e.isCorrect == null), isEmpty);

    final allKeys = <String>{};
    var cell = 0;
    var miss = 0;
    for (final s in samples) {
      allKeys.addAll(s.features.keys);
      for (final v in s.features.values) {
        cell++;
        if (v == MlFeatureFlat.missing) miss++;
      }
    }
    final dim = allKeys.length;
    final missRate = cell == 0 ? 1.0 : miss / cell;

    MlDatasetSplit.apply(
      samples,
      const MlSplitConfig(trainRatio: 0.6, validRatio: 0.2),
    );
    final train = MlDatasetSplit.trainOf(samples);
    final corrHits = <({String name, double corr})>[];
    for (final name in allKeys) {
      final xs = <double>[];
      final ys = <double>[];
      for (final s in train) {
        final v = s.features[name];
        if (v == null || v == MlFeatureFlat.missing) continue;
        xs.add(v);
        ys.add((s.isCorrect == true) ? 1.0 : 0.0);
      }
      if (xs.length < 8) continue;
      final c = _pearson(xs, ys).abs();
      if (c.isFinite) corrHits.add((name: name, corr: c));
    }
    corrHits.sort((a, b) => b.corr.compareTo(a.corr));
    final strong = corrHits.where((e) => e.corr >= 0.15).length;
    final weak = corrHits.where((e) => e.corr >= 0.05).length;

    final report = MlExperienceTrainer.fitTuneAndTest(samples: samples);
    final t = report.testStats;
    final baseline = t.alphaWinRate;
    final expWin = t.experienceWinRate;
    final lift = expWin - baseline;
    final acc = t.experienceAccuracy;
    final nOverD = samples.isEmpty ? 0.0 : samples.length / math.max(1, dim);

    final reasons = <String>[];
    if (samples.length < 30) reasons.add('样本过少(<30)');
    if (dim > samples.length * 5) reasons.add('维数远大于样本');
    if (strong < 3) reasons.add('强相关特征少(|corr|≥0.15<3)');
    if (t.adopted < 3) reasons.add('测试采纳过少(<3)');
    if (acc < 0.52 && lift <= 0) reasons.add('未优于瞎猜/基准');
    if (report.drift.alert) reasons.add('分布漂移告警');

    final worth = reasons.isEmpty &&
        samples.length >= 30 &&
        (acc >= 0.55 || lift >= 0.05) &&
        t.adopted >= 3;

    // ignore: avoid_print
    print('''
======== ML 特征价值评估 ========
数据根: $root
标的: 002003 1m 2004/07/19-20
K线数: ${bars.length}
样本数: ${samples.length} (买${samples.where((e) => e.side == 'B').length}/卖${samples.where((e) => e.side == 'S').length})
特征维(并集): $dim
样本/维: ${nOverD.toStringAsFixed(3)}
缺失率: ${(missRate * 100).toStringAsFixed(1)}%
展望窗: ${labelCfg.horizonBars}K
${report.drift.labelRateSummary}
${report.drift.driftSummary}
${report.tuneSummary}
测试基准胜率: ${(baseline * 100).toStringAsFixed(1)}%
测试经验胜率: ${(expWin * 100).toStringAsFixed(1)}% (采纳${t.adopted}/${t.total})
测试准确率: ${(acc * 100).toStringAsFixed(1)}%
相对基准提升: ${(lift * 100).toStringAsFixed(1)} pts
|corr|≥0.15: $strong；≥0.05: $weak（可比${corrHits.length}）
Top: ${corrHits.take(8).map((e) => '${e.name}=${e.corr.toStringAsFixed(3)}').join(' | ')}
裁决: ${worth ? '值得继续做（有弱信号）' : '当前不值得当主力特征包'}
原因: ${reasons.isEmpty ? '指标过线' : reasons.join('；')}
================================
''');

    expect(dim, greaterThan(0));
    expect(samples, isNotEmpty);
  }, timeout: const Timeout(Duration(minutes: 8)));
}

double _pearson(List<double> x, List<double> y) {
  final n = x.length;
  if (n != y.length || n < 2) return 0;
  var sx = 0.0, sy = 0.0;
  for (var i = 0; i < n; i++) {
    sx += x[i];
    sy += y[i];
  }
  final mx = sx / n;
  final my = sy / n;
  var nume = 0.0, dx = 0.0, dy = 0.0;
  for (var i = 0; i < n; i++) {
    final a = x[i] - mx;
    final b = y[i] - my;
    nume += a * b;
    dx += a * a;
    dy += b * b;
  }
  final den = math.sqrt(dx * dy);
  if (den < 1e-12) return 0;
  return nume / den;
}
