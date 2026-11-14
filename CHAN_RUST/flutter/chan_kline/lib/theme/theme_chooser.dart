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
    // 自监听：主题切换 / 护眼暖色拖动都来自 AppThemeController，
    // 外层即使传入同一个 const 实例，本控件也会随 notifyListeners 重建，
    // 保证对勾、滑杆始终与当前模式/强度同步。
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final cur = AppThemeController.instance.mode;
        final warmth = AppThemeController.instance.warmth;
        final brightness = AppThemeController.instance.brightness;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            DropdownButtonFormField<AppThemeMode>(
              isExpanded: true,
              initialValue: cur,
              decoration: const InputDecoration(
                labelText: '主题外观',
                isDense: true,
                border: OutlineInputBorder(),
              ),
              items: [
                for (final m in AppThemeMode.values)
                  DropdownMenuItem(
                    value: m,
                    child: Text(
                      m.label,
                      key: ValueKey<String>('theme_chip_${m.id}'),
                    ),
                  ),
              ],
              onChanged: (m) {
                if (m != null) AppThemeController.instance.setMode(m);
              },
            ),
            // 暖色强度 + 亮度：三模式全部开放，即时生效并落盘。
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    key: const ValueKey('theme_warmth'),
                    value: warmth,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) => AppThemeController.instance.setWarmth(v),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(warmth * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '暖色强度：三主题通用，越高越暖（米黄/暖橙），越低越中性；拖动即时生效并保留。',
              style: TextStyle(
                fontSize: 11,
                color: AppPalette.textSecondary,
                height: 1.3,
              ),
            ),
            const SizedBox(height: 4),
            Row(
              children: [
                Expanded(
                  child: Slider(
                    key: const ValueKey('theme_brightness'),
                    value: brightness,
                    min: 0.0,
                    max: 1.0,
                    onChanged: (v) =>
                        AppThemeController.instance.setBrightness(v),
                  ),
                ),
                SizedBox(
                  width: 44,
                  child: Text(
                    '${(brightness * 100).round()}%',
                    style: TextStyle(
                      fontSize: 11,
                      color: AppPalette.textSecondary,
                    ),
                  ),
                ),
              ],
            ),
            Text(
              '亮度：三主题通用，0~100%（50% 为各主题基准明度），拖动即时生效并保留。',
              style: TextStyle(
                fontSize: 11,
                color: AppPalette.textSecondary,
                height: 1.3,
              ),
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
      },
    );
  }
}
