import 'package:flutter/material.dart';

import '../chart/level_window_layout.dart';

/// 层级分窗网格：只负责切格子、分隔线与角标，不碰任何绘制/计算逻辑。
///
/// - 布局严格按 [LevelWindowGrid]：2 窗左右；4/6/8/10 窗上 N/2 下 N/2；
/// - 每格一个层级，顺序为「左→右、上→下」，与 `LevelWindowSettingsStore.activeLevels` 对齐；
/// - 含 K0 的格子标记「可操作」，其余标记「跟随」并屏蔽指针；
/// - 该层尚未生成时显示占位（不新建层级、不预测数据）。
class LevelChartGrid extends StatelessWidget {
  const LevelChartGrid({
    super.key,
    required this.count,
    required this.levels,
    required this.maxKn,
    required this.paneBuilder,
  });

  /// 窗口数量（会收敛为合法偶数档）。
  final int count;

  /// 每格层级，按「左→右、上→下」排列。
  final List<int> levels;

  /// 当前数据最高可显示层（`chartMaxKn` 口径）：`level < maxKn` 才认为该层有数据。
  final int maxKn;

  /// 建单个窗：`(context, 槽位, 层级, 是否可交互)`。
  final Widget Function(
    BuildContext context,
    int slot,
    int level,
    bool interactive,
  ) paneBuilder;

  @override
  Widget build(BuildContext context) {
    final grid = LevelWindowGrid(count);
    final rows = <Widget>[];
    var slot = 0;
    for (var r = 0; r < grid.rows; r++) {
      if (r > 0) rows.add(const _GridDivider(vertical: false));
      final cells = <Widget>[];
      for (var c = 0; c < grid.cols; c++) {
        if (c > 0) cells.add(const _GridDivider(vertical: true));
        final level = slot < levels.length ? levels[slot] : slot;
        final interactive = level == 0;
        final available = level == 0 || level < maxKn;
        cells.add(
          Expanded(
            child: _PaneChrome(
              level: level,
              interactive: interactive,
              child: available
                  ? paneBuilder(context, slot, level, interactive)
                  : _EmptyLevelPlaceholder(level: level),
            ),
          ),
        );
        slot++;
      }
      rows.add(
        Expanded(
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: cells,
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: rows,
    );
  }
}

/// 1px 分隔线（横/竖）。
class _GridDivider extends StatelessWidget {
  const _GridDivider({required this.vertical});

  final bool vertical;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: vertical ? 1 : null,
      height: vertical ? null : 1,
      color: const Color(0x33FFFFFF),
    );
  }
}

/// 单窗角标：含 K0 的格子标「可操作」，其余标「跟随」。
///
/// 角标只占顶部 24px（`KlineViewport.padT = 28` 之上），不压价格标签；
/// 用 [IgnorePointer] 包住，绝不抢鼠标。
class _PaneChrome extends StatelessWidget {
  const _PaneChrome({
    required this.level,
    required this.interactive,
    required this.child,
  });

  final int level;
  final bool interactive;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Stack(
      fit: StackFit.expand,
      children: [
        // 只有含 K0 的窗能接指针：其余窗平移/缩放/十字全被屏蔽，
        // 但仍会按联动控制器广播的 bar 与价格重绘（见 KlineChart.interactive）。
        IgnorePointer(ignoring: !interactive, child: child),
        Positioned(
          right: 6,
          top: 3,
          child: IgnorePointer(
            child: DecoratedBox(
              decoration: BoxDecoration(
                // 深色底 + 亮字：浅色主题与深色主题下都能看清（灰底灰字会糊成一片）。
                color: const Color(0xE61A1A1A),
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: interactive
                      ? const Color(0xFF42A5F5)
                      : const Color(0x66FFFFFF),
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                child: Text(
                  interactive ? 'K0 · 可操作' : 'K$level · 跟随',
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.2,
                    color: interactive
                        ? const Color(0xFF9CD2FF)
                        : const Color(0xFFCFCFCF),
                  ),
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

/// 该层尚未生成时的占位（不新建层级、不预测，等步进自然长出来）。
class _EmptyLevelPlaceholder extends StatelessWidget {
  const _EmptyLevelPlaceholder({required this.level});

  final int level;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: const Color(0xFF121212),
      child: Center(
        child: Text(
          'K$level 暂无数据\n（该层级尚未生成，继续步进后自动出现）',
          textAlign: TextAlign.center,
          style: const TextStyle(
            fontSize: 12,
            height: 1.6,
            color: Color(0xFF757575),
          ),
        ),
      ),
    );
  }
}
