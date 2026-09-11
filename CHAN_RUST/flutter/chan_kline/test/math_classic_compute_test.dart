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
    test('首根 DIF/DEA/MACD 均为 0', () {
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
    test('首根给 50', () {
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

    test('formatDemarkMarks 文案含完成买/卖', () {
      const marks = [
        DemarkMark(type: 'setup', dir: -1, idx: 9),
        DemarkMark(type: 'countdown', dir: 1, idx: 3),
        DemarkMark(type: 'complete', dir: -1, idx: 9),
      ];
      expect(
        BarFeatureLookup.formatDemarkMarks(marks),
        'S9 C3 完成买',
      );
    });

    test('默认宽松 countdown：close vs close[i-2]', () {
      // 构造：先走满买 Setup9，再让 countdown 在宽松条件下可数
      final bars = <KlineBar>[];
      // 0..3 铺底
      for (var i = 0; i < 4; i++) {
        bars.add(_bar(i, 20.0 - i * 0.1));
      }
      // 4..12：连续 9 根买 Setup（close[i] < close[i-4]）
      for (var i = 4; i <= 12; i++) {
        bars.add(_bar(i, 19.0 - (i - 4) * 0.5));
      }
      // 13..：宽松 countdown（close < close[i-2]）且不满足严格（close > low[i-2]）
      for (var i = 13; i < 30; i++) {
        final c = 14.0 - (i - 13) * 0.2;
        bars.add(_bar(i, c, high: c + 2, low: c - 3));
      }
      final loose = computeDemarkForLevel(
        displayKn: 0,
        bars: bars,
        config: const MathIndicatorConfig(
          demarkCountdownMode: DemarkCountdownMode.looseClose,
          demarkPerfect9: false,
        ),
      );
      final hasCd = loose.marksAt.any(
        (ms) => ms != null && ms.any((m) => m.type == 'countdown'),
      );
      expect(hasCd, isTrue);

      final strict = computeDemarkForLevel(
        displayKn: 0,
        bars: bars,
        config: const MathIndicatorConfig(
          demarkCountdownMode: DemarkCountdownMode.strictExtreme,
          demarkPerfect9: false,
        ),
      );
      // 严格更难触发；不强制为 0，仅验证模式字段生效且仍可跑完
      expect(strict.marksAt.length, bars.length);
    });
  });

  group('catalog', () {
    test('Demark 在主图目录；副图层全选不含 Demark', () {
      final mainCat = buildMainIndicatorCatalog(1);
      expect(
        mainCat.any((e) => e.kind == MainIndicatorKind.demark),
        isTrue,
      );
      expect(
        mainCat.any((e) => e.kind == MainIndicatorKind.boll),
        isTrue,
      );

      final subCat = buildSubIndicatorCatalog(1, maxBsClass: 9);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.macd), isTrue);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.rsi), isTrue);
      expect(subCat.any((e) => e.kind == SubIndicatorKind.kdj), isTrue);

      final dMain = defaultMainIndicatorsK0();
      // 默认只勾核心绘制项；BOLL/Demark 仍在层全选 catalog 内
      expect(dMain.any((e) => e.kind == MainIndicatorKind.boll), isFalse);
      expect(dMain.any((e) => e.kind == MainIndicatorKind.demark), isFalse);
      expect(isDefaultDrawnMain(const MainChartIndicator.demark(0)), isFalse);

      final dSub = defaultSubIndicatorsK0();
      expect(dSub.any((e) => e.kind == SubIndicatorKind.macd), isFalse);

      final lvl0 = subIndicatorsForLevel(0, subCat);
      expect(
        lvl0.where((e) => e.kind == SubIndicatorKind.divergence).length,
        DivergenceAlgoMeta.all.length,
      );
      expect(dSub.any((e) => e.kind == SubIndicatorKind.divergence), isFalse);

      final mainLvl = mainIndicatorsForLevel(0, mainCat);
      expect(mainLvl.any((e) => e.kind == MainIndicatorKind.demark), isTrue);
    });
  });
}
