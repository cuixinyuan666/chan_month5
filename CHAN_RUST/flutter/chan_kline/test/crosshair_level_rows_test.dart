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

  test('信息开着时，新窗口按自己本地状态广播不得把信息关掉', () {
    // 复现：鼠标移进新窗口，该窗本地还停在「只有十字线」，
    // 下一帧广播若按本地状态发 tooltip:false，面板就消失。
    // 口径：信息开关只升不降，关掉只能显式发 tooltip:false。
    final sync = ChartSyncController();
    sync.viewportFor(0).resetForBarCount(100);
    sync.viewportFor(1).resetForBarCount(100);

    sync.publishCrosshair(
      on: true,
      barIdx: 10,
      price: 5,
      ownerLevel: 0,
      tooltip: true,
    );

    final keep = sync.crosshairTooltip || false;
    sync.publishCrosshair(
      on: true,
      barIdx: 11,
      price: 5.2,
      ownerLevel: 1,
      tooltip: keep,
    );
    expect(sync.crosshairOwnerLevel, 1, reason: '主窗换成鼠标所在的窗口');
    expect(sync.crosshairTooltip, isTrue, reason: '跨窗不得把已开的信息关掉');

    // 关闭按钮：显式发 tooltip:false 才关。
    sync.publishCrosshair(
      on: true,
      barIdx: 11,
      price: 5.2,
      ownerLevel: 1,
      tooltip: false,
    );
    expect(sync.crosshairOn, isTrue);
    expect(sync.crosshairTooltip, isFalse);
  });
}
