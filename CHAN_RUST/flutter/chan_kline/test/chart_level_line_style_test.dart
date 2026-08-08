import 'package:chan_kline/widgets/chart_level_line_style.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('各 Kn 层级样式：色/粗细/线型互异（方案B·displayKn）', () {
    final s1 = ChartLevelLineStyle.forDisplayKn(1);
    final s2 = ChartLevelLineStyle.forDisplayKn(2);
    final s3 = ChartLevelLineStyle.forDisplayKn(3);
    final s4 = ChartLevelLineStyle.forDisplayKn(4);

    expect(s1.color, isNot(s2.color));
    expect(s2.color, isNot(s3.color));
    expect(s1.strokeWidth, lessThan(s2.strokeWidth));
    expect(s2.strokeWidth, lessThan(s3.strokeWidth));
    expect(s3.frozenDashPattern, isNotNull);
    expect(s1.frozenDashPattern, isNull);
    expect(s1.buildingDashPattern, isNot(equals(s2.buildingDashPattern)));
  });

  test('shortLabel 输出连线展示名 K{displayKn}', () {
    expect(ChartLevelLineStyle.shortLabel(0), 'K0');
    expect(ChartLevelLineStyle.shortLabel(1), 'K1');
    expect(ChartLevelLineStyle.shortLabel(4), 'K4');
  });

  test('同层连线与中枢同色', () {
    for (var displayKn = 0; displayKn <= 5; displayKn++) {
      final line = ChartLevelLineStyle.forDisplayKn(displayKn);
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
