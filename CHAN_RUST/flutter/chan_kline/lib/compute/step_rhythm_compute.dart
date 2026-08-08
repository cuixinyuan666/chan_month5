import '../models/bar_crosshair_feature.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'adjacent_ratio_compute.dart';

/// 步进节奏副图：normal 算法；全层同构；颗粒度 K0；不回写、无未来函数。
///
/// 口径（以 K0连线 + K1分型为例，Kn 同构）：
/// - 组锚点 = 上一父分型极值（K1底→极低 / K1顶→极高）；组内命名从 **0-0** 起
/// - 子分型打开推升/推降窗口后按 K0 步持续算；子反向分型确认当步起停写（单点不连后）
/// - 父分型确认：本组停止，下一组命名重置，自确认步按反向趋势重开
///
/// 方案B映射：子线 level==displayKn；子分型 confirms@displayKn；父分型 confirms@displayKn+1。
///
/// 踩坑（2026-07-31）：
/// - 勿用「父段 end_confirm」替代「父分型 confirms」切组；a0 取 fractalHigh/Low 而非 seq[0]
/// - 命名取消 1-0：roundCurrent=(evenIdx~/2)-1，roundRef 从 0 → 首条 0-0
/// - 关窗后禁止续写（例：25 出 0-1/1-0，26 顶确认后 26–38 应无点）；key 含 groupId
/// - 同棒顺序：bootstrap → 子窗 → 父切组（父优先）；副图仅 Δx==1 点线续连

/// 单条节奏线（同 key 多步连成折线；组切后 key 含 groupId）。
class StepRhythmLinePoint {
  final int x;
  final int displayKn;
  final String key;
  final double value;
  final double ratio;
  final String dir; // up / down
  final int roundCurrent;
  final int roundRef;
  final int layer;
  final String label;
  final int currentBiIdx;
  final int refBiIdx;
  final int retraceBiIdx;
  final int groupId;

  const StepRhythmLinePoint({
    required this.x,
    required this.displayKn,
    required this.key,
    required this.value,
    required this.ratio,
    required this.dir,
    required this.roundCurrent,
    required this.roundRef,
    required this.layer,
    required this.label,
    required this.currentBiIdx,
    required this.refBiIdx,
    required this.retraceBiIdx,
    this.groupId = 0,
  });
}

/// 本步节奏指标摘要。
class StepRhythmStepResult {
  final int x;
  final int displayKn;
  final List<StepRhythmLinePoint> lines;
  final String dir;
  final double? firstValue;

  const StepRhythmStepResult({
    required this.x,
    required this.displayKn,
    required this.lines,
    required this.dir,
    this.firstValue,
  });
}

/// 每层会话状态（换股/重载清空）。
class StepRhythmState {
  /// 当前组方向：1=升 / -1=降
  int? activeDir;
  /// 组序号（父分型切组自增；写入 key，防跨组连线）
  int groupId = 0;
  /// 组锚点价（父分型极值）
  double? a0;
  /// 父分型极点 K0
  int? anchorPoleX;
  /// 本组起始步（父分型确认 x）
  int? groupStartX;
  String? lastParentFxKey;
  String? lastChildFxKey;
  /// 子线推升/推降窗口：开着才逐K续写；反向子分型确认后关闭→单点不连后
  bool windowOpen = false;

  void reset() {
    activeDir = null;
    groupId = 0;
    a0 = null;
    anchorPoleX = null;
    groupStartX = null;
    lastParentFxKey = null;
    lastChildFxKey = null;
    windowOpen = false;
  }
}

LevelBundle? _bundleAtLevel(List<LevelBundle> levels, int level) {
  for (final lv in levels) {
    if (lv.level == level) return lv;
  }
  return null;
}

int rhythmLayerIndex(int roundCurrent, int roundRef) =>
    roundCurrent - roundRef;

String rhythmDirText(int dir) => dir > 0 ? 'up' : 'down';

int reverseDir(int dir) => dir > 0 ? -1 : 1;

bool _isTopFx(LevelConfirm c) =>
    c.fx == 'TOP' || c.value < 0;

bool _isBottomFx(LevelConfirm c) =>
    c.fx == 'BOTTOM' || c.value > 0;

/// 本步该层分型确认（仅 TOP/BOTTOM）。
List<LevelConfirm> fractalConfirmsOnDisplayX({
  required List<LevelBundle> levels,
  required int level,
  required int displayX,
}) {
  final lv = _bundleAtLevel(levels, level);
  if (lv == null) return const [];
  return [
    for (final c in lv.confirms)
      if (c.x == displayX && (_isTopFx(c) || _isBottomFx(c))) c,
  ];
}

/// 交替序列（冻段/动态虚线均可；虚实一视同仁）。
List<RatioChild> buildAlternatingChildSequence(
  List<RatioChild> children,
  int parentDir,
) {
  if (children.isEmpty) return const [];
  final seq = <RatioChild>[];
  var expected = parentDir;
  var started = false;
  for (final child in children) {
    if (child.dir != 1 && child.dir != -1) continue;
    if (!started) {
      if (child.dir != parentDir) continue;
      started = true;
    }
    if (child.dir != expected) continue;
    seq.add(child);
    expected = reverseDir(expected);
  }
  return seq;
}

/// 子分型：升组底开窗/顶关窗；降组镜像。关窗当步起不再续写。
void applyChildFractalWindow({
  required StepRhythmState state,
  required List<LevelConfirm> childSignals,
}) {
  if (state.activeDir != 1 && state.activeDir != -1) return;
  if (childSignals.isEmpty) return;
  final last = childSignals.last;
  final key = '${last.x}|${last.fx}|${last.poleX}';
  if (key == state.lastChildFxKey) return;
  state.lastChildFxKey = key;
  final top = _isTopFx(last);
  final bottom = _isBottomFx(last);
  if (state.activeDir == 1) {
    if (bottom) state.windowOpen = true;
    if (top) state.windowOpen = false;
  } else {
    if (top) state.windowOpen = true;
    if (bottom) state.windowOpen = false;
  }
}

/// 父分型切组：顶→降组锚极高；底→升组锚极低；命名组号+1；自本步开窗绘制。
void applyParentFractalGroup({
  required StepRhythmState state,
  required int displayX,
  required List<LevelConfirm> parentSignals,
}) {
  if (parentSignals.isEmpty) return;
  final last = parentSignals.last;
  final key = '${last.x}|${last.fx}|${last.poleX}';
  if (key == state.lastParentFxKey) return;
  state.lastParentFxKey = key;
  state.groupId += 1;
  state.groupStartX = displayX;
  state.anchorPoleX = last.poleX >= 0 ? last.poleX : displayX;
  // 清子窗键，避免同棒子分型抢先关窗
  state.lastChildFxKey = null;
  if (_isTopFx(last)) {
    state.activeDir = -1;
    state.a0 = last.fractalHigh;
    state.windowOpen = true;
  } else if (_isBottomFx(last)) {
    state.activeDir = 1;
    state.a0 = last.fractalLow;
    state.windowOpen = true;
  }
}

/// 无父分型时：用首条子线方向+起点价引导首组（仍从 0-0 起算）。
void bootstrapGroupIfNeeded({
  required StepRhythmState state,
  required List<RatioChild> children,
  required int displayX,
}) {
  if (state.activeDir == 1 || state.activeDir == -1) return;
  for (final line in children) {
    if (line.dir != 1 && line.dir != -1) continue;
    state.activeDir = line.dir;
    state.a0 = line.beginVal;
    state.anchorPoleX = line.beginX;
    state.groupStartX = displayX;
    state.groupId = 0;
    state.windowOpen = true;
    return;
  }
}

/// 本步计算节奏线（仅 normal）。
StepRhythmStepResult? calcStepRhythmForStep({
  required List<LevelBundle> levels,
  required int displayKn,
  required int displayX,
  required StepRhythmState state,
  List<KlineBar> bars = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  bool truncationCheck = true,
}) {
  final children = buildRatioChildren(
    levels: levels,
    displayKn: displayKn,
    bars: bars,
    barFeatures: barFeatures,
    truncationCheck: truncationCheck,
    displayX: displayX,
  );

  // 方案B：子线分型=displayKn；父分型=displayKn+1
  final childFx = fractalConfirmsOnDisplayX(
    levels: levels,
    level: displayKn,
    displayX: displayX,
  );
  final parentFx = fractalConfirmsOnDisplayX(
    levels: levels,
    level: displayKn + 1,
    displayX: displayX,
  );

  // 无组时先引导；再子窗；同棒父分型最后切组（父优先）
  bootstrapGroupIfNeeded(
    state: state,
    children: children,
    displayX: displayX,
  );
  applyChildFractalWindow(state: state, childSignals: childFx);
  applyParentFractalGroup(
    state: state,
    displayX: displayX,
    parentSignals: parentFx,
  );

  final dir = state.activeDir;
  // 窗口关闭：本步不产出（历史已写入的单点保留，不向后连）
  if (dir != 1 && dir != -1) {
    return null;
  }
  if (!state.windowOpen) {
    return null;
  }
  final activeDir = dir!;

  final anchorPole = state.anchorPoleX;
  final seqSrc = <RatioChild>[];
  for (final line in children) {
    if (line.dir != 1 && line.dir != -1) continue;
    if (line.endConfirmX > displayX) continue;
    // 组内：自父极点起的出现链（含极点开口线）
    if (anchorPole != null && line.beginX < anchorPole) continue;
    seqSrc.add(line);
  }

  final seq = buildAlternatingChildSequence(seqSrc, activeDir);
  if (seq.length < 3) return null;

  final evenIndices = <int>[
    for (var i = 2; i < seq.length; i += 2) i,
  ];
  if (evenIndices.isEmpty) return null;

  final currentEvenIdx = evenIndices.last;
  // 0-based：首组首条为 0-0（取消 1-0）
  final roundCurrent = (currentEvenIdx ~/ 2) - 1;
  if (roundCurrent < 0) return null;

  final dLine = seq[currentEvenIdx];
  final a0 = state.a0 ?? seq[0].beginVal;
  final dVal = dLine.endVal;
  final currentBiIdx = dLine.idx;
  final gid = state.groupId;

  final lines = <StepRhythmLinePoint>[];
  for (var roundRef = 0; roundRef <= roundCurrent; roundRef++) {
    final bIdx = 2 * roundRef;
    final cIdx = bIdx + 1;
    if (cIdx >= seq.length) continue;
    final bLine = seq[bIdx];
    final cLine = seq[cIdx];
    final bVal = bLine.endVal;
    final cVal = cLine.endVal;
    double? ratio;
    double? rhythmPrice;
    if (activeDir == 1) {
      final denom = bVal - a0;
      ratio = denom.abs() > 1e-12 ? (bVal - cVal) / denom : null;
      rhythmPrice =
          ratio != null ? dVal - (dVal - a0) * ratio : null;
    } else {
      final denom = a0 - bVal;
      ratio = denom.abs() > 1e-12 ? (cVal - bVal) / denom : null;
      rhythmPrice =
          ratio != null ? dVal + (a0 - dVal) * ratio : null;
    }
    if (ratio == null || rhythmPrice == null) continue;
    if (ratio < 0 || !rhythmPrice.isFinite) continue;
    final layerIdx = rhythmLayerIndex(roundCurrent, roundRef);
    lines.add(StepRhythmLinePoint(
      x: displayX,
      displayKn: displayKn,
      key:
          'step_rhythm|g$gid|${rhythmDirText(activeDir)}|$currentBiIdx|${bLine.idx}|${cLine.idx}',
      value: rhythmPrice,
      ratio: ratio,
      dir: rhythmDirText(activeDir),
      roundCurrent: roundCurrent,
      roundRef: roundRef,
      layer: layerIdx,
      label: '$roundRef-$layerIdx',
      currentBiIdx: currentBiIdx,
      refBiIdx: bLine.idx,
      retraceBiIdx: cLine.idx,
      groupId: gid,
    ));
  }

  if (lines.isEmpty) return null;
  return StepRhythmStepResult(
    x: displayX,
    displayKn: displayKn,
    lines: lines,
    dir: rhythmDirText(activeDir),
    firstValue: lines.first.value,
  );
}

void mergeStepRhythmResult(
  List<StepRhythmLinePoint> log,
  StepRhythmStepResult? result,
) {
  if (result == null) return;
  for (final p in result.lines) {
    final i = log.indexWhere((e) => e.x == p.x && e.key == p.key);
    if (i >= 0) {
      log[i] = p;
    } else {
      log.add(p);
    }
  }
}

void mergeStepRhythmForStep({
  required Map<int, List<StepRhythmLinePoint>> historyByKn,
  required Map<int, StepRhythmState> stateByKn,
  required List<LevelBundle> levels,
  required int displayX,
  required int maxDisplayKn,
  List<KlineBar> bars = const [],
  List<BarCrosshairFeature> barFeatures = const [],
  bool truncationCheck = true,
}) {
  for (var kn = 0; kn <= maxDisplayKn; kn++) {
    final state = stateByKn.putIfAbsent(kn, StepRhythmState.new);
    final log =
        historyByKn.putIfAbsent(kn, () => <StepRhythmLinePoint>[]);
    mergeStepRhythmResult(
      log,
      calcStepRhythmForStep(
        levels: levels,
        displayKn: kn,
        displayX: displayX,
        state: state,
        bars: bars,
        barFeatures: barFeatures,
        truncationCheck: truncationCheck,
      ),
    );
  }
}

/// 十字读数：行数 + 方向 + 首条最新值。
String formatStepRhythmReadout(
  List<StepRhythmLinePoint> history,
  int x,
) {
  final at = history.where((e) => e.x == x).toList();
  if (at.isEmpty) return '0';
  final dir = at.first.dir == 'up' ? '上' : '下';
  final v = at.first.value.toStringAsFixed(3);
  return '${at.length} $dir $v';
}
