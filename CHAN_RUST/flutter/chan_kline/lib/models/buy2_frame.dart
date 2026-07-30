/// Kn buy2 marker (Rust Buy2Frame; same level id as ZS / buy1).
class Buy2Frame {
  final int seq;
  final int zsSeq;
  final int x;
  final double price;
  /// "2Ba" / "2Bb" / ...
  final String label;
  final int segIdx;
  final int level;

  const Buy2Frame({
    this.seq = 0,
    this.zsSeq = 0,
    required this.x,
    required this.price,
    required this.label,
    this.segIdx = 0,
    required this.level,
  });

  factory Buy2Frame.fromJson(Map<String, dynamic> json) {
    return Buy2Frame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      zsSeq: (json['zs_seq'] as num?)?.toInt() ?? 0,
      x: (json['x'] as num?)?.toInt() ?? 0,
      price: (json['price'] as num?)?.toDouble() ?? 0,
      label: json['label'] as String? ?? '2Ba',
      segIdx: (json['seg_idx'] as num?)?.toInt() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 0,
    );
  }
}
