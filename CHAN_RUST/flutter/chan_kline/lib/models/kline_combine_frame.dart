/// K线合并线框（Rust `KlineCombineFrame`）。
class KlineCombineFrame {
  final int x1;
  final int x2;
  final String t1;
  final String t2;
  final double high;
  final double low;
  final String fx;
  final int count;
  /// 末端落在 x2 分钟 K 左半侧（右边界=该 K 中轴）
  final bool endAtLeftHalf;
  /// 起始落在 x1 分钟 K 右半侧（左边界=该 K 中轴）
  final bool startAtRightHalf;

  const KlineCombineFrame({
    required this.x1,
    required this.x2,
    required this.t1,
    required this.t2,
    required this.high,
    required this.low,
    required this.fx,
    required this.count,
    this.endAtLeftHalf = false,
    this.startAtRightHalf = false,
  });

  factory KlineCombineFrame.fromJson(Map<String, dynamic> json) {
    return KlineCombineFrame(
      x1: (json['x1'] as num).toInt(),
      x2: (json['x2'] as num).toInt(),
      t1: json['t1'] as String? ?? '',
      t2: json['t2'] as String? ?? '',
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      fx: json['fx'] as String? ?? 'UNKNOWN',
      count: (json['count'] as num?)?.toInt() ?? 1,
      endAtLeftHalf: json['end_at_left_half'] as bool? ?? false,
      startAtRightHalf: json['start_at_right_half'] as bool? ?? false,
    );
  }
}

/// 主图指标类型（可多选叠加）。
enum MainChartIndicator {
  kline('K线'),
  biLine('1段K线'),
  segLine('2段及以上K线'),
  klineCombine('K线合并'),
  biKlineCombine('1段K线合并');

  const MainChartIndicator(this.label);
  final String label;
}

/// 副图指标类型。
enum SubChartIndicator {
  volume('成交量'),
  klineCombine('K线合并'),
  biKlineCombine('1段K线合并'),
  biConfirm('K线合并分型确认'),
  segConfirm('段确认'),
  firstSegDir('首段向'),
  fractalPeakDist('K线分型极点距');

  const SubChartIndicator(this.label);
  final String label;
}
