import 'package:chan_kline/widgets/chart_level_line_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('各 Kn 层级样式：色/粗细/线型互异', () {
    final s2 = ChartLevelLineStyle.forLevel(2);
    final s3 = ChartLevelLineStyle.forLevel(3);
    final s4 = ChartLevelLineStyle.forLevel(4);
    final s5 = ChartLevelLineStyle.forLevel(5);

    expect(s2.color, isNot(s3.color));
    expect(s3.color, isNot(s4.color));
    expect(s2.strokeWidth, lessThan(s3.strokeWidth));
    expect(s3.strokeWidth, lessThan(s4.strokeWidth));
    expect(s4.frozenDashPattern, isNotNull);
    expect(s2.frozenDashPattern, isNull);
    expect(s2.buildingDashPattern, isNot(equals(s3.buildingDashPattern)));
  });

  test('shortLabel 输出连线展示名 K(level-1)', () {
    expect(ChartLevelLineStyle.shortLabel(2), 'K1');
    expect(ChartLevelLineStyle.shortLabel(5), 'K4');
  });

  test('同层连线与中枢同色', () {
    for (var displayKn = 0; displayKn <= 5; displayKn++) {
      final line = ChartLevelLineStyle.forLevel(displayKn + 1);
      final zs = ChartLevelLineStyle.forZS(displayKn);
      expect(line.color, zs.color, reason: 'K$displayKn 连线/中枢应同色');
    }
  });

  test('K0蓝 / K1黄 / K2粉', () {
    expect(
      ChartLevelLineStyle.colorForDisplayKn(0),
      const Color(0xCC6366F1),
    );
    expect(
      ChartLevelLineStyle.colorForDisplayKn(1),
      const Color(0xCCF59E0B),
    );
    expect(
      ChartLevelLineStyle.colorForDisplayKn(2),
      const Color(0xCCEC4899),
    );
  });
}
