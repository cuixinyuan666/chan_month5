import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/models/chart_indicator.dart';

/// 收纳列表白字=已选=绘制：选择集与默认绘制口径一致。
void main() {
  test('默认启动只含 isDefaultDrawn 主/副图指标', () {
    final mains = defaultMainIndicatorsK0();
    final subs = defaultSubIndicatorsK0();
    expect(mains.every(isDefaultDrawnMain), isTrue);
    expect(subs.every(isDefaultDrawnSub), isTrue);
    expect(mains.contains(const MainChartIndicator.boll(0)), isFalse);
    expect(subs.contains(const SubChartIndicator.volume(0)), isFalse);
  });

  test('用户勾选非默认指标后应进入选择集（无 muted 裁剪）', () {
    final selected = Set<MainChartIndicator>.from(defaultMainIndicatorsK0())
      ..add(const MainChartIndicator.boll(0));
    final drawn = selected; // 修复后：drawn == selected
    expect(selected.contains(const MainChartIndicator.boll(0)), isTrue);
    expect(drawn.contains(const MainChartIndicator.boll(0)), isTrue);
    expect(drawn.length, selected.length);
  });
}
