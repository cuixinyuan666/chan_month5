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

/// 把 BacktestResult 端出来：指标卡 / 净值 / 交易 / 信号订单链路。不重算。
class BacktestReportPanel extends StatelessWidget {
  final BacktestRun run;
  final List<KlineBar> bars;
  final BacktestReportTab tab;
  final ValueChanged<BacktestReportTab> onTab;
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
        _tabBar(),
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
    return ListView.builder(
      itemCount: result.trades.length,
      itemBuilder: (ctx, i) {
        final t = result.trades[i];
        final on = t.tradeId == selectedTradeId;
        final entryT = _time(t.entryX);
        final exitT = _time(t.exitX);
        return ListTile(
          dense: true,
          selected: on,
          selectedTileColor: const Color(0x334FC3F7),
          title: Text(
            '#${i + 1}  净 ${formatMoney(t.netPnL)}',
            style: TextStyle(
              fontSize: 13,
              color: t.netPnL >= 0 ? kStrategyBuyColor : const Color(0xFFFF8A65),
            ),
          ),
          subtitle: Text(
            '入 $entryT @${t.entryPrice.toStringAsFixed(3)}  →  出 $exitT @${t.exitPrice.toStringAsFixed(3)}\n'
            '量${t.quantity}  毛${formatMoney(t.grossPnL)}  费${formatMoney(t.commission)}  滑${formatMoney(t.slippage)}',
            style: const TextStyle(fontSize: 11),
          ),
          isThreeLine: true,
          onTap: () => onSelectTrade(t),
        );
      },
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
    return ListView.builder(
      itemCount: sigs.length,
      itemBuilder: (ctx, i) {
        final s = sigs[i];
        final o = link.orderForSignal(s.signalId);
        final f = link.fillForSignal(s.signalId);
        final t = link.tradeForSignal(s.signalId);
        final on = s.signalId == selectedSignalId;
        final side = s.side == TradeSide.buy ? '策买' : '策卖';
        final st = o == null ? '无订单' : _orderStatus(o);
        return Material(
          color: on ? const Color(0x33D500F9) : Colors.transparent,
          child: InkWell(
            onTap: () => onSelectSignal(s),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '$side  K${s.discoveryX}  $st',
                    style: const TextStyle(fontSize: 13),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    s.explainBlock,
                    style: const TextStyle(
                      fontSize: 11,
                      color: Color(0xFFCBD5E1),
                      height: 1.35,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '${f == null ? '未成交' : '成交K${f.executeX} @${f.price.toStringAsFixed(3)}'}'
                    '${t == null ? '' : '  · 交易 ${t.tradeId} 净${formatMoney(t.netPnL)}'}',
                    style: const TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
                  ),
                ],
              ),
            ),
          ),
        );
      },
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
