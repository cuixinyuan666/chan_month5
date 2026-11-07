/// 层级分窗：布局与校验的纯逻辑（无 Flutter 依赖，便于单测）。
///
/// 口径（2026-11-02 用户确认）：
/// - 窗口数量只能是偶数：2 / 4 / 6 / 8 / 10；
/// - 2 窗 = 左右两列（1 行）；4/6/8/10 窗 = 两行，上 N/2、下 N/2；
/// - 每个窗口显示哪个层级由用户逐个指定，不再自动按 K0→K(N-1) 铺；
/// - 所选层级里必须含 K0，且同一层级不得占用两个窗口；
/// - 最多 10 个窗口，对应 K0..K9。
library;

/// 可选窗口数量（只能偶数，最多 10）。
const List<int> kLevelWindowCountChoices = <int>[2, 4, 6, 8, 10];

/// 层级上限：K0..K9。
const int kLevelWindowMaxLevel = 9;

/// 槽位总数（= 层级总数）。超出当前窗口数的槽位只做记忆，不参与布局。
const int kLevelWindowSlotCount = kLevelWindowMaxLevel + 1;

/// 默认窗口数量（总开关打开后的初始值）。
const int kLevelWindowDefaultCount = 2;

/// 默认槽位：第 i 窗 = K{i}（i 从 0 起）。
List<int> defaultLevelWindowSlots() =>
    List<int>.generate(kLevelWindowSlotCount, (i) => i);

/// 把任意数量收敛到合法的偶数档（越界夹到最近一档）。
int normalizeLevelWindowCount(int? raw) {
  if (raw == null) return kLevelWindowDefaultCount;
  if (kLevelWindowCountChoices.contains(raw)) return raw;
  var best = kLevelWindowCountChoices.first;
  var bestDistance = (raw - best).abs();
  for (final c in kLevelWindowCountChoices) {
    final d = (raw - c).abs();
    if (d < bestDistance) {
      best = c;
      bestDistance = d;
    }
  }
  return best;
}

/// 网格行列：2 窗单行两列；其余固定两行，列数 = 窗口数 / 2。
class LevelWindowGrid {
  /// 已收敛的窗口数量。
  final int count;

  const LevelWindowGrid._(this.count);

  factory LevelWindowGrid(int count) =>
      LevelWindowGrid._(normalizeLevelWindowCount(count));

  int get rows => count == 2 ? 1 : 2;

  int get cols => count ~/ rows;
}

/// 槽位校验结果。
enum LevelWindowSlotIssue {
  /// 通过。
  none,

  /// 窗口数量不是合法偶数档。
  countNotEven,

  /// 某窗层级为空或越界（只允许 K0..K9）。
  levelOutOfRange,

  /// 同一层级被两个窗口占用。
  duplicateLevel,

  /// 所选层级里没有 K0（K0 为必选）。
  missingK0,
}

/// 槽位校验结论：不通过时带上出问题的槽位与层级，供弹窗精确定位。
class LevelWindowSlotCheck {
  final LevelWindowSlotIssue issue;

  /// 出问题的槽位（0 起）；[LevelWindowSlotIssue.missingK0] 时为 null。
  final int? slot;

  /// 出问题的层级；可能是 null（空槽）。
  final int? level;

  const LevelWindowSlotCheck(this.issue, this.slot, this.level);

  bool get ok => issue == LevelWindowSlotIssue.none;

  /// 弹窗文案（中文、可直接展示）。
  String get message {
    switch (issue) {
      case LevelWindowSlotIssue.none:
        return '';
      case LevelWindowSlotIssue.countNotEven:
        return '窗口数量只能是 2、4、6、8、10 中的一个。';
      case LevelWindowSlotIssue.levelOutOfRange:
        return '第 ${(slot ?? 0) + 1} 个窗口还没有选择层级（只能选 K0 到 K9）。';
      case LevelWindowSlotIssue.duplicateLevel:
        return 'K${level ?? 0} 被两个窗口同时选中了，同一个层级只能占用一个窗口。';
      case LevelWindowSlotIssue.missingK0:
        return '必须选择 K0 层级：只有含 K0 的窗口才能操作，其余窗口靠它联动。';
    }
  }
}

/// 校验当前生效的槽位（只看前 [count] 个）。
LevelWindowSlotCheck checkLevelWindowSlots({
  required int count,
  required List<int?> slots,
}) {
  if (!kLevelWindowCountChoices.contains(count)) {
    return const LevelWindowSlotCheck(
      LevelWindowSlotIssue.countNotEven,
      null,
      null,
    );
  }
  final seen = <int>{};
  for (var i = 0; i < count; i++) {
    final level = i < slots.length ? slots[i] : null;
    if (level == null || level < 0 || level > kLevelWindowMaxLevel) {
      return LevelWindowSlotCheck(
        LevelWindowSlotIssue.levelOutOfRange,
        i,
        level,
      );
    }
    if (!seen.add(level)) {
      return LevelWindowSlotCheck(
        LevelWindowSlotIssue.duplicateLevel,
        i,
        level,
      );
    }
  }
  if (!seen.contains(0)) {
    return const LevelWindowSlotCheck(LevelWindowSlotIssue.missingK0, null, 0);
  }
  return const LevelWindowSlotCheck(LevelWindowSlotIssue.none, null, null);
}

/// 补齐空槽：按 K0..K9 顺序填入尚未占用的层级；补齐后仍无法满足时原样返回。
///
/// 用途：用户调整窗口数量时，新长出来的窗口先给一个不重复的默认层级，
/// 避免出现「数量变了但下拉全是空」。
List<int> fillLevelWindowSlots({
  required int count,
  required List<int?> slots,
}) {
  final out = List<int?>.generate(
    kLevelWindowSlotCount,
    (i) => i < slots.length ? slots[i] : null,
  );
  final used = <int>{};
  for (var i = 0; i < count && i < out.length; i++) {
    final v = out[i];
    if (v != null && v >= 0 && v <= kLevelWindowMaxLevel && used.add(v)) {
      continue;
    }
    out[i] = null;
  }
  for (var i = 0; i < count && i < out.length; i++) {
    if (out[i] != null) continue;
    for (var lv = 0; lv <= kLevelWindowMaxLevel; lv++) {
      if (used.add(lv)) {
        out[i] = lv;
        break;
      }
    }
  }
  return <int>[
    for (var i = 0; i < out.length; i++) out[i] ?? 0,
  ];
}

/// 缩窗保护：若缩减后 K0 会被挤出可见窗口，把 K0 换到第 1 窗。
///
/// 返回 (新槽位, 是否发生了移动)。K0 必选，不能静默丢。
(List<int>, bool) keepK0VisibleInLevelWindowSlots({
  required int count,
  required List<int> slots,
}) {
  if (count <= 0) return (slots, false);
  final visible = slots.take(count).toList();
  if (visible.contains(0)) return (slots, false);
  final k0Slot = slots.indexOf(0);
  if (k0Slot < 0) return (slots, false);
  final out = List<int>.from(slots);
  final first = out[0];
  out[0] = 0;
  out[k0Slot] = first;
  return (out, true);
}

/// 桌面标题条高度。与 `kDesktopCaptionBarHeight` 同值；
/// 此处不引用界面文件，保持本文件无 Flutter 依赖。
const double kLevelBadgeCaptionHeight = 36.0;

/// 桌面图表四周留白。与 `kDesktopShellInset` 同值。
const double kLevelBadgeShellInset = 4.0;

/// 标题栏右侧窗控占位：设置钮 + 最小化 + 最大化 + 关闭。
///
/// 图表铺满后标题栏叠在最上层。分窗只在桌面出现，右上角那一格
/// （两窗的右侧窗、四窗及以上的右上角窗）的右缘贴着窗口右缘，
/// 层级标签若贴格子右缘，会正好压在关闭钮上。
const double kCaptionWindowControlsWidth = kLevelBadgeCaptionHeight * 4;

/// 层级标签与设置钮之间的缝。
/// 2026-11-06 用户反馈 8 像素仍与设置钮重叠，加大到 56（约一个半按钮宽）。
const double kLevelBadgeGapBeforeSettings = 56.0;

/// 右上角那一格的层级标签，距该格右缘的像素。
///
/// 右上角那格的右缘就在窗口右缘内侧 [paneRightInset] 处，
/// 与格子本身多宽无关：标签整段落到设置钮左侧。
/// 其余格子远离标题栏窗控，保持贴格子右缘。
double levelBadgeRightInset({
  required bool topRightPane,
  double paneRightInset = kLevelBadgeShellInset,
  double captionControlsWidth = kCaptionWindowControlsWidth,
  double gapBeforeSettings = kLevelBadgeGapBeforeSettings,
  double edgeInset = 6,
}) {
  if (!topRightPane) return edgeInset;
  final need = captionControlsWidth + gapBeforeSettings - paneRightInset;
  if (need <= edgeInset) return edgeInset;
  return need;
}
