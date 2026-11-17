/// 子窗口模式 · 首分型逐对判定（全层同构：K0 / K1..Kn 共用同一套口径）。
///
/// 口径（2026-11-12 用户确认）：
/// - 第二根的最高价、最低价**均低于**第一根 → 第一根直接判**顶分型**，
///   顶点取第一根的 high，且**不再执行取高策略**（该框单独成框，不并入合框）；
/// - 镜像规则：第二根的最高价、最低价**均高于**第一根 → 第一根直接判**底分型**，
///   顶点取第一根的 low，同样不合并；
/// - **仅当**两根存在包含关系（内包含 / 外包含）时，才执行取高策略（合并）；
/// - 顶底**交替**：连续同向的分型判定丢弃
///   （idx=0 已是顶分型后，下一个分型必须是底分型，故 idx=1、idx=2 都不算分型）。
///
/// 判定只需相邻两根：第二根到来时第一根即成立，故首分型可早于标准三元素
/// 分型出现 —— 这正是本规则的全部作用（只作用于「首分型前」）。
///
/// 判定输入为「该层画出来的框」（K0 层 = 引擎分组；K1..Kn 层 = 该层虚拟单元分组），
/// 与引擎自身的包含合并口径一致，故全层同构。
library;

import '../models/kline_combine_frame.dart';
import '../models/pre_first_fractal_mode.dart';

/// 相邻两根框 / 单元的关系。
enum FractalPairRel {
  /// 第二根双低（最高、最低均低于第一根）→ 顶分型
  bothLower,

  /// 第二根双高（最高、最低均高于第一根）→ 底分型
  bothHigher,

  /// 存在包含关系（内包含 / 外包含 / 高低交叉）→ 才执行取高合并
  ///
  /// 判定顺序与引擎 `test_combine_range`（engine.rs:242）一致：先判包含，
  /// 再判双高 / 双低，兜底 Combine。故「高低交叉」在本口径下也归入包含，
  /// 不存在独立的交叉分支。
  contained,
}

/// UNKNOWN 按码位判断（与 painter 的 `_fxIsUnknown` 同款）。
///
/// debug 内核里字符串相等会把别的分型也判成相等（已用逐码位日志核实），
/// 故此处不使用 `== 'UNKNOWN'`。
bool fxIsUnknownCodeUnit(String fx) {
  const units = <int>[85, 78, 75, 78, 79, 87, 78];
  final u = fx.codeUnits;
  if (u.length != units.length) return false;
  for (var i = 0; i < u.length; i++) {
    if (u[i] != units[i]) return false;
  }
  return true;
}

/// 相邻两根框 / 单元的关系判定。
FractalPairRel fractalPairRel(double h1, double l1, double h2, double l2) {
  if (h2 < h1 && l2 < l1) return FractalPairRel.bothLower;
  if (h2 > h1 && l2 > l1) return FractalPairRel.bothHigher;
  return FractalPairRel.contained;
}

/// 该关系应判的分型方向；null = 不判分型（走取高合并）。
String? fractalPairFx(FractalPairRel rel) {
  switch (rel) {
    case FractalPairRel.bothLower:
      return 'TOP';
    case FractalPairRel.bothHigher:
      return 'BOTTOM';
    case FractalPairRel.contained:
      return null;
  }
}

/// 顶底交替：同向丢弃。
bool fractalFxOpposite(String? lastFx, String fx) => lastFx != fx;

/// 首分型前合并框的高/低取值（绘制与 tooltip 共用，避免两处各写一套）。
///
/// - [PreFirstFractalMode.highHigh]：`high` / `low` **都取最大**（历史口径）；
/// - [PreFirstFractalMode.lowLow]：`high` / `low` **都取最小**；
/// - [PreFirstFractalMode.seedBox]：不合并，调用方不应走到这里；兜底按高高。
({double high, double low}) mergePreFractalBox(
  double h1,
  double l1,
  double h2,
  double l2,
  PreFirstFractalMode mode,
) {
  if (mode == PreFirstFractalMode.lowLow) {
    return (high: h1 < h2 ? h1 : h2, low: l1 < l2 ? l1 : l2);
  }
  return (high: h1 > h2 ? h1 : h2, low: l1 > l2 ? l1 : l2);
}

/// 首分型前：把「真首分型之前（含它）」的各框并成一个（全层同构）。
///
/// 规则（2026-11-17 用户最终确认，取代 11-16 的逐对生长版）：
/// - 找出该层第一个**引擎已给出分型**的帧（`stdIdx`）；
/// - 有 → 把 `[0, stdIdx]` 全部并成一框（含分型帧），fx 取该帧的引擎分型；
/// - 没有 → 把整个序列并成一框，fx 保持 UNKNOWN（虚线构建中）；
/// - 其余帧原样保留。
///
/// 为什么不再用「双高/双低提前断开」：那会让未确认的层凭空裂框——
/// K1 层曾出现「第 8 根一出来，首框从 1 个框裂成 2 个、下沿 10.26→10.10、
/// 样式由虚线变实线」，而该层 `confirms=0`、`segmentPolicy=seed`。
/// 用户口径：只有真分型出现才允许定型，K0 / K1 / … / Kn 同一条规则。
///
/// [standardFirstFx]：保留参数兼容旧调用方，当前未使用（分型一律取引擎）。
/// [mergeMode]：并框时的高/低取值口径（高高 = 都取最大、低低 = 都取最小）。
///
/// 返回新列表；原列表不变。
List<KlineCombineFrame> applyFirstPairFractalToFrames(
  List<KlineCombineFrame> frames, {
  String? standardFirstFx,
  PreFirstFractalMode mergeMode = PreFirstFractalMode.highHigh,
}) {
  if (frames.length <= 1) return frames;
  // 首个非 UNKNOWN 帧 = 该层真首分型所在帧；frames.length 表示还没有。
  var stdIdx = frames.length;
  for (var i = 0; i < frames.length; i++) {
    if (!fxIsUnknownCodeUnit(frames[i].fx)) {
      stdIdx = i;
      break;
    }
  }
  // 合并区间 [0, end)：有真分型并到它（含）为止，没有则并到序列末尾。
  final end = stdIdx < frames.length ? stdIdx + 1 : frames.length;
  if (end <= 1) return frames;

  var boxHigh = frames.first.high;
  var boxLow = frames.first.low;
  var boxCount = 0;
  for (var i = 0; i < end; i++) {
    final box = mergePreFractalBox(
      boxHigh,
      boxLow,
      frames[i].high,
      frames[i].low,
      mergeMode,
    );
    boxHigh = box.high;
    boxLow = box.low;
    boxCount += frames[i].count;
  }
  final last = frames[end - 1];
  return <KlineCombineFrame>[
    KlineCombineFrame(
      x1: frames.first.x1,
      x2: last.x2,
      t1: frames.first.t1,
      t2: last.t2,
      high: boxHigh,
      low: boxLow,
      fx: last.fx,
      count: boxCount,
      endAtLeftHalf: last.endAtLeftHalf,
      startAtRightHalf: frames.first.startAtRightHalf,
    ),
    ...frames.sublist(end),
  ];
}
