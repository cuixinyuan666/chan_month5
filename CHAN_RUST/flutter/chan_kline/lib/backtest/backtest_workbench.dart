import 'package:flutter/material.dart';

import '../compute/math_series_freeze_store.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'backtest_report_panel.dart';
import 'backtest_run.dart';
import 'order_models.dart';
import 'signal_event.dart';
import 'strategy_config.dart';
import 'strategy_config_form.dart';

/// 策略回测工作台：左侧配置，右侧报告。图表仍在上面，这里不重算。
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
  final BacktestReportTab tab;
  final ValueChanged<BacktestReportTab> onTab;
  final String? selectedSignalId;
  final String? selectedTradeId;
  final ValueChanged<TradeRecord> onSelectTrade;
  final ValueChanged<SignalEvent> onSelectSignal;
  final ValueChanged<int> onJumpX;
  final int? focusX;
  final List<LevelBundle> levels;
  final MathSeriesFreezeStore? mathFreeze;

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
  });

  @override
  Widget build(BuildContext context) {
    final stale = run != null &&
        run!.ok &&
        run!.sourceRange.asOfX != currentStepIdx;
    return Material(
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
                  '策略回测工作台',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                const Spacer(),
                if (onHelp != null)
                  IconButton(
                    tooltip: '说明',
                    onPressed: onHelp,
                    icon: const Icon(Icons.help_outline, size: 18),
                  ),
                IconButton(
                  tooltip: '收起',
                  onPressed: onClose,
                  icon: const Icon(Icons.expand_more, size: 20),
                ),
              ],
            ),
          ),
          const Divider(height: 1),
          if (stale)
            const Padding(
              padding: EdgeInsets.fromLTRB(10, 4, 10, 0),
              child: Text(
                'K 线已继续走，这是上一轮结果。要按当前根重跑，再点一次运行回测。',
                style: TextStyle(fontSize: 11, color: Color(0xFFFFB74D)),
              ),
            ),
          Expanded(
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                SizedBox(
                  width: 400,
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.fromLTRB(10, 8, 8, 8),
                    child: StrategyConfigForm(
                      config: config,
                      maxKn: maxKn,
                      onChanged: onConfigChanged,
                      onRun: onRun,
                      running: running,
                      bars: bars,
                      levels: levels,
                      mathFreeze: mathFreeze,
                      asOf: currentStepIdx,
                    ),
                  ),
                ),
                const VerticalDivider(width: 1),
                Expanded(
                  child: run == null
                      ? const Center(
                          child: Text(
                            '搭好买卖条件后点运行回测。图上的策买/策卖来自这一次结果，不会另算一遍。',
                            style: TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
                          ),
                        )
                      : BacktestReportPanel(
                          run: run!,
                          bars: bars,
                          tab: tab,
                          onTab: onTab,
                          selectedSignalId: selectedSignalId,
                          selectedTradeId: selectedTradeId,
                          onSelectTrade: onSelectTrade,
                          onSelectSignal: onSelectSignal,
                          onJumpX: onJumpX,
                          focusX: focusX,
                        ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}
