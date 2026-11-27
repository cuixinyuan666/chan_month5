/// 首分型前合并框（子窗口路径）与相邻框的几何关系。
///
/// 子窗口现行并框在 [applyFirstPairFractalToFrames]：找到该层第一个引擎已给分型的帧，
/// 把该帧及之前并成一框，分型取该帧；还没有分型就把整段并成一框，分型保持未知。
/// K0 / K1 / … / Kn 同一条。不再按双高、双低把生长框提前拆开。
///
/// [fractalPairRel] 只区分相邻两框是双低、双高还是其余（包含或交叉）。
/// 现行并框不调用它，测试仍覆盖这组分类。
library;

import '../models/kline_combine_frame.dart';
import '../models/pre_first_fractal_mode.dart';

/// 相邻两框的几何关系。只分类，不在这里判分型、也不并框。
enum FractalPairRel {
  /// 第二框的最高价、最低价都低于第一框。
  bothLower,

  /// 第二框的最高价、最低价都高于第一框。
  bothHigher,

  /// 其余情况：内包含、外包含，以及高低一高一低的交叉。
  contained,
}

/// 分型文字的码位是否恰好是 UNKNOWN。
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
  // 找到真分型（stdIdx < length）→ 已进入「首分型后」；没找到 → 仍首分型前。
  final bool beforeFirstStandardFx = stdIdx >= frames.length;
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
      beforeFirstStandardFx: beforeFirstStandardFx,
      // 真分型落在第 2 个框、且第 1 个框只有 1 根 K：首合并框仅单个。
      firstBoxWasSingle:
          end == 2 && stdIdx == 1 && frames.first.count <= 1,
    ),
    ...frames.sublist(end),
  ];
}
