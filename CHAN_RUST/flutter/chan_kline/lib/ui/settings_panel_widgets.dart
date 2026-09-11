import 'package:flutter/material.dart';

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
        foregroundColor: const Color(0xFFE2E8F0),
        side: const BorderSide(color: Color(0x55FFFFFF)),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      );

  static ButtonStyle filledStyle() => FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(buttonHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: const Color(0xFF2563EB),
        foregroundColor: Colors.white,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6)),
      );
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
          style: const TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w600,
            color: Color(0xFF94A3B8),
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
  Color iconColor = const Color(0xFFE2E8F0),
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
          icon: Icon(Icons.help_outline, size: 20, color: iconColor),
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
      iconColor: Colors.white,
    );
  }
}
