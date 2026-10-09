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

  /// 虚线（回归通道、延伸族点线）。
  final bool dashed;

  /// 柱状元素（MACD 柱、背驰 ±1 柱）。
  final bool bar;

  /// 柱的第二色（红涨绿跌的负色）；非柱为 null。
  final Color? color2;

  const LegendLine(
    this.label, {
    required this.color,
    this.dashed = false,
    this.bar = false,
    this.color2,
  });
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

  /// 布林/唐奇安：上下轨 = 中轨色降透明度。
  static Color bandSide(Color mid) => mid.withValues(alpha: 0.55);

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
      case MainIndicatorKind.donchian:
        final mid = ChartLevelLineStyle.colorForDisplayKn(m.kn);
        final side = IndicatorLinePalette.bandSide(mid);
        out.add(IndicatorLegendGroup(m.label, [
          LegendLine('中轨', color: mid),
          LegendLine('上轨', color: side),
          LegendLine('下轨', color: side),
        ]));
      case MainIndicatorKind.regressionChannel:
        final c = ChartLevelLineStyle.forDisplayKn(m.kn).color;
        out.add(IndicatorLegendGroup(m.label, [
          LegendLine('中轨', color: c, dashed: true),
          LegendLine('上轨', color: c.withValues(alpha: 0.39), dashed: true),
          LegendLine('下轨', color: c.withValues(alpha: 0.39), dashed: true),
        ]));
      case MainIndicatorKind.trendLine:
        final c = ChartLevelLineStyle.forDisplayKn(m.kn).color;
        out.add(IndicatorLegendGroup(m.label, [
          LegendLine('支撑', color: c, dashed: true),
          LegendLine('压力', color: c, dashed: true),
        ]));
      case MainIndicatorKind.fxQuadPair:
        final c = ChartLevelLineStyle.forDisplayKn(m.kn).color;
        out.add(IndicatorLegendGroup(m.label, [
          LegendLine('顶线', color: c, dashed: true),
          LegendLine('底线', color: c, dashed: true),
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
        out.add(IndicatorLegendGroup(s.label, const [
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
        out.add(IndicatorLegendGroup(s.label, const [
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