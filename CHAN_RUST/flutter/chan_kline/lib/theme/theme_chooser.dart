import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'theme_settings_store.dart';

/// 设置面板里的「主题外观」三选一：深色 / 浅色 / 护眼。
///
/// 点一下立刻生效（整棵树重建，绘图代码里的颜色都从 AppPalette 取，
/// 所以 K 线画布/坐标/图例一起换），同时写盘，重启后保留。
///
/// 版式取向：设置面板只有 300px 宽，主题项要「一眼看完」——
/// 一行下拉选主题 + 两行滑杆（暖色/亮度）+ 一行合并说明，
/// 不再给每个滑杆配一段重复的解释文字。
class ThemeChooser extends StatelessWidget {
  const ThemeChooser({super.key});

  @override
  Widget build(BuildContext context) {
    // 自监听：主题切换 / 暖色拖动都来自 AppThemeController，
    // 外层即使传入同一个 const 实例，本控件也会随 notifyListeners 重建，
    // 保证对勾、滑杆始终与当前模式/强度同步。
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final ctl = AppThemeController.instance;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            DropdownButtonFormField<AppThemeMode>(
              isExpanded: true,
              initialValue: ctl.mode,
              decoration: const InputDecoration(
                labelText: '主题外观',
                isDense: true,
                contentPadding:
                    EdgeInsets.symmetric(horizontal: 10, vertical: 10),
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
            _themeSlider(
              key: const ValueKey('theme_warmth'),
              label: '暖色',
              value: ctl.warmth,
              onChanged: ctl.setWarmth,
            ),
            _themeSlider(
              key: const ValueKey('theme_brightness'),
              label: '亮度',
              value: ctl.brightness,
              onChanged: ctl.setBrightness,
            ),
            Text(
              '暖色=偏米黄/暖橙，亮度 50% 为基准；拖动即时生效并保留，主图/分笔/K线画板同步换色。',
              style: TextStyle(
                fontSize: 11,
                height: 1.3,
                color: AppPalette.textSecondary,
              ),
            ),
          ],
        );
      },
    );
  }

  /// 紧凑滑杆：左侧 34px 标签、右侧 40px 百分比，滑杆本体压缩轨道与滑块，
  /// 整行高度从默认 ~48 降到 ~28，两行滑杆不再各自占掉一张卡片。
  Widget _themeSlider({
    required Key key,
    required String label,
    required double value,
    required Future<void> Function(double) onChanged,
  }) {
    return SizedBox(
      height: 30,
      child: Row(
        children: [
          SizedBox(
            width: 34,
            child: Text(
              label,
              style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
            ),
          ),
          Expanded(
            child: SliderTheme(
              data: SliderThemeData(
                trackHeight: 3,
                overlayShape: SliderComponentShape.noOverlay,
                thumbShape:
                    const RoundSliderThumbShape(enabledThumbRadius: 6),
              ),
              child: Slider(
                key: key,
                value: value,
                min: 0.0,
                max: 1.0,
                onChanged: (v) => onChanged(v),
              ),
            ),
          ),
          SizedBox(
            width: 40,
            child: Text(
              '${(value * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
            ),
          ),
        ],
      ),
    );
  }
}
