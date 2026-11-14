/// 首分型前合并框口径（设置项「首分型前合并框」）的唯一实现。
///
/// 绘制（主图 / 各子窗口）与 tooltip 的 MG/MD 都从这里取结果，
/// 保证「画出来的框」和「十字线上写的数」永远同一份。
///
/// 口径见 [PreFirstFractalMode]：
/// - 种子框：不合并，原样返回（种子框仍是第一根框，后续框各自独立）；
/// - 高高 / 低低：把「首个分型所在框之前」的全部框并成一个框。
///
/// 子窗口模式（层级分窗，全层同构）在并框前还走「逐对判定」
/// （见 `first_fractal_rule.dart`）：双低/双高直接判分型且不合并，
/// 仅包含关系才并框。**种子框口径下不跑逐对判定**（保持原框）。
library;

import '../models/kline_combine_frame.dart';
import '../models/level_models.dart';
import '../models/pre_first_fractal_mode.dart';
import 'first_fractal_rule.dart';

/// 首个非 UNKNOWN 框的下标；全 UNKNOWN 时返回长度（表示尚无标准首分型）。
int _standardFirstFxIndex(List<KlineCombineFrame> frames) {
  for (var i = 0; i < frames.length; i++) {
    if (!fxIsUnknownCodeUnit(frames[i].fx)) return i;
  }
  return frames.length;
}

/// 首分型前的框序列按 [mode] 重排（纯函数，不改入参）。
///
/// [earlyDynamicUnit] 为 false（经典口径）时原样返回；
/// [frames] 第一条不从 x1=0 起（说明已不是序列开头）时也原样返回。
List<KlineCombineFrame> applyPreFirstFractalMode(
  List<KlineCombineFrame> frames, {
  required PreFirstFractalMode mode,
  required bool subWindow,
  bool earlyDynamicUnit = true,
}) {
  if (!earlyDynamicUnit || frames.isEmpty) return frames;
  if (frames.first.x1 > 0) return frames;
  // 种子框：不合并，原样画（后续框不再并进第一根）。
  if (mode == PreFirstFractalMode.seedBox) return frames;

  final end = _standardFirstFxIndex(frames);

  // 子窗口模式：逐对判定（全层同构）。双低/双高 → 前一根直接判分型且不合并；
  // 仅包含关系才并框，高/低取值按 [mode]。顶底交替。
  if (subWindow) {
    return applyFirstPairFractalToFrames(
      frames,
      standardFirstFx: end < frames.length ? frames[end].fx : null,
      mergeMode: mode,
    );
  }

  // 单图模式：顶分型落在第二组时，第一根不能单独拆出去：
  // 并进后面那个框，左端仍从第一根 K 起。
  if (end == 1 &&
      frames.length > 1 &&
      frames.first.x1 <= 0 &&
      frames.first.count <= 1) {
    final a = frames.first;
    final b = frames[1];
    final box = mergePreFractalBox(a.high, a.low, b.high, b.low, mode);
    return <KlineCombineFrame>[
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
      ),
      ...frames.sublist(2),
    ];
  }
  if (end <= 1) return frames;

  // 首分型前的全部框并成一个：x 从 0 收到最后一组右端。
  final head = frames.sublist(0, end);
  final last = head.last;
  var box = (high: head.first.high, low: head.first.low);
  var count = 0;
  for (final f in head) {
    final merged = mergePreFractalBox(box.high, box.low, f.high, f.low, mode);
    box = merged;
    count += f.count;
  }
  return <KlineCombineFrame>[
    KlineCombineFrame(
      x1: head.first.x1,
      x2: last.x2,
      t1: head.first.t1,
      t2: last.t2,
      high: box.high,
      low: box.low,
      fx: 'UNKNOWN',
      count: count,
      endAtLeftHalf: last.endAtLeftHalf,
    ),
    ...frames.sublist(end),
  ];
}

/// 每层合并框按同一口径重排（tooltip 的 MG/MD 走这份）。
///
/// 只替换 [LevelBundle.combineFrames]，其它字段原样带过去。
List<LevelBundle> applyPreFirstFractalToLevels(
  List<LevelBundle> levels, {
  required PreFirstFractalMode mode,
  required bool subWindow,
  bool earlyDynamicUnit = true,
}) {
  if (levels.isEmpty) return levels;
  var changed = false;
  final out = <LevelBundle>[];
  for (final lv in levels) {
    final next = applyPreFirstFractalMode(
      lv.combineFrames,
      mode: mode,
      subWindow: subWindow,
      earlyDynamicUnit: earlyDynamicUnit,
    );
    if (identical(next, lv.combineFrames)) {
      out.add(lv);
    } else {
      changed = true;
      out.add(lv.withCombineFrames(next));
    }
  }
  return changed ? out : levels;
}
