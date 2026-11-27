import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/widgets/indicator_picker_overlay.dart';
import 'package:flutter_test/flutter_test.dart';

/// 三级树形分组口径：层级 → 类别 → 指标。
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
    expect(cats, contains('KnN类BS'));
    expect(cats, contains('背驰'));
    expect(k0.any((e) => e.kind == SubIndicatorKind.macd), isTrue);
  });

  test('K0 的 K线类别只有一项，应直接勾选而不展开子列表', () {
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
    final knNbs = buildSubIndicatorCatalog(2)
        .where((e) => e.displayLevel == 0 && e.kind.categoryLabel == 'KnN类BS')
        .toList();
    expect(knNbs.length, greaterThan(2));
    expect(knNbs.any((e) => e.kind == SubIndicatorKind.buy1), isTrue);
    expect(knNbs.any((e) => e.kind == SubIndicatorKind.buy2), isTrue);
    expect(knNbs.any((e) => e.kind == SubIndicatorKind.buyN), isTrue);
    expect(pickerHasUniqueChild(knNbs), isFalse);
  });

  test('延伸/均线/KnN类BS/背驰 默认展开；K 层默认折叠', () {
    expect(pickerCategoryDefaultExpanded('延伸'), isTrue);
    expect(pickerCategoryDefaultExpanded('均线'), isTrue);
    expect(pickerCategoryDefaultExpanded('KnN类BS'), isTrue);
    expect(pickerCategoryDefaultExpanded('背驰'), isTrue);
    expect(pickerCategoryDefaultExpanded('成交量'), isFalse);
    expect(pickerCategoryKey(1, '延伸'), '1|延伸');
  });

  test('KnN类BS 内排序：一类→二类→三类', () {
    final cat = buildSubIndicatorCatalog(1);
    final knN = cat
        .where((e) => e.displayLevel == 0 && e.kind.categoryLabel == 'KnN类BS')
        .toList()
      ..sort((a, b) => subIndicatorPickerOrder(a).compareTo(subIndicatorPickerOrder(b)));
    expect(knN.first.kind, SubIndicatorKind.buy1);
    expect(knN[1].kind, SubIndicatorKind.buy2);
    expect(knN[2].kind, SubIndicatorKind.buyN);
    expect(knN[2].bsClass, 3);
  });
}
