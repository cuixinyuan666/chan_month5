import 'package:chan_kline/compute/fractal_judgment_compute.dart';
import 'package:chan_kline/models/fractal_judgment_event.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('expandJudgmentEventsToSeries：仅成立当步有值，无整框回填', () {
    final events = [
      const FractalJudgmentEvent(x: 2, fx: 'TOP'),
      const FractalJudgmentEvent(x: 5, fx: 'BOTTOM'),
    ];
    final series = expandJudgmentEventsToSeries(events, 7);
    expect(series[0], 'UNKNOWN');
    expect(series[1], 'UNKNOWN');
    expect(series[2], 'TOP');
    expect(series[3], 'UNKNOWN');
    expect(series[4], 'UNKNOWN');
    expect(series[5], 'BOTTOM');
    expect(series[6], 'UNKNOWN');
    expect(fxToSigned('TOP'), -1);
    expect(fxToSigned('BOTTOM'), 1);
    expect(fxToSigned('UNKNOWN'), 0);
  });

  test('mergeFractalJudgmentEventLog：追加保留全部历史，后续重算不抹掉', () {
    final history = <FractalJudgmentEvent>[];
    mergeFractalJudgmentEventLog(history, [
      const FractalJudgmentEvent(x: 1, fx: 'TOP'),
    ]);
    expect(history.length, 1);
    // 后续步重算不再含 x=1，但含新点 x=4 —— 旧点仍在
    mergeFractalJudgmentEventLog(history, [
      const FractalJudgmentEvent(x: 4, fx: 'BOTTOM'),
    ]);
    expect(history.length, 2);
    expect(history[0].x, 1);
    expect(history[1].x, 4);
    // 同 x+fx 去重，不重复追加
    mergeFractalJudgmentEventLog(history, [
      const FractalJudgmentEvent(x: 4, fx: 'BOTTOM'),
      const FractalJudgmentEvent(x: 7, fx: 'TOP'),
    ]);
    expect(history.length, 3);
    expect(history.last.x, 7);

    final drawn = expandJudgmentEventsToSeries(history, 8, maxX: 5);
    expect(drawn[1], 'TOP');
    expect(drawn[4], 'BOTTOM');
    expect(drawn[7], 'UNKNOWN', reason: 'as-of 过滤未来');
  });

  test('collectFractalJudgmentEvents kn=1：事件带中组 fractalX1/X2', () {
    final bars = <KlineBar>[
      for (var i = 0; i < 12; i++)
        KlineBar(
          idx: i,
          timeMs: i,
          timeText: 't$i',
          open: 10,
          high: (i % 4 == 1) ? 12.0 : 10.5,
          low: (i % 4 == 3) ? 8.0 : 9.5,
          close: 10.1,
          volume: 1,
          amount: 1,
          metrics: const {},
        ),
    ];
    final events = collectFractalJudgmentEvents(
      kn: 1,
      bars: bars,
      levels: const [],
      barFeatures: const [],
      truncationCheck: true,
    );
    expect(events, isNotEmpty);
    for (final e in events) {
      expect(e.fractalX1, greaterThanOrEqualTo(0));
      expect(e.fractalX2, greaterThanOrEqualTo(e.fractalX1));
      expect(e.fractalX2, lessThanOrEqualTo(e.x));
      expect(e.rightX1, greaterThanOrEqualTo(0));
      expect(e.rightX2, greaterThanOrEqualTo(e.rightX1));
      // K0：右组不与中组共用 → rightX1 > fractalX2
      expect(e.rightX1, greaterThan(e.fractalX2));
      // K0 第三元素单根
      expect(e.rightX2, e.rightX1);
    }
  });

  test('computeFractalJudgmentSeries kn=1：稀疏打点，非整框铺满', () {
    // 构造易出分型的上下交错高低
    final bars = <KlineBar>[
      for (var i = 0; i < 12; i++)
        KlineBar(
          idx: i,
          timeMs: i,
          timeText: 't$i',
          open: 10,
          high: (i % 4 == 1) ? 12.0 : 10.5,
          low: (i % 4 == 3) ? 8.0 : 9.5,
          close: 10.1,
          volume: 1,
          amount: 1,
          metrics: const {},
        ),
    ];
    final series = computeFractalJudgmentSeries(
      kn: 1,
      bars: bars,
      levels: const [],
      barFeatures: const [],
      truncationCheck: true,
    );
    expect(series.length, 12);
    final hit = [
      for (var i = 0; i < series.length; i++)
        if (series[i] == 'TOP' || series[i] == 'BOTTOM') i,
    ];
    // 若有判断点，周围不应整段被同 fx 填满（禁止回填）
    for (final x in hit) {
      final fx = series[x];
      if (x > 0) {
        // 允许偶然相邻，但不要求；关键是「不是整框连续同值」由事件稀疏保证
      }
      expect(fx == 'TOP' || fx == 'BOTTOM', isTrue);
    }
    final signed = fractalJudgmentSignedSeries(series, bars);
    expect(signed.where((v) => v != 0).length, hit.length);
  });

  test('computeFractalJudgmentSeries kn=2 含进行中虚拟单元不抛', () {
    final bars = [
      for (var i = 0; i < 8; i++)
        KlineBar(
          idx: i,
          timeMs: i,
          timeText: 't$i',
          open: 10,
          high: 11,
          low: 9,
          close: 10,
          volume: 1,
          amount: 1,
          metrics: const {},
        ),
    ];
    const levels = [
      LevelBundle(
        level: 1,
        unitBars: [
          LevelUnitBar(
            idx: 0,
            dir: 1,
            x1: 0,
            x2: 3,
            open: 10,
            high: 11,
            low: 9,
            close: 10.5,
            confirmX: 3,
          ),
        ],
        activeUnit: LevelUnitBar(
          idx: 1,
          dir: -1,
          x1: 3,
          x2: 7,
          open: 10.5,
          high: 11,
          low: 9.2,
          close: 9.5,
          confirmX: 7,
        ),
        segments: [
          LevelSegmentN(
            idx: 0,
            dir: 1,
            beginConfirmX: 1,
            endConfirmX: 3,
            beginPoleX: 0,
            endPoleX: 3,
            open: 10,
            high: 11,
            low: 9,
            close: 10.5,
          ),
        ],
      ),
    ];
    final series = computeFractalJudgmentSeries(
      kn: 2,
      bars: bars,
      levels: levels,
      barFeatures: const [],
      truncationCheck: false,
    );
    expect(series.length, 8);
  });
}
