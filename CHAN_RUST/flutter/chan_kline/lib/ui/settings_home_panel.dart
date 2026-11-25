import 'package:flutter/material.dart';

import 'package:chan_kline/models/pre_first_fractal_unit_mode.dart';
import 'package:chan_kline/settings/telegram_settings_store.dart';
import 'package:chan_kline/theme/app_palette.dart';
import 'package:chan_kline/theme/theme_chooser.dart';
import 'package:chan_kline/theme/theme_settings_store.dart';

import 'settings_panel_widgets.dart';
import 'ticks_full_upload_panel.dart';

/// 设置分区台的五页内容。
///
/// 行情管加载，结构管缠论口径，分布管筹码和数学指标，
/// 研究管回测 / 寻优 / 计优 / 机器学习，工作台管外观、交互和同步。
/// 保存仍走原来的回调，这里只改分组和控件形态。
class SettingsHomePanel extends StatelessWidget {
  const SettingsHomePanel({
    super.key,
    required this.deskIndex,
    required this.onDeskIndex,
    required this.forMobileSheet,
    required this.busy,
    required this.bootstrapping,
    required this.codes,
    required this.selectedCode,
    required this.onRefreshStocks,
    required this.onStockSelected,
    required this.onPickStock,
    required this.periods,
    required this.period,
    required this.onPeriodSelected,
    required this.onPeriodHelp,
    required this.beginText,
    required this.endText,
    required this.onPickBegin,
    required this.onPickEnd,
    required this.onEditOhlc,
    required this.onOhlcHelp,
    required this.onTickDraw,
    required this.onTickDrawHelp,
    required this.onKlineDraw,
    required this.onKlineDrawHelp,
    required this.telegramEnabled,
    required this.onTelegram,
    required this.telegramSettings,
    required this.dataRoot,
    required this.onCreateUploadTask,
    required this.onShareDir,
    required this.truncationOn,
    required this.onTruncation,
    required this.onTruncationHelp,
    required this.unitMode,
    required this.onUnitMode,
    required this.onUnitHelp,
    required this.buildingDash,
    required this.onBuildingDash,
    required this.onBuildingHelp,
    required this.levelEnabled,
    required this.levelCount,
    required this.levelLabel,
    required this.onLevelEnabled,
    required this.onLevelHelp,
    required this.onEditLevel,
    required this.bspOverlay,
    required this.onBsp,
    required this.onBspHelp,
    required this.chipOn,
    required this.onChip,
    required this.onChipHelp,
    required this.peakOn,
    required this.peakEditable,
    required this.onPeak,
    required this.bucketStep,
    required this.onBucketSubmitted,
    required this.onMath,
    required this.onMathHelp,
    required this.backtestOpen,
    required this.onBacktest,
    required this.searchRunning,
    required this.onSearch,
    required this.onSearchHelp,
    required this.onLastSearch,
    required this.onSearchParams,
    required this.statRunning,
    required this.onStats,
    required this.onStatsHelp,
    required this.onStatsParams,
    required this.mlActive,
    required this.onMl,
    required this.onMlHelp,
    required this.onExitMl,
    required this.interactionOverride,
    required this.useAndroid,
    required this.onInteraction,
    required this.onProbe,
    required this.syncLine,
    required this.onSync,
  });

  final int deskIndex;
  final ValueChanged<int> onDeskIndex;
  final bool forMobileSheet;
  final bool busy;
  final bool bootstrapping;
  final List<String> codes;
  final String? selectedCode;
  final VoidCallback onRefreshStocks;
  final ValueChanged<String> onStockSelected;
  final VoidCallback onPickStock;
  final Map<String, String> periods;
  final String period;
  final ValueChanged<String> onPeriodSelected;
  final VoidCallback onPeriodHelp;
  final String beginText;
  final String endText;
  final VoidCallback? onPickBegin;
  final VoidCallback? onPickEnd;
  final VoidCallback? onEditOhlc;
  final VoidCallback onOhlcHelp;
  final VoidCallback? onTickDraw;
  final VoidCallback onTickDrawHelp;
  final VoidCallback? onKlineDraw;
  final VoidCallback onKlineDrawHelp;
  final bool telegramEnabled;
  final VoidCallback? onTelegram;
  final TelegramSettings telegramSettings;
  final String dataRoot;
  final Future<String> Function(TelegramSettings draft) onCreateUploadTask;
  final Future<void> Function(String shareDir) onShareDir;
  final bool truncationOn;
  final ValueChanged<bool>? onTruncation;
  final VoidCallback onTruncationHelp;
  final PreFirstFractalUnitMode unitMode;
  final ValueChanged<PreFirstFractalUnitMode>? onUnitMode;
  final VoidCallback onUnitHelp;
  final bool buildingDash;
  final ValueChanged<bool>? onBuildingDash;
  final VoidCallback onBuildingHelp;
  final bool levelEnabled;
  final int levelCount;
  final String levelLabel;
  final ValueChanged<bool> onLevelEnabled;
  final VoidCallback onLevelHelp;
  final VoidCallback? onEditLevel;
  final bool bspOverlay;
  final ValueChanged<bool>? onBsp;
  final VoidCallback onBspHelp;
  final bool chipOn;
  final ValueChanged<bool>? onChip;
  final VoidCallback onChipHelp;
  final bool peakOn;
  final bool peakEditable;
  final ValueChanged<bool>? onPeak;
  final double bucketStep;
  final ValueChanged<String> onBucketSubmitted;
  final VoidCallback? onMath;
  final VoidCallback onMathHelp;
  final bool backtestOpen;
  final VoidCallback? onBacktest;
  final bool searchRunning;
  final VoidCallback? onSearch;
  final VoidCallback onSearchHelp;
  final VoidCallback? onLastSearch;
  final VoidCallback? onSearchParams;
  final bool statRunning;
  final VoidCallback? onStats;
  final VoidCallback onStatsHelp;
  final VoidCallback? onStatsParams;
  final bool mlActive;
  final VoidCallback? onMl;
  final VoidCallback onMlHelp;
  final VoidCallback onExitMl;
  final bool? interactionOverride;
  final bool useAndroid;
  final ValueChanged<bool?> onInteraction;
  final VoidCallback? onProbe;
  final String syncLine;
  final VoidCallback? onSync;

  String get _periodLabel => periods[period] ?? period;

  String _unitShort(PreFirstFractalUnitMode mode) {
    switch (mode) {
      case PreFirstFractalUnitMode.off:
        return '经典';
      case PreFirstFractalUnitMode.seedBox:
        return '种子框';
      case PreFirstFractalUnitMode.highHigh:
        return '高高';
      case PreFirstFractalUnitMode.lowLow:
        return '低低';
    }
  }

  @override
  Widget build(BuildContext context) {
    final researchBits = <String>[
      if (backtestOpen) '回测开',
      if (searchRunning) '寻优中',
      if (statRunning) '计优中',
      if (mlActive) '学习中',
    ];
    return SettingsDesk(
      index: deskIndex,
      onChanged: onDeskIndex,
      sections: [
        SettingsDeskSection(
          title: '行情',
          railLabel: '行情',
          icon: Icons.show_chart,
          summary: '${selectedCode ?? "未选股票"} · $_periodLabel',
          searchTerms:
              '数据与加载 股票 周期 时间 加载 电报 Telegram 画板 OHLC 分笔 K线 上传',
          children: _marketChildren(),
        ),
        SettingsDeskSection(
          title: '结构',
          railLabel: '结构',
          icon: Icons.account_tree_outlined,
          summary:
              '首框 ${_unitShort(unitMode)} · ${levelEnabled ? "$levelCount 窗" : "单图"}',
          searchTerms: '主图显示 主图 截断 首框 早生成 高高 低低 种子 虚线 分窗 窗口 买卖 BSP',
          children: _structureChildren(),
        ),
        SettingsDeskSection(
          title: '分布',
          railLabel: '分布',
          icon: Icons.bar_chart,
          summary:
              '${chipOn ? "分布开" : "分布关"} · 桶宽 ${bucketStep.toStringAsFixed(2)}',
          searchTerms: '筹码 笔数 峰 桶宽 数学 指标 参数',
          children: _distributionChildren(),
        ),
        SettingsDeskSection(
          title: '研究',
          railLabel: '研究',
          icon: Icons.science_outlined,
          summary: researchBits.isEmpty ? '回测 · 寻优 · 计优' : researchBits.join(' · '),
          searchTerms: '分析与指标 回测 寻优 计优 机器学习 学习 策略',
          children: _researchChildren(),
        ),
        SettingsDeskSection(
          title: '工作台',
          railLabel: '工作台',
          icon: Icons.tune,
          summary:
              '${AppThemeController.instance.mode.label} · ${useAndroid ? "安卓" : "Windows"}',
          searchTerms: '界面与操作 维护与同步 主题 暖色 亮度 交互 同步 排查 复制',
          children: _benchChildren(),
        ),
      ],
    );
  }

  List<Widget> _marketChildren() {
    return [
      const SettingsGroupLabel('标的'),
      if (forMobileSheet)
        SettingsOutlinedButton(
          label: selectedCode == null
              ? '选择股票 (${codes.length})'
              : '股票：$selectedCode',
          icon: Icons.list_alt,
          onPressed: bootstrapping || busy || codes.isEmpty ? null : onPickStock,
        )
      else
        DropdownButtonFormField<String>(
          key: ValueKey(selectedCode),
          isExpanded: true,
          onTap: onRefreshStocks,
          initialValue: codes.contains(selectedCode) ? selectedCode : null,
          hint: Text(codes.isEmpty ? '无股票' : '选择股票'),
          decoration: InputDecoration(
            labelText: '股票 (${codes.length})',
            isDense: true,
            border: const OutlineInputBorder(),
          ),
          items: [
            for (final code in codes)
              DropdownMenuItem(
                value: code,
                child: Text(code, overflow: TextOverflow.ellipsis),
              ),
          ],
          onChanged: bootstrapping || codes.isEmpty
              ? null
              : (value) {
                  if (value != null) onStockSelected(value);
                },
        ),
      DropdownButtonFormField<String>(
        key: ValueKey(period),
        isExpanded: true,
        initialValue: periods.containsKey(period) ? period : 'tick',
        decoration: InputDecoration(
          labelText: '周期',
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIconConstraints: const BoxConstraints(minWidth: 32, minHeight: 32),
          suffixIcon: settingsHelpIcon(
            onPressed: onPeriodHelp,
            tooltip: '周期说明',
          ),
        ),
        items: [
          for (final entry in periods.entries)
            DropdownMenuItem(
              value: entry.key,
              child: Text(entry.value, overflow: TextOverflow.ellipsis),
            ),
        ],
        onChanged: bootstrapping
            ? null
            : (value) => onPeriodSelected(value ?? 'tick'),
      ),
      const SettingsGroupLabel('区间'),
      _dateField(label: '加载起始时间', value: beginText, onTap: onPickBegin),
      _dateField(label: '加载截止时间', value: endText, onTap: onPickEnd),
      if (selectedCode == 'test') ...[
        const SettingsGroupLabel('自定义'),
        SettingsOutlinedButton(
          label: '编辑/加载自定义 OHLC',
          icon: Icons.edit_note,
          onPressed: onEditOhlc,
          onHelp: onOhlcHelp,
          helpTooltip: '自定义 OHLC 说明',
        ),
        SettingsOutlinedButton(
          label: '分笔画板',
          icon: Icons.gesture,
          onPressed: onTickDraw,
          onHelp: onTickDrawHelp,
          helpTooltip: '分笔画板说明',
        ),
        SettingsOutlinedButton(
          label: 'K线画板',
          icon: Icons.candlestick_chart,
          onPressed: onKlineDraw,
          onHelp: onKlineDrawHelp,
          helpTooltip: 'K线画板说明',
        ),
      ],
      const SettingsGroupLabel('数据源'),
      SettingsOutlinedButton(
        label: telegramEnabled ? 'Telegram 数据源（已启用日线）' : 'Telegram 数据源',
        icon: Icons.cloud_download_outlined,
        onPressed: onTelegram,
      ),
      SettingsReveal(
        title: '全市场分笔上传',
        subtitle: '两机共享进度，点开再读取',
        child: TicksFullUploadPanel(
          settings: telegramSettings,
          dataRoot: dataRoot,
          onCreateTask: onCreateUploadTask,
          onShareDir: onShareDir,
        ),
      ),
    ];
  }

  List<Widget> _structureChildren() {
    return [
      const SettingsGroupLabel('合并口径'),
      SettingsSwitchRow(
        label: '截断机制',
        value: truncationOn,
        subtitle: truncationOn ? '已开启（当前口径）' : '已关闭（旧吸收行为）',
        helpTooltip: '截断机制说明',
        onHelp: onTruncationHelp,
        onChanged: onTruncation,
      ),
      SettingsChoiceCards<PreFirstFractalUnitMode>(
        label: '层级早生成 / 首分型前合并框',
        helper: unitMode.shortHint,
        layout: SettingsChoiceLayout.grid,
        value: unitMode,
        helpTooltip: '层级早生成 / 首分型前合并框说明',
        onHelp: onUnitHelp,
        onChanged: onUnitMode,
        options: [
          for (final mode in PreFirstFractalUnitMode.values)
            SettingsChoiceOption(
              value: mode,
              title: _unitShort(mode),
              tooltip: mode.label,
            ),
        ],
      ),
      SettingsSwitchRow(
        label: '构建中/未确认虚线',
        value: buildingDash,
        subtitle: buildingDash ? '已开启（构建中元素虚线）' : '已关闭（全部实线）',
        helpTooltip: '构建中/未确认虚线说明',
        onHelp: onBuildingHelp,
        onChanged: onBuildingDash,
      ),
      const SettingsGroupLabel('层级分窗'),
      SettingsSwitchRow(
        label: '层级分窗',
        value: levelEnabled,
        subtitle: levelEnabled
            ? '已开启（$levelCount 窗，每窗都能步进/缩放）'
            : '已关闭（单图集成，与原来完全一致）',
        helpTooltip: '层级分窗说明',
        onHelp: onLevelHelp,
        onChanged: onLevelEnabled,
      ),
      SettingsLinkRow(
        title: '窗口数量与每窗层级',
        subtitle: levelEnabled
            ? '当前：$levelLabel'
            : '开关关闭时不可调；请先打开上面的层级分窗',
        icon: Icons.grid_view,
        enabled: levelEnabled,
        onTap: onEditLevel,
      ),
      const SettingsGroupLabel('标记'),
      SettingsSwitchRow(
        label: 'BSP对错叠加X',
        value: bspOverlay,
        subtitle: bspOverlay
            ? '已开启（错标叠加X，对的不叠加）'
            : '已关闭（只显示原 Kn类BS 标记）',
        helpTooltip: 'BSP对错叠加说明',
        onHelp: onBspHelp,
        onChanged: onBsp,
      ),
    ];
  }

  List<Widget> _distributionChildren() {
    return [
      const SettingsGroupLabel('筹码与笔数'),
      SettingsSwitchRow(
        label: '筹码 / 笔数分布',
        value: chipOn,
        subtitle: chipOn ? '已开启（右侧筹码 + 左侧笔数，仅 K0）' : '已关闭',
        helpTooltip: '筹码/笔数分布说明',
        onHelp: onChipHelp,
        onChanged: onChip,
      ),
      SettingsSwitchRow(
        label: '峰延长线',
        value: peakOn,
        subtitle: peakOn ? '已开启（±1同色、±2同色…；框内 INn 另色）' : '已关闭',
        onChanged: peakEditable ? onPeak : null,
      ),
      SettingsBucketField(
        step: bucketStep,
        enabled: !busy,
        onSubmit: onBucketSubmitted,
      ),
      const SettingsGroupLabel('数学指标'),
      SettingsLinkRow(
        title: '数学指标参数',
        subtitle: '均线、通道、布林、MACD、Demark、背驰率',
        icon: Icons.functions,
        enabled: onMath != null,
        onTap: onMath,
        trailing: Icons.tune,
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton.icon(
          onPressed: onMathHelp,
          icon: const Icon(Icons.help_outline, size: 16),
          label: const Text('数学指标说明'),
        ),
      ),
    ];
  }

  List<Widget> _researchChildren() {
    return [
      SettingsCommandTile(
        title: backtestOpen ? '策略回测（已打开）' : '策略回测',
        subtitle: '用当前冻结账回放买卖',
        icon: Icons.show_chart,
        onPressed: onBacktest,
      ),
      SettingsCommandTile(
        title: searchRunning ? '寻优（进行中）' : '寻优',
        subtitle: '在已经走完的区间里找指标组合',
        icon: Icons.travel_explore,
        emphasized: true,
        onPressed: onSearch,
        onHelp: onSearchHelp,
        helpTooltip: '指标寻优说明',
        footer: Row(
          children: [
            Flexible(
              child: TextButton(
                onPressed: onLastSearch,
                child: const Text('上次寻优结果', overflow: TextOverflow.ellipsis),
              ),
            ),
            Flexible(
              child: TextButton(
                onPressed: onSearchParams,
                child: const Text('寻优参数', overflow: TextOverflow.ellipsis),
              ),
            ),
          ],
        ),
      ),
      SettingsCommandTile(
        title: statRunning ? '计优（进行中）' : '计优',
        subtitle: '统计各级别转折点上的指标',
        icon: Icons.analytics_outlined,
        emphasized: true,
        onPressed: onStats,
        onHelp: onStatsHelp,
        helpTooltip: '计优说明',
        footer: Align(
          alignment: Alignment.centerRight,
          child: TextButton(
            onPressed: onStatsParams,
            child: const Text('计优参数'),
          ),
        ),
      ),
      SettingsCommandTile(
        title: mlActive ? '机器学习（进行中）' : '机器学习',
        subtitle: mlActive ? '会话进行中，先退出再做别的研究' : '按当前股票训练、验证、测试',
        icon: Icons.psychology,
        emphasized: true,
        onPressed: onMl,
        onHelp: onMlHelp,
        helpTooltip: '机器学习说明',
      ),
      if (mlActive)
        SettingsOutlinedButton(
          label: '退出机器学习',
          icon: Icons.exit_to_app,
          onPressed: onExitMl,
        ),
    ];
  }

  List<Widget> _benchChildren() {
    final auto = interactionOverride == null;
    final interactionHelper = auto
        ? '自动：当前为${useAndroid ? "安卓" : "Windows"}交互'
        : (useAndroid ? '手动：安卓手势与布局' : '手动：Windows手势与布局');
    return [
      const SettingsGroupLabel('外观'),
      const ThemeChooser(),
      const SettingsGroupLabel('交互'),
      SettingsChoiceCards<bool?>(
        label: '交互模式',
        helper: interactionHelper,
        value: interactionOverride,
        onChanged: busy ? null : onInteraction,
        options: const [
          SettingsChoiceOption(value: null, title: '跟随系统', tooltip: '跟随系统自动'),
          SettingsChoiceOption(value: true, title: '安卓', tooltip: '安卓操作逻辑'),
          SettingsChoiceOption(value: false, title: 'Windows', tooltip: 'Windows操作逻辑'),
        ],
      ),
      const SettingsGroupLabel('维护'),
      SettingsOutlinedButton(
        label: '复制排查信息',
        icon: Icons.summarize,
        onPressed: onProbe,
      ),
      Text(
        '弹窗查看整合全文，底部「复制」一键带走；含页面状态、最近历史与验收探针，已去重精简。',
        style: TextStyle(fontSize: 11, height: 1.3, color: AppPalette.textSecondary),
      ),
      SettingsFilledButton(
        label: '双机同步',
        icon: Icons.sync,
        onPressed: onSync,
      ),
      Text(
        syncLine,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(fontSize: 11, height: 1.3, color: AppPalette.textSecondary),
      ),
    ];
  }

  Widget _dateField({
    required String label,
    required String value,
    required VoidCallback? onTap,
  }) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(8),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          isDense: true,
          border: const OutlineInputBorder(),
          suffixIcon: Icon(
            Icons.calendar_today,
            size: 16,
            color: AppPalette.textSecondary,
          ),
        ),
        child: Text(
          value,
          style: TextStyle(fontSize: 12, color: AppPalette.textPrimary),
        ),
      ),
    );
  }
}

/// 筹码桶宽。回车或点到输入框外面都会提交，避免只改了字、口径没落地。
class SettingsBucketField extends StatefulWidget {
  const SettingsBucketField({
    super.key,
    required this.step,
    required this.enabled,
    required this.onSubmit,
  });

  final double step;
  final bool enabled;
  final ValueChanged<String> onSubmit;

  @override
  State<SettingsBucketField> createState() => _SettingsBucketFieldState();
}

class _SettingsBucketFieldState extends State<SettingsBucketField> {
  late final TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.step.toStringAsFixed(2));
  }

  @override
  void didUpdateWidget(SettingsBucketField oldWidget) {
    super.didUpdateWidget(oldWidget);
    final next = widget.step.toStringAsFixed(2);
    if (oldWidget.step != widget.step && _controller.text != next) {
      _controller.text = next;
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  void _commit() {
    final next = _controller.text.trim();
    if (next == widget.step.toStringAsFixed(2)) return;
    widget.onSubmit(next);
  }

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: _controller,
      enabled: widget.enabled,
      decoration: const InputDecoration(
        labelText: '筹码分布桶宽',
        helperText: '最小 0.01，回车或点到外面生效；筹码和笔数分布共用',
        helperMaxLines: 2,
        isDense: true,
        border: OutlineInputBorder(),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      onFieldSubmitted: (_) => _commit(),
      onTapOutside: (_) => _commit(),
    );
  }
}
