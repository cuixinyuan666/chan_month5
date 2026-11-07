import '../models/chip_config.dart';
import '../models/math_indicator_config.dart';

/// 计优复现参数：分成**点位口径**与**指标参数**两层。
///
/// 为什么要分两层 —— 两层影响的东西根本不同：
/// - **点位口径**决定「统计的是哪些转折点」。其中 `truncationCheck` 会改变分型
///   确认路径，进而改变转折点的位置与数量；不记它，表就无法解释。
/// - **指标参数**决定「每一格的值是多少」。布林 N 从 20 改成 10，同一根 K 上的
///   布林中轨就完全不同；不记它，两张表不可比。
///
/// 与寻优的 `IndicatorSearchAlignSnapshot` 同构，只是字段按上述两层重组。
class KeyPointStatAlign {
  // ---- 点位层：决定「统计哪些点」----
  final String code;
  final String period;
  final String beginText;
  final String endText;

  /// 参与统计的 K0 根数。
  final int barCount;

  /// as-of（最后一根 K 的 idx），决定哪些转折点算「已确认」。
  final int asOf;

  final int maxKn;

  /// 截断监察：影响分型确认 → 影响转折点位置本身。
  final bool truncationCheck;

  /// BS 类号上界（影响三类及以上买卖点指标是否出现）。
  final int maxBsClass;

  // ---- 数值层：决定「每格的值是多少」----
  final MathIndicatorConfig mathConfig;

  /// 筹码分布桶宽。
  final double bucketStep;

  /// 筹码/笔数峰编号方案。
  final String peakRankMode;

  const KeyPointStatAlign({
    this.code = '',
    this.period = '',
    this.beginText = '',
    this.endText = '',
    this.barCount = 0,
    this.asOf = -1,
    this.maxKn = 0,
    this.truncationCheck = true,
    this.maxBsClass = 9,
    this.mathConfig = const MathIndicatorConfig(),
    this.bucketStep = 0.01,
    this.peakRankMode = 'spatial',
  });

  /// 第一行：点位口径（决定统计的是哪些转折点）。
  String pointScopeLine() {
    final scope = '$code $period'.trim();
    final range = beginText.isEmpty || endText.isEmpty
        ? ''
        : ' · 区间 $beginText ~ $endText';
    return '点位口径：$scope$range · K0 $barCount 根 · asOf $asOf · '
        'maxKn $maxKn · 截断监察 ${truncationCheck ? '开' : '关'} · '
        'BS类上界 $maxBsClass';
  }

  /// 第二行：指标参数（决定每一格的值）。
  String indicatorParamsLine() {
    final m = mathConfig;
    final d = m.demarkCountdownMode == DemarkCountdownMode.strictExtreme
        ? '严'
        : '宽松';
    return '指标参数：均线${_ints(m.meanPeriods)} · 通道${_ints(m.channelPeriods)} · '
        'MACD ${m.macdFast}/${m.macdSlow}/${m.macdSignal} · 布林${m.bollN} · '
        '唐奇安${m.donchianN} · 回归k${_r(m.regressK)} · RSI${m.rsiPeriod} · '
        'KDJ${m.kdjPeriod} · '
        'Demark ${m.demarkLen}/${m.demarkSetupBias}/${m.demarkCountdownBias}/'
        '${m.demarkMaxCountdown}/$d/完美9${m.demarkPerfect9 ? '开' : '关'}'
        '/反向打断${m.demarkInterruptCountdownOnReverse ? '开' : '关'} · '
        '背驰阈值${_r(m.divergenceRate)} · 筹码桶宽${_r(bucketStep)} · '
        '峰编号$peakRankMode';
  }

  /// 两行合起来（面板报告头 / TSV 注释行共用）。
  String get headerLines => '${pointScopeLine()}\n${indicatorParamsLine()}';

  static String _ints(List<int> v) => '[${v.join(',')}]';

  static String _r(double v) {
    if (v == v.roundToDouble()) return v.toStringAsFixed(0);
    return v.toString();
  }

  Map<String, dynamic> toJson() => {
        'point_scope': {
          'code': code,
          'period': period,
          'begin': beginText,
          'end': endText,
          'bar_count': barCount,
          'as_of': asOf,
          'max_kn': maxKn,
          'truncation_check': truncationCheck,
          'max_bs_class': maxBsClass,
        },
        'indicator_params': {
          ...mathConfig.toJson(),
          'chip_bucket_step': bucketStep,
          'peak_rank_mode': peakRankMode,
        },
      };

  /// 由设置里的筹码配置取桶宽与峰编号。
  factory KeyPointStatAlign.fromChipConfig(ChipConfig c) => KeyPointStatAlign(
        bucketStep: c.bucketStep,
        peakRankMode: c.peakRankConfig.schemeId,
      );
}