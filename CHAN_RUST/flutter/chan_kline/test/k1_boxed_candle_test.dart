import 'package:chan_kline/compute/chart_view_compute.dart';
import 'package:chan_kline/models/k1_bar.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:flutter_test/flutter_test.dart';

/// 实测默认 TEST 股 1 分钟数据（a_Data/test/custom.1m.csv）：
/// idx0 10.22/10.22/9.98/9.98 … idx11 共 11 根。
const _raw = <List<double>>[
  [10.22, 10.22, 9.98, 9.98],
  [10.10, 10.11, 10.02, 10.02],
  [10.15, 10.15, 10.11, 10.11],
  [10.19, 10.19, 10.17, 10.17],
  [10.10, 10.10, 10.07, 10.07],
  [10.19, 10.19, 10.15, 10.15],
];

List<KlineBar> _bars() => List<KlineBar>.generate(
      _raw.length,
      (i) => KlineBar(
        idx: i,
        open: _raw[i][0],
        high: _raw[i][1],
        low: _raw[i][2],
        close: _raw[i][3],
        volume: 1,
        timeMs: 1783000000000 + i * 60000,
        timeText: '09:${(30 + i).toString().padLeft(2, '0')}',
        amount: 0,
      ),
    );

K1Bar _unit(
  int idx, {
  required int x1,
  required int x2,
  required double o,
  required double h,
  required double l,
  required double c,
}) =>
    K1Bar(
      idx: idx,
      dir: 1,
      x1: x1,
      x2: x2,
      open: o,
      high: h,
      low: l,
      close: c,
      confirmX: x2,
    );

void main() {
  test('asOf=4：只有退化单元 0..0 时，补出首分型框 + 进行中动态 K', () {
    final units = [
      _unit(0, x1: 0, x2: 0, o: 10.17, h: 10.17, l: 10.17, c: 10.17),
    ];
    final out = boxedFirstFractalCandleBars(
      units: units,
      bars: _bars(),
      firstFractalX1: 0,
      firstFractalX2: 3,
      asOf: 4,
    );
    expect(out.length, 2);
    // 首根 = 首分型框整体极值
    expect(out[0].x1, 0);
    expect(out[0].x2, 3);
    expect(out[0].high, 10.22);
    expect(out[0].low, 9.98);
    // 第二根 = 框右端 → 当步
    expect(out[1].idx, 1);
    expect(out[1].x1, 3);
    expect(out[1].x2, 4);
    expect(out[1].high, 10.19);
    expect(out[1].low, 10.07);
  });

  test('asOf=5：末单元已盖到当步，不再重复补动态 K', () {
    final units = [
      _unit(0, x1: 0, x2: 0, o: 10.17, h: 10.17, l: 10.17, c: 10.17),
      _unit(1, x1: 0, x2: 4, o: 10.22, h: 10.22, l: 9.98, c: 10.07),
      _unit(2, x1: 4, x2: 5, o: 10.10, h: 10.10, l: 10.07, c: 10.07),
    ];
    final out = boxedFirstFractalCandleBars(
      units: units,
      bars: _bars(),
      firstFractalX1: 0,
      firstFractalX2: 3,
      asOf: 5,
    );
    expect(out.length, 3);
    expect(out.map((u) => '${u.x1}..${u.x2}').toList(),
        ['0..3', '3..4', '4..5']);
  });

  test('首单元非退化（已过首分型框阶段）时原样返回', () {
    final units = [
      _unit(1, x1: 0, x2: 4, o: 10.22, h: 10.22, l: 9.98, c: 10.07),
    ];
    final out = boxedFirstFractalCandleBars(
      units: units,
      bars: _bars(),
      firstFractalX1: 0,
      firstFractalX2: 3,
      asOf: 5,
    );
    expect(identical(out, units), isTrue);
  });
}
