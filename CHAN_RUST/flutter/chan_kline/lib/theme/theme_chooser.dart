import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'theme_settings_store.dart';

/// 设置面板里的「主题外观」三选一：深色 / 浅色 / 护眼。
///
/// 点一下立刻生效（整棵树重建，绘图代码里的颜色都从 AppPalette 取，
/// 所以 K 线画布/坐标/图例一起换），同时写盘，重启后保留。
class ThemeChooser extends StatelessWidget {
  const ThemeChooser({super.key});

  @override
  Widget build(BuildContext context) {
    final cur = AppThemeController.instance.mode;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          '主题外观',
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppPalette.textSecondary,
          ),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 6,
          children: [
            for (final m in AppThemeMode.values)
              ChoiceChip(
                key: ValueKey<String>('theme_chip_${m.id}'),
                label: Text(m.label),
                selected: cur == m,
                onSelected: (_) => AppThemeController.instance.setMode(m),
              ),
          ],
        ),
        const SizedBox(height: 4),
        Text(
          '深色=原来的黑底；浅色=白底；护眼=米黄底。切换即时生效，K 线画布/坐标/图例一起换，重启后保留。',
          style: TextStyle(
            fontSize: 11,
            color: AppPalette.textSecondary,
            height: 1.3,
          ),
        ),
      ],
    );
  }
}
