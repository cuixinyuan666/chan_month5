import 'kline_combine_frame.dart';
import 'zs_frame.dart';
import 'buy1_frame.dart';
import 'sell1_frame.dart';
import 'buy2_frame.dart';
import 'sell2_frame.dart';
import 'buy_n_frame.dart';
import 'sell_n_frame.dart';
import 'bs_verdict_frame.dart';

/// 每根 K0 × 每层 Kn 十字线快照（Rust `LevelSnap`，逐K当下冻结）。
class LevelSnap {
  /// 层级：1=K1(K0连线)，2=K2(K1连线)，…（旧称 n段）
  final int level;

  /// 当步所属 Kn 序号（进行中或刚冻结；首段确认前=null）
  final int? unitIdx;
  final int unitDir;

  /// 当步 Kn 的 K0 区间（进行中段 x2=当步K）
  final int unitX1;
  final int unitX2;
  final double unitOpen;
  final double unitHigh;
  final double unitLow;
  final double unitClose;
  final double unitVolume;

  /// 该 Kn 在 Kn合并框内序号（0 起）
  final int mergeInnerSeq;

  /// 所在合并框已含 Kn 根数（逐K当下）
  final int mergeCount;
  final double combineHigh;
  final double combineLow;
  final String combineFx;

  /// 当步所在合并框 1 分钟 K 起点（-1=无）
  final int combineX1;

  /// 当步所在 Kn 合并框序号（第几个合并框，1 起；0=未成框）
  final int mergeBoxSeq;

  // ---- 种子框（首 Kn 合并框）快照：逐K当下冻结 ----
  /// 种子框是否确定态（首个真实分型确认后冻结）
  final bool seedConfirmed;
  /// 种子框序号（=0；-1=无种子框）
  final int seedBoxSeq;
  /// 种子框区间 [x1,x2]
  final int seedBoxX1;
  final int seedBoxX2;
  /// 种子框极值（high/low）
  final double seedBoxHigh;
  final double seedBoxLow;
  /// 种子框分型方向（首个真实分型反向推断；UNKNOWN=未定）
  final String seedFx;
  /// 画线端点：A=种子极值, B=首个分型, C=次分型；-1=未就绪
  final int drawAX;
  final int drawBX;
  final int drawCX;
  /// 首个 Kn 分型状态：JUDGE=判断(线虚) / CONFIRM=确认(A→B实,B→C虚) / UNKNOWN=未就绪
  final String firstFxState;
  /// 离开种子方向（全层同构·方案2·D2）：0=仅 group0 不画开口；+1/-1=已有 group1
  final int seedLeaveDir;

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
    this.mergeBoxSeq = -1,
    this.seedConfirmed = false,
    this.seedBoxSeq = -1,
    this.seedBoxX1 = -1,
    this.seedBoxX2 = -1,
    this.seedBoxHigh = 0,
    this.seedBoxLow = 0,
    this.seedFx = 'UNKNOWN',
    this.drawAX = -1,
    this.drawBX = -1,
    this.drawCX = -1,
    this.firstFxState = 'UNKNOWN',
    this.seedLeaveDir = 0,
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
      mergeBoxSeq: (json['merge_box_seq'] as num?)?.toInt() ?? -1,
      seedConfirmed: json['seed_confirmed'] as bool? ?? false,
      seedBoxSeq: (json['seed_box_seq'] as num?)?.toInt() ?? -1,
      seedBoxX1: (json['seed_box_x1'] as num?)?.toInt() ?? -1,
      seedBoxX2: (json['seed_box_x2'] as num?)?.toInt() ?? -1,
      seedBoxHigh: (json['seed_box_high'] as num?)?.toDouble() ?? 0,
      seedBoxLow: (json['seed_box_low'] as num?)?.toDouble() ?? 0,
      seedFx: json['seed_fx'] as String? ?? 'UNKNOWN',
      drawAX: (json['draw_a_x'] as num?)?.toInt() ?? -1,
      drawBX: (json['draw_b_x'] as num?)?.toInt() ?? -1,
      drawCX: (json['draw_c_x'] as num?)?.toInt() ?? -1,
      firstFxState: json['first_fx_state'] as String? ?? 'UNKNOWN',
      seedLeaveDir: (json['seed_leave_dir'] as num?)?.toInt() ?? 0,
    );
  }
}

/// Kn 分型确认（Rust `LevelConfirm`，冻结历史）。
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

/// Kn 段（Rust `LevelSegment`，端点=分型极点 K0，OHLCV 冻结时已算好）。
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
  /// 起止分型组高低（相邻比例/节奏幅度用）
  final double beginFractalHigh;
  final double beginFractalLow;
  final double endFractalHigh;
  final double endFractalLow;
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
    this.beginFractalHigh = 0,
    this.beginFractalLow = 0,
    this.endFractalHigh = 0,
    this.endFractalLow = 0,
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
      beginFractalHigh: (json['begin_fractal_high'] as num?)?.toDouble() ?? 0,
      beginFractalLow: (json['begin_fractal_low'] as num?)?.toDouble() ?? 0,
      endFractalHigh: (json['end_fractal_high'] as num?)?.toDouble() ?? 0,
      endFractalLow: (json['end_fractal_low'] as num?)?.toDouble() ?? 0,
      isBootstrap: json['is_bootstrap'] as bool? ?? false,
      isPromotedDefault: json['is_promoted_default'] as bool? ?? false,
    );
  }
}

/// Kn 单元（Rust `LevelUnitBar`；旧称 N段K线）。
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

/// 每层 Kn 全量输出（Rust `LevelBundleOut`）。
class LevelBundle {
  final int level;
  final List<LevelConfirm> confirms;
  final List<LevelSegmentN> segments;
  final List<LevelUnitBar> unitBars;
  final List<KlineCombineFrame> combineFrames;
  final List<ZSFrame> zsFrames;
  /// 本层一买（当前枢在上个枢下方）
  final List<Buy1Frame> buy1Frames;
  /// 本层一卖（当前枢在上个枢上方；一买镜像）
  final List<Sell1Frame> sell1Frames;
  /// 本层二买（与一类同框；等高/更高低）
  final List<Buy2Frame> buy2Frames;
  /// 本层二卖（二买镜像）
  final List<Sell2Frame> sell2Frames;
  /// 本层三类+买（链升类）
  final List<BuyNFrame> buyNFrames;
  /// 本层三类+卖（买镜像）
  final List<SellNFrame> sellNFrames;
  /// 本层 BSP 在线评判（独立于原 BSP）
  final List<BsVerdictFrame> bsVerdictFrames;
  final int firstDir;
  final int firstDirX;

  /// 末步进行中 Kn（尚未冻结）
  final LevelUnitBar? activeUnit;

  /// 首段策略：seed=种子框未确认 / retained=已成段（兼容旧 pending）
  final String segmentPolicy;

  /// 已废弃：种子框由 LevelSnap.seed_* 展示，恒为 null
  final LevelUnitBar? pendingUnit;

  const LevelBundle({
    required this.level,
    this.confirms = const [],
    this.segments = const [],
    this.unitBars = const [],
    this.combineFrames = const [],
    this.zsFrames = const [],
    this.buy1Frames = const [],
    this.sell1Frames = const [],
    this.buy2Frames = const [],
    this.sell2Frames = const [],
    this.buyNFrames = const [],
    this.sellNFrames = const [],
    this.bsVerdictFrames = const [],
    this.firstDir = 0,
    this.firstDirX = -1,
    this.activeUnit,
    this.segmentPolicy = 'seed',
    this.pendingUnit,
  });

  factory LevelBundle.fromJson(
    Map<String, dynamic> json, {
    bool slim = false,
  }) {
    return LevelBundle(
      level: (json['level'] as num?)?.toInt() ?? 1,
      confirms: (json['confirms'] as List? ?? const [])
          .map((e) => LevelConfirm.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      segments: slim
          ? const []
          : (json['segments'] as List? ?? const [])
              .map((e) => LevelSegmentN.fromJson(Map<String, dynamic>.from(e as Map)))
              .toList(),
      unitBars: (json['unit_bars'] as List? ?? const [])
          .map((e) => LevelUnitBar.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      combineFrames: slim
          ? const []
          : (json['combine_frames'] as List? ?? const [])
              .map(
                (e) =>
                    KlineCombineFrame.fromJson(Map<String, dynamic>.from(e as Map)),
              )
              .toList(),
      zsFrames: (json['zs_frames'] as List? ?? const [])
          .map((e) => ZSFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buy1Frames: (json['buy1_frames'] as List? ?? const [])
          .map((e) => Buy1Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      sell1Frames: (json['sell1_frames'] as List? ?? const [])
          .map((e) => Sell1Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buy2Frames: (json['buy2_frames'] as List? ?? const [])
          .map((e) => Buy2Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      sell2Frames: (json['sell2_frames'] as List? ?? const [])
          .map((e) => Sell2Frame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      buyNFrames: (json['buy_n_frames'] as List? ?? const [])
          .map((e) => BuyNFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      sellNFrames: (json['sell_n_frames'] as List? ?? const [])
          .map((e) => SellNFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      bsVerdictFrames: (json['bs_verdict_frames'] as List? ?? const [])
          .map((e) =>
              BsVerdictFrame.fromJson(Map<String, dynamic>.from(e as Map)))
          .toList(),
      firstDir: (json['first_dir'] as num?)?.toInt() ?? 0,
      firstDirX: (json['first_dir_x'] as num?)?.toInt() ?? -1,
      activeUnit: json['active_unit'] is Map
          ? LevelUnitBar.fromJson(
              Map<String, dynamic>.from(json['active_unit'] as Map),
            )
          : null,
      segmentPolicy: json['segment_policy'] as String? ?? 'seed',
      pendingUnit: json['pending_unit'] is Map
          ? LevelUnitBar.fromJson(
              Map<String, dynamic>.from(json['pending_unit'] as Map),
            )
          : null,
    );
  }
}
