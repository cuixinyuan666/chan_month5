/// @file lib/agent_api/agent_api_host.dart
/// @brief Agent API 契约层：纯 Dart，不依赖具体 UI 状态。
/// 由 AgentApiHost（由主界面实现）提供状态读取与命令执行；
/// AgentApiServer / AgentApiFilePoller 分别把契约暴露为 HTTP 或文件轮询。
import 'dart:convert';

import '../models/bar_crosshair_feature.dart';
import '../models/bar_feature_lookup.dart';
import '../models/chart_indicator.dart';
import '../models/kline_bar.dart';
import '../models/kline_combine_bundle.dart';
import '../models/level_models.dart';
import '../models/chip_config.dart';
import '../models/tick_dist_config.dart';
import '../models/math_indicator_config.dart';

/// Agent 命令执行失败（可读原因）：Server 捕获后回 `ok:false`。
/// 用于「参数非法 / label 不存在 / 配置值越界」这类**不改变状态**的拒绝。
class AgentApiError implements Exception {
  final String message;

  AgentApiError(this.message);

  @override
  String toString() => message;
}

/// Agent 能读取/操作的全部接口契约。主界面（_KlineHomePageState）
/// 实现此抽象类即可；Agent API 层本身不引用任何 Widget，可离线测试。
abstract class AgentApiHost {
  /// 当前是否已加载 K 线会话。
  bool get hasSession;

  /// 选中的股票代码。
  String? get selectedCode;

  /// 当前周期键（tick/1m/5m/…）。
  String get period;

  /// 周期可读标签。
  String get periodLabel;

  /// 数据目录。
  String get dataRoot;

  /// 当前 stepIdx（-1=尚未步进）。
  int get stepIdx;

  /// 总 K0 根数。
  int get totalBars;

  /// 是否正在播放。
  bool get isPlaying;

  /// 主图已选指标集。
  Set<MainChartIndicator> get mainIndicators;

  /// 副图已选指标集。
  Set<SubChartIndicator> get subIndicators;

  /// 筹码配置。
  ChipConfig get chipConfig;

  /// 笔数分布配置。
  TickDistConfig get tickDistConfig;

  /// 数学指标配置。
  MathIndicatorConfig get mathIndicatorConfig;

  /// 截断监察开关。
  bool get truncationCheck;

  /// 当前已加载会话的 K 线序列（与主图同源，只读快照）。
  List<KlineBar> get bars;

  /// 应用可见前缀（0..stepIdx）并重算缠论；等价于用户“步进到第 N 根”。
  void stepTo(int idx);

  /// 向前/向后步进一根（等价于点左/右热区）。
  void stepRelative(int dir);

  /// 播放/暂停。
  void togglePlay();

  /// 一次性走到末尾。
  Future<void> runToEnd();

  /// 停止播放/走完。
  void stop();

  /// 选择股票并加载 K 线（等价于设置面板换代码）。
  Future<void> loadCode({required String code, String? period});

  /// 换周期（不换股票）。
  Future<void> setPeriod(String period);

  /// 返回第 idx 根 K 的十字线 tooltip 行（与画面 tooltip 同源）。
  List<AgentTooltipRow> tooltipRowsAt(int idx);

  /// 返回当前会话快照（各层段、分型确认、买卖点、中枢、末根 bar_feature）。
  AgentSnapshot snapshot();

  /// 按目录 label 设置主/副图指标集（等价用户在面板勾选，触发重绘）。
  ///
  /// [mainLabels] / [subLabels] 为 null 表示该侧不改；空集表示清空该侧。
  /// label 必须能在 `buildMainIndicatorCatalog` / `buildSubIndicatorCatalog` 里查到，
  /// 否则抛 [AgentApiError]（明确拒绝，不静默忽略）。
  Future<String> setIndicators({Set<String>? mainLabels, Set<String>? subLabels});

  /// 程序基础信息（版本、DLL 协议号、进程号、数据目录、运行时长）。
  AgentHealth health();

  /// 开始运行时记录的启动时刻（用于算运行时长）。
  DateTime get startedAt;

  /// 版本号（pubspec version）。
  String get appVersion;

  /// Rust FFI 动态库协议号（未初始化为 -1）。
  int get ffiAbiVersion;
}

/// 十字线 tooltip 一行（与画面 tooltip 同源）。
class AgentTooltipRow {
  final String label;
  final String value;

  AgentTooltipRow({required this.label, required this.value});

  /// 数字值外接方形框（复用 CrosshairTooltipRow 的口径）。
  static String boxNum(dynamic v) => CrosshairTooltipRow.boxNum(v);

  /// 复合字符串中所有数字外接方形框（复用 CrosshairTooltipRow 的口径）。
  static String boxNumInString(String s) => CrosshairTooltipRow.boxNumInString(s);

  Map<String, dynamic> toJson() => {'label': label, 'value': value};
}

/// Agent 可读的完整会话快照（JSON 友好）。
class AgentSnapshot {
  final String code;
  final String period;
  final String periodLabel;
  final int stepIdx;
  final int totalBars;
  final bool isPlaying;
  final int maxKn;

  /// 各层 Kn 流水线（简化：只输出展示字段，不嵌套全量 K1Bar）。
  final List<AgentLevelBundle> levels;

  /// K0 中枢。
  final List<AgentZsFrame> zsK0Frames;

  /// 各层买卖点（会话冻结历史）。
  final List<AgentBsFrame> buy1K0Frames;
  final List<AgentBsFrame> sell1K0Frames;
  final List<AgentBsFrame> buy2K0Frames;
  final List<AgentBsFrame> sell2K0Frames;
  final List<AgentBsFrame> buyNK0Frames;
  final List<AgentBsFrame> sellNK0Frames;

  /// K0 分型确认。
  final List<AgentK0Confirm> k0Confirms;

  /// K0 连线。
  final List<AgentK0Line> k0Lines;

  /// 末根可见 K 的 bar_feature（十字线特征）。
  final AgentBarFeature? tailBarFeature;

  AgentSnapshot({
    required this.code,
    required this.period,
    required this.periodLabel,
    required this.stepIdx,
    required this.totalBars,
    required this.isPlaying,
    required this.maxKn,
    required this.levels,
    required this.zsK0Frames,
    required this.buy1K0Frames,
    required this.sell1K0Frames,
    required this.buy2K0Frames,
    required this.sell2K0Frames,
    required this.buyNK0Frames,
    required this.sellNK0Frames,
    required this.k0Confirms,
    required this.k0Lines,
    required this.tailBarFeature,
  });

  Map<String, dynamic> toJson() {
    return {
      'code': code,
      'period': period,
      'period_label': periodLabel,
      'step_idx': stepIdx,
      'total_bars': totalBars,
      'is_playing': isPlaying,
      'max_kn': maxKn,
      'levels': levels.map((e) => e.toJson()).toList(),
      'zs_k0_frames': zsK0Frames.map((e) => e.toJson()).toList(),
      'buy1_k0_frames': buy1K0Frames.map((e) => e.toJson()).toList(),
      'sell1_k0_frames': sell1K0Frames.map((e) => e.toJson()).toList(),
      'buy2_k0_frames': buy2K0Frames.map((e) => e.toJson()).toList(),
      'sell2_k0_frames': sell2K0Frames.map((e) => e.toJson()).toList(),
      'buy_n_k0_frames': buyNK0Frames.map((e) => e.toJson()).toList(),
      'sell_n_k0_frames': sellNK0Frames.map((e) => e.toJson()).toList(),
      'k0_confirms': k0Confirms.map((e) => e.toJson()).toList(),
      'k0_lines': k0Lines.map((e) => e.toJson()).toList(),
      'tail_bar_feature': tailBarFeature?.toJson(),
    };
  }
}

class AgentLevelBundle {
  final int level;
  final String segmentPolicy;
  final int firstDir;
  final int firstDirX;
  final List<AgentLevelConfirm> confirms;
  final List<AgentLevelSegment> segments;
  final List<AgentLevelUnitBar> unitBars;
  final List<AgentLevelSnap> activeLevels;
  final AgentLevelUnitBar? activeUnit;
  final List<AgentZsFrame> zsFrames;
  final List<AgentBsFrame> buy1Frames;
  final List<AgentBsFrame> sell1Frames;
  final List<AgentBsFrame> buy2Frames;
  final List<AgentBsFrame> sell2Frames;
  final List<AgentBsFrame> buyNFrames;
  final List<AgentBsFrame> sellNFrames;

  AgentLevelBundle({
    required this.level,
    required this.segmentPolicy,
    required this.firstDir,
    required this.firstDirX,
    required this.confirms,
    required this.segments,
    required this.unitBars,
    required this.activeLevels,
    required this.activeUnit,
    required this.zsFrames,
    required this.buy1Frames,
    required this.sell1Frames,
    required this.buy2Frames,
    required this.sell2Frames,
    required this.buyNFrames,
    required this.sellNFrames,
  });

  Map<String, dynamic> toJson() {
    return {
      'level': level,
      'segment_policy': segmentPolicy,
      'first_dir': firstDir,
      'first_dir_x': firstDirX,
      'confirms': confirms.map((e) => e.toJson()).toList(),
      'segments': segments.map((e) => e.toJson()).toList(),
      'unit_bars': unitBars.map((e) => e.toJson()).toList(),
      'active_levels': activeLevels.map((e) => e.toJson()).toList(),
      'active_unit': activeUnit?.toJson(),
      'zs_frames': zsFrames.map((e) => e.toJson()).toList(),
      'buy1_frames': buy1Frames.map((e) => e.toJson()).toList(),
      'sell1_frames': sell1Frames.map((e) => e.toJson()).toList(),
      'buy2_frames': buy2Frames.map((e) => e.toJson()).toList(),
      'sell2_frames': sell2Frames.map((e) => e.toJson()).toList(),
      'buy_n_frames': buyNFrames.map((e) => e.toJson()).toList(),
      'sell_n_frames': sellNFrames.map((e) => e.toJson()).toList(),
    };
  }
}

class AgentLevelConfirm {
  final int x;
  final String fx;
  final int value;
  final int fractalX1;
  final int fractalX2;
  final double fractalHigh;
  final double fractalLow;
  final bool used;
  final bool truncated;

  AgentLevelConfirm({
    required this.x,
    required this.fx,
    required this.value,
    required this.fractalX1,
    required this.fractalX2,
    required this.fractalHigh,
    required this.fractalLow,
    required this.used,
    required this.truncated,
  });

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'fx': fx,
      'value': value,
      'fractal_x1': fractalX1,
      'fractal_x2': fractalX2,
      'fractal_high': fractalHigh,
      'fractal_low': fractalLow,
      'used': used,
      'truncated': truncated,
    };
  }
}

class AgentLevelSegment {
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

  AgentLevelSegment({
    required this.idx,
    required this.dir,
    required this.beginConfirmX,
    required this.endConfirmX,
    required this.beginPoleX,
    required this.endPoleX,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
  });

  Map<String, dynamic> toJson() {
    return {
      'idx': idx,
      'dir': dir,
      'begin_confirm_x': beginConfirmX,
      'end_confirm_x': endConfirmX,
      'begin_pole_x': beginPoleX,
      'end_pole_x': endPoleX,
      'open': open,
      'high': high,
      'low': low,
      'close': close,
      'volume': volume,
    };
  }
}

class AgentLevelUnitBar {
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

  AgentLevelUnitBar({
    required this.idx,
    required this.dir,
    required this.x1,
    required this.x2,
    required this.open,
    required this.high,
    required this.low,
    required this.close,
    required this.volume,
    required this.confirmX,
  });

  Map<String, dynamic> toJson() {
    return {
      'idx': idx,
      'dir': dir,
      'x1': x1,
      'x2': x2,
      'open': open,
      'high': high,
      'low': low,
      'close': close,
      'volume': volume,
      'confirm_x': confirmX,
    };
  }
}

class AgentLevelSnap {
  final int level;
  final int? unitIdx;
  final int unitDir;
  final int unitX1;
  final int unitX2;
  final double unitOpen;
  final double unitHigh;
  final double unitLow;
  final double unitClose;
  final double unitVolume;
  final int mergeInnerSeq;
  final int mergeCount;
  final double combineHigh;
  final double combineLow;
  final String combineFx;
  final int combineX1;
  final int mergeBoxSeq;
  final bool seedConfirmed;
  final int seedBoxSeq;
  final int seedBoxX1;
  final int seedBoxX2;
  final double seedBoxHigh;
  final double seedBoxLow;
  final String seedFx;
  final int drawAX;
  final int drawBX;
  final int drawCX;
  final String firstFxState;
  final int seedLeaveDir;

  AgentLevelSnap({
    required this.level,
    required this.unitIdx,
    required this.unitDir,
    required this.unitX1,
    required this.unitX2,
    required this.unitOpen,
    required this.unitHigh,
    required this.unitLow,
    required this.unitClose,
    required this.unitVolume,
    required this.mergeInnerSeq,
    required this.mergeCount,
    required this.combineHigh,
    required this.combineLow,
    required this.combineFx,
    required this.combineX1,
    required this.mergeBoxSeq,
    required this.seedConfirmed,
    required this.seedBoxSeq,
    required this.seedBoxX1,
    required this.seedBoxX2,
    required this.seedBoxHigh,
    required this.seedBoxLow,
    required this.seedFx,
    required this.drawAX,
    required this.drawBX,
    required this.drawCX,
    required this.firstFxState,
    required this.seedLeaveDir,
  });

  Map<String, dynamic> toJson() {
    return {
      'level': level,
      'unit_idx': unitIdx,
      'unit_dir': unitDir,
      'unit_x1': unitX1,
      'unit_x2': unitX2,
      'unit_open': unitOpen,
      'unit_high': unitHigh,
      'unit_low': unitLow,
      'unit_close': unitClose,
      'unit_volume': unitVolume,
      'merge_inner_seq': mergeInnerSeq,
      'merge_count': mergeCount,
      'combine_high': combineHigh,
      'combine_low': combineLow,
      'combine_fx': combineFx,
      'combine_x1': combineX1,
      'merge_box_seq': mergeBoxSeq,
      'seed_confirmed': seedConfirmed,
      'seed_box_seq': seedBoxSeq,
      'seed_box_x1': seedBoxX1,
      'seed_box_x2': seedBoxX2,
      'seed_box_high': seedBoxHigh,
      'seed_box_low': seedBoxLow,
      'seed_fx': seedFx,
      'draw_a_x': drawAX,
      'draw_b_x': drawBX,
      'draw_c_x': drawCX,
      'first_fx_state': firstFxState,
      'seed_leave_dir': seedLeaveDir,
    };
  }
}

class AgentZsFrame {
  final int kn;
  final int seq;
  final int count;
  final int x1;
  final int x2;
  final double high;
  final double low;
  final bool isSure;

  AgentZsFrame({
    required this.kn,
    required this.seq,
    required this.count,
    required this.x1,
    required this.x2,
    required this.high,
    required this.low,
    required this.isSure,
  });

  Map<String, dynamic> toJson() {
    return {
      'kn': kn,
      'seq': seq,
      'count': count,
      'x1': x1,
      'x2': x2,
      'high': high,
      'low': low,
      'is_sure': isSure,
    };
  }
}

class AgentBsFrame {
  final String label;
  final int x;
  final double price;
  final int segIdx;
  final int zsSeq;

  AgentBsFrame({
    required this.label,
    required this.x,
    required this.price,
    required this.segIdx,
    required this.zsSeq,
  });

  Map<String, dynamic> toJson() {
    return {
      'label': label,
      'x': x,
      'price': price,
      'seg_idx': segIdx,
      'zs_seq': zsSeq,
    };
  }
}

class AgentK0Confirm {
  final int x;
  final String fx;
  final double value;
  final int fractalX1;
  final int fractalX2;
  final bool truncated;

  AgentK0Confirm({
    required this.x,
    required this.fx,
    required this.value,
    required this.fractalX1,
    required this.fractalX2,
    required this.truncated,
  });

  Map<String, dynamic> toJson() {
    return {
      'x': x,
      'fx': fx,
      'value': value,
      'fractal_x1': fractalX1,
      'fractal_x2': fractalX2,
      'truncated': truncated,
    };
  }
}

class AgentK0Line {
  final int idx;
  final int dir;
  final int beginConfirmX;
  final int endConfirmX;
  final int prevIdx;
  final int nextIdx;

  AgentK0Line({
    required this.idx,
    required this.dir,
    required this.beginConfirmX,
    required this.endConfirmX,
    required this.prevIdx,
    required this.nextIdx,
  });

  Map<String, dynamic> toJson() {
    return {
      'idx': idx,
      'dir': dir,
      'begin_confirm_x': beginConfirmX,
      'end_confirm_x': endConfirmX,
      'prev_idx': prevIdx,
      'next_idx': nextIdx,
    };
  }
}

class AgentBarFeature {
  final int idx;
  final String weekday;
  final int mergeInnerSeq;
  final int mergeCount;
  final int mergeBoxSeq;
  final String combineFx;
  final double combineHigh;
  final double combineLow;
  final int fractalPeakDist;
  final int? k1Idx;
  final int k1MergeInnerSeq;
  final int k1MergeCount;
  final double k1Open;
  final double k1High;
  final double k1Low;
  final double k1Close;
  final double k1Volume;
  final double k1CombineHigh;
  final double k1CombineLow;
  final String k1CombineFx;
  final List<AgentLevelSnap> levels;
  final List<AgentZsHit> zsHits;
  final List<AgentBs1Hit> bs1Hits;

  AgentBarFeature({
    required this.idx,
    required this.weekday,
    required this.mergeInnerSeq,
    required this.mergeCount,
    required this.mergeBoxSeq,
    required this.combineFx,
    required this.combineHigh,
    required this.combineLow,
    required this.fractalPeakDist,
    required this.k1Idx,
    required this.k1MergeInnerSeq,
    required this.k1MergeCount,
    required this.k1Open,
    required this.k1High,
    required this.k1Low,
    required this.k1Close,
    required this.k1Volume,
    required this.k1CombineHigh,
    required this.k1CombineLow,
    required this.k1CombineFx,
    required this.levels,
    required this.zsHits,
    required this.bs1Hits,
  });

  Map<String, dynamic> toJson() {
    return {
      'idx': idx,
      'weekday': weekday,
      'merge_inner_seq': mergeInnerSeq,
      'merge_count': mergeCount,
      'merge_box_seq': mergeBoxSeq,
      'combine_fx': combineFx,
      'combine_high': combineHigh,
      'combine_low': combineLow,
      'fractal_peak_dist': fractalPeakDist,
      'k1_idx': k1Idx,
      'k1_merge_inner_seq': k1MergeInnerSeq,
      'k1_merge_count': k1MergeCount,
      'k1_open': k1Open,
      'k1_high': k1High,
      'k1_low': k1Low,
      'k1_close': k1Close,
      'k1_volume': k1Volume,
      'k1_combine_high': k1CombineHigh,
      'k1_combine_low': k1CombineLow,
      'k1_combine_fx': k1CombineFx,
      'levels': levels.map((e) => e.toJson()).toList(),
      'zs_hits': zsHits.map((e) => e.toJson()).toList(),
      'bs1_hits': bs1Hits.map((e) => e.toJson()).toList(),
    };
  }
}

class AgentZsHit {
  final int kn;
  final int seq;
  final double high;
  final double low;
  final bool isSure;

  AgentZsHit({required this.kn, required this.seq, required this.high, required this.low, required this.isSure});

  Map<String, dynamic> toJson() {
    return {
      'kn': kn,
      'seq': seq,
      'high': high,
      'low': low,
      'is_sure': isSure,
    };
  }
}

class AgentBs1Hit {
  final int kn;
  final String side;
  final String label;
  final int x;
  final double price;

  AgentBs1Hit({required this.kn, required this.side, required this.label, required this.x, required this.price});

  Map<String, dynamic> toJson() {
    return {
      'kn': kn,
      'side': side,
      'label': label,
      'x': x,
      'price': price,
    };
  }
}

/// 程序健康信息。
class AgentHealth {
  final String appVersion;
  final int ffiAbiVersion;
  final int pid;
  final String dataRoot;
  final Duration uptime;

  AgentHealth({
    required this.appVersion,
    required this.ffiAbiVersion,
    required this.pid,
    required this.dataRoot,
    required this.uptime,
  });

  Map<String, dynamic> toJson() {
    return {
      'app_version': appVersion,
      'ffi_abi_version': ffiAbiVersion,
      'pid': pid,
      'data_root': dataRoot,
      'uptime_seconds': uptime.inSeconds,
    };
  }
}

/// Agent 可发出的命令（通过 POST /command 或 command.json 发送）。
class AgentCommand {
  /// 命令类型：step_to | step | play | pause | stop | run_to_end | load_code | set_period | set_indicators
  final String type;

  /// step_to 的目标索引。
  final int? idx;

  /// step 的方向：+1 步进，-1 步退。
  final int? dir;

  /// load_code 时的股票代码。
  final String? code;

  /// load_code/set_period 时的周期。
  final String? period;

  /// set_indicators 时的主图/副图指标（逗号分隔的 label）。
  final String? mainIndicators;
  final String? subIndicators;

  AgentCommand({
    required this.type,
    this.idx,
    this.dir,
    this.code,
    this.period,
    this.mainIndicators,
    this.subIndicators,
  });

  factory AgentCommand.fromJson(Map<String, dynamic> json) {
    return AgentCommand(
      type: json['type'] as String? ?? '',
      idx: (json['idx'] as num?)?.toInt(),
      dir: (json['dir'] as num?)?.toInt(),
      code: json['code'] as String?,
      period: json['period'] as String?,
      mainIndicators: json['main_indicators'] as String?,
      subIndicators: json['sub_indicators'] as String?,
    );
  }

  Map<String, dynamic> toJson() {
    return {
      'type': type,
      if (idx != null) 'idx': idx,
      if (dir != null) 'dir': dir,
      if (code != null) 'code': code,
      if (period != null) 'period': period,
      if (mainIndicators != null) 'main_indicators': mainIndicators,
      if (subIndicators != null) 'sub_indicators': subIndicators,
    };
  }
}

/// 命令执行结果。
class AgentCommandResult {
  final bool ok;
  final String message;
  final Map<String, dynamic>? data;

  AgentCommandResult({required this.ok, required this.message, this.data});

  Map<String, dynamic> toJson() {
    return {'ok': ok, 'message': message, if (data != null) 'data': data};
  }
}

/// 从 LevelBundle 构造 AgentLevelBundle（只取展示字段，不嵌套全量 K1Bar）。
AgentLevelBundle toAgentLevelBundle(LevelBundle lv) {
  return AgentLevelBundle(
    level: lv.level,
    segmentPolicy: lv.segmentPolicy,
    firstDir: lv.firstDir,
    firstDirX: lv.firstDirX,
    confirms: lv.confirms
        .map((c) => AgentLevelConfirm(
              x: c.x,
              fx: c.fx,
              value: c.value,
              fractalX1: c.fractalX1,
              fractalX2: c.fractalX2,
              fractalHigh: c.fractalHigh,
              fractalLow: c.fractalLow,
              used: c.used,
              truncated: c.truncated,
            ))
        .toList(),
    segments: lv.segments
        .map((s) => AgentLevelSegment(
              idx: s.idx,
              dir: s.dir,
              beginConfirmX: s.beginConfirmX,
              endConfirmX: s.endConfirmX,
              beginPoleX: s.beginPoleX,
              endPoleX: s.endPoleX,
              open: s.open,
              high: s.high,
              low: s.low,
              close: s.close,
              volume: s.volume,
            ))
        .toList(),
    unitBars: lv.unitBars
        .map((u) => AgentLevelUnitBar(
              idx: u.idx,
              dir: u.dir,
              x1: u.x1,
              x2: u.x2,
              open: u.open,
              high: u.high,
              low: u.low,
              close: u.close,
              volume: u.volume,
              confirmX: u.confirmX,
            ))
        .toList(),
    activeLevels: [],
    activeUnit: lv.activeUnit != null
        ? AgentLevelUnitBar(
              idx: lv.activeUnit!.idx,
              dir: lv.activeUnit!.dir,
              x1: lv.activeUnit!.x1,
              x2: lv.activeUnit!.x2,
              open: lv.activeUnit!.open,
              high: lv.activeUnit!.high,
              low: lv.activeUnit!.low,
              close: lv.activeUnit!.close,
              volume: lv.activeUnit!.volume,
              confirmX: lv.activeUnit!.confirmX,
            )
        : null,
    zsFrames: lv.zsFrames
        .map((z) => AgentZsFrame(
              kn: z.level,
              seq: z.seq,
              count: z.count,
              x1: z.x1,
              x2: z.x2,
              high: z.high,
              low: z.low,
              isSure: z.isSure,
            ))
        .toList(),
    buy1Frames: lv.buy1Frames
        .map((b) => AgentBsFrame(
              label: b.label,
              x: b.x,
              price: b.price,
              segIdx: b.segIdx,
              zsSeq: b.zsSeq,
            ))
        .toList(),
    sell1Frames: lv.sell1Frames
        .map((s) => AgentBsFrame(
              label: s.label,
              x: s.x,
              price: s.price,
              segIdx: s.segIdx,
              zsSeq: s.zsSeq,
            ))
        .toList(),
    buy2Frames: lv.buy2Frames
        .map((b) => AgentBsFrame(
              label: b.label,
              x: b.x,
              price: b.price,
              segIdx: b.segIdx,
              zsSeq: b.zsSeq,
            ))
        .toList(),
    sell2Frames: lv.sell2Frames
        .map((s) => AgentBsFrame(
              label: s.label,
              x: s.x,
              price: s.price,
              segIdx: s.segIdx,
              zsSeq: s.zsSeq,
            ))
        .toList(),
    buyNFrames: lv.buyNFrames
        .map((b) => AgentBsFrame(
              label: b.label,
              x: b.x,
              price: b.price,
              segIdx: b.segIdx,
              zsSeq: b.zsSeq,
            ))
        .toList(),
    sellNFrames: lv.sellNFrames
        .map((s) => AgentBsFrame(
              label: s.label,
              x: s.x,
              price: s.price,
              segIdx: s.segIdx,
              zsSeq: s.zsSeq,
            ))
        .toList(),
  );
}

/// 从 BarCrosshairFeature 构造 AgentBarFeature。
AgentBarFeature toAgentBarFeature(BarCrosshairFeature f) {
  return AgentBarFeature(
    idx: f.idx,
    weekday: f.weekday,
    mergeInnerSeq: f.mergeInnerSeq,
    mergeCount: f.mergeCount,
    mergeBoxSeq: f.mergeBoxSeq,
    combineFx: f.combineFx,
    combineHigh: f.combineHigh,
    combineLow: f.combineLow,
    fractalPeakDist: f.fractalPeakDist,
    k1Idx: f.k1Idx,
    k1MergeInnerSeq: f.k1MergeInnerSeq,
    k1MergeCount: f.k1MergeCount,
    k1Open: f.k1Open,
    k1High: f.k1High,
    k1Low: f.k1Low,
    k1Close: f.k1Close,
    k1Volume: f.k1Volume,
    k1CombineHigh: f.k1CombineHigh,
    k1CombineLow: f.k1CombineLow,
    k1CombineFx: f.k1CombineFx,
    levels: f.levels.map((l) {
      return AgentLevelSnap(
        level: l.level,
        unitIdx: l.unitIdx,
        unitDir: l.unitDir,
        unitX1: l.unitX1,
        unitX2: l.unitX2,
        unitOpen: l.unitOpen,
        unitHigh: l.unitHigh,
        unitLow: l.unitLow,
        unitClose: l.unitClose,
        unitVolume: l.unitVolume,
        mergeInnerSeq: l.mergeInnerSeq,
        mergeCount: l.mergeCount,
        combineHigh: l.combineHigh,
        combineLow: l.combineLow,
        combineFx: l.combineFx,
        combineX1: l.combineX1,
        mergeBoxSeq: l.mergeBoxSeq,
        seedConfirmed: l.seedConfirmed,
        seedBoxSeq: l.seedBoxSeq,
        seedBoxX1: l.seedBoxX1,
        seedBoxX2: l.seedBoxX2,
        seedBoxHigh: l.seedBoxHigh,
        seedBoxLow: l.seedBoxLow,
        seedFx: l.seedFx,
        drawAX: l.drawAX,
        drawBX: l.drawBX,
        drawCX: l.drawCX,
        firstFxState: l.firstFxState,
        seedLeaveDir: l.seedLeaveDir,
      );
    }).toList(),
    zsHits: f.zsHits
        .map((z) => AgentZsHit(
              kn: z.kn,
              seq: z.seq,
              high: z.high,
              low: z.low,
              isSure: z.isSure,
            ))
        .toList(),
    bs1Hits: f.bs1Hits
        .map((b) => AgentBs1Hit(
              kn: b.kn,
              side: b.side,
              label: b.label,
              x: b.x,
              price: b.price,
            ))
        .toList(),
  );
}

/// 从 KlineCombineBundle 构造 AgentSnapshot（调用方负责传入 tailBarFeature）。
AgentSnapshot bundleToSnapshot({
  required KlineCombineBundle bundle,
  required String code,
  required String period,
  required String periodLabel,
  required int stepIdx,
  required int totalBars,
  required bool isPlaying,
  required AgentBarFeature? tailBarFeature,
}) {
  final maxKn = bundle.levels.isEmpty ? 0 : bundle.levels.last.level;
  return AgentSnapshot(
    code: code,
    period: period,
    periodLabel: periodLabel,
    stepIdx: stepIdx,
    totalBars: totalBars,
    isPlaying: isPlaying,
    maxKn: maxKn,
    levels: bundle.levels.map(toAgentLevelBundle).toList(),
    zsK0Frames: bundle.zsK0Frames
        .map((z) => AgentZsFrame(
              kn: z.level,
              seq: z.seq,
              count: z.count,
              x1: z.x1,
              x2: z.x2,
              high: z.high,
              low: z.low,
              isSure: z.isSure,
            ))
        .toList(),
    buy1K0Frames: bundle.buy1K0Frames
        .map((b) => AgentBsFrame(
              label: b.label,
              x: b.x,
              price: b.price,
              segIdx: b.segIdx,
              zsSeq: b.zsSeq,
            ))
        .toList(),
    sell1K0Frames: bundle.sell1K0Frames
        .map((s) => AgentBsFrame(
              label: s.label,
              x: s.x,
              price: s.price,
              segIdx: s.segIdx,
              zsSeq: s.zsSeq,
            ))
        .toList(),
    buy2K0Frames: bundle.buy2K0Frames
        .map((b) => AgentBsFrame(
              label: b.label,
              x: b.x,
              price: b.price,
              segIdx: b.segIdx,
              zsSeq: b.zsSeq,
            ))
        .toList(),
    sell2K0Frames: bundle.sell2K0Frames
        .map((s) => AgentBsFrame(
              label: s.label,
              x: s.x,
              price: s.price,
              segIdx: s.segIdx,
              zsSeq: s.zsSeq,
            ))
        .toList(),
    buyNK0Frames: bundle.buyNK0Frames
        .map((b) => AgentBsFrame(
              label: b.label,
              x: b.x,
              price: b.price,
              segIdx: b.segIdx,
              zsSeq: b.zsSeq,
            ))
        .toList(),
    sellNK0Frames: bundle.sellNK0Frames
        .map((s) => AgentBsFrame(
              label: s.label,
              x: s.x,
              price: s.price,
              segIdx: s.segIdx,
              zsSeq: s.zsSeq,
            ))
        .toList(),
    k0Confirms: bundle.k0Confirms
        .map((c) => AgentK0Confirm(
              x: c.x,
              fx: c.fx,
              value: c.value.toDouble(),
              fractalX1: c.fractalX1,
              fractalX2: c.fractalX2,
              truncated: c.truncated,
            ))
        .toList(),
    k0Lines: bundle.k0Lines
        .map((l) => AgentK0Line(
              idx: l.idx,
              dir: l.dir,
              beginConfirmX: l.beginConfirmX,
              endConfirmX: l.endConfirmX,
              prevIdx: l.prevIdx ?? -1,
              nextIdx: l.nextIdx ?? -1,
            ))
        .toList(),
    tailBarFeature: tailBarFeature,
  );
}

/// JSON 编码辅助（紧凑单行，便于剪贴板/文件）。
String agentJsonEncode(Object? value) => const JsonEncoder.withIndent('  ').convert(value);

/// 单根 K 线的 Agent JSON：
/// `idx / ts / time_text / open / high / low / close / volume / amount / tick_count`。
/// [tickCount] 缺省时取 `metrics.tick_count`（与副图笔数同源）；完整系列请用
/// `computeK0TickCountSeries` 取口径一致的笔数再传入。
Map<String, dynamic> agentBarJson(KlineBar bar, {double? tickCount}) {
  final raw = bar.metrics['tick_count'];
  return {
    'idx': bar.idx,
    'ts': bar.timeMs,
    'time_text': bar.timeText,
    'open': bar.open,
    'high': bar.high,
    'low': bar.low,
    'close': bar.close,
    'volume': bar.volume,
    'amount': bar.amount,
    'tick_count': tickCount ?? (raw is num ? raw.toDouble() : 0.0),
  };
}

/// JSON 解码辅助。
Map<String, dynamic>? agentJsonDecode(String? text) {
  if (text == null || text.isEmpty) return null;
  try {
    final decoded = jsonDecode(text);
    if (decoded is Map<String, dynamic>) return decoded;
    return null;
  } catch (_) {
    return null;
  }
}
