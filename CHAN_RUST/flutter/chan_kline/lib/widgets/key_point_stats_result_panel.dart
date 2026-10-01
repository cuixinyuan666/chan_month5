import 'package:flutter/material.dart';

import '../key_point_stats/key_point_stat_runner.dart';
import '../key_point_stats/stat_metrics.dart';

enum KeyPointStatSort {
  name,
  samples,
  mean,
  mode,
}

/// 计优结果面板：分组 Tab + 指标统计表（固定表头、可排序、可按类型过滤）。
class KeyPointStatsResultPanel extends StatefulWidget {
  const KeyPointStatsResultPanel({
    super.key,
    required this.result,
    required this.jsonPath,
    required this.tsvPath,
  });

  final KeyPointStatResult result;
  final String jsonPath;
  final String tsvPath;

  @override
  State<KeyPointStatsResultPanel> createState() =>
      _KeyPointStatsResultPanelState();
}

class _KeyPointStatsResultPanelState extends State<KeyPointStatsResultPanel> {
  KeyPointStatSort _sort = KeyPointStatSort.name;
  bool _ascending = true;
  StatValueKind? _kindFilter;

  List<StatSummary> _rows(KeyPointStatGroup g) {
    final list = g.stats
        .where((e) => _kindFilter == null || e.kind == _kindFilter)
        .toList();
    int cmp(StatSummary a, StatSummary b) {
      switch (_sort) {
        case KeyPointStatSort.name:
          return a.labelCn.compareTo(b.labelCn);
        case KeyPointStatSort.samples:
          return a.sampleCount.compareTo(b.sampleCount);
        case KeyPointStatSort.mean:
          return (a.mean ?? double.negativeInfinity)
              .compareTo(b.mean ?? double.negativeInfinity);
        case KeyPointStatSort.mode:
          return (a.modeCount).compareTo(b.modeCount);
      }
    }

    final c = cmp;
    list.sort(_ascending ? c : (a, b) => c(b, a));
    return list;
  }

  String _num(double? v) {
    if (v == null || !v.isFinite) return '—';
    final a = v.abs();
    if (a != 0 && (a < 0.001 || a >= 100000)) return v.toStringAsExponential(2);
    return v.toStringAsFixed(4);
  }

  String _ratio(double? v) =>
      v == null ? '—' : '${(v * 100).toStringAsFixed(0)}%';

  void _toggleSort(KeyPointStatSort s) {
    setState(() {
      if (_sort == s) {
        _ascending = !_ascending;
      } else {
        _sort = s;
        _ascending = true;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final r = widget.result;
    if (r.groups.isEmpty) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Text(
            '区间内还没有已确认的连线转折点。\n'
            '请先把 K 线步进到更靠后的位置（转折点要等连线确认后才成立）。',
            style: const TextStyle(fontSize: 13, height: 1.5),
          ),
        ),
      );
    }

    return DefaultTabController(
      length: r.groups.length,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
            r.headerLine,
            style: const TextStyle(fontSize: 11, height: 1.35),
          ),
          const SizedBox(height: 4),
          Text(
            '关键点位 ${r.collect.keyPoints.length} 个 · '
            '统计分组 ${r.groups.length} 张 · 每张 ${r.metricCount} 项指标 · '
            '耗时 ${r.elapsed.inMilliseconds}ms',
            style: TextStyle(fontSize: 11, color: Colors.grey.shade700),
          ),
          Text(
            'JSON：${widget.jsonPath}\nTSV：${widget.tsvPath}',
            style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
          ),
          if (r.collect.skippedUnconfirmed > 0 ||
              r.collect.skippedNoPole > 0)
            Text(
              '已排除：进行中未确认 ${r.collect.skippedUnconfirmed} · '
              '找不到极值 ${r.collect.skippedNoPole}',
              style: TextStyle(fontSize: 10, color: Colors.grey.shade600),
            ),
          const SizedBox(height: 4),
          Row(
            children: [
              const Text('过滤：', style: TextStyle(fontSize: 11)),
              _filterChip('全部', null),
              const SizedBox(width: 6),
              _filterChip('数值型', StatValueKind.numeric),
              const SizedBox(width: 6),
              _filterChip('类别型', StatValueKind.categorical),
            ],
          ),
          const SizedBox(height: 4),
          TabBar(
            isScrollable: true,
            tabAlignment: TabAlignment.start,
            labelPadding: const EdgeInsets.symmetric(horizontal: 10),
            tabs: [
              for (final g in r.groups)
                Tab(text: '${g.groupLabel} (${g.pointCount})'),
            ],
          ),
          Expanded(
            child: TabBarView(
              children: [
                for (final g in r.groups) _groupView(g),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _filterChip(String label, StatValueKind? kind) {
    final active = _kindFilter == kind;
    return ChoiceChip(
      label: Text(label, style: const TextStyle(fontSize: 11)),
      visualDensity: VisualDensity.compact,
      selected: active,
      onSelected: (_) => setState(() => _kindFilter = kind),
    );
  }

  Widget _groupView(KeyPointStatGroup g) {
    final rows = _rows(g);
    if (rows.isEmpty) {
      return const Center(child: Text('该分组在当前过滤下没有指标'));
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _header(),
        Expanded(
          child: ListView.builder(
            itemCount: rows.length,
            itemBuilder: (ctx, i) => _row(rows[i]),
          ),
        ),
      ],
    );
  }
static const List<int> _flexes = [4, 1, 1, 2, 2, 2, 2, 2, 2];

  Widget _cell(String label, KeyPointStatSort? sort, {int index = 0}) {
    final active = sort != null && _sort == sort;
    final arrow = !active ? '' : (_ascending ? ' ↑' : ' ↓');
    final child = InkWell(
      onTap: sort == null ? null : () => _toggleSort(sort),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
        child: Text(
          '$label$arrow',
          style: TextStyle(
            fontSize: 11,
            fontWeight: FontWeight.w600,
            color: active ? Colors.blue.shade700 : null,
          ),
          textAlign: index == 0 ? TextAlign.left : TextAlign.right,
        ),
      ),
    );
    return Expanded(flex: _flexes[index], child: child);
  }

  Widget _header() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade400)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          _cell('指标', KeyPointStatSort.name, index: 0),
          _cell('样本', KeyPointStatSort.samples, index: 1),
          _cell('非空', null, index: 2),
          _cell('平均数', KeyPointStatSort.mean, index: 3),
          _cell('中位数', null, index: 4),
          _cell('标准差', null, index: 5),
          _cell('最小', null, index: 6),
          _cell('最大', null, index: 7),
          _cell('众数', KeyPointStatSort.mode, index: 8),
        ],
      ),
    );
  }

  Widget _row(StatSummary s) {
    final isNum = s.kind == StatValueKind.numeric;
    const nameStyle = TextStyle(fontSize: 11, height: 1.25);
    const valStyle = TextStyle(fontSize: 11, height: 1.25);

    final modeText = isNum
        ? '${_num(s.mode)} (${s.modeCount})'
        : '${s.modeLabel ?? '—'} (${s.modeCount})';

    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 5),
      decoration: BoxDecoration(
        border: Border(bottom: BorderSide(color: Colors.grey.shade200)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: [
          Expanded(
            flex: _flexes[0],
            child: Text(
              '${s.labelCn}  ·  ${isNum ? '' : '类别 '}${s.metricKey}',
              style: nameStyle.copyWith(color: Colors.grey.shade700),
            ),
          ),
          Expanded(
            flex: _flexes[1],
            child: Text('${s.sampleCount}', style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[2],
            child: Text(_ratio(s.coverage), style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[3],
            child: Text(isNum ? _num(s.mean) : '—', style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[4],
            child: Text(isNum ? _num(s.median) : '—', style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[5],
            child: Text(isNum ? _num(s.stddev) : '—', style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[6],
            child: Text(isNum ? _num(s.min) : '—', style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[7],
            child: Text(isNum ? _num(s.max) : '—', style: valStyle, textAlign: TextAlign.right),
          ),
          Expanded(
            flex: _flexes[8],
            child: Text(modeText, style: valStyle, textAlign: TextAlign.right),
          ),
        ],
      ),
    );
  }
}