import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// 设置面板统一间距与按钮样式。
abstract final class SettingsPanelTheme {
  static const sectionGap = 12.0;
  static const fieldGap = 10.0;
  static const buttonHeight = 42.0;
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
  });

  final String title;
  final IconData icon;
  final List<Widget> children;
  final bool initiallyExpanded;

  @override
  Widget build(BuildContext context) {
    final border = AppPalette.border.withValues(alpha: 0.72);
    return Padding(
      padding: const EdgeInsets.only(bottom: SettingsPanelTheme.fieldGap),
      child: Material(
        color: AppPalette.surfaceAlt.withValues(alpha: 0.46),
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
            childrenPadding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
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
            children: [
              for (var i = 0; i < children.length; i++) ...[
                if (i > 0) const SizedBox(height: SettingsPanelTheme.fieldGap),
                children[i],
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
    final field = DropdownButtonFormField<T>(
      isExpanded: true,
      initialValue: value,
      decoration: InputDecoration(
        labelText: label,
        helperText: helper,
        helperMaxLines: 2,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      items: items,
      onChanged: onChanged,
    );
    if (onHelp == null) return field;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        IconButton(
          tooltip: helpTooltip ?? '说明',
          visualDensity: VisualDensity.compact,
          icon: const Icon(Icons.help_outline, size: 18),
          onPressed: onHelp,
        ),
        Expanded(child: field),
      ],
    );
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

/// 问号叠在按钮左侧，不挤占整行宽度，好和上方按钮对齐。
Widget settingsButtonWithLeftHelp({
  required Widget button,
  required VoidCallback onHelp,
  required String helpTooltip,
  Color? iconColor,
}) {
  return Stack(
    alignment: Alignment.center,
    children: [
      button,
      Positioned(
        left: 0,
        top: 0,
        bottom: 0,
        child: IconButton(
          tooltip: helpTooltip,
          onPressed: onHelp,
          visualDensity: VisualDensity.compact,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          icon: Icon(Icons.help_outline, size: 20, color: iconColor ?? AppPalette.rgb(0xFFE2E8F0)),
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
    return settingsButtonWithLeftHelp(
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
    return settingsButtonWithLeftHelp(
      button: button,
      onHelp: onHelp!,
      helpTooltip: helpTooltip ?? '说明',
      iconColor: AppPalette.rgb(0xFFFFFFFF),
    );
  }
}
