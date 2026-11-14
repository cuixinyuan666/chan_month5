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

/// 首分型前的框序列按逐对判定重排（全层同构，子窗口专用）。
///
/// 规则：
/// - 相邻两根有包含关系 → **合并**（高/低取值按 [mergeMode]：高高=都取最大、
///   低低=都取最小），合为一个框；
/// - 相邻两根双低 / 双高 → **不合并**，前一根判分型（顶点=前一根 high/low），
///   顶底交替，同向丢弃；
/// - 标准三元素首分型所在框及其后各框原样保留（该框作为跨界配对的伙伴参与判定，
///   但自身 fx 不改）。
///
/// [standardFirstFx]：标准三元素首分型的方向；候选与它同向时丢弃
/// （分型必须顶底交替）。
///
/// [mergeMode]：包含关系合并时的高/低取值口径（高高 / 低低）。
///
/// 返回新列表；原列表不变。
List<KlineCombineFrame> applyFirstPairFractalToFrames(
  List<KlineCombineFrame> frames, {
  String? standardFirstFx,
  PreFirstFractalMode mergeMode = PreFirstFractalMode.highHigh,
}) {
  if (frames.length <= 1) return frames;
  // 标准首分型所在框下标；frames.length 表示尚无标准首分型。
  var stdIdx = frames.length;
  for (var i = 0; i < frames.length; i++) {
    if (!fxIsUnknownCodeUnit(frames[i].fx)) {
      stdIdx = i;
      break;
    }
  }
  // 判定区间 = [0, stdIdx]，stdIdx 框作为跨界配对的伙伴（自身 fx 不改）。
  final limit = stdIdx;
  if (limit <= 0) return frames;

  final out = <KlineCombineFrame>[];
  // 交替锚点：先按标准首分型方向起算（候选在时间上更早，方向须与后继相反）。
  var lastFx = standardFirstFx ??
      (stdIdx < frames.length ? frames[stdIdx].fx : null);

  var i = 0;
  while (i < limit) {
    // 配对伙伴 = 下一框：须落在判定区间内（<= limit）且真实存在（< 长度）。
    // limit == frames.length（尚无标准首分型）时，最后一框没有伙伴。
    final hasPartner = i + 1 <= limit && i + 1 < frames.length;
    if (hasPartner) {
      final a = frames[i];
      final b = frames[i + 1];
      final rel = fractalPairRel(a.high, a.low, b.high, b.low);
      if (rel == FractalPairRel.contained) {
        // 仅包含关系才合并；高/低取值按设置口径（高高=都取最大，低低=都取最小）。
        // 保留右框 fx（标准首分型标记）
        final box = mergePreFractalBox(a.high, a.low, b.high, b.low, mergeMode);
        out.add(
          KlineCombineFrame(
            x1: a.x1,
            x2: b.x2,
            t1: a.t1,
            t2: b.t2,
            high: box.high,
            low: box.low,
            fx: b.fx,
            count: a.count + b.count,
            endAtLeftHalf: b.endAtLeftHalf,
            startAtRightHalf: a.startAtRightHalf,
          ),
        );
        i += 2;
        continue;
      }
      final fx = fractalPairFx(rel);
      if (fx != null && fractalFxOpposite(lastFx, fx)) {
        // 判分型：不合并，前一根单独成框，顶点=前一根 high(TOP)/low(BOTTOM)
        out.add(
          KlineCombineFrame(
            x1: a.x1,
            x2: a.x2,
            t1: a.t1,
            t2: a.t2,
            high: a.high,
            low: a.low,
            fx: fx,
            count: a.count,
            endAtLeftHalf: a.endAtLeftHalf,
            startAtRightHalf: a.startAtRightHalf,
          ),
        );
        lastFx = fx;
        i += 1;
        continue;
      }
    }
    out.add(frames[i]);
    i += 1;
  }
  return <KlineCombineFrame>[...out, ...frames.sublist(limit)];
}
