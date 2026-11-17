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
/// 规则（2026-11-16 用户最终确认：首框按「与前一个合并框比包含」迭代生成，
/// 与分笔画板 K0 首框同构）：
/// - 首根 K 先成一个「正在生长的合并框」；后续每根 K 都**与这个已生长的框**
///   判包含关系（不是与相邻单根逐对比）：
///   - 包含（内包含 / 外包含 / 高低交叉）→ 并进该框，框的高/低按 [mergeMode]
///     更新（高高=都取最大、低低=都取最小），框继续生长；
///   - 双低（h2<h1 且 l2<l1）/ 双高 → 停止生长，前一根判顶/底分型，
///     顶点=前一根 high(TOP)/low(BOTTOM)，顶底交替，同向丢弃；
/// - 这样「第一个合并框」会把首分型前所有与它含融的 K 都吃进去（当前 5 根
///   数据高高口径 = 前 4 根一框），而旧实现只两两相邻比、只并到前 2 根；
/// - 标准三元素首分型所在框及其后各框原样保留（首框生长可以越过该框把它并
///   进去，一旦并入则以框为单位，不再为它单独画分型）；
/// - **该层还没有真首分型时（`stdIdx == frames.length`）只做含融合并，
///   不判双高/双低分型**——2026-11-17 用户明确的全层同构要求：K1 层曾出现
///   「第 7 根一出来，首框从虚线直接变确认框」，而该层 confirms=0、
///   segmentPolicy=seed，等于凭空盖章；K0 层没这问题（它的 fx 来自引擎）。
///   现在所有层同一条规则：没有真分型 → 框一律保持 UNKNOWN（虚线构建中）。
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
  // 该层有没有**真**首分型（引擎确认过的那种）。
  //
  // 全层同构（2026-11-17 用户明确）：没有真分型的层，只许做含融合并，
  // 不许凭"相邻两根双高/双低"给首框盖分型的章。否则 K1 层会出现
  // 「第 7 根一出来，首框从虚线直接变确认框」——而该层 confirms 仍为 0、
  // segmentPolicy 仍是 seed，等于凭空认定，与 K0 层口径不同构。
  final hasStandardFx = stdIdx < frames.length;
  // 判定区间 = [0, stdIdx]：首框生长只发生在这段「首分型前」区域。
  final limit = stdIdx;
  if (limit <= 0) return frames;

  final out = <KlineCombineFrame>[];
  // 交替锚点：先按标准首分型方向起算（候选在时间上更早，方向须与后继相反）。
  var lastFx = standardFirstFx ??
      (stdIdx < frames.length ? frames[stdIdx].fx : null);

  var i = 0;
  while (i < limit) {
    // 以 frames[i] 起一个「生长框」，把后面每一根与**当前框**判包含，
    // 含融就并进来，直到双高/双低或越过 limit 才停。
    var boxHigh = frames[i].high;
    var boxLow = frames[i].low;
    var boxCount = frames[i].count;
    final x1 = frames[i].x1;
    final t1 = frames[i].t1;
    final startAtRightHalf = frames[i].startAtRightHalf;
    var x2 = frames[i].x2;
    var t2 = frames[i].t2;
    var endAtLeftHalf = frames[i].endAtLeftHalf;
    var grew = false;
    var j = i + 1;
    while (j < frames.length) {
      final rel = fractalPairRel(boxHigh, boxLow, frames[j].high, frames[j].low);
      if (rel != FractalPairRel.contained) break;
      // 与当前生长框含融 → 并进来；高/低按口径更新，框继续生长。
      final box = mergePreFractalBox(
        boxHigh,
        boxLow,
        frames[j].high,
        frames[j].low,
        mergeMode,
      );
      boxHigh = box.high;
      boxLow = box.low;
      boxCount += frames[j].count;
      x2 = frames[j].x2;
      t2 = frames[j].t2;
      endAtLeftHalf = frames[j].endAtLeftHalf;
      grew = true;
      j += 1;
    }

    if (grew) {
      // 首框（及后续并出的框）吃进了 j-i 根 K；fx 保留最后并入那根的标记
      // （若并进了标准首分型框，则 fx 就是那个分型）。
      out.add(
        KlineCombineFrame(
          x1: x1,
          x2: x2,
          t1: t1,
          t2: t2,
          high: boxHigh,
          low: boxLow,
          fx: frames[j - 1].fx,
          count: boxCount,
          endAtLeftHalf: endAtLeftHalf,
          startAtRightHalf: startAtRightHalf,
        ),
      );
      i = j;
      continue;
    }

    // 没有含融：与下一根判双高/双低 → 前一根判分型（不合并，顶底交替）。
    //
    // 只在**该层已有真首分型**时才判：无真分型的层原样输出，保持 UNKNOWN
    // （虚线构建中），绝不凭空认定。
    final hasPartner = hasStandardFx && i + 1 <= limit && i + 1 < frames.length;
    if (hasPartner) {
      final a = frames[i];
      final b = frames[i + 1];
      final rel = fractalPairRel(a.high, a.low, b.high, b.low);
      final fx = fractalPairFx(rel);
      if (fx != null && fractalFxOpposite(lastFx, fx)) {
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
  return <KlineCombineFrame>[...out, ...frames.sublist(i)];
}
