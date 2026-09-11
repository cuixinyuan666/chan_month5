import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/widgets/indicator_picker_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三级导航分组口径：层级 → 类别 → 指标。
void main() {
  test('主图 catalog 可按 displayLevel 与 category 分组', () {
    final cat = buildMainIndicatorCatalog(2);
    final levels = mainDisplayLevels(cat);
    expect(levels, [0, 1, 2]);

    final k0 = cat.where((e) => e.displayLevel == 0).toList();
    final cats = k0.map((e) => e.kind.categoryLabel).toSet();
    expect(cats, containsAll(['K线', '合并', '中枢', '连线', '延伸', '均线']));
    expect(k0.any((e) => e.kind == MainIndicatorKind.boll), isTrue);
  });

  test('副图 catalog 可按 displayLevel 与 category 分组', () {
    final cat = buildSubIndicatorCatalog(2);
    final levels = subDisplayLevels(cat);
    expect(levels, containsAll([0, 1]));

    final k0 = cat.where((e) => e.displayLevel == 0).toList();
    final cats = k0.map((e) => e.kind.categoryLabel).toSet();
    expect(cats, contains('成交量'));
    expect(cats, contains('分型确认'));
    expect(k0.any((e) => e.kind == SubIndicatorKind.macd), isTrue);
  });

  test('K0 的 K线类别只有一项，应直接勾选而不进子菜单', () {
    final cat = buildMainIndicatorCatalog(2);
    final kLine = cat
        .where((e) => e.displayLevel == 0 && e.kind.categoryLabel == 'K线')
        .toList();
    expect(kLine, hasLength(1));
    expect(kLine.single.kind, MainIndicatorKind.kn);
    expect(pickerHasUniqueChild(kLine), isTrue);

    final extend = cat
        .where((e) => e.displayLevel == 0 && e.kind.categoryLabel == '延伸')
        .toList();
    expect(extend.length, greaterThan(1));
    expect(pickerHasUniqueChild(extend), isFalse);

    final vol = buildSubIndicatorCatalog(2)
        .where((e) => e.displayLevel == 0 && e.kind.categoryLabel == '成交量')
        .toList();
    expect(pickerHasUniqueChild(vol), isTrue);
    final nBs = buildSubIndicatorCatalog(2)
        .where((e) => e.displayLevel == 0 && e.kind.categoryLabel == 'N类BS')
        .toList();
    expect(pickerHasUniqueChild(nBs), isFalse);
  });
}
