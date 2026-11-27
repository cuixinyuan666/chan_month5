import 'package:flutter/material.dart';
import 'package:chan_kline/theme/app_palette.dart';

/// 设置面板统一间距与按钮样式。
///
/// 桌面分区台宽 432（见 [EdgeControlPanel.panelW]）：左侧轨 + 右侧一页。
/// 组间距 10、项间距 8，页内不再叠第二层空白。
abstract final class SettingsPanelTheme {
  static const sectionGap = 10.0;
  static const fieldGap = 8.0;
  static const buttonHeight = 38.0;
  static const railWidth = 76.0;
  static const fieldDecoration = InputDecoration(
    isDense: true,
    border: OutlineInputBorder(),
    contentPadding: EdgeInsets.symmetric(horizontal: 10, vertical: 10),
  );

  static ButtonStyle outlinedStyle() => OutlinedButton.styleFrom(
        minimumSize: const Size.fromHeight(buttonHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        foregroundColor: AppPalette.textPrimary,
        side: BorderSide(color: AppPalette.border),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
      );

  static ButtonStyle filledStyle() => FilledButton.styleFrom(
        minimumSize: const Size.fromHeight(buttonHeight),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        backgroundColor: AppPalette.accent,
        foregroundColor: AppPalette.rgb(0xFFFFFFFF),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8)),
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

/// 问号按钮：放进输入框 suffix，或跟在标题右侧。
Widget settingsHelpIcon({
  required VoidCallback onPressed,
  String tooltip = '说明',
}) {
  return IconButton(
    tooltip: tooltip,
    visualDensity: VisualDensity.compact,
    padding: EdgeInsets.zero,
    iconSize: 16,
    onPressed: onPressed,
    icon: Icon(Icons.help_outline, size: 16, color: AppPalette.textSecondary),
  );
}

/// 页内小标题：左侧一笔强调色，用来把一页再分成「口径 / 分窗 / 标记」。
class SettingsGroupLabel extends StatelessWidget {
  const SettingsGroupLabel(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Container(
          width: 3,
          height: 12,
          decoration: BoxDecoration(
            color: AppPalette.accent,
            borderRadius: BorderRadius.circular(2),
          ),
        ),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            text,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: AppPalette.textSecondary,
            ),
          ),
        ),
      ],
    );
  }
}

/// 二元口径：一行标题 + 一句现状 + 开关。说明问号不占独立列。
class SettingsSwitchRow extends StatelessWidget {
  const SettingsSwitchRow({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.subtitle,
    this.onHelp,
    this.helpTooltip,
  });

  final String label;
  final String? subtitle;
  final bool value;
  final ValueChanged<bool>? onChanged;
  final VoidCallback? onHelp;
  final String? helpTooltip;

  @override
  Widget build(BuildContext context) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.center,
      children: [
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
              if (subtitle != null)
                Text(
                  subtitle!,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 11,
                    height: 1.25,
                    color: AppPalette.textSecondary,
                  ),
                ),
            ],
          ),
        ),
        if (onHelp != null)
          settingsHelpIcon(
            onPressed: onHelp!,
            tooltip: helpTooltip ?? '说明',
          ),
        Switch(
          value: value,
          onChanged: onChanged,
          materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
        ),
      ],
    );
  }
}

class SettingsChoiceOption<T> {
  const SettingsChoiceOption({
    required this.value,
    required this.title,
    this.tooltip,
  });

  final T value;
  final String title;
  final String? tooltip;
}

enum SettingsChoiceLayout { stack, grid }

/// 少量互斥项：格子或竖排点选，不再用下拉把当前值藏进一层菜单。
class SettingsChoiceCards<T> extends StatelessWidget {
  const SettingsChoiceCards({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
    this.helper,
    this.onHelp,
    this.helpTooltip,
    this.layout = SettingsChoiceLayout.stack,
  });

  final String label;
  final String? helper;
  final T value;
  final List<SettingsChoiceOption<T>> options;
  final ValueChanged<T>? onChanged;
  final VoidCallback? onHelp;
  final String? helpTooltip;
  final SettingsChoiceLayout layout;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                label,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                  color: AppPalette.textPrimary,
                ),
              ),
            ),
            if (onHelp != null)
              settingsHelpIcon(
                onPressed: onHelp!,
                tooltip: helpTooltip ?? '说明',
              ),
          ],
        ),
        if (helper != null) ...[
          const SizedBox(height: 2),
          Text(
            helper!,
            maxLines: 3,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 11,
              height: 1.3,
              color: AppPalette.textSecondary,
            ),
          ),
        ],
        const SizedBox(height: 6),
        if (layout == SettingsChoiceLayout.grid)
          LayoutBuilder(
            builder: (context, c) {
              final cellW = c.maxWidth < 80 ? c.maxWidth : (c.maxWidth - 6) / 2;
              return Wrap(
                spacing: 6,
                runSpacing: 6,
                children: [
                  for (final o in options)
                    SizedBox(width: cellW, child: _cell(o)),
                ],
              );
            },
          )
        else
          for (var i = 0; i < options.length; i++) ...[
            if (i > 0) const SizedBox(height: 6),
            _cell(options[i]),
          ],
      ],
    );
  }

  Widget _cell(SettingsChoiceOption<T> option) {
    final selected = option.value == value;
    final enabled = onChanged != null;
    return Tooltip(
      message: option.tooltip ?? option.title,
      child: Material(
        color: selected
            ? AppPalette.accent.withValues(alpha: 0.16)
            : AppPalette.surfaceAlt.withValues(alpha: AppPalette.isDark ? 0.45 : 1),
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(8),
          side: BorderSide(
            color: selected ? AppPalette.accent : AppPalette.border,
            width: selected ? 1.4 : 1,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: enabled ? () => onChanged!(option.value) : null,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
            child: Row(
              children: [
                Icon(
                  selected ? Icons.check_circle : Icons.circle_outlined,
                  size: 14,
                  color: selected ? AppPalette.accent : AppPalette.textSecondary,
                ),
                const SizedBox(width: 6),
                Expanded(
                  child: Text(
                    option.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
                      color: AppPalette.textPrimary,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// 跳到下一级对话框的行（窗口布局、数学指标参数）。
class SettingsLinkRow extends StatelessWidget {
  const SettingsLinkRow({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onTap,
    this.enabled = true,
    this.trailing,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onTap;
  final bool enabled;
  final IconData? trailing;

  @override
  Widget build(BuildContext context) {
    final on = enabled ? onTap : null;
    return Material(
      color: AppPalette.surfaceAlt.withValues(alpha: AppPalette.isDark ? 0.4 : 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: BorderSide(color: AppPalette.border),
      ),
      child: ListTile(
        dense: true,
        enabled: on != null,
        contentPadding: const EdgeInsets.symmetric(horizontal: 10),
        leading: Icon(icon, size: 18, color: AppPalette.accent),
        title: Text(
          title,
          maxLines: 1,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 13, color: AppPalette.textPrimary),
        ),
        subtitle: Text(
          subtitle,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
        ),
        trailing: Icon(
          trailing ?? Icons.chevron_right,
          size: 18,
          color: AppPalette.textSecondary,
        ),
        onTap: on,
      ),
    );
  }
}

/// 研究类入口：图标、现状、主操作，底部可挂「参数 / 上次结果」。
class SettingsCommandTile extends StatelessWidget {
  const SettingsCommandTile({
    super.key,
    required this.title,
    required this.subtitle,
    required this.icon,
    required this.onPressed,
    this.onHelp,
    this.helpTooltip,
    this.emphasized = false,
    this.footer,
  });

  final String title;
  final String subtitle;
  final IconData icon;
  final VoidCallback? onPressed;
  final VoidCallback? onHelp;
  final String? helpTooltip;
  final bool emphasized;
  final Widget? footer;

  @override
  Widget build(BuildContext context) {
    return Material(
      color: emphasized
          ? AppPalette.accent.withValues(alpha: 0.14)
          : AppPalette.surfaceAlt.withValues(alpha: AppPalette.isDark ? 0.4 : 1),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(
          color: emphasized ? AppPalette.accent.withValues(alpha: 0.7) : AppPalette.border,
        ),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          InkWell(
            onTap: onPressed,
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 4, 8),
              child: Row(
                children: [
                  Icon(icon, size: 20, color: AppPalette.accent),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        Text(
                          title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                            color: AppPalette.textPrimary,
                          ),
                        ),
                        Text(
                          subtitle,
                          maxLines: 2,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 11,
                            height: 1.25,
                            color: AppPalette.textSecondary,
                          ),
                        ),
                      ],
                    ),
                  ),
                  if (onHelp != null)
                    settingsHelpIcon(
                      onPressed: onHelp!,
                      tooltip: helpTooltip ?? '说明',
                    ),
                  Icon(
                    Icons.arrow_forward,
                    size: 16,
                    color: onPressed == null
                        ? AppPalette.textSecondary.withValues(alpha: 0.4)
                        : AppPalette.textSecondary,
                  ),
                  const SizedBox(width: 6),
                ],
              ),
            ),
          ),
          ?footer,
        ],
      ),
    );
  }
}

/// 默认收起的一块内容。子组件在点开前不挂载，避免一开设置就触发副作用。
class SettingsReveal extends StatefulWidget {
  const SettingsReveal({
    super.key,
    required this.title,
    required this.subtitle,
    required this.child,
  });

  final String title;
  final String subtitle;
  final Widget child;

  @override
  State<SettingsReveal> createState() => _SettingsRevealState();
}

class _SettingsRevealState extends State<SettingsReveal> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SettingsLinkRow(
          title: widget.title,
          subtitle: _open ? '已展开' : widget.subtitle,
          icon: Icons.cloud_upload_outlined,
          trailing: _open ? Icons.expand_less : Icons.expand_more,
          onTap: () => setState(() => _open = !_open),
        ),
        if (_open) ...[
          const SizedBox(height: 8),
          widget.child,
        ],
      ],
    );
  }
}

/// 设置分区台的一页。
class SettingsDeskSection {
  const SettingsDeskSection({
    required this.title,
    required this.railLabel,
    required this.icon,
    required this.summary,
    required this.searchTerms,
    required this.children,
  });

  final String title;
  final String railLabel;
  final IconData icon;
  final String summary;

  /// 搜索用的词，含旧分区名，方便按原来的叫法跳过来。
  final String searchTerms;
  final List<Widget> children;
}

/// 左侧分区轨 + 钉住的页标题 + 只滚当前页。
///
/// 2026-11-17 要求「往下滚时分类标题一直看得见」。
/// 现在标题不参加滚动，所以任何滚动位置都看得到当前分区。
class SettingsDesk extends StatefulWidget {
  const SettingsDesk({
    super.key,
    required this.index,
    required this.onChanged,
    required this.sections,
  });

  final int index;
  final ValueChanged<int> onChanged;
  final List<SettingsDeskSection> sections;

  @override
  State<SettingsDesk> createState() => _SettingsDeskState();
}

class _SettingsDeskState extends State<SettingsDesk> {
  final _query = TextEditingController();
  final _scrolls = <int, ScrollController>{};
  final _visited = <int>{};

  @override
  void dispose() {
    _query.dispose();
    for (final c in _scrolls.values) {
      c.dispose();
    }
    super.dispose();
  }

  ScrollController _ctrl(int i) =>
      _scrolls.putIfAbsent(i, ScrollController.new);

  List<int> _hits(List<SettingsDeskSection> sections) {
    final q = _query.text.trim().toLowerCase();
    if (q.isEmpty) {
      return [for (var i = 0; i < sections.length; i++) i];
    }
    final out = <int>[];
    for (var i = 0; i < sections.length; i++) {
      final s = sections[i];
      final blob =
          '${s.title} ${s.railLabel} ${s.summary} ${s.searchTerms}'.toLowerCase();
      if (blob.contains(q)) out.add(i);
    }
    return out;
  }

  void _onQuery(String _) {
    final hits = _hits(widget.sections);
    if (hits.isNotEmpty && !hits.contains(widget.index)) {
      widget.onChanged(hits.first);
    }
    setState(() {});
  }

  List<Widget> _spaced(List<Widget> children) {
    final items = <Widget>[
      for (final c in children)
        if (c is! SizedBox) c,
    ];
    return [
      for (var i = 0; i < items.length; i++) ...[
        if (i > 0) const SizedBox(height: SettingsPanelTheme.fieldGap),
        items[i],
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final sections = widget.sections;
    if (sections.isEmpty) return const SizedBox.shrink();
    final index = widget.index.clamp(0, sections.length - 1);
    _visited.add(index);
    final hits = _hits(sections);
    final active = sections[index];
    return LayoutBuilder(
      builder: (context, c) {
        final narrow = c.maxWidth < 392;
        final bounded = c.maxHeight.isFinite;
        final search = _searchBox();
        final header = _header(
          active,
          index,
          empty: hits.isEmpty,
        );
        if (!bounded) {
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              search,
              _railHorizontal(sections, index, hits),
              header,
              if (hits.isEmpty)
                _emptyQuery()
              else
                Padding(
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
                  child: SelectionArea(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: _spaced(active.children),
                    ),
                  ),
                ),
            ],
          );
        }
        final page = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            header,
            Expanded(child: _pageBody(sections, index, hits)),
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            search,
            Expanded(
              child: narrow
                  ? Column(
                      children: [
                        _railHorizontal(sections, index, hits),
                        Expanded(child: page),
                      ],
                    )
                  : Row(
                      crossAxisAlignment: CrossAxisAlignment.stretch,
                      children: [
                        _railVertical(sections, index, hits),
                        Expanded(child: page),
                      ],
                    ),
            ),
          ],
        );
      },
    );
  }

  Widget _searchBox() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
      child: TextField(
        key: const Key('settings-desk-search'),
        controller: _query,
        onChanged: _onQuery,
        style: TextStyle(fontSize: 13, color: AppPalette.textPrimary),
        decoration: InputDecoration(
          isDense: true,
          hintText: '搜索：首框 / 筹码 / 寻优',
          hintStyle: TextStyle(fontSize: 12, color: AppPalette.textSecondary),
          prefixIcon: Icon(Icons.search, size: 18, color: AppPalette.textSecondary),
          prefixIconConstraints: const BoxConstraints(minWidth: 36, minHeight: 32),
          suffixIcon: _query.text.isEmpty
              ? null
              : IconButton(
                  tooltip: '清除搜索',
                  onPressed: () {
                    _query.clear();
                    _onQuery('');
                  },
                  icon: Icon(Icons.close, size: 16, color: AppPalette.textSecondary),
                ),
          filled: true,
          fillColor: AppPalette.surfaceAlt.withValues(
            alpha: AppPalette.isDark ? 0.45 : 0.9,
          ),
          contentPadding: const EdgeInsets.symmetric(vertical: 10),
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppPalette.border),
          ),
          enabledBorder: OutlineInputBorder(
            borderRadius: BorderRadius.circular(10),
            borderSide: BorderSide(color: AppPalette.border),
          ),
        ),
      ),
    );
  }

  Widget _header(SettingsDeskSection section, int index, {required bool empty}) {
    final n = (index + 1).toString().padLeft(2, '0');
    return Container(
      key: const Key('settings-sticky-category'),
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: AppPalette.border)),
      ),
      child: Row(
        children: [
          Text(
            n,
            style: TextStyle(
              fontSize: 22,
              height: 1,
              fontWeight: FontWeight.w700,
              color: AppPalette.accent.withValues(alpha: 0.9),
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  section.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 15,
                    fontWeight: FontWeight.w700,
                    color: AppPalette.textPrimary,
                  ),
                ),
                Text(
                  empty ? '没有匹配的分区' : section.summary,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(fontSize: 11, color: AppPalette.textSecondary),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _emptyQuery() {
    return Padding(
      padding: const EdgeInsets.all(16),
      child: Text(
        '没有叫「${_query.text.trim()}」的设置。试试首框、筹码、寻优、主题。',
        style: TextStyle(fontSize: 12, height: 1.35, color: AppPalette.textSecondary),
      ),
    );
  }

  Widget _pageBody(List<SettingsDeskSection> sections, int index, List<int> hits) {
    if (hits.isEmpty) return _emptyQuery();
    return Stack(
      children: [
        for (final i in _visited)
          Offstage(
            offstage: i != index,
            child: _sectionScroll(i, sections[i], active: i == index),
          ),
      ],
    );
  }

  Widget _sectionScroll(int i, SettingsDeskSection section, {required bool active}) {
    return SingleChildScrollView(
      key: active ? const Key('settings-scroll') : null,
      controller: _ctrl(i),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 16),
      child: SelectionArea(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: _spaced(section.children),
        ),
      ),
    );
  }

  Widget _railVertical(
    List<SettingsDeskSection> sections,
    int index,
    List<int> hits,
  ) {
    return SizedBox(
      width: SettingsPanelTheme.railWidth,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: AppPalette.surfaceAlt.withValues(alpha: AppPalette.isDark ? 0.28 : 0.65),
          border: Border(right: BorderSide(color: AppPalette.border)),
        ),
        child: ListView(
          padding: const EdgeInsets.symmetric(vertical: 6),
          children: [
            for (var i = 0; i < sections.length; i++)
              _railButton(sections[i], i, selected: i == index, dim: _dim(i, hits)),
          ],
        ),
      ),
    );
  }

  Widget _railHorizontal(
    List<SettingsDeskSection> sections,
    int index,
    List<int> hits,
  ) {
    return SizedBox(
      height: 46,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 8),
        children: [
          for (var i = 0; i < sections.length; i++)
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _railButton(
                sections[i],
                i,
                selected: i == index,
                dim: _dim(i, hits),
                horizontal: true,
              ),
            ),
        ],
      ),
    );
  }

  bool _dim(int i, List<int> hits) =>
      _query.text.trim().isNotEmpty && !hits.contains(i);

  Widget _railButton(
    SettingsDeskSection section,
    int i, {
    required bool selected,
    required bool dim,
    bool horizontal = false,
  }) {
    final iconColor = selected ? AppPalette.accent : AppPalette.textSecondary;
    final label = Text(
      section.railLabel,
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
      style: TextStyle(
        fontSize: 11,
        fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
        color: selected ? AppPalette.textPrimary : AppPalette.textSecondary,
      ),
    );
    return Opacity(
      opacity: dim ? 0.38 : 1,
      child: Material(
        color: selected
            ? AppPalette.accent.withValues(alpha: 0.16)
            : Colors.transparent,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          key: Key('settings-rail-${section.title}'),
          borderRadius: BorderRadius.circular(10),
          onTap: () => widget.onChanged(i),
          child: Padding(
            padding: horizontal
                ? const EdgeInsets.symmetric(horizontal: 10, vertical: 6)
                : const EdgeInsets.symmetric(vertical: 8, horizontal: 4),
            child: horizontal
                ? Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(section.icon, size: 16, color: iconColor),
                      const SizedBox(width: 4),
                      label,
                    ],
                  )
                : Column(
                    children: [
                      Icon(section.icon, size: 18, color: iconColor),
                      const SizedBox(height: 2),
                      label,
                    ],
                  ),
          ),
        ),
      ),
    );
  }
}
