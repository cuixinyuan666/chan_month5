import 'package:chan_kline/chart/level_window_layout.dart';
import 'package:flutter_test/flutter_test.dart';

/// 层级分窗：布局与槽位校验（纯逻辑，无 Flutter 依赖）。
///
/// 口径（2026-11-02 用户确认）：
/// - 数量只能偶数：2 / 4 / 6 / 8 / 10，最多 10 窗；
/// - 2 窗左右；4/6/8/10 上 N 下 N；
/// - 每窗层级由用户逐个指定，不重复，且必须含 K0。
void main() {
  group('窗口数量收敛', () {
    test('合法偶数档原样保留', () {
      for (final c in kLevelWindowCountChoices) {
        expect(normalizeLevelWindowCount(c), c);
      }
    });

    test('非法/越界数量收敛到最近的合法档', () {
      expect(normalizeLevelWindowCount(null), kLevelWindowDefaultCount);
      expect(normalizeLevelWindowCount(0), 2);
      expect(normalizeLevelWindowCount(1), 2);
      expect(normalizeLevelWindowCount(3), 2);
      expect(normalizeLevelWindowCount(5), 4);
      expect(normalizeLevelWindowCount(7), 6);
      expect(normalizeLevelWindowCount(9), 8);
      expect(normalizeLevelWindowCount(10), 10);
      expect(normalizeLevelWindowCount(11), 10);
      expect(normalizeLevelWindowCount(99), 10);
      expect(normalizeLevelWindowCount(-5), 2);
    });

    test('数量上限 10（K0..K9）', () {
      expect(kLevelWindowMaxLevel, 9);
      expect(kLevelWindowSlotCount, 10);
      expect(kLevelWindowCountChoices.last, 10);
    });
  });

  group('网格行列', () {
    test('2 窗左右两列，其余上 N 下 N', () {
      final two = LevelWindowGrid(2);
      expect(two.rows, 1);
      expect(two.cols, 2);

      for (final entry in <int, int>{4: 2, 6: 3, 8: 4, 10: 5}.entries) {
        final g = LevelWindowGrid(entry.key);
        expect(g.rows, 2, reason: '${entry.key} 窗应为两行');
        expect(g.cols, entry.value, reason: '${entry.key} 窗每行应为 ${entry.value} 个');
      }
    });

    test('行列构造会自动收敛数量', () {
      expect(LevelWindowGrid(3).count, 2);
      expect(LevelWindowGrid(3).rows, 1);
      expect(LevelWindowGrid(3).cols, 2);
    });
  });

  group('槽位校验', () {
    test('默认槽位（K0..K9）在任意合法数量下均通过', () {
      for (final c in kLevelWindowCountChoices) {
        final check =
            checkLevelWindowSlots(count: c, slots: defaultLevelWindowSlots());
        expect(check.ok, isTrue, reason: '$c 窗默认槽位应合法');
        expect(check.issue, LevelWindowSlotIssue.none);
      }
    });

    test('缺少 K0 拒绝', () {
      final check = checkLevelWindowSlots(
        count: 2,
        slots: [1, 2],
      );
      expect(check.ok, isFalse);
      expect(check.issue, LevelWindowSlotIssue.missingK0);
      expect(check.message, contains('K0'));
    });

    test('同一层级占用两个窗口拒绝', () {
      final check = checkLevelWindowSlots(
        count: 2,
        slots: [0, 0],
      );
      expect(check.ok, isFalse);
      expect(check.issue, LevelWindowSlotIssue.duplicateLevel);
      expect(check.slot, 1);
      expect(check.level, 0);
    });

    test('只校验前 count 个槽位：多余的记忆槽位不参与判定', () {
      // 第 3 窗起重复/空都不影响 2 窗判定。
      final check = checkLevelWindowSlots(
        count: 2,
        slots: [0, 5, 5, 9, 9, 9, 9, 9, 9, 9],
      );
      expect(check.ok, isTrue);
    });

    test('空槽与越界层级拒绝', () {
      final empty = checkLevelWindowSlots(count: 2, slots: [0, null]);
      expect(empty.issue, LevelWindowSlotIssue.levelOutOfRange);
      expect(empty.slot, 1);

      final tooHigh = checkLevelWindowSlots(count: 2, slots: [0, 10]);
      expect(tooHigh.issue, LevelWindowSlotIssue.levelOutOfRange);

      final negative = checkLevelWindowSlots(count: 2, slots: [-1, 0]);
      expect(negative.issue, LevelWindowSlotIssue.levelOutOfRange);
      expect(negative.slot, 0);
    });

    test('非法数量拒绝', () {
      final check = checkLevelWindowSlots(count: 3, slots: [0, 1, 2]);
      expect(check.ok, isFalse);
      expect(check.issue, LevelWindowSlotIssue.countNotEven);
    });

    test('槽位不足按空处理（不越界读取）', () {
      final check = checkLevelWindowSlots(count: 4, slots: [0, 1]);
      expect(check.issue, LevelWindowSlotIssue.levelOutOfRange);
      expect(check.slot, 2);
    });
  });

  group('补齐空槽', () {
    test('补齐后长度恒为 10，且先出现的非空槽位保持不变', () {
      final out = fillLevelWindowSlots(count: 10, slots: [3, 1]);
      expect(out.length, kLevelWindowSlotCount);
      expect(out[0], 3);
      expect(out[1], 1);
      expect(out.toSet().length, kLevelWindowSlotCount, reason: '补齐后不允许重复');
      expect(out.contains(0), isTrue, reason: '补齐后必须含 K0');
    });

    test('重复槽位被清掉后换成未占用层级', () {
      final out = fillLevelWindowSlots(count: 4, slots: [0, 0, 1, 1]);
      expect(out.take(4).toSet().length, 4);
      expect(out[0], 0);
      expect(out[2], 1);
      expect(out[1], isNot(0));
      expect(out[3], isNot(1));
    });

    test('空列表也能补齐出含 K0 的完整槽位', () {
      final out = fillLevelWindowSlots(count: 2, slots: const []);
      expect(out.take(2).toList(), [0, 1]);
      final check = checkLevelWindowSlots(count: 2, slots: out);
      expect(check.ok, isTrue);
    });
  });

  group('缩窗保护', () {
    test('K0 已在可见范围内：不移动', () {
      final (out, moved) = keepK0VisibleInLevelWindowSlots(
        count: 2,
        slots: [0, 3, 4, 5, 6, 7, 8, 9, 1, 2],
      );
      expect(moved, isFalse);
      expect(out.take(2).toList(), [0, 3]);
    });

    test('K0 被挤出可见范围：换到第 1 窗并保留被顶掉的层级', () {
      final slots = [2, 3, 4, 5, 0, 7, 8, 9, 1, 6];
      final (out, moved) = keepK0VisibleInLevelWindowSlots(
        count: 2,
        slots: slots,
      );
      expect(moved, isTrue);
      expect(out[0], 0);
      expect(out[4], 2, reason: '原第 1 窗的层级不能丢');
      expect(out.take(2).toSet().length, 2, reason: '缩窗后前两窗仍不能重复');
      final check = checkLevelWindowSlots(count: 2, slots: out);
      expect(check.ok, isTrue);
    });

    test('槽位里根本没有 K0：原样返回，交给校验层拦截', () {
      final slots = [1, 2, 3, 4, 5, 6, 7, 8, 9, 1];
      final (out, moved) = keepK0VisibleInLevelWindowSlots(
        count: 2,
        slots: slots,
      );
      expect(moved, isFalse);
      expect(out, slots);
    });
  });

  group('右上角层级标签让位', () {
    test('贴着窗口右缘的格子：标签落到设置钮左侧', () {
      // 默认按桌面四周留白计算，不传格子宽度。
      final right = levelBadgeRightInset(topRightPane: true);
      expect(
        right,
        kCaptionWindowControlsWidth +
            kLevelBadgeGapBeforeSettings -
            kLevelBadgeShellInset,
      );
      expect(right, greaterThan(6), reason: '必须离开格子右缘，否则压住关闭钮');
    });

    test('格子右缘已经在窗控左侧：保持贴右缘', () {
      final right = levelBadgeRightInset(
        topRightPane: true,
        paneRightInset: kCaptionWindowControlsWidth + kLevelBadgeGapBeforeSettings + 40,
      );
      expect(right, 6);
    });

    test('不是右上角那一格：不受窗控影响', () {
      final right = levelBadgeRightInset(
        topRightPane: false,
        paneRightInset: 0,
        captionControlsWidth: kCaptionWindowControlsWidth,
      );
      expect(right, 6);
    });

    test('窗口变窄时让位跟着变，不会算成负数', () {
      final right = levelBadgeRightInset(
        topRightPane: true,
        paneRightInset: 20,
        captionControlsWidth: 100,
      );
      expect(right, 100 + kLevelBadgeGapBeforeSettings - 20);
    });
  });
}
