import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/widgets/chart_sync_controller.dart';
import 'package:chan_kline/widgets/kline_viewport.dart';
import 'package:flutter_test/flutter_test.dart';

/// 画板/分窗视口口径：每窗独立；缩小到视窗大于数据跨度后仍可双向拖动。
void main() {
  List<KlineBar> bars(int n) => [
        for (var i = 0; i < n; i++)
          KlineBar(
            idx: i,
            timeMs: i * 60000,
            timeText: '2026/07/10 09:30:00',
            open: 10,
            high: 11,
            low: 9,
            close: 10,
            volume: 1,
            amount: 0,
          ),
      ];

  test('分窗各层视口互不牵连', () {
    final sync = ChartSyncController();
    final v0 = sync.viewportFor(0);
    final v1 = sync.viewportFor(1);
    expect(identical(v0, v1), isFalse);

    v0.resetForBarCount(100);
    v1.resetForBarCount(100);
    v0.viewXMin = 10;
    v0.viewXMax = 40;
    expect(v1.viewXMin, 0);
    expect(v1.viewXMax, 99);
  });

  test('缩小到视窗大于数据跨度后，左右两侧都还能拖动', () {
    final vp = KlineViewport();
    vp.resetForBarCount(10);
    // 视窗跨度放大到 30（> 数据 10 根），两侧留空白。
    vp.viewXMin = -10;
    vp.viewXMax = 20;

    // 往左拖（dx>0 → 视窗向左移）：允许移动到 leftFloor 之外一点？不允许低于 allXMin-slack。
    vp.panByPixels(400, 0, 800, 400);
    expect(vp.viewXMin, greaterThanOrEqualTo(-20.0 - 1e-9));
    expect(vp.viewXMax, greaterThan(vp.viewXMin));

    // 往右拖（dx<0）：不能超过右边界 slack。
    final before = vp.viewXMax;
    vp.panByPixels(-4000, 0, 800, 400);
    expect(vp.viewXMax, lessThanOrEqualTo(10.0 + 20.0 + 1e-9));
    expect(vp.viewXMax, greaterThanOrEqualTo(before - 40));
  });

  test('未缩小到超跨度时，左边界仍贴数据左端', () {
    final vp = KlineViewport();
    vp.resetForBarCount(100);
    vp.viewXMin = 0;
    vp.viewXMax = 20;
    vp.panByPixels(4000, 0, 800, 400);
    expect(vp.viewXMin, closeTo(0.0, 1e-9));
  });
}
