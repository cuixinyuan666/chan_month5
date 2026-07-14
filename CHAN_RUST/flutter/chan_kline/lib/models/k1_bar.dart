/// K0连线确认后包装成的 K1 bar（Rust `K1Bar`）。

class K1Bar {
  final int idx;
  final int dir;
  final int x1;
  final int x2;
  final double open;
  final double high;
  final double low;
  final double close;
  final int confirmX;

  const K1Bar({
    required this.idx,
    required this.dir,
    required this.x1,
    required this.x2,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.confirmX,
  });

  factory K1Bar.fromJson(Map<String, dynamic> json) {
    return K1Bar(
      idx: (json['idx'] as num).toInt(),
      dir: (json['dir'] as num).toInt(),
      x1: (json['x1'] as num).toInt(),
      x2: (json['x2'] as num).toInt(),
      open: (json['open'] as num).toDouble(),
      high: (json['high'] as num).toDouble(),
      low: (json['low'] as num).toDouble(),
      close: (json['close'] as num).toDouble(),
      confirmX: (json['confirm_x'] as num).toInt(),
    );
  }

  bool get isUp => close >= open;
}
