/// 缠论中枢框（Rust `ZSFrame`；K0=原生分钟K段，K1+=连线段）。
/// high=ZD 上沿，low=ZG 下沿，gg=GG 极高，dd=DD 极低；level：0=K0，1=K1…
class ZSFrame {
  final int seq;
  final int x1;
  final int x2;
  final double high;
  final double low;
  final double gg;
  final double dd;
  final int level;
  final int count;
  final int dir;
  final bool isSure;
  final int? inSegIdx;
  final int? outSegIdx;

  const ZSFrame({
    this.seq = 0,
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
    this.gg = 0,
    this.dd = 0,
    required this.level,
    this.count = 0,
    this.dir = 0,
    this.isSure = true,
    this.inSegIdx,
    this.outSegIdx,
  });

  factory ZSFrame.fromJson(Map<String, dynamic> json) {
    return ZSFrame(
      seq: (json['seq'] as num?)?.toInt() ?? 0,
      x1: (json['x1'] as num?)?.toInt() ?? 0,
      x2: (json['x2'] as num?)?.toInt() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      gg: (json['gg'] as num?)?.toDouble() ?? 0,
      dd: (json['dd'] as num?)?.toDouble() ?? 0,
      level: (json['level'] as num?)?.toInt() ?? 1,
      count: (json['count'] as num?)?.toInt() ?? 0,
      dir: (json['dir'] as num?)?.toInt() ?? 0,
      isSure: json['is_sure'] as bool? ?? true,
      inSegIdx: json['in_seg_idx'] is num
          ? (json['in_seg_idx'] as num).toInt()
          : null,
      outSegIdx: json['out_seg_idx'] is num
          ? (json['out_seg_idx'] as num).toInt()
          : null,
    );
  }
}
