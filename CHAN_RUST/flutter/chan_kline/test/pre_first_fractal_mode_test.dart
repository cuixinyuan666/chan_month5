import 'package:chan_kline/compute/first_fractal_rule.dart';
import 'package:chan_kline/compute/pre_first_fractal_compute.dart';
import 'package:chan_kline/models/kline_combine_frame.dart';
import 'package:chan_kline/models/level_models.dart';
import 'package:chan_kline/models/pre_first_fractal_mode.dart';
import 'package:flutter_test/flutter_test.dart';

KlineCombineFrame _f(
  int x1,
  int x2,
  double high,
  double low, {
  String fx = 'UNKNOWN',
  int count = 1,
}) {
  return KlineCombineFrame(
    x1: x1,
    x2: x2,
    t1: 't$x1',
    t2: 't$x2',
    high: high,
    low: low,
    fx: fx,
    count: count,
  );
}

void main() {
  group('存储口径', () {
    test('默认口径是高高', () {
      expect(PreFirstFractalMode.defaultMode, PreFirstFractalMode.highHigh);
      expect(PreFirstFractalMode.highHigh.storageValue, 'highHigh');
    });

    test('缺键 / 脏值回落高高，合法值原样还原', () {
      expect(PreFirstFractalMode.fromStorage(null), PreFirstFractalMode.highHigh);
      expect(
        PreFirstFractalMode.fromStorage('不存在的口径'),
        PreFirstFractalMode.highHigh,
      );
      expect(
        PreFirstFractalMode.fromStorage('seedBox'),
        PreFirstFractalMode.seedBox,
      );
      expect(
        PreFirstFractalMode.fromStorage('lowLow'),
        PreFirstFractalMode.lowLow,
      );
    });

    test('三个选项的中文名固定为 种子框 / 高高 / 低低', () {
      expect(PreFirstFractalMode.seedBox.label, '种子框');
      expect(PreFirstFractalMode.highHigh.label, '高高');
      expect(PreFirstFractalMode.lowLow.label, '低低');
    });
  });

  group('单图：首分型前并框', () {
    // 3 个 UNKNOWN 框 + 第 4 个带分型的框
    List<KlineCombineFrame> head3() => [
          _f(0, 0, 10.0, 9.0),
          _f(1, 1, 9.5, 8.8),
          _f(2, 2, 9.2, 8.5),
          _f(3, 3, 9.0, 8.2, fx: 'TOP'),
        ];

    test('种子框：不合并，原样返回', () {
      final frames = head3();
      final out = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.seedBox,
        subWindow: false,
      );
      expect(identical(out, frames), isTrue);
      expect(out.length, 4);
      expect(out.first.x2, 0);
    });

    test('高高：high / low 都取各框最大', () {
      final out = applyPreFirstFractalMode(
        head3(),
        mode: PreFirstFractalMode.highHigh,
        subWindow: false,
      );
      expect(out.length, 2);
      expect(out.first.x1, 0);
      expect(out.first.x2, 2);
      expect(out.first.high, 10.0);
      expect(out.first.low, 9.0);
      expect(out.first.count, 3);
      expect(fxIsUnknownCodeUnit(out.first.fx), isTrue);
      // 首分型所在框及其后原样
      expect(out[1].fx, 'TOP');
      expect(out[1].x1, 3);
    });

    test('低低：high / low 都取各框最小', () {
      final out = applyPreFirstFractalMode(
        head3(),
        mode: PreFirstFractalMode.lowLow,
        subWindow: false,
      );
      expect(out.length, 2);
      expect(out.first.high, 9.2);
      expect(out.first.low, 8.5);
    });

    test('首分型落在第二框：第一根并进第二框（左端仍从 0 起）', () {
      final frames = [
        _f(0, 0, 10.0, 9.0),
        _f(1, 1, 9.5, 9.5, fx: 'TOP'),
      ];
      final high = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.highHigh,
        subWindow: false,
      );
      expect(high.length, 1);
      expect(high.first.x1, 0);
      expect(high.first.x2, 1);
      expect(high.first.high, 10.0);
      expect(high.first.low, 9.5);
      expect(high.first.fx, 'TOP');
      expect(high.first.count, 2);

      final low = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.lowLow,
        subWindow: false,
      );
      expect(low.first.high, 9.5);
      expect(low.first.low, 9.0);
    });
  });

  group('子窗口：逐对判定 + 并框口径', () {
    test('双低：不合并（三种口径都一样，且种子框不跑逐对判定）', () {
      final frames = [
        _f(0, 0, 10.0, 10.0),
        _f(1, 1, 9.5, 9.5),
        _f(2, 2, 9.1, 9.1),
      ];
      for (final mode in PreFirstFractalMode.values) {
        final out = applyPreFirstFractalMode(
          frames,
          mode: mode,
          subWindow: true,
        );
        expect(out.length, 3, reason: '$mode 不应合并双低两根');
      }
      // 高高/低低 走逐对判定：第一根判顶分型
      final high = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.highHigh,
        subWindow: true,
      );
      expect(high.first.fx, 'TOP');
      // 种子框不判分型，保持原样
      final seed = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.seedBox,
        subWindow: true,
      );
      expect(seed.first.fx, 'UNKNOWN');
    });

    test('包含关系：并框取值按口径（高高=都取最大 / 低低=都取最小）', () {
      final frames = [
        _f(0, 0, 10.0, 9.0),
        _f(1, 1, 9.5, 9.5),
      ];
      final high = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.highHigh,
        subWindow: true,
      );
      expect(high.length, 1);
      expect(high.first.high, 10.0);
      expect(high.first.low, 9.5);

      final low = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.lowLow,
        subWindow: true,
      );
      expect(low.length, 1);
      expect(low.first.high, 9.5);
      expect(low.first.low, 9.0);
    });
  });

  group('不生效的情形', () {
    test('经典口径（earlyDynamicUnit=false）原样返回', () {
      final frames = [
        _f(0, 0, 10.0, 9.0),
        _f(1, 1, 9.5, 8.8),
        _f(2, 2, 9.0, 8.2, fx: 'TOP'),
      ];
      final out = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.lowLow,
        subWindow: false,
        earlyDynamicUnit: false,
      );
      expect(identical(out, frames), isTrue);
    });

    test('第一框不从 x1=0 起（不是序列开头）原样返回', () {
      final frames = [
        _f(5, 5, 10.0, 9.0),
        _f(6, 6, 9.5, 8.8, fx: 'TOP'),
      ];
      final out = applyPreFirstFractalMode(
        frames,
        mode: PreFirstFractalMode.highHigh,
        subWindow: false,
      );
      expect(identical(out, frames), isTrue);
    });
  });

  group('各层合并框（tooltip 用）', () {
    test('只重排 combineFrames，其它层字段原样保留', () {
      final levels = [
        const LevelBundle(level: 0),
        LevelBundle(
          level: 1,
          firstDir: 1,
          firstDirX: 7,
          combineFrames: [
            _f(0, 0, 10.0, 9.0),
            _f(1, 1, 9.2, 8.5),
            _f(2, 2, 9.0, 8.2, fx: 'TOP'),
          ],
        ),
      ];
      final out = applyPreFirstFractalToLevels(
        levels,
        mode: PreFirstFractalMode.lowLow,
        subWindow: false,
      );
      expect(out.length, 2);
      expect(identical(out[0], levels[0]), isTrue);
      expect(out[1].level, 1);
      expect(out[1].firstDir, 1);
      expect(out[1].firstDirX, 7);
      expect(out[1].combineFrames.length, 2);
      expect(out[1].combineFrames.first.high, 9.2);
      expect(out[1].combineFrames.first.low, 8.5);
      // 入参不被改写
      expect(levels[1].combineFrames.length, 3);
    });

    test('种子框口径下各层原样（同一实例）', () {
      final levels = [
        LevelBundle(
          level: 1,
          combineFrames: [
            _f(0, 0, 10.0, 9.0),
            _f(1, 1, 9.2, 8.5),
          ],
        ),
      ];
      final out = applyPreFirstFractalToLevels(
        levels,
        mode: PreFirstFractalMode.seedBox,
        subWindow: false,
      );
      expect(identical(out, levels), isTrue);
    });
  });

  group('并框几何 helper', () {
    test('高高 / 低低 与单框一致', () {
      final high = mergePreFractalBox(
        10.0,
        9.0,
        9.5,
        9.5,
        PreFirstFractalMode.highHigh,
      );
      expect(high.high, 10.0);
      expect(high.low, 9.5);
      final low = mergePreFractalBox(
        10.0,
        9.0,
        9.5,
        9.5,
        PreFirstFractalMode.lowLow,
      );
      expect(low.high, 9.5);
      expect(low.low, 9.0);
    });
  });
}
