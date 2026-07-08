/// 笔确认后包装成的笔 K 线（Rust `BiVirtualBar`）。

class BiVirtualBar {
  final int idx;
  final int dir;
  final int x1;
  final int x2;
  final double open;
  final double high;
  final double low;
  final double close;
  final int confirmX;

  const BiVirtualBar({
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

  factory BiVirtualBar.fromJson(Map<String, dynamic> json) {
    return BiVirtualBar(
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
