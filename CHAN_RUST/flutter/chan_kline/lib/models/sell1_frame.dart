/// Kn sell1 marker (Rust Sell1Frame; same level id as ZS / buy1).
class Sell1Frame {
  final int seq;
  final int zsSeq;
  final int x;
  final double price;
  /// "1Sa" / "1Sb" / ...
  final String label;
  final int segIdx;
  final int level;

  const Sell1Frame({
    this.seq = 0,
    this.zsSeq = 0,
    required this.x,
    required this.price,
    required this.label,
    this.segIdx = 0,
    required this.level,
  });

  factory Sell1Frame.fromJson(Map<String, dynamic> json) {
    return Sell1Frame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? '1Sa',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}
