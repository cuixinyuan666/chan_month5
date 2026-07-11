import 'kline_combine_frame.dart';

/// 每根 1 分钟 K × 每层 N 段十字线快照（Rust `LevelSnap`，逐K当下冻结）。
class LevelSnap {
  /// 段层级：1=笔，2=线段，…
  final int level;

  /// 当步所属 N 段K线序号（进行中或刚冻结；首段确认前=null）
  final int? unitIdx;
  final int unitDir;

  /// 当步 N 段K线 1 分钟 K 区间（进行中段 x2=当步K）
  final int unitX1;
  final int unitX2;
  final double unitOpen;
  final double unitHigh;
  final double unitLow;
  final double unitClose;
  final double unitVolume;

  /// 该 N 段K线在 N段K线合并框内序号（0 起）
  final int mergeInnerSeq;

  /// 所在合并框已含 N 段K线根数（逐K当下）
  final int mergeCount;
  final double combineHigh;
  final double combineLow;
  final String combineFx;

  /// 当步所在合并框 1 分钟 K 起点（-1=无）
  final int combineX1;

  const LevelSnap({
    required this.level,
    this.unitIdx,
    this.unitDir = 0,
    this.unitX1 = -1,
    this.unitX2 = -1,
    this.unitOpen = 0,
    this.unitHigh = 0,
    this.unitLow = 0,
    this.unitClose = 0,
    this.unitVolume = 0,
    this.mergeInnerSeq = 0,
    this.mergeCount = 1,
    this.combineHigh = 0,
    this.combineLow = 0,
    this.combineFx = 'UNKNOWN',
    this.combineX1 = -1,
  });

  factory LevelSnap.fromJson(Map<String, dynamic> json) {
    final unitRaw = json['unit_idx'];
    return LevelSnap(
      level: (json['level'] as num?)?.toInt() ?? 1,
      unitIdx: unitRaw == null ? null : (unitRaw as num).toInt(),
      unitDir: (json['unit_dir'] as num?)?.toInt() ?? 0,
      unitX1: (json['unit_x1'] as num?)?.toInt() ?? -1,
      unitX2: (json['unit_x2'] as num?)?.toInt() ?? -1,
      unitOpen: (json['unit_open'] as num?)?.toDouble() ?? 0,
      unitHigh: (json['unit_high'] as num?)?.toDouble() ?? 0,
      unitLow: (json['unit_low'] as num?)?.toDouble() ?? 0,
      unitClose: (json['unit_close'] as num?)?.toDouble() ?? 0,
      unitVolume: (json['unit_volume'] as num?)?.toDouble() ?? 0,
      mergeInnerSeq: (json['merge_inner_seq'] as num?)?.toInt() ?? 0,
      mergeCount: (json['merge_count'] as num?)?.toInt() ?? 1,
      combineHigh: (json['combine_high'] as num?)?.toDouble() ?? 0,
      combineLow: (json['combine_low'] as num?)?.toDouble() ?? 0,
      combineFx: json['combine_fx'] as String? ?? 'UNKNOWN',
      combineX1: (json['combine_x1'] as num?)?.toInt() ?? -1,
    );
  }
}

/// N 段分型确认（Rust `LevelConfirm`，冻结历史）。
class LevelConfirm {
  final int x;
  final String fx;

  /// 顶=-1，底=1
  final int value;
  final int fractalX1;
  final int fractalX2;
  final double fractalHigh;
  final double fractalLow;
  final int poleX;
  final int triggerUid;

  /// 是否被用作段端点（同向丢弃/校验失败=false）
  final bool used;

  /// 截断确认（上升/下降截断触发，非常规三元素路径）
  final bool truncated;

  const LevelConfirm({
    required this.x,
    required this.fx,
    required this.value,
    this.fractalX1 = -1,
    this.fractalX2 = -1,
    this.fractalHigh = 0,
    this.fractalLow = 0,
    this.poleX = -1,
    this.triggerUid = -1,
    this.used = false,
    this.truncated = false,
  });

  factory LevelConfirm.fromJson(Map<String, dynamic> json) {
    return LevelConfirm(
      x: (json['x'] as num?)?.toInt() ?? -1,
      fx: json['fx'] as String? ?? 'UNKNOWN',
      value: (json['value'] as num?)?.toInt() ?? 0,
      fractalX1: (json['fractal_x1'] as num?)?.toInt() ?? -1,
      fractalX2: (json['fractal_x2'] as num?)?.toInt() ?? -1,
      fractalHigh: (json['fractal_high'] as num?)?.toDouble() ?? 0,
      fractalLow: (json['fractal_low'] as num?)?.toDouble() ?? 0,
      poleX: (json['pole_x'] as num?)?.toInt() ?? -1,
      triggerUid: (json['trigger_uid'] as num?)?.toInt() ?? -1,
      used: json['used'] as bool? ?? false,
      truncated: json['truncated'] as bool? ?? false,
    );
  }
}

/// N 段（Rust `LevelSegment`，端点=分型极点 1 分钟 K，OHLCV 冻结时已算好）。
class LevelSegmentN {
  final int idx;
  final int dir;
  final int beginConfirmX;
  final int endConfirmX;
  final int beginPoleX;
  final int endPoleX;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final int beginFractalX1;
  final int beginFractalX2;
  final int endFractalX1;
  final int endFractalX2;
  final bool isBootstrap;
  final bool isPromotedDefault;

  const LevelSegmentN({
    required this.idx,
    required this.dir,
    required this.beginConfirmX,
    required this.endConfirmX,
    required this.beginPoleX,
    required this.endPoleX,
    this.open = 0,
    this.high = 0,
    this.low = 0,
    this.close = 0,
    this.volume = 0,
    this.beginFractalX1 = -1,
    this.beginFractalX2 = -1,
    this.endFractalX1 = -1,
    this.endFractalX2 = -1,
    this.isBootstrap = false,
    this.isPromotedDefault = false,
  });

  factory LevelSegmentN.fromJson(Map<String, dynamic> json) {
    return LevelSegmentN(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      dir: (json['dir'] as num?)?.toInt() ?? 0,
      beginConfirmX: (json['begin_confirm_x'] as num?)?.toInt() ?? -1,
      endConfirmX: (json['end_confirm_x'] as num?)?.toInt() ?? -1,
      beginPoleX: (json['begin_pole_x'] as num?)?.toInt() ?? -1,
      endPoleX: (json['end_pole_x'] as num?)?.toInt() ?? -1,
      open: (json['open'] as num?)?.toDouble() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      close: (json['close'] as num?)?.toDouble() ?? 0,
      volume: (json['volume'] as num?)?.toDouble() ?? 0,
      beginFractalX1: (json['begin_fractal_x1'] as num?)?.toInt() ?? -1,
      beginFractalX2: (json['begin_fractal_x2'] as num?)?.toInt() ?? -1,
      endFractalX1: (json['end_fractal_x1'] as num?)?.toInt() ?? -1,
      endFractalX2: (json['end_fractal_x2'] as num?)?.toInt() ?? -1,
      isBootstrap: json['is_bootstrap'] as bool? ?? false,
      isPromotedDefault: json['is_promoted_default'] as bool? ?? false,
    );
  }
}

/// N 段K线（Rust `LevelUnitBar`）。
class LevelUnitBar {
  final int idx;
  final int dir;
  final int x1;
  final int x2;
  final double open;
  final double high;
  final double low;
  final double close;
  final double volume;
  final int confirmX;

  const LevelUnitBar({
    required this.idx,
    required this.dir,
    required this.x1,
    required this.x2,
    this.open = 0,
    this.high = 0,
    this.low = 0,
    this.close = 0,
    this.volume = 0,
    this.confirmX = -1,
  });

  factory LevelUnitBar.fromJson(Map<String, dynamic> json) {
    return LevelUnitBar(
      idx: (json['idx'] as num?)?.toInt() ?? 0,
      dir: (json['dir'] as num?)?.toInt() ?? 0,
      x1: (json['x1'] as num?)?.toInt() ?? -1,
      x2: (json['x2'] as num?)?.toInt() ?? -1,
      open: (json['open'] as num?)?.toDouble() ?? 0,
      high: (json['high'] as num?)?.toDouble() ?? 0,
      low: (json['low'] as num?)?.toDouble() ?? 0,
      close: (json['close'] as num?)?.toDouble() ?? 0,
      volume: (json['volume'] as num?)?.toDouble() ?? 0,
      confirmX: (json['confirm_x'] as num?)?.toInt() ?? -1,
    );
  }
}

/// 每层 N 段全量输出（Rust `LevelBundleOut`）。
class LevelBundle {
  final int level;
  final List<LevelConfirm> confirms;
  final List<LevelSegmentN> segments;
  final List<LevelUnitBar> unitBars;
  final List<KlineCombineFrame> combineFrames;
  final int firstDir;
  final int firstDirX;

  /// 末步进行中 N 段K线（尚未冻结）
  final LevelUnitBar? activeUnit;

  /// 首段策略：pending / retained / purged
  final String segmentPolicy;

  /// 首确认前 pending 占位段
  final LevelUnitBar? pendingUnit;

  const LevelBundle({
    required this.level,
    this.confirms = const [],
    this.segments = const [],
    this.unitBars = const [],
    this.combineFrames = const [],
    this.firstDir = 0,
    this.firstDirX = -1,
    this.activeUnit,
    this.segmentPolicy = 'pending',
    this.pendingUnit,
  });

  factory LevelBundle.fromJson(Map<String, dynamic> json) {
    return LevelBundle(
      level: (json['level'] as num?)?.toInt() ?? 1,
      confirms: (json['confirms'] as List? ?? const [])
          .map((e) => LevelConfirm.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      segments: (json['segments'] as List? ?? const [])
          .map((e) => LevelSegmentN.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      unitBars: (json['unit_bars'] as List? ?? const [])
          .map((e) => LevelUnitBar.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      combineFrames: (json['combine_frames'] as List? ?? const [])
          .map((e) =>
              KlineCombineFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      firstDir: (json['first_dir'] as num?)?.toInt() ?? 0,
      firstDirX: (json['first_dir_x'] as num?)?.toInt() ?? -1,
      activeUnit: json['active_unit'] is Map
          ? LevelUnitBar.fromJson(
              Map<String, dynamic>.from(json['active_unit'] as Map),
            )
          : null,
      segmentPolicy: json['segment_policy'] as String? ?? 'pending',
      pendingUnit: json['pending_unit'] is Map
          ? LevelUnitBar.fromJson(
              Map<String, dynamic>.from(json['pending_unit'] as Map),
            )
          : null,
    );
  }
}
