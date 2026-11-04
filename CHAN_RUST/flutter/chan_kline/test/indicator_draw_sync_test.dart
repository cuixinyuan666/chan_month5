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

  test('非默认指标勾选后默认 muted，需再点才绘制', () {
    final selected = Set<MainChartIndicator>.from(defaultMainIndicatorsK0())
      ..add(const MainChartIndicator.boll(0));
    final muted = <MainChartIndicator>{
      for (final e in selected)
        if (!isDefaultDrawnMain(e)) e,
    };
    final drawn = selected.difference(muted);
    expect(selected.contains(const MainChartIndicator.boll(0)), isTrue);
    expect(muted.contains(const MainChartIndicator.boll(0)), isTrue);
    expect(drawn.contains(const MainChartIndicator.boll(0)), isFalse);
  });

  test('层级分窗默认每个窗勾本层 Kn 与连线，其余主图指标全不启用', () {
    final mains = defaultLevelWindowMainIndicators(const [0, 1, 3, 5]);
    expect(mains, <MainChartIndicator>{
      const MainChartIndicator.kn(0),
      const MainChartIndicator.line(0),
      const MainChartIndicator.kn(1),
      const MainChartIndicator.line(1),
      const MainChartIndicator.kn(3),
      const MainChartIndicator.line(3),
      const MainChartIndicator.kn(5),
      const MainChartIndicator.line(5),
    });
    expect(mains.contains(const MainChartIndicator.combine(0)), isFalse);
    expect(mains.contains(const MainChartIndicator.zs(0)), isFalse);
  });

  test('分窗空勾选只兜底本层 Kn，不自动补合并/中枢/连线', () {
    final drawn = drawnMainIndicatorsForLevel(
      level: 1,
      selected: const <MainChartIndicator>{},
      muted: const <MainChartIndicator>{},
      catalog: buildMainIndicatorCatalog(3),
    );
    expect(drawn, <MainChartIndicator>{const MainChartIndicator.kn(1)});
    expect(drawn.any((e) => e.kind == MainIndicatorKind.combine), isFalse);
    expect(drawn.any((e) => e.kind == MainIndicatorKind.zs), isFalse);
    expect(drawn.any((e) => e.kind == MainIndicatorKind.line), isFalse);
  });

  test('分窗副图没勾选就留空，不再默认补量柱', () {
    final drawn = drawnSubIndicatorsForLevel(
      level: 1,
      selected: const <SubChartIndicator>{},
      muted: const <SubChartIndicator>{},
    );
    expect(drawn, isEmpty);
  });
}
