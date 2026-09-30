import 'package:flutter/material.dart';

import '../backtest/condition_ast.dart';
import '../indicator_search/candidate_builder.dart';
import '../indicator_search/search_core.dart';
import '../indicator_search/search_env.dart';
import '../indicator_search/search_verdict_views.dart';

/// 寻优结果：多维度 Tab + 固定表头 + 列排序。
class IndicatorSearchResultPanel extends StatelessWidget {
  const IndicatorSearchResultPanel({
    super.key,
    required this.header,
    required this.verdicts,
    required this.resultsFilePath,
    required this.elapsed,
    this.maxKn = 16,
    this.skipOosEarly = true,
    this.buildSummary,
  });

  final String header;
  final List<ComboVerdict> verdicts;
  final String resultsFilePath;
  final Duration elapsed;
  final int maxKn;
  final bool skipOosEarly;
  final CandidateBuildSummary? buildSummary;

  @override
  Widget build(BuildContext context) {
    final dual = SearchVerdictBuckets.dualPassed(verdicts);
    final inOnly = SearchVerdictBuckets.inSampleOnly(verdicts);
    final outOnly = SearchVerdictBuckets.outSampleOnly(verdicts);
    final skippedOos = verdicts.where((e) => e.outSampleSkipped).length;
    final outStrong = SearchVerdictBuckets.outSegmentStrong(verdicts);
    final rankNotDual = SearchVerdictBuckets.rankPositiveNotDual(verdicts);
    final allRank = SearchVerdictBuckets.byRankDesc(verdicts);
    // P2 体检：只在「榜首被小样本∞占据」这种真正需要警惕时占界面，
    // 避免常态下多挤一行把下方 TabBar 顶出视口。
    final infDiag = SearchInfPayoffDiagnostics.of(verdicts);
    final infAlert = infDiag.infInTop > 0 && infDiag.topMinTrades < 10;
    final infLine = infAlert ? infDiag.toDisplayLine() : null;

    return DefaultTabController(
      length: 6,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            header.trim(),
            style: const TextStyle(fontSize: 11, height: 1.35),
          ),
          const SizedBox(height: 6),
          Text(
            '耗时 ${elapsed.inMinutes}分${elapsed.inSeconds % 60}秒 · '
            '跑通 ${verdicts.length} · 双达标 ${dual.length}'
            '${skippedOos > 0 ? ' · 外段未测 $skippedOos' : ''}',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
          Text(
            '完整 TSV：$resultsFilePath',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
          if (buildSummary != null) ...[
            const SizedBox(height: 4),
            Text(
              buildSummary!.toDisplayLine(),
              style: TextStyle(fontSize: 10, color: Colors.grey.shade700),
            ),
          ],
          if (infLine != null) ...[
            const SizedBox(height: 4),
            Text(
              infLine,
              style: TextStyle(
                fontSize: 10,
                color: infAlert ? Colors.brown.shade800 : Colors.grey.shade700,
                fontWeight: infAlert ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ],
          if (skipOosEarly) ...[
            const SizedBox(height: 6),
            Material(
              color: Colors.amber.shade50,
              borderRadius: BorderRadius.circular(6),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: Text(
                  '内段不过关则外段不参与双达标（外段绩效仍会列出，表列「未测」仅表示未参与双达标门槛）。'
                  '注意：该开关不省算力，外段照样回测一次；关闭后「仅外达标」「外段过线」等分桶才会收录这类组合。',
                  style: TextStyle(fontSize: 10, color: Colors.brown.shade800),
                ),
              ),
            ),
          ],
          const SizedBox(height: 6),
          TabBar(
            isScrollable: true,
            labelStyle: const TextStyle(fontSize: 11),
            tabs: [
              Tab(text: '双达标(${dual.length})'),
              Tab(text: '仅内达标(${inOnly.length})'),
              Tab(text: '仅外达标(${outOnly.length})'),
              // 早停开启时「仅外达标」不含未测外段；见摘要「外段未测」计数
              Tab(text: '外段过线(${outStrong.length})'),
              Tab(text: '有分未双标(${rankNotDual.length})'),
              Tab(text: '保守分全量(${allRank.length})'),
            ],
          ),
          const SizedBox(height: 4),
          Expanded(
            child: TabBarView(
              children: [
                _VerdictTable(rows: dual, maxKn: maxKn),
                _VerdictTable(rows: inOnly, maxKn: maxKn),
                _VerdictTable(rows: outOnly, maxKn: maxKn),
                _VerdictTable(rows: outStrong, maxKn: maxKn),
                _VerdictTable(rows: rankNotDual, maxKn: maxKn),
                _VerdictTable(rows: allRank, maxKn: maxKn),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _VerdictTable extends StatefulWidget {
  const _VerdictTable({required this.rows, required this.maxKn});

  final List<ComboVerdict> rows;
  final int maxKn;

  @override
  State<_VerdictTable> createState() => _VerdictTableState();
}

class _VerdictTableState extends State<_VerdictTable> {
  final ScrollController _vertical = ScrollController();
  VerdictSortState _sort = const VerdictSortState();

  @override
  void dispose() {
    _vertical.dispose();
    super.dispose();
  }

  void _onSort(VerdictSortColumn col) {
    setState(() => _sort = _sort.toggle(col));
  }

  @override
  Widget build(BuildContext context) {
    if (widget.rows.isEmpty) {
      return const Center(child: Text('（无）', style: TextStyle(fontSize: 12)));
    }
    final sorted = sortVerdicts(widget.rows, _sort);
    final headerBg = Theme.of(context).colorScheme.surfaceContainerHighest;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Material(
          color: headerBg,
          elevation: 1,
          child: _VerdictHeaderRow(sort: _sort, onSort: _onSort),
        ),
        const Divider(height: 1),
        Expanded(
          child: Scrollbar(
            controller: _vertical,
            thumbVisibility: true,
            child: ListView.separated(
              controller: _vertical,
              itemCount: sorted.length,
              separatorBuilder: (_, _) => const Divider(height: 1),
              itemBuilder: (_, i) =>
                  _VerdictDataRow(v: sorted[i], maxKn: widget.maxKn),
            ),
          ),
        ),
      ],
    );
  }
}

class _VerdictHeaderRow extends StatelessWidget {
  const _VerdictHeaderRow({required this.sort, required this.onSort});

  final VerdictSortState sort;
  final void Function(VerdictSortColumn) onSort;

  Widget _cell(String label, VerdictSortColumn? col, {int flex = 1}) {
    Widget child;
    if (col == null) {
      child = Text(
        label,
        style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w600),
      );
    } else {
      final active = sort.column == col;
      final arrow = !active ? '' : (sort.ascending ? ' ↑' : ' ↓');
      child = InkWell(
        onTap: () => onSort(col),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 4),
          child: Text(
            '$label$arrow',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              color: active ? Colors.blue.shade700 : null,
            ),
            textAlign: col == VerdictSortColumn.type
                ? TextAlign.left
                : TextAlign.center,
          ),
        ),
      );
    }
    return Expanded(flex: flex, child: child);
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _cell('类型', VerdictSortColumn.type, flex: 1),
          _cell('买入条件', null, flex: 3),
          _cell('卖出条件', null, flex: 3),
          _cell('内笔', VerdictSortColumn.inTrades),
          _cell('内胜率', VerdictSortColumn.inWinRate),
          _cell('内盈亏比', VerdictSortColumn.inPayoff),
          _cell('外笔', VerdictSortColumn.outTrades),
          _cell('外胜率', VerdictSortColumn.outWinRate),
          _cell('外盈亏比', VerdictSortColumn.outPayoff),
          _cell('保守分', VerdictSortColumn.rank),
        ],
      ),
    );
  }
}

class _VerdictDataRow extends StatelessWidget {
  const _VerdictDataRow({required this.v, required this.maxKn});

  final ComboVerdict v;
  final int maxKn;

  @override
  Widget build(BuildContext context) {
    final i = v.inSample, o = v.outSample;
    const dataStyle = TextStyle(fontSize: 11, height: 1.25);
    const ruleStyle = TextStyle(fontSize: 10, height: 1.35);
    final buy = conditionDisplayText(v.buyText, maxKn: maxKn);
    final sell = conditionDisplayText(v.sellText, maxKn: maxKn);

    Widget numCell(String t) =>
        Text(t, style: dataStyle, textAlign: TextAlign.center);

    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Expanded(
            flex: 1,
            child: Text(
              v.passed ? '✔ ${v.categoryLabel}' : v.categoryLabel,
              style: dataStyle.copyWith(
                fontWeight: v.passed ? FontWeight.w600 : FontWeight.normal,
              ),
            ),
          ),
          Expanded(flex: 3, child: Text(buy, style: ruleStyle)),
          Expanded(flex: 3, child: Text(sell, style: ruleStyle)),
          Expanded(flex: 1, child: numCell('${i.trades}')),
          Expanded(flex: 1, child: numCell(pctText(i.winRate))),
          Expanded(flex: 1, child: numCell(fxText(i.payoff))),
          Expanded(
            flex: 1,
            child: numCell(v.outSampleSkipped ? '未测' : '${o.trades}'),
          ),
          Expanded(
            flex: 1,
            child: numCell(v.outSampleSkipped ? '—' : pctText(o.winRate)),
          ),
          Expanded(
            flex: 1,
            child: numCell(v.outSampleSkipped ? '—' : fxText(o.payoff)),
          ),
          Expanded(flex: 1, child: numCell(v.inRankScore.toStringAsFixed(3))),
        ],
      ),
    );
  }
}
