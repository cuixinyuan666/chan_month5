/// Kn sell2 marker (Rust Sell2Frame; same level id as ZS / buy2).
class Sell2Frame {
  final int seq;
  final int zsSeq;
  final int x;
  final double price;
  /// "2Sa" / "2Sb" / ...
  final String label;
  final int segIdx;
  final int level;

  const Sell2Frame({
    this.seq = 0,
    this.zsSeq = 0,
    required this.x,
    required this.price,
    required this.label,
    this.segIdx = 0,
    required this.level,
  });

  factory Sell2Frame.fromJson(Map<String, dynamic> json) {
    return Sell2Frame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? '2Sa',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}
