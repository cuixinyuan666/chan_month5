import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';

/// 用户确认后的分窗配置。
class LevelWindowConfig {
  final int count;
  final List<int> slots;

  const LevelWindowConfig({required this.count, required this.slots});
}

/// 层级分窗设置弹窗：窗口数量 + 每窗层级 + 操作说明。
///
/// 规则（2026-11-02 用户确认）：
/// - 数量只能偶数 2/4/6/8/10；
/// - 每窗层级由用户逐个指定，不允许重复；
/// - **必须含 K0**，否则弹模态警告并拒绝应用（K0 窗是全局键盘的唯一归属窗）。
class LevelWindowSettingsDialog extends StatefulWidget {
  const LevelWindowSettingsDialog({
    super.key,
    required this.initialCount,
    required this.initialSlots,
  });

  final int initialCount;
  final List<int> initialSlots;

  @override
  State<LevelWindowSettingsDialog> createState() =>
      _LevelWindowSettingsDialogState();
}

class _LevelWindowSettingsDialogState extends State<LevelWindowSettingsDialog> {
  late int _count;
  late List<int> _slots;

  /// 缩窗自动把 K0 挪回可见范围时的提示（不静默丢 K0）。
  String? _hint;

  @override
  void initState() {
    super.initState();
    _count = normalizeLevelWindowCount(widget.initialCount);
    _slots = fillLevelWindowSlots(
      count: kLevelWindowSlotCount,
      slots: widget.initialSlots,
    );
  }

  void _setCount(int next) {
    var slots = fillLevelWindowSlots(
      count: kLevelWindowSlotCount,
      slots: _slots,
    );
    final (kept, moved) =
        keepK0VisibleInLevelWindowSlots(count: next, slots: slots);
    slots = kept;
    setState(() {
      _count = next;
      _slots = slots;
      _hint = moved ? '窗口减少会把 K0 挤出可见范围，已自动把 K0 换到第 1 窗。' : null;
    });
  }

  void _resetToSequential() {
    setState(() {
      _count = normalizeLevelWindowCount(_count);
      _slots = defaultLevelWindowSlots();
      _hint = '已按顺序排好：第 1 窗 K0、第 2 窗 K1……可继续手动改。';
    });
  }

  Future<void> _apply() async {
    final check = checkLevelWindowSlots(count: _count, slots: _slots);
    if (!check.ok) {
      await showDialog<void>(
        context: context,
        builder: (ctx) => AlertDialog(
          title: const Text('无法应用'),
          content: Text(check.message),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: const Text('知道了'),
            ),
          ],
        ),
      );
      return;
    }
    if (!mounted) return;
    Navigator.of(context).pop(
      LevelWindowConfig(count: _count, slots: List<int>.from(_slots)),
    );
  }

  @override
  Widget build(BuildContext context) {
    final usedByOther = <int, int>{};
    for (var i = 0; i < _count; i++) {
      usedByOther[_slots[i]] = i;
    }
    return AlertDialog(
      title: const Text('层级分窗设置'),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                '布局规则：2 窗为左右排布；4/6/8/10 窗为上 N 下 N'
                '（4 窗上 2 下 2、6 窗上 3 下 3，以此类推）。\n'
                '窗口按「左→右、上→下」依次取用下面的设置。\n'
                '每窗默认只显示本层 Kn 与本层连线，合并/中枢、'
                '副图指标一律不默认启用；要看就点该窗对应的指标面板自行勾选。\n'
                '每一窗都能操作：步进（颗粒度＝K0 一根 K）、播放、缩放、平移、十字线；'
                '各窗缩放/位置互不影响。\n'
                '开启十字线时，其余窗会切到开启窗同一段视口：'
                '同一根 K 的竖线、同一价格的横线落在同一像素；关闭后各窗恢复原位。',
                style: TextStyle(fontSize: 12, height: 1.6),
              ),
              const SizedBox(height: 12),
              Row(
                children: [
                  const SizedBox(
                    width: 76,
                    child: Text('窗口数量', style: TextStyle(fontSize: 13)),
                  ),
                  Expanded(
                    child: DropdownButtonFormField<int>(
                      initialValue: _count,
                      isDense: true,
                      items: [
                        for (final c in kLevelWindowCountChoices)
                          DropdownMenuItem(
                            value: c,
                            child: Text('$c 窗'),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) _setCount(v);
                      },
                    ),
                  ),
                  const SizedBox(width: 8),
                  TextButton(
                    onPressed: _resetToSequential,
                    child: const Text('按顺序重置'),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              for (var i = 0; i < _count; i++) ...[
                Row(
                  children: [
                    SizedBox(
                      width: 76,
                      child: Text(
                        '第 ${i + 1} 窗',
                        style: const TextStyle(fontSize: 13),
                      ),
                    ),
                    Expanded(
                      child: DropdownButtonFormField<int>(
                        // 槽位是固定位置，用 ValueKey 防止换数量后串值。
                        key: ValueKey<int>(i),
                        initialValue: _slots[i],
                        isDense: true,
                        items: [
                          for (var lv = 0; lv <= kLevelWindowMaxLevel; lv++)
                            DropdownMenuItem(
                              value: lv,
                              enabled: usedByOther[lv] == null ||
                                  usedByOther[lv] == i,
                              child: Text(
                                lv == 0 ? 'K0（键盘归属）' : 'K$lv',
                              ),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          setState(() {
                            _slots[i] = v;
                            _hint = null;
                          });
                        },
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 6),
              ],
              if (_hint != null) ...[
                const SizedBox(height: 4),
                Text(
                  _hint!,
                  style: const TextStyle(
                    fontSize: 11,
                    height: 1.5,
                    color: Color(0xFFFFB74D),
                  ),
                ),
              ],
              const SizedBox(height: 4),
              const Text(
                '同一层级只能占用一个窗口；必须包含 K0。',
                style: TextStyle(fontSize: 11, color: Color(0xFF9E9E9E)),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('取消'),
        ),
        FilledButton(
          onPressed: _apply,
          child: const Text('应用'),
        ),
      ],
    );
  }
}
