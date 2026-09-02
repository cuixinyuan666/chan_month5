import 'package:flutter/material.dart';

import '../compute/math_series_freeze_store.dart';
import '../models/bar_feature_lookup.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'backtest_report_panel.dart';
import 'backtest_run.dart';
import 'chan_event_store.dart';
import 'chart_line_store.dart';
import 'chip_peak_store.dart';
import 'divergence_relation_store.dart';
import 'order_models.dart';
import 'signal_event.dart';
import 'strategy_config.dart';
import 'strategy_config_form.dart';
import 'zhongshu_object_store.dart';

export 'backtest_report_panel.dart'
    show BacktestReportTab, BacktestWorkbenchTab, reportTabOf;

/// 桌面自绘标题条高度（与 main 顶栏最小/最大/关闭一致）。
const kDesktopCaptionBarHeight = 36.0;

/// 桌面图表区四周留白（与 main Padding 一致）。
const kDesktopShellInset = 4.0;

/// 右侧工作台整块再下移：先对齐标题条下沿，再留 4 缝，避免运行/关闭挡住窗控。
const kDesktopBacktestWorkbenchTopInset =
    kDesktopCaptionBarHeight - kDesktopShellInset + 4.0;

/// 策略回测工作台：顶栏标签一次只开一页；桌面与 K 线左右排时占右侧。
class BacktestWorkbench extends StatelessWidget {
  final StrategyConfig config;
  final int maxKn;
  final ValueChanged<StrategyConfig> onConfigChanged;
  final ValueChanged<StrategyConfig> onRun;
  final VoidCallback onClose;
  final VoidCallback? onHelp;
  final bool running;
  final BacktestRun? run;
  final List<KlineBar> bars;
  final int currentStepIdx;
  final BacktestWorkbenchTab tab;
  final ValueChanged<BacktestWorkbenchTab> onTab;
  final String? selectedSignalId;
  final String? selectedTradeId;
  final ValueChanged<TradeRecord> onSelectTrade;
  final ValueChanged<SignalEvent> onSelectSignal;
  final ValueChanged<int> onJumpX;
  final int? focusX;
  final List<LevelBundle> levels;
  final MathSeriesFreezeStore? mathFreeze;
  final ChanEventStore chanEvents;
  final ZhongshuObjectStore? zsObjects;
  final DivergenceRelationStore? diverRelations;
  final ChartLineStore? lineSeries;
  final BarFeatureLookup? features;
  final ChipPeakFreezeStore? chipPeaks;
  final double bucketStep;
  /// 与 K 线图 mobileLayout 一致：窄屏仍可竖向贴在图下。
  final bool compactLayout;

  const BacktestWorkbench({
    super.key,
    required this.config,
    required this.maxKn,
    required this.onConfigChanged,
    required this.onRun,
    required this.onClose,
    this.onHelp,
    this.running = false,
    required this.run,
    required this.bars,
    required this.currentStepIdx,
    required this.tab,
    required this.onTab,
    required this.selectedSignalId,
    required this.selectedTradeId,
    required this.onSelectTrade,
    required this.onSelectSignal,
    required this.onJumpX,
    this.focusX,
    this.levels = const [],
    this.mathFreeze,
    this.chanEvents = ChanEventStore.empty,
    this.zsObjects,
    this.diverRelations,
    this.lineSeries,
    this.features,
    this.chipPeaks,
    this.bucketStep = 0.1,
    this.compactLayout = false,
  });

  @override
  Widget build(BuildContext context) {
    final stale = run != null &&
        run!.ok &&
        run!.sourceRange.asOfX != currentStepIdx;
    final reportTab = reportTabOf(tab);

    final panel = Material(
      color: const Color(0xF01A1A1A),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          SizedBox(
            height: 36,
            child: Row(
              children: [
                const SizedBox(width: 10),
                const Text(
                  '策略回测',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                FilledButton.tonalIcon(
                  onPressed: running ? null : () => onRun(config),
                  icon: Icon(running ? Icons.hourglass_empty : Icons.play_arrow,
                      size: 16),
                  label: Text(running ? '回测中' : '运行',
                      style: const TextStyle(fontSize: 12)),
                  style: FilledButton.styleFrom(
                    visualDensity: VisualDensity.compact,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                  ),
                ),
                if (onHelp != null)
                  IconButton(
                    tooltip: '说明',
                    onPressed: onHelp,
                    icon: const Icon(Icons.help_outline, size: 18),
                  ),
                IconButton(
                  key: const Key('backtestWorkbenchClose'),
                  tooltip: '关闭',
                  onPressed: onClose,
                  icon: const Icon(Icons.close, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          _tabBar(),
          if (stale)
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 4, 10, 0),
              child: Text(
                'K 线已继续走，这是上一轮结果。要按当前根重跑，再点一次运行。',
                style: TextStyle(fontSize: 11, color: Color(0xFFFFB74D)),
              ),
            ),
          Expanded(
            child: reportTab == null
                ? SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                    child: StrategyConfigForm(
                      config: config,
                      maxKn: maxKn,
                      onChanged: onConfigChanged,
                      onRun: onRun,
                      running: running,
                      section: tab == BacktestWorkbenchTab.conditions
                          ? StrategyFormSection.conditions
                          : StrategyFormSection.capital,
                      showRunButton: false,
                      bars: bars,
                      levels: levels,
                      mathFreeze: mathFreeze,
                      chanEvents: chanEvents,
                      zsObjects: zsObjects,
                      diverRelations: diverRelations,
                      lineSeries: lineSeries,
                      features: features,
                      chipPeaks: chipPeaks,
                      bucketStep: bucketStep,
                      asOf: currentStepIdx,
                    ),
                  )
                : (run == null
                    ? const Center(
                        child: Text(
                          '搭好买卖条件后点运行。图上买/卖按组显示在发现当根，被拒的不画。',
                          style:
                              TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                        ),
                      )
                    : BacktestReportPanel(
                        run: run!,
                        bars: bars,
                        tab: reportTab,
                        onTab: (_) {},
                        showTabBar: false,
                        selectedSignalId: selectedSignalId,
                        selectedTradeId: selectedTradeId,
                        onSelectTrade: onSelectTrade,
                        onSelectSignal: onSelectSignal,
                        onJumpX: onJumpX,
                        focusX: focusX,
                      )),
          ),
        ],
      ),
    );
    // 电脑：整块台子下移，不挡窗口最小/最大/关闭；手机贴在图下不必再挪。
    if (compactLayout) return panel;
    return Padding(
      key: const Key('backtestWorkbenchDesktopInset'),
      padding: const EdgeInsets.only(top: kDesktopBacktestWorkbenchTopInset),
      child: panel,
    );
  }

  Widget _tabBar() {
    Widget chip(BacktestWorkbenchTab t, String label) {
      final on = tab == t;
      return Padding(
        padding: const EdgeInsets.only(right: 6),
        child: ChoiceChip(
          label: Text(label, style: const TextStyle(fontSize: 12)),
          selected: on,
          onSelected: (_) => onTab(t),
          visualDensity: VisualDensity.compact,
        ),
      );
    }

    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.fromLTRB(8, 4, 8, 4),
      child: Row(
        children: [
          chip(BacktestWorkbenchTab.conditions, '条件'),
          chip(BacktestWorkbenchTab.capital, '资金'),
          chip(BacktestWorkbenchTab.metrics, '指标'),
          chip(BacktestWorkbenchTab.equity, '净值'),
          chip(BacktestWorkbenchTab.trades, '交易'),
          chip(BacktestWorkbenchTab.chain, '链路'),
          chip(BacktestWorkbenchTab.attribution, '归因'),
        ],
      ),
    );
  }
}
