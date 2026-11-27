import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首分型前「父层首框 → 子层动态 K」回归（2026-11-19 全层同构）。
void main() {
  List<KlineBar> bars(List<List<double>> ohlc) => [
        for (var i = 0; i < ohlc.length; i++)
          KlineBar(
            idx: i,
            timeMs: DateTime.utc(2026, 7, 10, 9, 30).millisecondsSinceEpoch +
                i * 60000,
            timeText: '2026/07/10 09:${(30 + i).toString().padLeft(2, '0')}:00',
            open: ohlc[i][0],
            high: ohlc[i][1],
            low: ohlc[i][2],
            close: ohlc[i][3],
            volume: 1,
            amount: 0,
          ),
      ];

  KlineCombineFrame frame(
    int x1,
    int x2,
    double high,
    double low, {
    String fx = 'UNKNOWN',
  }) =>
      KlineCombineFrame(
        x1: x1,
        x2: x2,
        t1: 't$x1',
        t2: 't$x2',
        high: high,
        low: low,
        fx: fx,
        count: 1,
      );

  test('首根 = 父层首框固定映射：open=框内首根 open、close=框内末根 close、high/low=框沿', () {
    final b = bars([
      [10.22, 10.22, 9.98, 10.10],
      [10.10, 10.15, 10.02, 10.13],
      [10.13, 10.19, 10.11, 10.17],
      [10.17, 10.19, 10.17, 10.18],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [frame(0, 3, 10.22, 10.17)],
      asOf: 3,
    );
    expect(out.length, 1, reason: '无两元素章时只生首根');
    expect(out.first.open, closeTo(10.22, 1e-9));
    expect(out.first.close, closeTo(10.18, 1e-9));
    expect(out.first.high, closeTo(10.22, 1e-9));
    expect(out.first.low, closeTo(10.17, 1e-9));
    expect(out.first.confirmX, 3);
  });

  test('顶分型：第二根区间 = 首框最高 → 当前最低', () {
    final b = bars([
      [10.22, 10.22, 9.98, 10.10],
      [10.10, 10.15, 10.02, 10.13],
      [10.13, 10.19, 10.11, 10.17],
      [10.17, 10.19, 10.17, 10.18],
      [10.18, 10.18, 10.05, 10.08],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [frame(0, 3, 10.22, 10.17, fx: 'TOP')],
      asOf: 4,
    );
    expect(out.length, 2);
    final second = out[1];
    expect(second.dir, -1);
    expect(second.high, closeTo(10.22, 1e-9));
    expect(second.low, closeTo(10.05, 1e-9));
    expect(second.open, closeTo(10.22, 1e-9));
    expect(second.close, closeTo(10.05, 1e-9));
    expect(second.x2, 4);
  });

  test('底分型：第二根区间 = 首框最低 → 当前最高', () {
    final b = bars([
      [9.80, 9.90, 9.70, 9.85],
      [9.85, 9.95, 9.75, 9.90],
      [9.90, 9.98, 9.80, 9.95],
      [9.95, 10.20, 9.92, 10.15],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [frame(0, 2, 9.98, 9.70, fx: 'BOTTOM')],
      asOf: 3,
    );
    expect(out.length, 2);
    final second = out[1];
    expect(second.dir, 1);
    expect(second.low, closeTo(9.70, 1e-9));
    expect(second.high, closeTo(10.20, 1e-9));
    expect(second.open, closeTo(9.70, 1e-9));
    expect(second.close, closeTo(10.20, 1e-9));
  });

  test('父层首框为空：不生成', () {
    final out = buildPreFirstDynamicK1Bars(
      bars: bars([
        [10.0, 10.1, 9.9, 10.0],
      ]),
      parentFrames: const [],
      asOf: 0,
    );
    expect(out, isEmpty);
  });

  test('首框只有 1 根：只生成 idx=0，取第一条构建虚线端点，不生成 idx=1', () {
    final b = bars([
      [10.11, 10.11, 9.78, 9.78],
      [9.84, 9.84, 9.68, 9.68],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [frame(0, 0, 10.11, 9.78, fx: 'TOP')],
      asOf: 1,
    );
    expect(out.length, 1, reason: '单根首框不生成 idx=1');
    expect(out.first.idx, 0);
    expect(out.first.x1, 0);
    expect(out.first.x2, 1);
    expect(out.first.open, closeTo(10.11, 1e-9));
    expect(out.first.high, closeTo(10.11, 1e-9));
    expect(out.first.low, closeTo(9.68, 1e-9));
    expect(out.first.close, closeTo(9.68, 1e-9));
    expect(out.first.confirmX, greaterThan(1), reason: '保持动态');
  });

  test('首框只有 1 根：收盘取 K0 最新一根收盘（test4：9.55，不是终点价 9.37）', () {
    final b = bars([
      [10.12, 10.12, 9.85, 9.85],
      [9.37, 9.55, 9.37, 9.55],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [frame(0, 0, 10.12, 9.85, fx: 'TOP')],
      asOf: 1,
    );
    expect(out.length, 1);
    expect([out.first.open, out.first.high, out.first.low, out.first.close],
        [10.12, 10.12, 9.37, 9.55]);
  });

  test('首框只有 1 根且虚线未出现：不生成', () {
    final b = bars([
      [10.11, 10.11, 9.78, 9.78],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [frame(0, 0, 10.11, 9.78, fx: 'TOP')],
      asOf: 0,
    );
    expect(out, isEmpty);
  });

  test('首合并框仅单个（并框后 0..1、标记 firstBoxWasSingle）：只生成 idx=0', () {
    final b = bars([
      [10.11, 10.11, 9.78, 9.78],
      [9.84, 9.84, 9.68, 9.68],
    ]);
    final out = buildPreFirstDynamicK1Bars(
      bars: b,
      parentFrames: [
        const KlineCombineFrame(
          x1: 0,
          x2: 1,
          t1: 't0',
          t2: 't1',
          high: 10.11,
          low: 9.78,
          fx: 'TOP',
          count: 2,
          firstBoxWasSingle: true,
        ),
      ],
      asOf: 1,
    );
    expect(out.length, 1, reason: '首合并框仅单个不生成 idx=1');
    expect(out.first.open, closeTo(10.11, 1e-9));
    expect(out.first.high, closeTo(10.11, 1e-9));
    expect(out.first.low, closeTo(9.68, 1e-9));
    expect(out.first.close, closeTo(9.68, 1e-9));
    expect(out.first.x1, 0);
    expect(out.first.x2, 1);
    expect(out.first.confirmX, greaterThan(1));
  });

  group('二元素章预告线', () {
    test('顶分型：首框最高 ↔ 当前最低（构建中虚线）', () {
      final b = bars([
        [10.22, 10.22, 9.98, 10.10],
        [10.10, 10.15, 10.02, 10.13],
        [10.13, 10.19, 10.11, 10.17],
        [10.17, 10.19, 10.17, 10.18],
        [10.18, 10.18, 10.05, 10.08],
      ]);
      final line = computePreFirstFractalTipLine(
        bars: b,
        first: frame(0, 3, 10.22, 10.17, fx: 'TOP'),
        asOf: 4,
      );
      expect(line, isNotNull);
      expect(line!.begin.barIdx, 0);
      expect(line.begin.price, closeTo(10.22, 1e-9));
      expect(line.end.barIdx, 4);
      expect(line.end.price, closeTo(10.05, 1e-9));
      expect(line.dir, -1);
      expect(line.asSolid, isFalse, reason: '预告线走构建中虚线通道');
    });

    test('底分型：首框最低 ↔ 当前最高', () {
      final b = bars([
        [9.80, 9.90, 9.70, 9.85],
        [9.85, 9.95, 9.75, 9.90],
        [9.90, 9.98, 9.80, 9.95],
        [9.95, 10.20, 9.92, 10.15],
      ]);
      final line = computePreFirstFractalTipLine(
        bars: b,
        first: frame(0, 2, 9.98, 9.70, fx: 'BOTTOM'),
        asOf: 3,
      );
      expect(line, isNotNull);
      expect(line!.begin.barIdx, 0);
      expect(line.begin.price, closeTo(9.70, 1e-9));
      expect(line.end.barIdx, 3);
      expect(line.end.price, closeTo(10.20, 1e-9));
      expect(line.dir, 1);
    });

    test('无两元素章：不画预告线', () {
      final b = bars([
        [10.22, 10.22, 9.98, 10.10],
        [10.10, 10.15, 10.02, 10.13],
      ]);
      final line = computePreFirstFractalTipLine(
        bars: b,
        first: frame(0, 1, 10.22, 10.02),
        asOf: 1,
      );
      expect(line, isNull);
    });
  });
}
