import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/widgets/candle_wick.dart';

/// 影线跟随实体宽度，且不穿过实体。
void main() {
  group('影线粗细跟随实体宽度', () {
    test('实体越宽影线越粗', () {
      expect(candleWickWidth(20), greaterThan(candleWickWidth(8)));
      expect(candleWickWidth(40), greaterThan(candleWickWidth(20)));
    });

    test('最细 1 像素，最粗 11 像素', () {
      expect(candleWickWidth(2), 1.0);
      expect(candleWickWidth(4), closeTo(1.28, 1e-9));
      expect(candleWickWidth(100), 11.0);
    });

    test('常见宽度按实体约三分之一', () {
      expect(candleWickWidth(12), closeTo(3.84, 1e-9));
      expect(candleWickWidth(30), closeTo(9.6, 1e-9));
    });

    test('widthMult 再乘一档（构建中/确认态）', () {
      final b = candleWickWidth(20);
      expect(candleWickWidth(20, widthMult: 0.88), lessThan(b));
      expect(candleWickWidth(20, widthMult: 1.15), greaterThan(b));
    });
  });

  group('影线不穿过实体', () {
    test('只画实体上下两段时判定为不穿过', () {
      // 上影线停在实体上沿，下影线从实体下沿起。
      expect(
        candleWickCrossesBody(
          wickTop: 10,
          wickBottom: 40,
          bodyTop: 40,
          bodyBottom: 80,
        ),
        isFalse,
      );
      expect(
        candleWickCrossesBody(
          wickTop: 80,
          wickBottom: 120,
          bodyTop: 40,
          bodyBottom: 80,
        ),
        isFalse,
      );
    });

    test('从最高点直画到最低点会穿过实体（旧画法，不再使用）', () {
      expect(
        candleWickCrossesBody(
          wickTop: 10,
          wickBottom: 120,
          bodyTop: 40,
          bodyBottom: 80,
        ),
        isTrue,
      );
    });
  });
}
