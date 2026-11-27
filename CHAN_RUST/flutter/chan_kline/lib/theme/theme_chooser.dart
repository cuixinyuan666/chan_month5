import 'package:flutter/material.dart';

import 'app_palette.dart';
import 'theme_settings_store.dart';

/// 设置面板里的「主题外观」：深色 / 浅色 / 护眼，三块色样直接点。
///
/// 点一下立刻生效（整棵树重建，绘图颜色都从 AppPalette 取），同时写盘。
/// 暖色、亮度两根滑杆三套主题通用。
class ThemeChooser extends StatelessWidget {
  const ThemeChooser({super.key});

  static const _swatch = <AppThemeMode, Color>{
    AppThemeMode.dark: Color(0xFF121212),
    AppThemeMode.light: Color(0xFFF6F7F9),
    AppThemeMode.eyeCare: Color(0xFFF4EFDF),
  };

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: AppThemeController.instance,
      builder: (context, _) {
        final ctl = AppThemeController.instance;
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                for (final m in AppThemeMode.values)
                  Expanded(
                    child: Padding(
                      padding: EdgeInsets.only(
                        right: m == AppThemeMode.eyeCare ? 0 : 6,
                      ),
                      child: _swatchButton(m, selected: ctl.mode == m),
                    ),
                  ),
              ],
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
              '暖色偏米黄，亮度 50% 为基准。拖动即时生效并保留，主图、分笔画板、K线画板一起换色。',
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

  Widget _swatchButton(AppThemeMode mode, {required bool selected}) {
    final color = _swatch[mode]!;
    final ink = color.computeLuminance() > 0.55
        ? const Color(0xFF111111)
        : const Color(0xFFF8FAFC);
    return Material(
      key: ValueKey<String>('theme_chip_${mode.id}'),
      color: Colors.transparent,
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => AppThemeController.instance.setMode(mode),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Column(
            children: [
              Container(
                height: 28,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: color,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(
                    color: selected ? AppPalette.accent : AppPalette.border,
                    width: selected ? 2 : 1,
                  ),
                ),
                child: selected
                    ? Icon(Icons.check, size: 16, color: ink)
                    : null,
              ),
              const SizedBox(height: 4),
              Text(
                mode.label,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 11,
                  fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                  color: selected ? AppPalette.accent : AppPalette.textSecondary,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 紧凑滑杆：左侧 34px 标签、右侧 40px 百分比。
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
                thumbShape: const RoundSliderThumbShape(enabledThumbRadius: 6),
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
