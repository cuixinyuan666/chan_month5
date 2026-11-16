import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/chip_config.dart';
import 'package:chan_kline/models/kline_combine_bundle.dart';
import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:chan_kline/models/tick_dist_config.dart';
import 'package:chan_kline/widgets/chart_sync_controller.dart';
import 'package:chan_kline/widgets/kline_chart.dart';
import 'package:chan_kline/widgets/kline_draw_board.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _host(KlineDrawBoardModel model) => MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 900,
          height: 700,
          child: KlineDrawBoard(
            model: model,
            bundle: KlineCombineBundle.empty(),
            mainIndicators: const <MainChartIndicator>{},
            subIndicators: const <SubChartIndicator>{},
            truncationCheck: true,
            earlyDynamicUnit: true,
            showBuildingDash: true,
            chipConfig: const ChipConfig(),
            tickDistConfig: const TickDistConfig(),
            onChanged: (_) {},
            onMainIndicatorsChanged: (_) {},
            onSubIndicatorsChanged: (_) {},
          ),
        ),
      ),
    );

/// 开启十字线后，光标在任意子窗口移动时该窗接管主窗——参考分笔画板逻辑。
/// 与分笔不同的是 K线画板四窗周期各异，走 timeMs 跨周期对位且视口互不接管。
void main() {
  testWidgets('开启十字线后光标移入任一子窗，该窗接管主窗并按 timeMs 跨周期对位',
      (tester) async {
    var model = KlineDrawBoardModel.initial();
    for (var i = 0; i < 30; i++) {
      model = model.addCandle(KlineDrawCandle(
        open: 10.0 + i,
        high: 11.0 + i,
        low: 9.0 + i,
        close: 10.5 + i,
      ));
    }
    await tester.pumpWidget(_host(model));
    await tester.pump();

    KlineChart chart(String key) =>
        tester.widget<KlineChart>(find.byKey(ValueKey<String>(key)));
    final k0 = chart('kline-draw-0-0-1m');
    final sync = k0.sync!;
    final barTimeMs = k0.bars[12].timeMs;

    // 在操作窗开启十字线（模拟双击/中键后控制器进入 on 状态）
    sync.publishCrosshair(
      on: true,
      barIdx: 12,
      price: 16.0,
      ownerLevel: 0,
      ownerKey: 0,
      matchMode: CrosshairMatchMode.timeMs,
      barTimeMs: barTimeMs,
      tooltip: true,
    );
    await tester.pump();
    expect(sync.crosshairOn, isTrue);
    expect(sync.crosshairOwnerKey, 0);

    // 单个连续鼠标手势，依次移入三个子窗（右上 1min-K1 / 左下 5min / 右下 15min），
    // 每个都应接管为主窗。参考分笔「光标进哪个窗哪个窗接管」的联动口径。
    final gesture = await tester.createGesture(kind: PointerDeviceKind.mouse);
    for (final entry in <MapEntry<String, int>>[
      const MapEntry<String, int>('kline-draw-1-1-1m', 1),
      const MapEntry<String, int>('kline-draw-2-0-5m', 2),
      const MapEntry<String, int>('kline-draw-3-0-15m', 3),
    ]) {
      final finder = find.byKey(ValueKey<String>(entry.key));
      expect(finder, findsOneWidget, reason: '子窗 ${entry.key} 应存在');
      final box = tester.element(finder).findRenderObject() as RenderBox;
      final origin = tester.getTopLeft(finder);
      await gesture.moveTo(
          origin + Offset(box.size.width * 0.6, box.size.height * 0.5));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 80));

      expect(sync.crosshairOwnerKey, entry.value,
          reason: '光标移入子窗 ${entry.key} 后应由该窗接管为主窗');
      expect(sync.crosshairMatchMode, CrosshairMatchMode.timeMs,
          reason: '跨周期联动口径保持 timeMs');
      // 接管不能把十字线本身关掉（早期实现里「刚接手」的分支若广播 on=false，
      // 光标一进少根 K 的周期窗十字线就消失）。
      expect(sync.crosshairOn, isTrue,
          reason: '接管主窗后十字线仍应保持开启');
    }
  });
}
