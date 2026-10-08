import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 2),
          child: Text(
            '任意文字可拖选复制；列名悬停看白话口径；鼠标右键点某一行＝复制该行整行'
            '（制表符分列，列序与表头一致，可直接贴进表格）',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
        ),
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

/// 列名 tooltip：白话口径 + 英文键（寻优结果宽表列说明的唯一落点）。
///
/// [scope] 取「样本内 / 样本外 / 排序用」；[plain] 是该列的白话算法；[note] 补三态说明。
String _colTip(
  String label,
  String key,
  String scope,
  String plain, [
  String? note,
]) =>
    note == null
        ? '$label：$plain（$scope）\n$key'
        : '$label：$plain（$scope）\n$key（$note）';

class _VerdictHeaderRow extends StatelessWidget {
  const _VerdictHeaderRow({required this.sort, required this.onSort});

  final VerdictSortState sort;
  final void Function(VerdictSortColumn) onSort;

  Widget _cell(String label, VerdictSortColumn? col,
      {int flex = 1, String? tooltip}) {
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
    return Expanded(
      flex: flex,
      child: col == null
          ? child
          : Tooltip(
              message: tooltip ?? label,
              waitDuration: const Duration(milliseconds: 300),
              child: child,
            ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _cell(
            '类型',
            VerdictSortColumn.type,
            flex: 1,
            tooltip: _colTip('类型', 'type', '标识',
                '这行买卖条件取自哪一类信号族'),
          ),
          _cell(
            '买入条件',
            null,
            flex: 3,
            tooltip: '买入条件：这组合的开仓触发条件\n(buy)',
          ),
          _cell(
            '卖出条件',
            null,
            flex: 3,
            tooltip: '卖出条件：这组合的平仓触发条件\n(sell)',
          ),
          _cell(
            '内笔',
            VerdictSortColumn.inTrades,
            tooltip: _colTip('内笔', 'in_trades', '样本内', '已平仓笔数'),
          ),
          _cell(
            '内胜率',
            VerdictSortColumn.inWinRate,
            tooltip: _colTip('内胜率', 'in_win_rate', '样本内',
                '盈利笔数 ÷ 已平仓总笔数'),
          ),
          _cell(
            '内盈亏比',
            VerdictSortColumn.inPayoff,
            tooltip: _colTip('内盈亏比', 'in_payoff', '样本内',
                '单笔平均盈利 ÷ 单笔平均亏损', '全胜无亏显示 ∞'),
          ),
          _cell(
            '外笔',
            VerdictSortColumn.outTrades,
            tooltip: _colTip('外笔', 'out_trades', '样本外', '已平仓笔数',
                '未测算时显示「未测」'),
          ),
          _cell(
            '外胜率',
            VerdictSortColumn.outWinRate,
            tooltip: _colTip('外胜率', 'out_win_rate', '样本外',
                '盈利笔数 ÷ 已平仓总笔数', '未测算时显示「—」'),
          ),
          _cell(
            '外盈亏比',
            VerdictSortColumn.outPayoff,
            tooltip: _colTip('外盈亏比', 'out_payoff', '样本外',
                '单笔平均盈利 ÷ 单笔平均亏损', '未测算时显示「—」'),
          ),
          _cell(
            '保守分',
            VerdictSortColumn.rank,
            tooltip: _colTip(
                '保守分', 'in_rank_score', '排序用', '只按样本内算的打分，越大越好',
                '笔数不足门槛记 0；小样本与极端盈亏比都会被压缩'),
          ),
        ],
      ),
    );
  }
}

class _VerdictDataRow extends StatelessWidget {
  const _VerdictDataRow({required this.v, required this.maxKn});

  final ComboVerdict v;
  final int maxKn;

  /// 该行整行的 TSV（列序与表头一致，买卖条件用面板同一套中文口径）。
  String _rowTsv(String buy, String sell) {
    final i = v.inSample;
    final o = v.outSample;
    String one(String s) => s.replaceAll('\t', ' ').replaceAll('\n', ' ');
    return [
      one(v.categoryLabel),
      one(buy),
      one(sell),
      '${i.trades}',
      pctText(i.winRate),
      fxText(i.payoff),
      v.outSampleSkipped ? '未测' : '${o.trades}',
      v.outSampleSkipped ? '—' : pctText(o.winRate),
      v.outSampleSkipped ? '—' : fxText(o.payoff),
      v.inRankScore.toStringAsFixed(3),
    ].join('\t');
  }

  void _copyRow(BuildContext context, String buy, String sell) {
    Clipboard.setData(ClipboardData(text: _rowTsv(buy, sell)));
    ScaffoldMessenger.maybeOf(context)
      ?..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(
        content: Text('已复制该行（${v.categoryLabel}）整行文本'),
        duration: const Duration(milliseconds: 1200),
      ));
  }

  @override
  Widget build(BuildContext context) {
    final i = v.inSample, o = v.outSample;
    const dataStyle = TextStyle(fontSize: 11, height: 1.25);
    const ruleStyle = TextStyle(fontSize: 10, height: 1.35);
    final buy = conditionDisplayText(v.buyText, maxKn: maxKn);
    final sell = conditionDisplayText(v.sellText, maxKn: maxKn);

    Widget numCell(String t) =>
        Text(t, style: dataStyle, textAlign: TextAlign.center);

    return GestureDetector(
      // 鼠标右键＝复制该行整行（桌面端；触屏走拖选复制）
      onSecondaryTapUp: (_) => _copyRow(context, buy, sell),
      child: Padding(
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
      ),
    );
  }
}
