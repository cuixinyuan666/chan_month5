import 'package:flutter/material.dart';

import '../models/kline_bar.dart';
import 'backtest_link.dart';
import 'backtest_result.dart';
import 'backtest_run.dart';
import 'equity_curve.dart';
import 'equity_curve_chart.dart';
import 'metric_format.dart';
import 'order_models.dart';
import 'signal_event.dart';
import 'strategy_signal_painter.dart';

enum BacktestReportTab { metrics, equity, trades, chain, attribution }

/// 工作台顶栏标签：条件/资金 + 报告各页，一次只开一页。
enum BacktestWorkbenchTab {
  conditions,
  capital,
  metrics,
  equity,
  trades,
  chain,
  attribution,
}

BacktestReportTab? reportTabOf(BacktestWorkbenchTab t) => switch (t) {
      BacktestWorkbenchTab.metrics => BacktestReportTab.metrics,
      BacktestWorkbenchTab.equity => BacktestReportTab.equity,
      BacktestWorkbenchTab.trades => BacktestReportTab.trades,
      BacktestWorkbenchTab.chain => BacktestReportTab.chain,
      BacktestWorkbenchTab.attribution => BacktestReportTab.attribution,
      _ => null,
    };

/// 把 BacktestResult 端出来：指标卡 / 净值 / 交易 / 信号订单链路。不重算。
class BacktestReportPanel extends StatelessWidget {
  final BacktestRun run;
  final List<KlineBar> bars;
  final BacktestReportTab tab;
  final ValueChanged<BacktestReportTab> onTab;
  /// false：外层工作台已有标签，这里不再画一排 chip。
  final bool showTabBar;
  final String? selectedSignalId;
  final String? selectedTradeId;
  final ValueChanged<TradeRecord> onSelectTrade;
  final ValueChanged<SignalEvent> onSelectSignal;
  final ValueChanged<int> onJumpX;
  final int? focusX;

  const BacktestReportPanel({
    super.key,
    required this.run,
    required this.bars,
    required this.tab,
    required this.onTab,
    required this.selectedSignalId,
    required this.selectedTradeId,
    required this.onSelectTrade,
    required this.onSelectSignal,
    required this.onJumpX,
    this.focusX,
    this.showTabBar = true,
  });

  @override
  Widget build(BuildContext context) {
    final result = run.result;
    if (run.error != null || result == null) {
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          run.error ?? '还没有回测结果',
          style: const TextStyle(color: Color(0xFFFFB74D), fontSize: 13),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        if (showTabBar) _tabBar(),
        Expanded(child: _body(result)),
      ],
    );
  }

  Widget _tabBar() {
    Widget chip(BacktestReportTab t, String label) {
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
          chip(BacktestReportTab.metrics, '指标'),
          chip(BacktestReportTab.equity, '净值/回撤'),
          chip(BacktestReportTab.trades, '交易'),
          chip(BacktestReportTab.chain, '信号链路'),
          chip(BacktestReportTab.attribution, '归因'),
        ],
      ),
    );
  }

  Widget _body(BacktestResult result) {
    return switch (tab) {
      BacktestReportTab.metrics => _metrics(result),
      BacktestReportTab.equity => _equity(result),
      BacktestReportTab.trades => _trades(result),
      BacktestReportTab.chain => _chain(result),
      BacktestReportTab.attribution => _attribution(result),
    };
  }

  Widget _metrics(BacktestResult result) {
    final m = result.metrics;
    String ddRange() {
      final a = m.maxDrawdownStartX;
      final b = m.maxDrawdownEndX;
      if (a == null || b == null) return '无回撤';
      final rec = m.recoveryX == null ? '未回到前高' : '回到前高@${m.recoveryX}';
      return 'K$a → K$b（$rec）';
    }

    return ListView(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      children: [
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: [
            _card('净利润', formatMoney(m.netProfit)),
            _card('收益率', formatPctFraction(m.returnPct)),
            _card('胜率', formatPctFraction(m.winRate)),
            _card('盈亏比', formatMetricNum(m.payoffRatio)),
            _card('Profit Factor', formatMetricNum(m.profitFactor)),
            _card(
              '最大回撤',
              '${formatMoney(m.maxDrawdown)}  ${formatPctFraction(MetricNum.finite(m.maxDrawdownPct))}',
            ),
          ],
        ),
        const SizedBox(height: 8),
        Text(
          '回撤区间 $ddRange · 已平仓 ${m.totalTrades} 笔'
          '${result.openPosition == null ? '' : ' · 期末仍持仓（浮盈已计入净值）'}',
          style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
        ),
        Text(
          '引擎 ${run.engineVersion} · ${run.runId}'
          '${run.context == null ? '' : ' · 策略${run.context!.strategyVersion} · 契约${run.context!.dataContractVersion} · 结构${run.context!.structureSemanticVersion}'}',
          style: const TextStyle(fontSize: 10, color: Color(0xFF64748B)),
        ),
      ],
    );
  }

  Widget _card(String title, String value) {
    return Container(
      width: 148,
      padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(title, style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          const SizedBox(height: 4),
          Text(
            value,
            style: const TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w700,
              color: Color(0xFFF8FAFC),
            ),
          ),
        ],
      ),
    );
  }

  Widget _equity(BacktestResult result) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
      child: Column(
        children: [
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('净值（直接用回测曲线）', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          ),
          Expanded(
            child: EquityCurveChart(
              curve: result.equityCurve,
              metrics: result.metrics,
              focusX: focusX,
              onTapX: onJumpX,
            ),
          ),
          const Align(
            alignment: Alignment.centerLeft,
            child: Text('回撤（同一条净值上的峰-当前）', style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8))),
          ),
          Expanded(
            child: DrawdownCurveChart(
              curve: result.equityCurve,
              metrics: result.metrics,
            ),
          ),
        ],
      ),
    );
  }

  Widget _trades(BacktestResult result) {
    if (result.trades.isEmpty) {
      final open = result.openPosition;
      return Padding(
        padding: const EdgeInsets.all(12),
        child: Text(
          open == null
              ? '没有闭合交易'
              : '没有闭合交易，期末仍持仓 数量${open.quantity} 浮盈 ${formatMoney(open.unrealizedPnL)}',
          style: const TextStyle(color: Color(0xFF94A3B8), fontSize: 13),
        ),
      );
    }
    final link = BacktestLinkIndex(result);
    const headerStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF94A3B8),
    );
    const cellStyle = TextStyle(fontSize: 11, color: Color(0xFFE2E8F0));
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Table(
                columnWidths: const {
                  0: FixedColumnWidth(72),
                  1: FixedColumnWidth(72),
                  2: FixedColumnWidth(52),
                  3: FixedColumnWidth(52),
                  4: FixedColumnWidth(64),
                  5: FixedColumnWidth(52),
                  6: FixedColumnWidth(52),
                  7: FixedColumnWidth(64),
                  8: FixedColumnWidth(44),
                  9: FixedColumnWidth(64),
                  10: FixedColumnWidth(56),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                border: TableBorder(
                  horizontalInside: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  verticalInside: BorderSide(
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: Color(0xFF1E293B)),
                    children: [
                      _th('组', headerStyle),
                      _th('净利', headerStyle),
                      _th('信号K入', headerStyle),
                      _th('成交K入', headerStyle),
                      _th('入价', headerStyle),
                      _th('信号K出', headerStyle),
                      _th('成交K出', headerStyle),
                      _th('出价', headerStyle),
                      _th('数量', headerStyle),
                      _th('毛利', headerStyle),
                      _th('费用', headerStyle),
                    ],
                  ),
                  for (var i = 0; i < result.trades.length; i++)
                    _tradeRow(
                      i: i,
                      t: result.trades[i],
                      link: link,
                      selected: result.trades[i].tradeId == selectedTradeId,
                      cellStyle: cellStyle,
                      onTap: () => onSelectTrade(result.trades[i]),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  TableRow _tradeRow({
    required int i,
    required TradeRecord t,
    required BacktestLinkIndex link,
    required bool selected,
    required TextStyle cellStyle,
    required VoidCallback onTap,
  }) {
    final entrySig = link.entrySignalOf(t);
    final exitSig = link.exitSignalOf(t);
    final groupLabel = link.rounds.tradeGroupLabel(t);
    final pnlColor =
        t.netPnL >= 0 ? kStrategyBuyColor : const Color(0xFFFF8A65);
    return TableRow(
      decoration: BoxDecoration(
        color: selected ? const Color(0x334FC3F7) : null,
      ),
      children: [
        _tdTap(
          onTap,
          Text(
            groupLabel,
            style: cellStyle.copyWith(fontWeight: FontWeight.w600),
          ),
        ),
        _tdTap(
          onTap,
          Text(
            formatMoney(t.netPnL),
            style: cellStyle.copyWith(color: pnlColor, fontWeight: FontWeight.w600),
          ),
        ),
        _tdTap(onTap, Text('${entrySig?.discoveryX ?? '-'}', style: cellStyle)),
        _tdTap(onTap, Text('${t.entryX}', style: cellStyle)),
        _tdTap(onTap, Text(t.entryPrice.toStringAsFixed(3), style: cellStyle)),
        _tdTap(onTap, Text('${exitSig?.discoveryX ?? '-'}', style: cellStyle)),
        _tdTap(onTap, Text('${t.exitX}', style: cellStyle)),
        _tdTap(onTap, Text(t.exitPrice.toStringAsFixed(3), style: cellStyle)),
        _tdTap(onTap, Text('${t.quantity}', style: cellStyle)),
        _tdTap(onTap, Text(formatMoney(t.grossPnL), style: cellStyle)),
        _tdTap(
          onTap,
          Text(
            formatMoney(t.commission + t.slippage),
            style: cellStyle,
          ),
        ),
      ],
    );
  }

  Widget _chain(BacktestResult result) {
    final link = BacktestLinkIndex(result);
    final sigs = result.signals;
    if (sigs.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text('没有策略信号', style: TextStyle(color: Color(0xFF94A3B8))),
      );
    }
    const headerStyle = TextStyle(
      fontSize: 11,
      fontWeight: FontWeight.w600,
      color: Color(0xFF94A3B8),
    );
    const cellStyle = TextStyle(fontSize: 11, color: Color(0xFFE2E8F0));
    const condStyle = TextStyle(
      fontSize: 10,
      color: Color(0xFFCBD5E1),
      height: 1.3,
    );
    return LayoutBuilder(
      builder: (context, constraints) {
        return SingleChildScrollView(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: ConstrainedBox(
              constraints: BoxConstraints(minWidth: constraints.maxWidth),
              child: Table(
                columnWidths: const {
                  0: FixedColumnWidth(40),
                  1: FixedColumnWidth(44),
                  2: FixedColumnWidth(108),
                  3: FixedColumnWidth(72),
                  4: FixedColumnWidth(44),
                  5: FixedColumnWidth(64),
                  6: FixedColumnWidth(52),
                  7: FixedColumnWidth(72),
                  8: FlexColumnWidth(2),
                },
                defaultVerticalAlignment: TableCellVerticalAlignment.middle,
                border: TableBorder(
                  horizontalInside: BorderSide(
                    color: Colors.white.withValues(alpha: 0.08),
                  ),
                  verticalInside: BorderSide(
                    color: Colors.white.withValues(alpha: 0.05),
                  ),
                ),
                children: [
                  TableRow(
                    decoration: const BoxDecoration(color: Color(0xFF1E293B)),
                    children: [
                      _th('方向', headerStyle),
                      _th('信号K', headerStyle),
                      _th('时间', headerStyle),
                      _th('订单', headerStyle),
                      _th('成交K', headerStyle),
                      _th('成交价', headerStyle),
                      _th('组', headerStyle),
                      _th('净利', headerStyle),
                      _th('条件', headerStyle),
                    ],
                  ),
                  for (final s in sigs)
                    _chainRow(
                      s: s,
                      link: link,
                      selected: s.signalId == selectedSignalId,
                      cellStyle: cellStyle,
                      condStyle: condStyle,
                      onTap: () => onSelectSignal(s),
                    ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  TableRow _chainRow({
    required SignalEvent s,
    required BacktestLinkIndex link,
    required bool selected,
    required TextStyle cellStyle,
    required TextStyle condStyle,
    required VoidCallback onTap,
  }) {
    final side = s.side;
    final o = link.orderForSignal(s.signalId);
    final f = link.fillForSignal(s.signalId);
    final t = link.tradeForSignal(s.signalId);
    final sideLabel = link.rounds.sideLabel(s);
    final sideColor =
        side == null ? const Color(0xFF94A3B8) : strategySideColor(side);
    return TableRow(
      decoration: BoxDecoration(
        color: selected ? const Color(0x33D500F9) : null,
      ),
      children: [
        _tdTap(
          onTap,
          Text(
            sideLabel,
            style: cellStyle.copyWith(
              color: sideColor,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        _tdTap(onTap, Text('${s.discoveryX}', style: cellStyle)),
        _tdTap(onTap, Text(_time(s.discoveryX), style: cellStyle)),
        _tdTap(
          onTap,
          Text(o == null ? '无订单' : _orderStatus(o), style: cellStyle),
        ),
        _tdTap(
          onTap,
          Text(f == null ? '-' : '${f.executeX}', style: cellStyle),
        ),
        _tdTap(
          onTap,
          Text(f == null ? '-' : f.price.toStringAsFixed(3), style: cellStyle),
        ),
        _tdTap(
          onTap,
          Text(
            t == null ? '-' : link.rounds.tradeGroupShort(t),
            style: cellStyle,
          ),
        ),
        _tdTap(
          onTap,
          Text(
            t == null ? '-' : formatMoney(t.netPnL),
            style: cellStyle.copyWith(
              color: t == null
                  ? const Color(0xFF94A3B8)
                  : (t.netPnL >= 0
                      ? kStrategyBuyColor
                      : const Color(0xFFFF8A65)),
            ),
          ),
        ),
        _tdTap(
          onTap,
          Text(s.explainBlock, style: condStyle, maxLines: 3, overflow: TextOverflow.ellipsis),
        ),
      ],
    );
  }

  static Widget _th(String text, TextStyle style) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
      child: Text(text, style: style),
    );
  }

  static Widget _tdTap(VoidCallback onTap, Widget child) {
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
        child: child,
      ),
    );
  }

  Widget _attribution(BacktestResult result) {
    final rows = result.rulePerformances;
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(12),
        child: Text(
          '没有规则归因。先跑出信号后，这里会按买/卖条件分别统计。',
          style: TextStyle(color: Color(0xFF94A3B8)),
        ),
      );
    }
    return ListView.builder(
      padding: const EdgeInsets.fromLTRB(10, 4, 10, 8),
      itemCount: rows.length,
      itemBuilder: (ctx, i) {
        final p = rows[i];
        final side = p.side == TradeSide.buy ? '买规则' : '卖规则';
        return Card(
          color: const Color(0xFF1E293B),
          margin: const EdgeInsets.only(bottom: 8),
          child: Padding(
            padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '$side  ${p.ruleId}',
                  style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
                ),
                const SizedBox(height: 4),
                Text(
                  p.label,
                  style: const TextStyle(fontSize: 12, height: 1.35),
                ),
                const SizedBox(height: 6),
                Text(
                  '信号 ${p.signalCount}  · 接单 ${p.acceptedOrderCount}  · 成交 ${p.filledCount}  · 闭合 ${p.tradeCount}\n'
                  '胜率 ${formatPctFraction(p.winRate)}  · 净 ${formatMoney(p.netProfit)}  · 笔均 ${formatMetricNum(p.avgTrade)}  · PF ${formatMetricNum(p.profitFactor)}',
                  style: const TextStyle(fontSize: 11, color: Color(0xFFCBD5E1), height: 1.4),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  String _time(int x) {
    final b = klineBarByIdx(bars, x);
    if (b == null) return 'K$x';
    return b.timeText.isEmpty ? 'K$x' : b.timeText;
  }

  String _orderStatus(Order o) {
    return switch (o.status) {
      OrderStatus.filled => '已成交',
      OrderStatus.rejected => '拒绝 ${o.rejectReason ?? ''}',
      OrderStatus.expired => '过期 ${o.rejectReason ?? ''}',
      OrderStatus.pending => '待成交',
    };
  }
}
