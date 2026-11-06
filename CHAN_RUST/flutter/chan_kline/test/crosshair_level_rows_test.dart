import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/widgets/chart_sync_controller.dart';
import 'package:flutter_test/flutter_test.dart';

/// 十字信息按窗口层级过滤：
/// K0 窗口只出 K0，K1 窗口只出 K1，日期头始终保留。
void main() {
  List<CrosshairTooltipRow> sample() => const [
        CrosshairTooltipRow.kv('日期时间', '2004/07/19'),
        CrosshairTooltipRow.separator(),
        CrosshairTooltipRow.kv('K0 idx', '0'),
        CrosshairTooltipRow.kv('K0', 'O1'),
        CrosshairTooltipRow.kv('K0分型确认', '0'),
        CrosshairTooltipRow.separator(),
        CrosshairTooltipRow.kv('K1 idx', '0'),
        CrosshairTooltipRow.kv('K1', 'O2'),
        CrosshairTooltipRow.kv('K1中枢ZG', '3'),
        CrosshairTooltipRow.separator(),
        CrosshairTooltipRow.kv('K2 idx', '0'),
        CrosshairTooltipRow.kv('K2', 'O3'),
      ];

  List<String> labels(List<CrosshairTooltipRow> rows) => [
        for (final r in rows)
          if (!r.isSeparator && !r.isStar) r.label,
      ];

  test('K0 窗口只留 K0，去掉 K1/K2', () {
    final out = crosshairRowsForLevel(sample(), 0);
    expect(labels(out), ['日期时间', 'K0 idx', 'K0', 'K0分型确认']);
    expect(out.any((r) => r.label.startsWith('K1')), isFalse);
    expect(out.any((r) => r.label.startsWith('K2')), isFalse);
  });

  test('K1 窗口只留日期头和 K1', () {
    final out = crosshairRowsForLevel(sample(), 1);
    expect(labels(out), ['日期时间', 'K1 idx', 'K1', 'K1中枢ZG']);
    expect(out.any((r) => r.label.startsWith('K0')), isFalse);
    expect(out.any((r) => r.label.startsWith('K2')), isFalse);
  });

  test('K2 窗口只留日期头和 K2', () {
    final out = crosshairRowsForLevel(sample(), 2);
    expect(labels(out), ['日期时间', 'K2 idx', 'K2']);
  });

  test('十字信息开关随广播跨窗口保持', () {
    final sync = ChartSyncController();
    sync.viewportFor(0).resetForBarCount(100);
    sync.viewportFor(1).resetForBarCount(100);

    // 第一次滚轮单击：只开十字线，不出信息。
    sync.publishCrosshair(on: true, barIdx: 10, price: 5, ownerLevel: 0);
    expect(sync.crosshairOn, isTrue);
    expect(sync.crosshairTooltip, isFalse);

    // 第二次滚轮单击：开十字信息。
    sync.publishCrosshair(
      on: true,
      barIdx: 10,
      price: 5,
      ownerLevel: 0,
      tooltip: true,
    );
    expect(sync.crosshairTooltip, isTrue);

    // 鼠标跨到 K1 窗口：信息仍开着，主窗换成 K1。
    sync.publishCrosshair(
      on: true,
      barIdx: 11,
      price: 5.2,
      ownerLevel: 1,
      tooltip: true,
    );
    expect(sync.crosshairOwnerLevel, 1);
    expect(sync.crosshairTooltip, isTrue);

    // 关掉十字线：信息一起关。
    sync.publishCrosshair(on: false);
    expect(sync.crosshairOn, isFalse);
    expect(sync.crosshairTooltip, isFalse);
  });
}
