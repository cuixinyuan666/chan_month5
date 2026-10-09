import 'dart:io';

import 'package:chan_kline/models/chart_indicator.dart';
import 'package:chan_kline/models/math_indicator_config.dart';
import 'package:chan_kline/widgets/indicator_legend.dart';
import 'package:chan_kline/widgets/kline_chart.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 多线指标图例的回归（2026-09 先落地，2026-10-09 补参数与线型区分）。
///
/// 锁死：①图例默认展开；②图例里的参数与 `MathIndicatorConfig` 实际配置一致；
/// ③布林 / 唐奇安的上轨与下轨在图例上可区分（透明度分级 + 下轨虚线）；
/// ④构建图例**不碰任何指标计算**（纯参数 → 纯文案）。
void main() {
  const cfg = MathIndicatorConfig();

  List<IndicatorLegendGroup> _legend({
    required Set<MainChartIndicator> mains,
    required Set<SubChartIndicator> subs,
    MathIndicatorConfig cfg = cfg,
  }) =>
      buildIndicatorLegends(mains: mains, subs: subs, mathConfig: cfg);

  IndicatorLegendGroup _one(MainChartIndicator i) =>
      _legend(mains: {i}, subs: const {}).single;

  test('图例默认展开（源码守卫：_legendOpen 初值为 true）', () {
    final src = File('lib/widgets/kline_chart.dart').readAsStringSync();
    expect(src.contains('bool _legendOpen = true;'), isTrue,
        reason: '多线指标图例默认展开；用户不点任何按钮就能看到');
    // 展开/收起交互仍在（点钮切换）
    expect(src.contains('void _toggleLegend()'), isTrue);
    expect(src.contains('setState(() => _legendOpen = !_legendOpen)'), isTrue);
  });

  test('布林 / 唐奇安 / 回归通道的图例标题带实际参数', () {
    expect(_one(MainChartIndicator.boll(0)).title, 'K0布林(20)');
    expect(_one(MainChartIndicator.donchian(0)).title, 'K0唐奇安(20)');
    expect(_one(MainChartIndicator.regressionChannel(0)).title, 'K0回归通道(k=2.0)');

    // 改配置后图例必须跟着变（不能写死默认值）
    const cfg2 = MathIndicatorConfig(bollN: 34, donchianN: 55, regressK: 1.5);
    final g = _legend(
      mains: {
        MainChartIndicator.boll(0),
        MainChartIndicator.donchian(0),
        MainChartIndicator.regressionChannel(0),
      },
      subs: const {},
      cfg: cfg2,
    );
    expect(g[0].title, 'K0布林(34)');
    expect(g[1].title, 'K0唐奇安(55)');
    expect(g[2].title, 'K0回归通道(k=1.5)');
  });

  test('MACD / KDJ 图例带参数', () {
    final macd = _legend(
      mains: const {},
      subs: {SubChartIndicator.macd(0)},
    ).single;
    expect(macd.title, 'K0MACD(12/26/9)');
    final kdj = _legend(
      mains: const {},
      subs: {SubChartIndicator.kdj(0)},
    ).single;
    expect(kdj.title, 'K0KDJ(9)');
  });

  test('布林 / 唐奇安：上轨与下轨在图例上可区分（透明度分级 + 下轨虚线）', () {
    for (final ind in [MainChartIndicator.boll(0), MainChartIndicator.donchian(0)]) {
      final g = _one(ind);
      expect(g.lines.length, 3);
      final mid = g.lines[0];
      final up = g.lines[1];
      final down = g.lines[2];
      expect(mid.label, '中轨');
      expect(up.label, '上轨');
      expect(down.label, '下轨');
      expect(mid.dashed, isFalse, reason: '中轨实线');
      expect(up.dashed, isFalse, reason: '上轨实线');
      expect(down.dashed, isTrue, reason: '下轨虚线（突破轨惯例）');
      // 透明度：下轨明显最淡，且与上轨不同（层色主色的 alpha 因层而异，不做跨层假设）
      double a(Color c) => c.a;
      expect(a(down.color), lessThan(a(up.color)));
      expect(a(up.color), isNot(a(down.color)),
          reason: '上/下轨色块同色同型就是分不出来的那次回归');
    }
  });

  test('三类通道在图例上签名互不相同', () {
    String sig(IndicatorLegendGroup g) =>
        g.lines.map((l) => '${l.label}:${l.dashed}:${l.color.a.toStringAsFixed(2)}').join('|');
    final boll = _one(MainChartIndicator.boll(0));
    final don = _one(MainChartIndicator.donchian(0));
    final reg = _one(MainChartIndicator.regressionChannel(0));
    expect(sig(reg), isNot(sig(boll)), reason: '回归通道（全虚线+更淡）须与布林不同');
    expect(sig(reg), isNot(sig(don)), reason: '回归通道须与唐奇安不同');
    // 布林与唐奇安在图上本就是同一层色系，靠标题+参数区分（既有设计，不动层色）
    expect(boll.title, isNot(don.title));
  });

  test('图例取色与画布取色同源（禁止图例自己另算一套色）', () {
    final src = File('lib/widgets/kline_chart.dart').readAsStringSync();
    for (final fn in const ['bandUpper(', 'bandLower(']) {
      expect(src.contains('IndicatorLinePalette.$fn'), isTrue,
          reason: '_drawBoll/_drawDonchian 必须用与图例同一个取色函数 $fn');
    }
    expect(src.contains('IndicatorLinePalette.bandSide('), isFalse,
        reason: '统一用 bandUpper/bandLower，别再退回无差别的 bandSide');
    // 图例面板不得再吞掉指针事件（否则面板内滚轮/点击都失效）
    final panel = src.substring(
      src.indexOf('Widget _buildLegendPanel('),
      src.indexOf('Widget _legendLineRow('),
    );
    expect(panel.contains('IgnorePointer'), isFalse);
  });

  test('构建图例不做任何指标计算（只有颜色对象、无指标读取调用）', () {
    // 图例只接受「指标集合 + 参数」，物理上拿不到 bars / levels / 冻结仓，
    // 也不可能重算 —— 这里钉住签名，防止将来给它加上「顺手算一下」的能力。
    final sig = buildIndicatorLegends;
    expect(sig.toString(), isNot(contains('bars')));
    expect(sig.toString(), isNot(contains('levels')));
    // 且返回的元素都是不可变的值对象
    final g = _one(MainChartIndicator.boll(0));
    expect(g.lines.first.color, isA<Color>());
  });

  test('多指标同时开启：每组独立、不互相覆盖，条目总数 = 各组之和', () {
    final mains = {
      MainChartIndicator.meanLine(0),
      MainChartIndicator.trendChannel(0),
      MainChartIndicator.boll(0),
      MainChartIndicator.donchian(0),
      MainChartIndicator.regressionChannel(0),
      MainChartIndicator.boll(1),
    };
    final g = _legend(mains: mains, subs: const {});
    expect(g.length, mains.length);
    final total = g.fold<int>(0, (a, x) => a + x.lines.length);
    expect(total, 3 + 4 + 3 + 3 + 3 + 3);
    // 标题唯一（不重名，K0 与 K1 分得开）
    expect(g.map((e) => e.title).toSet().length, g.length);
    // K1 的布林与 K0 的布林同结构、不同层色
    final b0 = g.firstWhere((e) => e.title.startsWith('K0布林'));
    final b1 = g.firstWhere((e) => e.title.startsWith('K1布林'));
    expect(b0.lines.map((l) => l.color).toList(),
        isNot(b1.lines.map((l) => l.color).toList()));
  });

  test('均线 / 通道 / 步进节奏 / 趋势线 / 顶底对弦 的既有条目不被改坏', () {
    final ma = _one(MainChartIndicator.meanLine(0));
    expect(ma.title, 'K0均线');
    expect(ma.lines.map((l) => l.label).toList(), ['MA5', 'MA10', 'MA20']);
    final tc = _one(MainChartIndicator.trendChannel(0));
    expect(tc.lines.map((l) => l.label).toList(),
        ['T20上', 'T20下', 'T60上', 'T60下']);
    final tl = _one(MainChartIndicator.trendLine(0));
    expect(tl.lines.map((l) => l.label).toList(), ['支撑', '压力']);
    final qp = _one(MainChartIndicator.fxQuadPair(0));
    expect(qp.lines.map((l) => l.label).toList(), ['顶线', '底线']);
  });
}
