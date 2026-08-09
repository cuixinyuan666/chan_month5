import 'dart:convert';
import 'dart:io';

import 'package:chan_kline/ml/ml_bsp_export.dart';
import 'package:chan_kline/ml/ml_bsp_labeler.dart';
import 'package:chan_kline/ml/ml_bsp_sample.dart';
import 'package:chan_kline/ml/ml_bsp_sampler.dart';
import 'package:chan_kline/ml/ml_feature_flat.dart';
import 'package:chan_kline/ml/ml_feature_schema.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/buy1_frame.dart';
import 'package:chan_kline/models/k0_line.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/sell1_frame.dart';
import 'package:flutter_test/flutter_test.dart';

List<KlineBar> _bars(int n) => List.generate(
      n,
      (i) => KlineBar(
        idx: i,
        timeMs: i * 60000,
        timeText: '2024/01/02 09:${i.toString().padLeft(2, '0')}',
        open: 10.0 + i * 0.1,
        high: 10.5 + i * 0.1,
        low: 9.5 + i * 0.1,
        close: 10.2 + i * 0.1,
        volume: 100,
        amount: 1,
      ),
    );

void main() {
  test('采样去重：同 step 同 key 只采一次', () {
    final bars = _bars(5);
    final sampler = MlBspSampler();
    final buy = const Buy1Frame(
      x: 2,
      price: 9.7,
      label: '1Ba',
      segIdx: 0,
      level: 0,
    );
    BarFeatureLookup build() => BarFeatureLookup.build(
          bars: bars.take(3).toList(),
          combineFrames: const [],
          k0Confirms: const [],
        );
    sampler.onStep(
      stepIdx: 2,
      visibleBars: bars.take(3).toList(),
      buy1K0: [buy],
      sell1K0: const [],
      buildLookup: build,
    );
    sampler.onStep(
      stepIdx: 2,
      visibleBars: bars.take(3).toList(),
      buy1K0: [buy],
      sell1K0: const [],
      buildLookup: build,
    );
    expect(sampler.samples.length, 1);
    expect(sampler.samples.first.side, 'B');
  });

  test('α label：集合命中 + K0连线最低为√', () {
    // 构造：x=1 为区间最低
    final bars = [
      const KlineBar(
        idx: 0,
        timeMs: 0,
        timeText: 't0',
        open: 10,
        high: 11,
        low: 10,
        close: 10.5,
        volume: 1,
        amount: 1,
      ),
      const KlineBar(
        idx: 1,
        timeMs: 1,
        timeText: 't1',
        open: 10,
        high: 10.2,
        low: 9.0,
        close: 9.5,
        volume: 1,
        amount: 1,
      ),
      const KlineBar(
        idx: 2,
        timeMs: 2,
        timeText: 't2',
        open: 9.5,
        high: 12,
        low: 9.4,
        close: 11,
        volume: 1,
        amount: 1,
      ),
    ];
    const line = K0Line(
      idx: 0,
      dir: 1,
      beginConfirmX: 0,
      endConfirmX: 2,
      beginFractalX1: 0,
      beginFractalX2: 0,
      endFractalX1: 2,
      endFractalX2: 2,
    );
    final sample = MlBspSample(
      x: 1,
      side: 'B',
      label: '1Ba',
      price: 9.0,
      segIdx: 0,
      openTime: 't1',
      featureFrozenAt: 1,
      features: {'open': 10},
    );
    MlBspLabeler.applyLabels(
      samples: [sample],
      finalBuy1K0: const [
        Buy1Frame(x: 1, price: 9.0, label: '1Ba', segIdx: 0, level: 0),
      ],
      finalSell1K0: const [],
      k0Lines: const [line],
      bars: bars,
    );
    expect(sample.isCorrect, isTrue);

    final lost = MlBspSample(
      x: 1,
      side: 'B',
      label: '1Ba',
      price: 9.0,
      segIdx: 0,
      openTime: 't1',
      featureFrozenAt: 1,
      features: const {},
    );
    MlBspLabeler.applyLabels(
      samples: [lost],
      finalBuy1K0: const [],
      finalSell1K0: const [],
      k0Lines: const [line],
      bars: bars,
    );
    expect(lost.isCorrect, isFalse);
  });

  test('导出 libsvm/meta 无禁止键且 label 对齐', () async {
    final dir = await Directory.systemTemp.createTemp('ml_bsp_');
    final samples = [
      MlBspSample(
        x: 1,
        side: 'B',
        label: '1Ba',
        price: 9,
        segIdx: 0,
        openTime: 't',
        featureFrozenAt: 1,
        features: {'open': 1.0, 'sub.volume_0': 2.0},
      )..isCorrect = true,
      MlBspSample(
        x: 2,
        side: 'S',
        label: '1Sa',
        price: 12,
        segIdx: 0,
        openTime: 't',
        featureFrozenAt: 2,
        features: {'open': 3.0},
      )..isCorrect = false,
    ];
    // 禁止键不应进 flatten；这里直接测 schema
    expect(MlFeatureSchema.isForbiddenKey('K0筹码峰-1'), isTrue);

    final result = await MlBspExport.write(
      samples: samples,
      dataRoot: dir.path,
      code: '000001',
      period: '1m',
      stepIdx: 2,
    );
    expect(File(result.libsvmPath).existsSync(), isTrue);
    expect(File(result.trainPath).existsSync(), isTrue);
    expect(File(result.examPath).existsSync(), isTrue);
    expect(File(result.examReportPath).existsSync(), isTrue);
    expect(File(result.metaPath).existsSync(), isTrue);
    // 默认 70/30：2 条 → 训练1 / 考试1；feature.libsvm=训练集
    expect(result.trainCount, 1);
    expect(result.examCount, 1);
    final trainLines = await File(result.trainPath).readAsLines();
    final examLines = await File(result.examPath).readAsLines();
    expect(trainLines.length, 1);
    expect(examLines.length, 1);
    expect(trainLines[0].startsWith('1 '), isTrue);
    expect(examLines[0].startsWith('0 '), isTrue);
    final meta = jsonDecode(await File(result.metaPath).readAsString()) as Map;
    expect(meta.containsKey('open'), isTrue);

    final dense = MlFeatureFlat.denseFromMeta(
      {for (final e in meta.entries) e.key.toString(): (e.value as num).toInt()},
      samples[0].features,
    );
    expect(dense.length, meta.length);
    await dir.delete(recursive: true);
  });

  test('Sell1 极值：最高点为√', () {
    final bars = [
      const KlineBar(
        idx: 0,
        timeMs: 0,
        timeText: 't0',
        open: 10,
        high: 10.5,
        low: 9.5,
        close: 10,
        volume: 1,
        amount: 1,
      ),
      const KlineBar(
        idx: 1,
        timeMs: 1,
        timeText: 't1',
        open: 10,
        high: 13.0,
        low: 10,
        close: 12,
        volume: 1,
        amount: 1,
      ),
      const KlineBar(
        idx: 2,
        timeMs: 2,
        timeText: 't2',
        open: 12,
        high: 12.2,
        low: 11,
        close: 11.5,
        volume: 1,
        amount: 1,
      ),
    ];
    const line = K0Line(
      idx: 0,
      dir: -1,
      beginConfirmX: 0,
      endConfirmX: 2,
      beginFractalX1: 0,
      beginFractalX2: 0,
      endFractalX1: 2,
      endFractalX2: 2,
    );
    final sample = MlBspSample(
      x: 1,
      side: 'S',
      label: '1Sa',
      price: 13.0,
      segIdx: 0,
      openTime: 't1',
      featureFrozenAt: 1,
      features: const {},
    );
    MlBspLabeler.applyLabels(
      samples: [sample],
      finalBuy1K0: const [],
      finalSell1K0: const [
        Sell1Frame(x: 1, price: 13.0, label: '1Sa', segIdx: 0, level: 0),
      ],
      k0Lines: const [line],
      bars: bars,
    );
    expect(sample.isCorrect, isTrue);
  });
}
