import 'package:chan_kline/compute/kline_period_aggregate.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/chart_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

KlineBar _bar(int i) => KlineBar(
      idx: i,
      timeMs: i * 60000,
      timeText: '',
      open: 10,
      high: 11,
      low: 9,
      close: 10.5,
      volume: 1,
      amount: 0,
    );

void main() {
  test('跨周期按 timeMs 对位：同一时刻落在覆盖它的周期 K 上', () {
    final oneMin = List<KlineBar>.generate(30, _bar);
    final m5 = aggregateKlineBarsByPeriod(oneMin, '5m');
    final m15 = aggregateKlineBarsByPeriod(oneMin, '15m');

    // 周期 K 的 timeMs 取组末时间，所以「第一根 timeMs >= 目标」才是覆盖它的 K。
    expect(barIndexAtTimeMs(m5, oneMin[9].timeMs), 1,
        reason: '1m idx9 落在 5m 覆盖 5..9 的那根');
    expect(barIndexAtTimeMs(m15, oneMin[9].timeMs), 0,
        reason: '1m idx9 落在 15m 覆盖 0..14 的那根');
    expect(barIndexAtTimeMs(m15, oneMin[16].timeMs), 1);

    // 与 idx 比例交叉验证：floor(i/N) 才是同一时刻，而不是 clamp(i, N)。
    for (var i = 0; i < oneMin.length; i++) {
      expect(barIndexAtTimeMs(m5, oneMin[i].timeMs), i ~/ 5);
      expect(barIndexAtTimeMs(m15, oneMin[i].timeMs), i ~/ 15);
    }
  });

  test('跨周期对位边界：早于首根 / 晚于末根 / 空列表', () {
    final bars = List<KlineBar>.generate(10, _bar);
    expect(barIndexAtTimeMs(bars, -1), 0);
    expect(barIndexAtTimeMs(bars, 999999999), 9);
    expect(barIndexAtTimeMs(const <KlineBar>[], 0), 0);
  });

  test('timeMs 联动口径：ownerKey 生效且四窗视口绝不接管 / 还原', () {
    final sync = ChartSyncController();
    for (var k = 0; k < 4; k++) {
      final vp = sync.viewportFor(k)
        ..viewXMin = k * 100.0
        ..viewXMax = k * 100.0 + 50;
      expect(vp.viewXMin, k * 100.0);
    }
    String snap(int k) {
      final v = sync.viewportFor(k);
      return '${v.viewXMin}/${v.viewXMax}';
    }

    final before = {for (var k = 0; k < 4; k++) k: snap(k)};

    sync.publishCrosshair(
      on: true,
      barIdx: 9,
      price: 11.0,
      ownerLevel: 0,
      ownerKey: 2,
      matchMode: CrosshairMatchMode.timeMs,
      barTimeMs: 540000,
    );

    expect(sync.crosshairOwnerKey, 2);
    expect(sync.crosshairOwnerLevel, 2, reason: '旧字段保持兼容');
    expect(sync.crosshairMatchMode, CrosshairMatchMode.timeMs);
    expect(sync.crosshairBarTimeMs, 540000);
    for (var k = 0; k < 4; k++) {
      expect(snap(k), before[k], reason: '跨周期联动绝不接管视口');
    }

    sync.publishCrosshair(on: false);
    for (var k = 0; k < 4; k++) {
      expect(snap(k), before[k], reason: '关闭也不还原（从没接管过）');
    }
    expect(sync.crosshairOwnerKey, isNull);
    expect(sync.crosshairMatchMode, CrosshairMatchMode.levelIdx);
  });

  test('旧 levelIdx 口径不变：仍按层号接管与还原视口', () {
    final sync = ChartSyncController();
    for (var k = 0; k < 4; k++) {
      sync.viewportFor(k)
        ..viewXMin = k * 100.0
        ..viewXMax = k * 100.0 + 50;
    }

    sync.publishCrosshair(on: true, barIdx: 9, price: 11.0, ownerLevel: 2);
    expect(sync.viewportFor(0).viewXMin, sync.viewportFor(2).viewXMin,
        reason: '旧口径仍把其余窗视口抄成主窗');
    expect(sync.crosshairOwnerLevel, 2);

    sync.publishCrosshair(on: false);
    expect(sync.viewportFor(0).viewXMin, 0.0, reason: '旧口径关闭后还原');
  });
}
