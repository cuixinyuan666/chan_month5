import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/compute/k1_combine_compute.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// 首分型前各层统一取轨（2026-11-26 用户确认 · 全层同构）回归：
/// 窗口 Kn 只看上一层画面上的合并框，K1/K2/…/Kn 同一个函数。
void main() {
  List<KlineBar> mk(List<List<double>> ohlc) => [
        for (var i = 0; i < ohlc.length; i++)
          KlineBar(
            idx: i,
            timeMs: DateTime.utc(2026, 7, 10, 9, 30).millisecondsSinceEpoch +
                i * 60000,
            timeText:
                '2026/07/10 09:${(30 + i).toString().padLeft(2, '0')}:00',
            open: ohlc[i][0],
            high: ohlc[i][1],
            low: ohlc[i][2],
            close: ohlc[i][3],
            volume: 1,
            amount: 0,
          ),
      ];

  KlineCombineFrame f(int x1, int x2, double h, double l,
          {String fx = 'UNKNOWN', int count = 1}) =>
      KlineCombineFrame(
        x1: x1,
        x2: x2,
        t1: 't$x1',
        t2: 't$x2',
        high: h,
        low: l,
        fx: fx,
        count: count,
      );

  // 默认数据（2026-11-26 22:35 版）：第 1 根被第 0 根包含，首框 0..1（高高 9.88/9.78）；
  // 第 2 根整体更低 → 首框盖二元素顶章。
  final bars = mk([
    [9.88, 9.88, 9.69, 9.69],
    [9.81, 9.82, 9.78, 9.78],
    [9.76, 9.76, 9.72, 9.72],
  ]);

  test('K0 idx=0：首框只有 1 根、未盖章 → K1 不出生', () {
    final out = buildPreFirstUnifiedUnits(
      bars: bars.sublist(0, 1),
      parentFrames: [f(0, 0, 9.88, 9.69)],
      asOf: 0,
    );
    expect(out, isEmpty);
  });

  test('K0 idx=1：首框 0..1 未盖章 → idx=0 = 框内合成（真实高低），动态', () {
    final out = buildPreFirstUnifiedUnits(
      bars: bars.sublist(0, 2),
      parentFrames: [f(0, 1, 9.88, 9.78, count: 2)],
      asOf: 1,
    );
    expect(out.length, 1);
    final h = out.single;
    expect([h.idx, h.x1, h.x2], [0, 0, 1]);
    expect([h.open, h.high, h.low, h.close], [9.88, 9.88, 9.69, 9.78]);
    expect(h.confirmX > 1, isTrue, reason: '未盖章 → 动态虚线');
  });

  test('K0 idx=2：首根不压缩、转确认；idx=1 从首框右端起，9.88 → 9.72', () {
    final out = buildPreFirstUnifiedUnits(
      bars: bars,
      parentFrames: [
        f(0, 1, 9.88, 9.78, fx: 'TOP', count: 2),
        f(2, 2, 9.76, 9.72),
      ],
      asOf: 2,
    );
    expect(out.length, 2);
    final h = out[0];
    expect([h.idx, h.x1, h.x2], [0, 0, 1], reason: '首根不压缩');
    expect([h.open, h.high, h.low, h.close], [9.88, 9.88, 9.69, 9.78],
        reason: '与 idx=1 那步价位相同，不跳');
    expect(h.confirmX <= 2, isTrue, reason: '已盖章 → 确认实线');
    final s = out[1];
    expect([s.idx, s.x1, s.x2, s.dir], [1, 1, 2, -1]);
    expect([s.open, s.high, s.low, s.close], [9.88, 9.88, 9.72, 9.72]);
    expect(s.confirmX > 2, isTrue, reason: '右组未盖章 → 动态虚线');

    final frames = computeK1CombineFrames(
      bars,
      out,
      mode: PreFirstFractalMode.highHigh,
    );
    expect(frames.length, 1, reason: '两根有包含 → 一只合并框');
    expect([frames.first.x1, frames.first.x2], [0, 2]);
    expect(frames.first.count, 2);
  });

  test('上一组默认数据 K0 idx=2：结果与上一轮一致（全层同构未改价）', () {
    final b = mk([
      [10.06, 10.06, 9.86, 9.86],
      [10.16, 10.16, 9.84, 9.84],
      [10.24, 10.24, 10.21, 10.21],
    ]);
    final out = buildPreFirstUnifiedUnits(
      bars: b,
      parentFrames: [
        f(0, 1, 10.16, 9.86, fx: 'BOTTOM', count: 2),
        f(2, 2, 10.24, 10.21),
      ],
      asOf: 2,
    );
    expect([out[0].x1, out[0].x2, out[0].low], [0, 1, 9.84]);
    expect([out[1].x1, out[1].x2, out[1].open, out[1].close],
        [1, 2, 9.84, 10.24]);
  });

  test('上一层首框只有 1 个单元（K2 看 K1 的情形）：按单元数判单根，不按 K0 跨度', () {
    // K1 首框跨 K0 0..1，但只含 1 根 K1、未盖章 → 下一层不出生。
    final out = buildPreFirstUnifiedUnits(
      bars: bars.sublist(0, 2),
      parentFrames: [f(0, 1, 9.88, 9.69)],
      asOf: 1,
    );
    expect(out, isEmpty);
  });

  test('首框只有 1 根且已盖章 → 只有 idx=0（首连线两端），动态', () {
    final out = buildPreFirstUnifiedUnits(
      bars: bars,
      parentFrames: [f(0, 0, 9.88, 9.69, fx: 'TOP'), f(1, 2, 9.82, 9.72)],
      asOf: 2,
    );
    expect(out.length, 1);
    expect([out.single.x1, out.single.x2], [0, 2]);
    expect([out.single.open, out.single.close], [9.88, 9.72]);
    expect(out.single.confirmX > 2, isTrue);
  });

  test('默认数据 test4 K0 idx=1：首框单根已盖顶章 → 收盘取 K0 最新一根收盘 9.55（2026-11-27）', () {
    final b = mk([
      [10.12, 10.12, 9.85, 9.85],
      [9.37, 9.55, 9.37, 9.55],
    ]);
    final out = buildPreFirstUnifiedUnits(
      bars: b,
      parentFrames: [f(0, 0, 10.12, 9.85, fx: 'TOP'), f(1, 1, 9.55, 9.37)],
      asOf: 1,
    );
    expect(out.length, 1);
    final u = out.single;
    expect([u.idx, u.x1, u.x2], [0, 0, 1]);
    expect([u.open, u.high, u.low, u.close], [10.12, 10.12, 9.37, 9.55]);
    expect(u.confirmX > 1, isTrue, reason: '动态虚线');
  });

  test('Kn≥2：首框单根时收盘取调用方传入的上一层最新一根 K 收盘，并夹在高低内', () {
    final b = mk([
      [10.12, 10.12, 9.85, 9.85],
      [9.37, 9.55, 9.37, 9.55],
    ]);
    final head = [f(0, 0, 10.12, 9.85, fx: 'TOP'), f(1, 1, 9.55, 9.37)];
    final a = buildPreFirstUnifiedUnits(
        bars: b, parentFrames: head, asOf: 1, tailClose: 9.60);
    expect(a.single.close, 9.60);
    final c = buildPreFirstUnifiedUnits(
        bars: b, parentFrames: head, asOf: 1, tailClose: 11.0);
    expect(c.single.close, 10.12, reason: '夹在高低内');
  });
}
