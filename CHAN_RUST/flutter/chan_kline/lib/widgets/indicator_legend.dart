import 'package:flutter/material.dart';

import '../compute/step_rhythm_compute.dart';
import '../models/chart_indicator.dart';
import '../models/math_indicator_config.dart';
import 'chart_level_line_style.dart';

/// 指标图例：一条线一行（色块 + 名称），一个指标一段。
///
/// 只收「一个指标画出多条线」的指标（均线/通道/布林/唐奇安/回归通道/趋势线/
/// 顶底对弦线/步进节奏 + MACD/KDJ/背驰）；单线指标（连线、合并、中枢、延伸单线、
/// RSI、斜率、比例、量柱、BS 副图）不进图例。
class LegendLine {
  final String label;

  /// 主色（线色 / 柱的正色）。
  final Color color;

  /// 虚线节距（单位 px），null = 实线。
  /// **与画布 `_paintPriceSeries(dashPattern:)` 用同一份数值**，
  /// 图例小样按它画，图上就按它画 —— 不会「图上是长虚线、图例画三个点」。
  final List<double>? dashPattern;

  /// 柱状元素（MACD 柱、背驰 ±1 柱）。
  final bool bar;

  /// 柱的第二色（红涨绿跌的负色）；非柱为 null。
  final Color? color2;

  const LegendLine(
    this.label, {
    required this.color,
    this.dashPattern,
    this.bar = false,
    this.color2,
  });

  /// 是否虚线（供绘制与测试判定）。
  bool get dashed => dashPattern != null;
}

/// 各类线条的**线型签名**，图上与图例共用的唯一落点。
///
/// 2026-10-09：布林与唐奇安原先在图上完全同型（同层同色、三条都实线），
/// 图例两行色块也一模一样。现在用「中/上/下三档各自的实虚」把三类通道区分开：
/// - 布林：中轨实线、上轨实线、下轨虚线（突破轨惯例）
/// - 唐奇安：中轨长虚线、上轨点虚线、下轨实线（与布林签名完全不同）
/// - 回归通道：三条全虚线、整体更淡（既有形态，不动）
class LegendDash {
  const LegendDash._();

  static const List<double>? solid = null;
  static const List<double> dash = [4, 3];
  static const List<double> longDash = [7, 4];
  static const List<double> dotDash = [2, 3];
}

class IndicatorLegendGroup {
  final String title;
  final List<LegendLine> lines;

  const IndicatorLegendGroup(this.title, this.lines);
}

/// 多线指标取色的**唯一出处**：painter 与图例都调这里，保证图上颜色与图例色块一致。
///
/// 这里的每个函数都是把原来内联在 `kline_chart.dart` 里的公式原样搬过来，
/// 取值一个不改（改色值会同时改动图上线条与图例，属于显示语义变更，须先确认）。
class IndicatorLinePalette {
  const IndicatorLinePalette._();

  /// 均线第 i 条（i 按周期升序）：hue = i*0.17。
  static Color meanLine(int i) =>
      HSVColor.fromAHSV(1, ((i * 0.17) % 1.0) * 360, 0.75, 0.95).toColor();

  /// 通道第 i 组上轨：hue = 0.05 + i*0.21。
  static Color channelTop(int i) {
    final hue = (0.05 + i * 0.21) % 1.0;
    return HSVColor.fromAHSV(1, hue * 360, 0.8, 0.95).toColor();
  }

  /// 通道第 i 组下轨：上轨色相 +0.45（明度略低）。
  static Color channelBottom(int i) {
    final hue = (0.05 + i * 0.21) % 1.0;
    return HSVColor.fromAHSV(1, ((hue + 0.45) % 1.0) * 360, 0.8, 0.9).toColor();
  }

  /// 布林 / 唐奇安：**上下轨透明度分级**（2026-10-09）。
  ///
  /// 原先上轨与下轨用同一个 alpha，图例上两行色块完全同色同型、肉眼分不出。
  /// 现在上轨更实、下轨更淡**且下轨画虚线** —— 与市面软件「突破轨」的惯例一致，
  /// 颜色淡的一眼就知道是下轨。三类通道的签名：
  /// - 布林 / 唐奇安：中轨实线 + 上轨实线 + 下轨虚线（深浅分级）
  /// - 回归通道：三条全虚线、整体更淡（既有形态，不动）
  ///
  /// 同层主色仍取 [ChartLevelLineStyle]（全工程统一的层色），不动。
  static Color bandSide(Color mid, {double alpha = 0.55}) =>
      mid.withValues(alpha: alpha);

  /// 上轨：偏实。
  static Color bandUpper(Color mid) => bandSide(mid, alpha: 0.8);

  /// 下轨：偏淡（配合虚线，图例上一眼分得开）。
  static Color bandLower(Color mid) => bandSide(mid, alpha: 0.45);

  /// MACD DIF / DEA / KDJ K·D。
  static const macdDif = Color(0xFF2563EB);
  static const macdDea = Color(0xFFF59E0B);
  static const kdjK = Color(0xFF2563EB);
  static const kdjD = Color(0xFFF59E0B);
  static const kdjJ = Color(0xFF9333EA);

  /// MACD 柱 / 背驰 ±1 柱：正红负绿。
  static const histUp = Color(0xCCDC2626);
  static const histDown = Color(0xCC16A34A);

  /// 副图零轴 / 参考虚线。
  static const axisRef = Color(0x6694A3B8);

  /// 步进节奏：升组暖色（同 roundRef 共用一色）。
  static const rhythmWarm = <Color>[
    Color(0xFFE11D48), // 玫红
    Color(0xFFF59E0B), // 琥珀
    Color(0xFFF97316), // 橙
    Color(0xFFEF4444), // 红
    Color(0xFFD97706), // 深琥珀
    Color(0xFFFB7185), // 浅玫
    Color(0xFFEA580C), // 深橙
    Color(0xFFB45309), // 棕橙
    Color(0xFFF43F5E), // 玫
  ];

  /// 步进节奏：降组冷色。
  static const rhythmCool = <Color>[
    Color(0xFF2563EB), // 蓝
    Color(0xFF0EA5E9), // 天蓝
    Color(0xFF14B8A6), // 青
    Color(0xFF6366F1), // 靛
    Color(0xFF06B6D4), // 青蓝
    Color(0xFF3B82F6), // 亮蓝
    Color(0xFF8B5CF6), // 紫（偏冷）
    Color(0xFF0284C7), // 深蓝
    Color(0xFF0D9488), // 深青
  ];

  /// 节奏点取色（升暖降冷，按 roundRef 上色）。
  static Color rhythm(StepRhythmLinePoint p) {
    final palette = p.dir == 'up' ? rhythmWarm : rhythmCool;
    return palette[p.roundRef.clamp(0, palette.length - 1)];
  }
}

/// 按当前显示的主/副图指标生成图例分组；无多线指标时返回空表（钮自动隐藏）。
///
/// [mains] / [subs] 传「实际绘制集」（已扣灰度），[mathConfig] 提供均线/通道周期，
/// [stepRhythmByKn] 提供步进节奏分组（图上名与图例名同源）。
List<IndicatorLegendGroup> buildIndicatorLegends({
  required Set<MainChartIndicator> mains,
  required Set<SubChartIndicator> subs,
  required MathIndicatorConfig mathConfig,
  Map<int, List<StepRhythmLinePoint>> stepRhythmByKn = const {},
}) {
  final out = <IndicatorLegendGroup>[];

  final sortedMains = mains.toList()
    ..sort((a, b) {
      final c = a.kn.compareTo(b.kn);
      return c != 0 ? c : a.kindOrderInLevel.compareTo(b.kindOrderInLevel);
    });
  final meanPeriods = mathConfig.meanPeriods.toList()..sort();
  final channelPeriods = mathConfig.channelPeriods.toList()..sort();

  for (final m in sortedMains) {
    switch (m.kind) {
      case MainIndicatorKind.meanLine:
        if (meanPeriods.length < 2) break;
        out.add(IndicatorLegendGroup(
          m.label,
          [
            for (var i = 0; i < meanPeriods.length; i++)
              LegendLine('MA${meanPeriods[i]}',
                  color: IndicatorLinePalette.meanLine(i)),
          ],
        ));
      case MainIndicatorKind.trendChannel:
        if (channelPeriods.isEmpty) break;
        out.add(IndicatorLegendGroup(m.label, [
          for (var i = 0; i < channelPeriods.length; i++) ...[
            LegendLine('T${channelPeriods[i]}上',
                color: IndicatorLinePalette.channelTop(i)),
            LegendLine('T${channelPeriods[i]}下',
                color: IndicatorLinePalette.channelBottom(i)),
          ],
        ]));
      case MainIndicatorKind.boll:
        final mid = ChartLevelLineStyle.colorForDisplayKn(m.kn);
        out.add(IndicatorLegendGroup('${m.label}(${mathConfig.bollN})', [
          LegendLine('中轨', color: mid, dashPattern: LegendDash.solid),
          LegendLine('上轨',
              color: IndicatorLinePalette.bandUpper(mid),
              dashPattern: LegendDash.solid),
          LegendLine('下轨',
              color: IndicatorLinePalette.bandLower(mid),
              dashPattern: LegendDash.dash),
        ]));
      case MainIndicatorKind.donchian:
        final mid = ChartLevelLineStyle.colorForDisplayKn(m.kn);
        out.add(IndicatorLegendGroup('${m.label}(${mathConfig.donchianN})', [
          // 与布林完全不同的线型签名：中长虚 / 上点虚 / 下实线
          LegendLine('中轨', color: mid, dashPattern: LegendDash.longDash),
          LegendLine('上轨',
              color: IndicatorLinePalette.bandUpper(mid),
              dashPattern: LegendDash.dotDash),
          LegendLine('下轨',
              color: IndicatorLinePalette.bandLower(mid),
              dashPattern: LegendDash.solid),
        ]));
      case MainIndicatorKind.regressionChannel:
        final c = ChartLevelLineStyle.forDisplayKn(m.kn).color;
        final k = mathConfig.regressK.toStringAsFixed(1);
        out.add(IndicatorLegendGroup('${m.label}(k=$k)', [
          LegendLine('中轨', color: c, dashPattern: LegendDash.dash),
          LegendLine('上轨',
              color: c.withValues(alpha: 0.39), dashPattern: LegendDash.dash),
          LegendLine('下轨',
              color: c.withValues(alpha: 0.39), dashPattern: LegendDash.dash),
        ]));
      case MainIndicatorKind.trendLine:
        final c = ChartLevelLineStyle.forDisplayKn(m.kn).color;
        out.add(IndicatorLegendGroup(m.label, [
          LegendLine('支撑', color: c, dashPattern: LegendDash.dash),
          LegendLine('压力', color: c, dashPattern: LegendDash.dash),
        ]));
      case MainIndicatorKind.fxQuadPair:
        final c = ChartLevelLineStyle.forDisplayKn(m.kn).color;
        out.add(IndicatorLegendGroup(m.label, [
          LegendLine('顶线', color: c, dashPattern: LegendDash.dash),
          LegendLine('底线', color: c, dashPattern: LegendDash.dash),
        ]));
      case MainIndicatorKind.stepRhythm:
        final pts = stepRhythmByKn[m.kn] ?? const <StepRhythmLinePoint>[];
        final seen = <String>{};
        final lines = <LegendLine>[];
        for (final p in pts) {
          if (!seen.add(p.key)) continue;
          lines.add(LegendLine(p.label, color: IndicatorLinePalette.rhythm(p)));
        }
        if (lines.isEmpty) break;
        out.add(IndicatorLegendGroup(m.label, lines));
      // 单线/非线指标不进图例：连线、合并、中枢、Demark 文字标记、三极平行线、
      // 对弦平移线、顶/底极贴合线、筹码峰。
      case MainIndicatorKind.line:
      case MainIndicatorKind.combine:
      case MainIndicatorKind.zs:
      case MainIndicatorKind.fxTripleParallel:
      case MainIndicatorKind.fxChordTranslated:
      case MainIndicatorKind.fxBottomSnug:
      case MainIndicatorKind.fxTopSnug:
      case MainIndicatorKind.demark:
      case MainIndicatorKind.chipPeakSpatial:
      case MainIndicatorKind.chipPeakVolume:
      case MainIndicatorKind.chipPeakPure:
      case MainIndicatorKind.kn:
        break;
    }
  }

  final sortedSubs = subs.toList()
    ..sort((a, b) {
      final c = a.kn.compareTo(b.kn);
      if (c != 0) return c;
      return subIndicatorPickerOrder(a).compareTo(subIndicatorPickerOrder(b));
    });
  for (final s in sortedSubs) {
    switch (s.kind) {
      case SubIndicatorKind.macd:
        out.add(IndicatorLegendGroup(
            '${s.label}(${mathConfig.macdFast}/${mathConfig.macdSlow}/'
            '${mathConfig.macdSignal})',
            const [
              LegendLine('DIF', color: IndicatorLinePalette.macdDif),
              LegendLine('DEA', color: IndicatorLinePalette.macdDea),
              LegendLine(
                'MACD柱',
                color: IndicatorLinePalette.histUp,
                bar: true,
                color2: IndicatorLinePalette.histDown,
              ),
            ]));
      case SubIndicatorKind.kdj:
        out.add(IndicatorLegendGroup(
            '${s.label}(${mathConfig.kdjPeriod})',
            const [
              LegendLine('K', color: IndicatorLinePalette.kdjK),
              LegendLine('D', color: IndicatorLinePalette.kdjD),
              LegendLine('J', color: IndicatorLinePalette.kdjJ),
            ]));
      case SubIndicatorKind.divergence:
        final c = ChartLevelLineStyle.colorForDisplayKn(s.kn);
        out.add(IndicatorLegendGroup(s.label, [
          LegendLine('+1柱',
              color: IndicatorLinePalette.histUp,
              bar: true,
              color2: IndicatorLinePalette.histDown),
          LegendLine('比值线', color: c),
        ]));
      // 单要素副图不进图例：成交量/笔数/分型类/截断/中枢类/BS/比例/斜率/RSI。
      case SubIndicatorKind.volume:
      case SubIndicatorKind.tickCount:
      case SubIndicatorKind.fractalConfirm:
      case SubIndicatorKind.fractalJudgment:
      case SubIndicatorKind.fractalPeakDist:
      case SubIndicatorKind.truncation:
      case SubIndicatorKind.zsConfirm:
      case SubIndicatorKind.zsJudgment:
      case SubIndicatorKind.buy1:
      case SubIndicatorKind.buy2:
      case SubIndicatorKind.buyN:
      case SubIndicatorKind.adjacentRatio:
      case SubIndicatorKind.lineSlope:
      case SubIndicatorKind.rsi:
        break;
    }
  }

  return out;
}