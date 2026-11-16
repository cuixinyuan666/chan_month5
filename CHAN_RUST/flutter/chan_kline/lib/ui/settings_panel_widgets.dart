import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// 设置面板统一间距与按钮样式。
///
/// 面板宽度只有 300（见 [EdgeControlPanel.panelW]），稠密优先：
/// 组间距 10、项间距 8，卡片内部不再叠第二层空白。
abstract final class SettingsPanelTheme {
  static const sectionGap = 10.0;
  static const fieldGap = 8.0;
  static const buttonHeight = 38.0;
  static const fieldDecoration = InputDecoration(
    isDense: true,
    border: OutlineInputBorder(),
    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
  );

  static ButtonStyle outlinedStyle() => OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(buttonHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: AppPalette.rgb(0xFFE2E8F0),
        side: BorderSide(color: AppPalette.rgb(0x55FFFFFF)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      );

  static ButtonStyle filledStyle() => FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(buttonHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: AppPalette.rgb(0xFF2563EB),
        foregroundColor: AppPalette.rgb(0xFFFFFFFF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      );
}

class SettingsCategory extends StatelessWidget {
  const SettingsCategory({
    super.key,
    required this.title,
    required this.icon,
    required this.children,
    this.initiallyExpanded = false,
    this.summary,
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  /// 收起状态下的一行摘要（可选）。收起后仍能一眼看到当前口径，
  /// 不必逐个展开确认，避免「折叠 = 信息全丢」。
  final String? summary;

  @override
  Widget build(BuildContext context) {
    final border = AppPalette.border.withValues(alpha: 0.72);
    // 卡片底：深色用半透明次级底压在暗面板上；浅色/护眼直接用不透明卡面，
    // 否则叠色后卡片与面板几乎同色，看不出分组。
    final cardColor = AppPalette.isDark
        ? AppPalette.surfaceAlt.withValues(alpha: 0.50)
        : AppPalette.surface;
    // 项间距由本卡片统一提供：调用方若在 children 里又塞了 SizedBox 占位，
    // 会与本处的 fieldGap 叠加成双倍空白（原来每组项间实际 18~20px）。
    // 统一剔除，保证全局面板只有一层间距。
    final items = <Widget>[
      for (final c in children)
        if (c is! SizedBox) c,
    ];
    return Padding(
      padding: const EdgeInsets.only(bottom: SettingsPanelTheme.fieldGap),
      child: Material(
        color: cardColor,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(color: border),
        ),
        clipBehavior: Clip.antiAlias,
        child: Theme(
          data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
          child: ExpansionTile(
            initiallyExpanded: initiallyExpanded,
            maintainState: true,
            tilePadding: const EdgeInsets.symmetric(horizontal: 10),
            childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
            // 展开时不要 Material3 默认的 surfaceTint 染色，保持卡片单色。
            backgroundColor: Colors.transparent,
            collapsedBackgroundColor: Colors.transparent,
            iconColor: AppPalette.textSecondary,
            collapsedIconColor: AppPalette.textSecondary,
            leading: Icon(icon, size: 18, color: AppPalette.accent),
            title: Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w700,
                color: AppPalette.textPrimary,
              ),
            ),
            subtitle: summary == null
                ? null
                : Text(
                    summary!,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 11,
                      height: 1.2,
                      color: AppPalette.textSecondary,
                    ),
                  ),
            children: [
              for (var i = 0; i < items.length; i++) ...[
                if (i > 0) const SizedBox(height: SettingsPanelTheme.fieldGap),
                items[i],
              ],
            ],
          ),
        ),
      ),
    );
  }
}

/// 设置项下拉：开/关或少量互斥项。保存值仍由调用方原函数写入。
class SettingsChoiceDropdown<T> extends StatelessWidget {
  const SettingsChoiceDropdown({
    super.key,
    required this.label,
    required this.value,
    required this.items,
    required this.onChanged,
    this.helper,
    this.onHelp,
    this.helpTooltip,
  });

  final String label;
  final T value;
  final List<DropdownMenuItem<T>> items;
  final ValueChanged<T?>? onChanged;
  final String? helper;
  final VoidCallback? onHelp;
  final String? helpTooltip;

  @override
  Widget build(BuildContext context) {
    // 帮助入口不再单独占一列（原来左侧 48px 的 IconButton 会把输入框挤到
    // 232px，长标签/长说明在窄面板里被截断）。改为输入框内的 suffixIcon，
    // 输入框保持整宽，问号也不会盖住控件的可点区域。
    final field = DropdownButtonFormField<T>(
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 3,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10, vertical: 10),
        border: const OutlineInputBorder(),
        suffixIconConstraints:
            const BoxConstraints(minWidth: 30, minHeight: 30),
        suffixIcon: onHelp == null
            ? null
            : IconButton(
                tooltip: helpTooltip ?? '说明',
                visualDensity: VisualDensity.compact,
                padding: EdgeInsets.zero,
                iconSize: 16,
                icon: const Icon(Icons.help_outline),
                onPressed: onHelp,
              ),
      ),
      items: items,
      onChanged: onChanged,
    );
    return field;
  }
}

class SettingsSection extends StatelessWidget {
  const SettingsSection({
    super.key,
    required this.title,
    required this.children,
  });

  final String title;
  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: AppPalette.rgb(0xFF94A3B8),
          ),
        ),
        const SizedBox(height: 8),
        ...children,
      ],
    );
  }
}

/// 按钮 + 右侧问号：问号单独占一列，不叠在按钮上。
///
/// 旧实现用 Stack 把问号浮在按钮左端，既会挡住按钮左 1/3 的可点区域
/// （点按钮左缘实际触发的是帮助），长标签时也会和文字重叠。
Widget settingsButtonWithHelp({
  required Widget button,
  required VoidCallback onHelp,
  required String helpTooltip,
  Color? iconColor,
}) {
  return Row(
    children: [
      Expanded(child: button),
      SizedBox(
        width: 30,
        height: SettingsPanelTheme.buttonHeight,
        child: IconButton(
          tooltip: helpTooltip,
          onPressed: onHelp,
          visualDensity: VisualDensity.compact,
          padding: EdgeInsets.zero,
          iconSize: 18,
          icon: Icon(
            Icons.help_outline,
            size: 18,
            color: iconColor ?? AppPalette.textSecondary,
          ),
        ),
      ),
    ],
  );
}

class SettingsOutlinedButton extends StatelessWidget {
  const SettingsOutlinedButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.tooltip,
    this.onHelp,
    this.helpTooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? tooltip;
  final VoidCallback? onHelp;
  final String? helpTooltip;

  @override
  Widget build(BuildContext context) {
    final child = icon == null
        ? Text(label)
        : Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Icon(icon, size: 18),
              const SizedBox(width: 8),
              Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
            ],
          );
    final button = Tooltip(
      message: tooltip ?? label,
      child: OutlinedButton(
        style: SettingsPanelTheme.outlinedStyle(),
        onPressed: onPressed,
        child: child,
      ),
    );
    if (onHelp == null) return button;
    return settingsButtonWithHelp(
      button: button,
      onHelp: onHelp!,
      helpTooltip: helpTooltip ?? '说明',
    );
  }
}

class SettingsFilledButton extends StatelessWidget {
  const SettingsFilledButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.onHelp,
    this.helpTooltip,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final VoidCallback? onHelp;
  final String? helpTooltip;

  @override
  Widget build(BuildContext context) {
    final button = FilledButton(
      style: SettingsPanelTheme.filledStyle(),
      onPressed: onPressed,
      child: Row(
        mainAxisAlignment: MainAxisAlignment.center,
        children: [
          if (icon != null) ...[
            Icon(icon, size: 18),
            const SizedBox(width: 8),
          ],
          Flexible(child: Text(label, overflow: TextOverflow.ellipsis)),
        ],
      ),
    );
    if (onHelp == null) return button;
    return settingsButtonWithHelp(
      button: button,
      onHelp: onHelp!,
      helpTooltip: helpTooltip ?? '说明',
      iconColor: AppPalette.rgb(0xFFFFFFFF),
    );
  }
}
