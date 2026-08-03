import 'package:flutter_test/flutter_test.dart';

import 'package:chan_kline/compute/demark_compute.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/divergence_algo.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/math_indicator_config.dart';

KlineBar _bar(int idx, double close, {double? high, double? low}) {
  return KlineBar(
    idx: idx,
    timeMs: idx * 60000,
    timeText: 't$idx',
    open: close,
    high: high ?? close + 1,
    low: low ?? close - 1,
    close: close,
    volume: 1,
    amount: 1,
  );
}

void main() {
  group('MACD', () {
    test('首值 DIF/DEA/MACD 均为 0', () {
      final bars = [_bar(0, 10)];
      final macd = computeMacdForLevel(displayKn: 0, bars: bars);
      expect(macd.dif[0], closeTo(0, 1e-12));
      expect(macd.dea[0], closeTo(0, 1e-12));
      expect(macd.macd[0], closeTo(0, 1e-12));
    });

    test('第二根起 DIF 有值', () {
      final bars = [_bar(0, 10), _bar(1, 12)];
      final macd = computeMacdForLevel(displayKn: 0, bars: bars);
      expect(macd.dif[1], isNotNull);
      expect(macd.dif[1]!, isNot(closeTo(0, 1e-12)));
    });
  });

  group('BOLL', () {
    test('MID 为滑窗均值', () {
      final bars = [
        for (var i = 0; i < 5; i++) _bar(i, (i + 1).toDouble()),
      ];
      final boll = computeBollForLevel(displayKn: 0, bars: bars, n: 3);
      expect(boll.mid[2], closeTo(2, 1e-12)); // (1+2+3)/3
      expect(boll.up[2], greaterThan(boll.mid[2]!));
      expect(boll.down[2], lessThan(boll.mid[2]!));
    });
  });

  group('RSI', () {
    test('首根为 50', () {
      final bars = [_bar(0, 10)];
      final rsi = computeRsiForLevel(displayKn: 0, bars: bars, period: 14);
      expect(rsi[0], closeTo(50, 1e-12));
    });
  });

  group('KDJ', () {
    test('输出 K/D/J', () {
      final bars = [
        for (var i = 0; i < 12; i++) _bar(i, 10 + i * 0.5),
      ];
      final kdj = computeKdjForLevel(displayKn: 0, bars: bars, period: 9);
      expect(kdj.k[11], isNotNull);
      expect(kdj.d[11], isNotNull);
      expect(kdj.j[11], isNotNull);
    });
  });

  group('Demark', () {
    test('smoke：可产生标记', () {
      final bars = [
        for (var i = 0; i < 30; i++)
          _bar(i, 10 + (i % 5) * 0.3, high: 12 + i * 0.1, low: 8 - i * 0.05),
      ];
      final demark = computeDemarkForLevel(
        displayKn: 0,
        bars: bars,
        config: const MathIndicatorConfig(),
      );
      expect(demark.marksAt.length, bars.length);
      final anyMark = demark.marksAt.any((e) => e != null && e.isNotEmpty);
      expect(anyMark, isTrue);
    });

    test('formatDemarkMarks 文案', () {
      const marks = [
        DemarkMark(type: 'setup', dir: -1, idx: 9),
        DemarkMark(type: 'countdown', dir: 1, idx: 3),
      ];
      expect(
        BarFeatureLookup.formatDemarkMarks(marks),
        'S↓9 C↑3',
      );
    });
  });

  group('catalog', () {
    test('含布林/Demark/MACD/RSI/KDJ', () {
      final mainCat = buildMainIndicatorCatalog(1);
      expect(
        mainCat.any((e) => e.kind == MainIndicatorKind.boll),
        isTrue,
      );

      final subCat = buildSubIndicatorCatalog(1, maxBsClass: 9);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.macd), isTrue);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.rsi), isTrue);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.kdj), isTrue);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.demark), isTrue);

      final dMain = defaultMainIndicatorsK0();
      expect(dMain.any((e) => e.kind == MainIndicatorKind.boll), isTrue);

      final dSub = defaultSubIndicatorsK0();
      expect(dSub.any((e) => e.kind == SubIndicatorKind.macd), isTrue);
      expect(dSub.any((e) => e.kind == SubIndicatorKind.rsi), isTrue);
      expect(dSub.any((e) => e.kind == SubIndicatorKind.kdj), isTrue);
      expect(dSub.any((e) => e.kind == SubIndicatorKind.demark), isTrue);

      // Kn指标层全选含 Demark + 背驰
      final lvl0 = subIndicatorsForLevel(0, subCat);
      expect(lvl0.any((e) => e.kind == SubIndicatorKind.demark), isTrue);
      expect(
        lvl0.where((e) => e.kind == SubIndicatorKind.divergence).length,
        DivergenceAlgoMeta.all.length,
      );
      // 启动默认：背驰仍不勾
      expect(dSub.any((e) => e.kind == SubIndicatorKind.divergence), isFalse);
    });
  });
}
