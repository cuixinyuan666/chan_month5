/// 单根 K 线主单元（字典式，对齐 CKLine_Unit 核心字段 + 可扩展指标槽）。
class KlineBar {
  final int idx;
  final int timeMs;
  final String timeText;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final double amount;
  final Map<String, dynamic> metrics;

  const KlineBar({
    this.idx = 0,
    required this.timeMs,
    required this.timeText,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.amount,
    this.metrics = const {},
  });

  factory KlineBar.fromJson(Map<String, dynamic> json) {
    final rawMetrics = json['metrics'];
    return KlineBar(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      timeMs: (json['time_ms'] as num).toInt(),
      timeText: json['time_text'] as String? ?? '',
      open: (json['open'] as num).toDouble(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      close: (json['close'] as num).toDouble(),
      volume: (json['volume'] as num).toDouble(),
      amount: (json['amount'] as num).toDouble(),
      metrics: rawMetrics is Map
          ? Map<String, dynamic>.from(rawMetrics)
          : const {},
    );
  }

  bool get isUp => close >= open;

  Map<String, dynamic> toJson() => {
        'idx': idx,
        'time_ms': timeMs,
        'time_text': timeText,
        'open': open,
        'high': high,
        'low': low,
        'close': close,
        'volume': volume,
        'amount': amount,
        if (metrics.isNotEmpty) 'metrics': metrics,
      };
}
