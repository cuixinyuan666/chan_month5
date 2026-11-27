import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:chan_kline/models/pre_first_fractal_unit_mode.dart';
import 'package:flutter_test/flutter_test.dart';

/// 「层级早生成 / 首分型前合并框」四档合一后的派生与迁移口径。
void main() {
  group('四档 → 两个内部字段的派生', () {
    test('关闭档：总闸关，闸下口径回落高高（不参与绘制）', () {
      const m = PreFirstFractalUnitMode.off;
      expect(m.earlyDynamicUnit, isFalse);
      expect(m.preFirstFractalMode, PreFirstFractalMode.highHigh);
    });

    test('三个开启档：总闸开，闸下口径按档位', () {
      expect(PreFirstFractalUnitMode.seedBox.earlyDynamicUnit, isTrue);
      expect(
        PreFirstFractalUnitMode.seedBox.preFirstFractalMode,
        PreFirstFractalMode.seedBox,
      );
      expect(PreFirstFractalUnitMode.highHigh.earlyDynamicUnit, isTrue);
      expect(
        PreFirstFractalUnitMode.highHigh.preFirstFractalMode,
        PreFirstFractalMode.highHigh,
      );
      expect(PreFirstFractalUnitMode.lowLow.earlyDynamicUnit, isTrue);
      expect(
        PreFirstFractalUnitMode.lowLow.preFirstFractalMode,
        PreFirstFractalMode.lowLow,
      );
    });

    test('默认档＝开启 · 高高（与合并前的默认组合一致）', () {
      expect(
        PreFirstFractalUnitMode.defaultMode,
        PreFirstFractalUnitMode.highHigh,
      );
      expect(PreFirstFractalUnitMode.defaultMode.earlyDynamicUnit, isTrue);
      expect(
        PreFirstFractalUnitMode.defaultMode.preFirstFractalMode,
        PreFirstFractalMode.defaultMode,
      );
    });
  });

  group('落盘值', () {
    test('storageValue 用枚举名，可原样 round-trip', () {
      for (final m in PreFirstFractalUnitMode.values) {
        expect(m.storageValue, m.name);
        expect(PreFirstFractalUnitMode.fromStorage(m.storageValue), m);
      }
    });

    test('缺键 / 脏值回落默认（开启 · 高高）', () {
      expect(PreFirstFractalUnitMode.fromStorage(null), PreFirstFractalUnitMode.highHigh);
      expect(
        PreFirstFractalUnitMode.fromStorage('不存在的档位'),
        PreFirstFractalUnitMode.highHigh,
      );
      expect(PreFirstFractalUnitMode.fromStorage(1), PreFirstFractalUnitMode.highHigh);
    });
  });

  group('老设置文件迁移（两旧键 → 四档）', () {
    test('early_dynamic_unit=false → 关闭档（忽略并框口径）', () {
      expect(
        PreFirstFractalUnitMode.fromLegacy(
          earlyDynamicUnit: false,
          mode: PreFirstFractalMode.lowLow,
        ),
        PreFirstFractalUnitMode.off,
      );
    });

    test('early_dynamic_unit=true → 按旧并框口径落到对应开启档', () {
      expect(
        PreFirstFractalUnitMode.fromLegacy(
          earlyDynamicUnit: true,
          mode: PreFirstFractalMode.seedBox,
        ),
        PreFirstFractalUnitMode.seedBox,
      );
      expect(
        PreFirstFractalUnitMode.fromLegacy(
          earlyDynamicUnit: true,
          mode: PreFirstFractalMode.highHigh,
        ),
        PreFirstFractalUnitMode.highHigh,
      );
      expect(
        PreFirstFractalUnitMode.fromLegacy(
          earlyDynamicUnit: true,
          mode: PreFirstFractalMode.lowLow,
        ),
        PreFirstFractalUnitMode.lowLow,
      );
    });

    test('迁移后再派生回两个字段，与老文件完全一致', () {
      for (final legacyEarly in <bool>[true, false]) {
        for (final legacyMode in PreFirstFractalMode.values) {
          final unit = PreFirstFractalUnitMode.fromLegacy(
            earlyDynamicUnit: legacyEarly,
            mode: legacyMode,
          );
          expect(unit.earlyDynamicUnit, legacyEarly);
          if (legacyEarly) expect(unit.preFirstFractalMode, legacyMode);
        }
      }
    });
  });

  test('四档副标题都非空且互不相同', () {
    final hints = PreFirstFractalUnitMode.values.map((e) => e.shortHint).toSet();
    expect(hints.length, PreFirstFractalUnitMode.values.length);
    for (final h in hints) {
      expect(h.trim(), isNotEmpty);
    }
  });
}
