import 'package:flutter_test/flutter_test.dart';

import 'dart:math' as math;

import 'package:chan_kline/compute/demark_compute.dart';
import 'package:chan_kline/compute/kn_ohlc_sample_compute.dart';
import 'package:chan_kline/compute/math_classic_compute.dart';
import 'package:chan_kline/models/bar_feature_lookup.dart';
import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/divergence_algo.dart';
import 'package:chan_kline/models/kline_bar.dart';
import 'package:chan_kline/models/level_models.dart';
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

  group('回归通道(父层连线绑定)', () {
    // 父层 = structure level displayKn+1；K0回归通道看 level1（K1连线）
    LevelBundle parentBundle(
      List<LevelSegmentN> segs, {
      int level = 1,
      LevelUnitBar? active,
    }) =>
        LevelBundle(level: level, segments: segs, activeUnit: active);

    test('基准=父层最后一段；一路外推到 asOf', () {
      final bars = [for (var i = 0; i < 7; i++) _bar(i, 10 + i.toDouble())];
      final s0 = LevelSegmentN(
        idx: 0, dir: 1, beginConfirmX: 1, endConfirmX: 3,
        beginPoleX: 1, endPoleX: 3,
      );
      final s1 = LevelSegmentN(
        idx: 1, dir: -1, beginConfirmX: 3, endConfirmX: 5,
        beginPoleX: 3, endPoleX: 5,
      );
      final rc = computeRegressionChannelForLevel(
        displayKn: 0,
        bars: bars,
        levels: [parentBundle([s0, s1])],
      );
      // 只认最后一段 [3,5]：3 之前不出线
      expect(rc.mid[2], isNull);
      expect(rc.mid[3], closeTo(13, 1e-9));
      // 完美直线斜率 1 → 外推到末根 6
      expect(rc.mid[6], closeTo(16, 1e-9));
      // 残差≈0 → 带宽≈0（下限 1e-7）
      expect(rc.up[4]! - rc.mid[4]!, lessThan(1e-5));
    });

    test('上下轨关于中轨对称（±k×残差总体标准差，除 m）', () {
      final bars = [
        _bar(0, 10), _bar(1, 13), _bar(2, 12), _bar(3, 15), _bar(4, 14),
      ];
      final seg = LevelSegmentN(
        idx: 0, dir: 1, beginConfirmX: 0, endConfirmX: 4,
        beginPoleX: 0, endPoleX: 4,
      );
      final rc = computeRegressionChannelForLevel(
        displayKn: 0, bars: bars, levels: [parentBundle([seg])], k: 2.0,
      );
      final m = rc.mid[2]!, u = rc.up[2]!, d = rc.down[2]!;
      // 残差 std = sqrt(0.96) ≈ 0.9798（非收盘价 std≈1.72）
      expect(u - m, closeTo(2 * math.sqrt(0.96), 1e-9));
      expect(m - d, closeTo(2 * math.sqrt(0.96), 1e-9));
    });

    test('k 越大轨道越宽', () {
      final bars = [
        _bar(0, 10), _bar(1, 13), _bar(2, 12), _bar(3, 15), _bar(4, 14),
      ];
      final seg = LevelSegmentN(
        idx: 0, dir: 1, beginConfirmX: 0, endConfirmX: 4,
        beginPoleX: 0, endPoleX: 4,
      );
      final w1 = computeRegressionChannelForLevel(
        displayKn: 0, bars: bars, levels: [parentBundle([seg])], k: 1,
      );
      final w2 = computeRegressionChannelForLevel(
        displayKn: 0, bars: bars, levels: [parentBundle([seg])], k: 2,
      );
      expect(
        w2.up[2]! - w2.mid[2]!,
        greaterThan(w1.up[2]! - w1.mid[2]!),
      );
    });

    test('asOf 回退：基准取当时可见那段，右端截到 asOf', () {
      final bars = [for (var i = 0; i < 7; i++) _bar(i, 10 + i.toDouble())];
      final s0 = LevelSegmentN(
        idx: 0, dir: 1, beginConfirmX: 0, endConfirmX: 3,
        beginPoleX: 0, endPoleX: 3,
      );
      final s1 = LevelSegmentN(
        idx: 1, dir: -1, beginConfirmX: 3, endConfirmX: 6,
        beginPoleX: 3, endPoleX: 6,
      );
      // asOf=4 时第二段（endConfirmX=6）还看不见 → 基准回到 [0,3]
      final rc = computeRegressionChannelForLevel(
        displayKn: 0, bars: bars, levels: [parentBundle([s0, s1])], asOf: 4,
      );
      expect(rc.mid[0], closeTo(10, 1e-9));
      expect(rc.mid[4], closeTo(14, 1e-9));
      expect(rc.mid[5], isNull);
      expect(rc.mid[6], isNull);
    });

    test('全层同构：K1回归通道看 level2 连线，样本用本层虚拟K', () {
      final bars = [for (var i = 0; i < 6; i++) _bar(i, 10 + i.toDouble())];
      final seg = LevelSegmentN(
        idx: 0, dir: 1, beginConfirmX: 0, endConfirmX: 4,
        beginPoleX: 0, endPoleX: 4,
      );
      final rc = computeRegressionChannelForLevel(
        displayKn: 1,
        bars: bars,
        levels: [parentBundle([seg], level: 2)],
        samples: [
          for (var i = 0; i <= 4; i++)
            KnOhlcSample(
              endX: i,
              open: 10 + i.toDouble(),
              high: 11 + i.toDouble(),
              low: 9 + i.toDouble(),
              close: 10 + 2 * i.toDouble(), // 斜率 2
            ),
        ],
      );
      expect(rc.mid[0], closeTo(10, 1e-9));
      expect(rc.mid[2], closeTo(14, 1e-9));
      expect(rc.mid[5], closeTo(20, 1e-9)); // 外推到 asOf=5
    });

    test('无父层 bundle / 区间不足 2 点 → 整条不出线（不打崩）', () {
      final bars = [for (var i = 0; i < 5; i++) _bar(i, 10 + i.toDouble())];
      final empty = computeRegressionChannelForLevel(
        displayKn: 0, bars: bars, levels: const [],
      );
      expect(empty.mid.every((e) => e == null), isTrue);

      // 父层只有一个点（起=终）→ 无有效段
      final onePoint = LevelSegmentN(
        idx: 0, dir: 1, beginConfirmX: 2, endConfirmX: 2,
        beginPoleX: 2, endPoleX: 2,
      );
      final rc = computeRegressionChannelForLevel(
        displayKn: 0, bars: bars, levels: [parentBundle([onePoint])],
      );
      expect(rc.mid.every((e) => e == null), isTrue);
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

    test('回归通道入主图目录、归「延伸」、序在 fxTopSnug 后、默认不绘制', () {
      final mainCat = buildMainIndicatorCatalog(1);
      final rcItems = mainCat
          .where((e) => e.kind == MainIndicatorKind.regressionChannel)
          .toList();
      // 0..maxKn 每层一套
      expect(rcItems.length, 2);
      expect(rcItems.map((e) => e.label), containsAll(['K0回归通道', 'K1回归通道']));
      expect(MainIndicatorKind.regressionChannel.categoryLabel, '延伸');
      expect(
        const MainChartIndicator.regressionChannel(0).kindOrderInLevel,
        greaterThan(const MainChartIndicator.fxTopSnug(0).kindOrderInLevel),
      );
      expect(
        isDefaultDrawnMain(const MainChartIndicator.regressionChannel(0)),
        isFalse,
      );
    });
  });
}
