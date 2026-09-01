import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../compute/math_series_freeze_store.dart';
import '../models/bar_feature_lookup.dart';
import '../models/kline_bar.dart';
import '../models/level_models.dart';
import 'chan_event_store.dart';
import 'chart_line_store.dart';
import 'chip_peak_store.dart';
import 'condition_ast.dart';
import 'divergence_relation_store.dart';
import 'signal_data_catalog.dart';
import 'strategy_compile.dart';
import 'strategy_config.dart';
import 'trade_clock.dart';
import 'trade_operand.dart';
import 'trade_var_diagnose.dart';
import 'zhongshu_object_store.dart';

/// 通用条件构建器：比较 / 穿越 / AND / OR / 变量 vs 常数。只搭 AST，不算真假。
class StrategyConfigForm extends StatefulWidget {
  final StrategyConfig config;
  final int maxKn;
  final ValueChanged<StrategyConfig> onChanged;
  final ValueChanged<StrategyConfig>? onRun;
  final bool running;
  final List<KlineBar> bars;
  final List<LevelBundle> levels;
  final MathSeriesFreezeStore? mathFreeze;
  final ChanEventStore chanEvents;
  final ZhongshuObjectStore? zsObjects;
  final DivergenceRelationStore? diverRelations;
  final ChartLineStore? lineSeries;
  final BarFeatureLookup? features;
  final ChipPeakFreezeStore? chipPeaks;
  final double bucketStep;
  final int asOf;

  const StrategyConfigForm({
    super.key,
    required this.config,
    required this.maxKn,
    required this.onChanged,
    this.onRun,
    this.running = false,
    this.bars = const [],
    this.levels = const [],
    this.mathFreeze,
    this.chanEvents = ChanEventStore.empty,
    this.zsObjects,
    this.diverRelations,
    this.lineSeries,
    this.features,
    this.chipPeaks,
    this.bucketStep = 0.1,
    this.asOf = 0,
  });

  @override
  State<StrategyConfigForm> createState() => _StrategyConfigFormState();
}

class _LeafDraft {
  int kn;
  String leftId;
  TradeBinaryOp op;
  bool rightIsConst;
  String rightId;
  double rightConst;
  String enumToken;

  _LeafDraft({
    required this.kn,
    required this.leftId,
    required this.op,
    required this.rightIsConst,
    required this.rightId,
    required this.rightConst,
    this.enumToken = 'DOWN',
  });

  factory _LeafDraft.fromCmp(TradeCmpAst cmp, {int fallbackKn = 0}) {
    final leftId = cmp.left is TradeVarRef
        ? (cmp.left as TradeVarRef).variableId
        : rawOhlcId(fallbackKn, 'CLOSE');
    final kn = knFromVariableId(leftId) ??
        (cmp.right is TradeVarRef
            ? knFromVariableId((cmp.right as TradeVarRef).variableId)
            : null) ??
        fallbackKn;
    final rightIsConst =
        cmp.right is TradeConstRef || cmp.right is TradeEnumRef;
    final rightId = cmp.right is TradeVarRef
        ? (cmp.right as TradeVarRef).variableId
        : bollBandId(kn, 'DOWN');
    final enumToken = cmp.right is TradeEnumRef
        ? (cmp.right as TradeEnumRef).token
        : 'DOWN';
    return _LeafDraft(
      kn: kn,
      leftId: leftId,
      op: cmp.op,
      rightIsConst: rightIsConst,
      rightId: rightId,
      rightConst: cmp.right is TradeConstRef
          ? (cmp.right as TradeConstRef).value
          : 0,
      enumToken: enumToken,
    );
  }

  factory _LeafDraft.fromLeaf(TradeAst ast, {int fallbackKn = 0}) {
    if (ast is TradeEventAst) {
      final kn = knFromVariableId(ast.variableId) ?? fallbackKn;
      return _LeafDraft(
        kn: kn,
        leftId: ast.variableId,
        op: TradeBinaryOp.eventExists,
        rightIsConst: true,
        rightId: rawOhlcId(kn, 'CLOSE'),
        rightConst: 0,
      );
    }
    if (ast is TradeCmpAst) {
      return _LeafDraft.fromCmp(ast, fallbackKn: fallbackKn);
    }
    return _LeafDraft.fromCmp(kDefaultBollBuyAst, fallbackKn: fallbackKn);
  }

  bool get isEventLeft {
    final def = lookupTradeVariable(leftId, maxKn: 32);
    return def != null &&
        def.expressionReady &&
        def.valueType == TradeValueType.event;
  }

  bool get isEnumLeft {
    final def = lookupTradeVariable(leftId, maxKn: 32);
    return def != null &&
        def.expressionReady &&
        def.valueType == TradeValueType.enumeration;
  }

  TradeAst toNode() {
    if (isEventLeft) return TradeEventAst(leftId);
    return toCmp();
  }

  TradeCmpAst toCmp() {
    final TradeValueRef right;
    if (isEnumLeft) {
      right = TradeEnumRef(enumToken);
    } else if (rightIsConst) {
      right = TradeConstRef(rightConst);
    } else {
      right = TradeVarRef(rightId);
    }
    return TradeCmpAst(left: TradeVarRef(leftId), right: right, op: op);
  }
}

class _SideDraft {
  List<_LeafDraft> leaves;
  List<CondJoin> joins;

  _SideDraft({required this.leaves, required this.joins});

  factory _SideDraft.fromAst(TradeAst ast, {int fallbackKn = 0}) {
    final flat = flattenAstChain(ast);
    final leaves = [
      for (final c in flat.leaves)
        _LeafDraft.fromLeaf(c, fallbackKn: fallbackKn),
    ];
    if (leaves.isEmpty) {
      leaves.add(_LeafDraft.fromCmp(kDefaultBollBuyAst, fallbackKn: fallbackKn));
    }
    return _SideDraft(leaves: leaves, joins: [...flat.joins]);
  }

  TradeAst toAst() {
    final nodes = [for (final l in leaves) l.toNode()];
    return foldAstChain(nodes, joins);
  }
}

class _StrategyConfigFormState extends State<StrategyConfigForm> {
  late final TextEditingController _qty;
  late final TextEditingController _cap;
  late final TextEditingController _fee;
  late final TextEditingController _slip;
  late _SideDraft _buy;
  late _SideDraft _sell;
  final Map<String, TextEditingController> _constCtrls = {};
  String? _diagId;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: '${widget.config.quantity}');
    _cap = TextEditingController(
      text: widget.config.initialCapital.toStringAsFixed(0),
    );
    _fee = TextEditingController(text: '${widget.config.commissionRate}');
    _slip = TextEditingController(text: '${widget.config.slippageAmount}');
    _buy = _SideDraft.fromAst(widget.config.buyAst);
    _sell = _SideDraft.fromAst(widget.config.sellAst);
  }

  @override
  void didUpdateWidget(covariant StrategyConfigForm oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.config.quantity != widget.config.quantity) {
      _qty.text = '${widget.config.quantity}';
    }
    if (oldWidget.config.initialCapital != widget.config.initialCapital) {
      _cap.text = widget.config.initialCapital.toStringAsFixed(0);
    }
    if (oldWidget.config.commissionRate != widget.config.commissionRate) {
      _fee.text = '${widget.config.commissionRate}';
    }
    if (oldWidget.config.slippageAmount != widget.config.slippageAmount) {
      _slip.text = '${widget.config.slippageAmount}';
    }
  }

  @override
  void dispose() {
    _qty.dispose();
    _cap.dispose();
    _fee.dispose();
    _slip.dispose();
    for (final c in _constCtrls.values) {
      c.dispose();
    }
    super.dispose();
  }

  TextEditingController _constCtrl(String key, double value) {
    final existing = _constCtrls[key];
    if (existing != null) return existing;
    final c = TextEditingController(
      text: value == value.roundToDouble() ? '${value.toInt()}' : '$value',
    );
    _constCtrls[key] = c;
    return c;
  }

  StrategyConfig _readNums(StrategyConfig base) {
    final q = int.tryParse(_qty.text);
    final c = double.tryParse(_cap.text);
    final f = double.tryParse(_fee.text);
    final s = double.tryParse(_slip.text);
    var next = base;
    if (q != null && q > 0) next = next.copyWith(quantity: q);
    if (c != null && c > 0) next = next.copyWith(initialCapital: c);
    if (f != null && f >= 0) next = next.copyWith(commissionRate: f);
    if (s != null && s >= 0) next = next.copyWith(slippageAmount: s);
    return next;
  }

  void _emit() {
    final next = _readNums(widget.config.copyWith(
      buyAst: _buy.toAst(),
      sellAst: _sell.toAst(),
    ));
    widget.onChanged(next);
  }

  void _flushNums() {
    widget.onChanged(_readNums(widget.config.copyWith(
      buyAst: _buy.toAst(),
      sellAst: _sell.toAst(),
    )));
  }

  @override
  Widget build(BuildContext context) {
    final maxKn = widget.maxKn < 0 ? 0 : widget.maxKn;
    final kns = [for (var i = 0; i <= maxKn; i++) i];
    final compiled = compileStrategyConfig(
      widget.config.copyWith(buyAst: _buy.toAst(), sellAst: _sell.toAst()),
      maxKn: maxKn,
    );
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        _sideBlock(
          title: '买入条件（同层同钟，真假由回测引擎算）',
          draft: _buy,
          kns: kns,
          maxKn: maxKn,
          prefix: 'buy',
        ),
        const SizedBox(height: 10),
        _sideBlock(
          title: '卖出条件（独立于买入，也可同层同钟）',
          draft: _sell,
          kns: kns,
          maxKn: maxKn,
          prefix: 'sell',
        ),
        if (compiled is StrategyCompileIllegal) ...[
          const SizedBox(height: 8),
          Text(
            compiled.reason,
            style: const TextStyle(fontSize: 11, color: Color(0xFFFFB74D)),
          ),
        ],
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _field('手数/数量', _qty)),
            const SizedBox(width: 8),
            Expanded(child: _field('本金', _cap)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(child: _field('手续费率', _fee)),
            const SizedBox(width: 8),
            Expanded(child: _field('滑点价差', _slip)),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: DropdownButtonFormField<TradeFillPriceMode>(
                isExpanded: true,
                value: widget.config.fillPriceMode,
                decoration: _dec('成交价格（买/卖共用）'),
                items: [
                  for (final mode in TradeFillPriceMode.values)
                    DropdownMenuItem(
                      value: mode,
                      child: Text(tradeFillPriceModeLabel(mode)),
                    ),
                ],
                onChanged: (v) {
                  if (v == null) return;
                  widget.onChanged(
                    _readNums(widget.config.copyWith(fillPriceMode: v)),
                  );
                },
              ),
            ),
            IconButton(
              tooltip: '成交价格说明',
              onPressed: () => _showFillPriceHelp(context),
              icon: const Icon(Icons.help_outline, size: 20),
            ),
          ],
        ),
        const SizedBox(height: 10),
        FilledButton.icon(
          onPressed: widget.running
              ? null
              : () {
                  final next = _readNums(widget.config.copyWith(
                    buyAst: _buy.toAst(),
                    sellAst: _sell.toAst(),
                  ));
                  widget.onChanged(next);
                  widget.onRun?.call(next);
                },
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(widget.running ? '正在回测…' : '运行回测'),
        ),
        const SizedBox(height: 10),
        _diagnoseCard(),
      ],
    );
  }

  Widget _sideBlock({
    required String title,
    required _SideDraft draft,
    required List<int> kns,
    required int maxKn,
    required String prefix,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Text(
          title,
          style: const TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 4),
        for (var i = 0; i < draft.leaves.length; i++) ...[
          if (i > 0) _joinRow(draft, i - 1),
          _leafCard(
            draft: draft,
            index: i,
            kns: kns,
            maxKn: maxKn,
            prefix: prefix,
          ),
        ],
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: () {
              final last = draft.leaves.last;
              draft.leaves.add(_LeafDraft(
                kn: last.kn,
                leftId: rawOhlcId(last.kn, 'CLOSE'),
                op: TradeBinaryOp.lt,
                rightIsConst: false,
                rightId: bollBandId(last.kn, 'MID'),
                rightConst: 0,
              ));
              draft.joins.add(CondJoin.and);
              setState(() {});
              _emit();
            },
            icon: const Icon(Icons.add, size: 16),
            label: const Text('添加条件', style: TextStyle(fontSize: 12)),
          ),
        ),
      ],
    );
  }

  Widget _joinRow(_SideDraft draft, int joinIndex) {
    final join = draft.joins[joinIndex];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        children: [
          ChoiceChip(
            label: const Text('AND', style: TextStyle(fontSize: 11)),
            selected: join == CondJoin.and,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              draft.joins[joinIndex] = CondJoin.and;
              setState(() {});
              _emit();
            },
          ),
          const SizedBox(width: 6),
          ChoiceChip(
            label: const Text('OR', style: TextStyle(fontSize: 11)),
            selected: join == CondJoin.or,
            visualDensity: VisualDensity.compact,
            onSelected: (_) {
              draft.joins[joinIndex] = CondJoin.or;
              setState(() {});
              _emit();
            },
          ),
        ],
      ),
    );
  }

  Widget _leafCard({
    required _SideDraft draft,
    required int index,
    required List<int> kns,
    required int maxKn,
    required String prefix,
  }) {
    final leaf = draft.leaves[index];
    final kn = leaf.kn.clamp(0, maxKn);
    final eventLeft = leaf.isEventLeft;
    final enumLeft = leaf.isEnumLeft;
    const ops = <TradeBinaryOp>[
      TradeBinaryOp.gt,
      TradeBinaryOp.lt,
      TradeBinaryOp.ge,
      TradeBinaryOp.le,
      TradeBinaryOp.crossAbove,
      TradeBinaryOp.crossBelow,
    ];
    final shownOps = eventLeft
        ? const <TradeBinaryOp>[TradeBinaryOp.eventExists]
        : enumLeft
            ? const <TradeBinaryOp>[TradeBinaryOp.eq]
            : ops;
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF1E293B),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        children: [
          Row(
            children: [
              SizedBox(
                width: 72,
                child: DropdownButtonFormField<int>(
                  isExpanded: true,
                  value: kns.contains(kn) ? kn : kns.first,
                  decoration: _dec('层'),
                  items: [
                    for (final k in kns)
                      DropdownMenuItem(value: k, child: Text('K$k')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    leaf.kn = v;
                    leaf.leftId = remapRegisteredVarId(
                      leaf.leftId,
                      v,
                      maxKn: maxKn,
                    );
                    if (!leaf.rightIsConst) {
                      leaf.rightId = remapRegisteredVarId(
                        leaf.rightId,
                        v,
                        maxKn: maxKn,
                      );
                    }
                    setState(() {});
                    _emit();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: _varPicker(
                  id: leaf.leftId,
                  kn: kn,
                  maxKn: maxKn,
                  label: '左',
                  onId: (id) {
                    leaf.leftId = id;
                    final def = lookupTradeVariable(id, maxKn: maxKn);
                    if (def != null && def.valueType == TradeValueType.event) {
                      leaf.op = TradeBinaryOp.eventExists;
                    } else if (def != null &&
                        def.valueType == TradeValueType.enumeration) {
                      leaf.op = TradeBinaryOp.eq;
                      leaf.rightIsConst = true;
                    } else if (leaf.op == TradeBinaryOp.eventExists ||
                        leaf.op == TradeBinaryOp.eq) {
                      leaf.op = TradeBinaryOp.gt;
                    }
                    setState(() {});
                    _emit();
                  },
                ),
              ),
              const SizedBox(width: 6),
              SizedBox(
                width: 72,
                child: DropdownButtonFormField<TradeBinaryOp>(
                  isExpanded: true,
                  value: shownOps.contains(leaf.op) ? leaf.op : shownOps.first,
                  decoration: _dec('关系'),
                  items: [
                    for (final o in shownOps)
                      DropdownMenuItem(
                        value: o,
                        child: Text(tradeOpLabelCn(o)),
                      ),
                  ],
                  onChanged: eventLeft || enumLeft
                      ? null
                      : (v) {
                          if (v == null) return;
                          leaf.op = v;
                          setState(() {});
                          _emit();
                        },
                ),
              ),
              if (draft.leaves.length > 1)
                IconButton(
                  tooltip: '删除这条',
                  visualDensity: VisualDensity.compact,
                  onPressed: () {
                    draft.leaves.removeAt(index);
                    if (index == 0) {
                      if (draft.joins.isNotEmpty) draft.joins.removeAt(0);
                    } else if (index - 1 < draft.joins.length) {
                      draft.joins.removeAt(index - 1);
                    }
                    setState(() {});
                    _emit();
                  },
                  icon: const Icon(Icons.close, size: 16),
                ),
              IconButton(
                tooltip: '诊断这个变量',
                visualDensity: VisualDensity.compact,
                onPressed: () => setState(() => _diagId = leaf.leftId),
                icon: const Icon(Icons.monitor_heart_outlined, size: 16),
              ),
            ],
          ),
          if (enumLeft) ...[
          const SizedBox(height: 6),
          DropdownButtonFormField<String>(
            isExpanded: true,
            value: leaf.enumToken == 'UP' || leaf.enumToken == 'DOWN'
                ? leaf.enumToken
                : 'DOWN',
            decoration: _dec('方向'),
            items: const [
              DropdownMenuItem(value: 'UP', child: Text('向上')),
              DropdownMenuItem(value: 'DOWN', child: Text('向下')),
            ],
            onChanged: (v) {
              if (v == null) return;
              leaf.enumToken = v;
              setState(() {});
              _emit();
            },
          ),
          ] else if (!eventLeft) ...[
          const SizedBox(height: 6),
          Row(
            children: [
              SizedBox(
                width: 88,
                child: DropdownButtonFormField<bool>(
                  isExpanded: true,
                  value: leaf.rightIsConst,
                  decoration: _dec('右'),
                  items: const [
                    DropdownMenuItem(value: false, child: Text('变量')),
                    DropdownMenuItem(value: true, child: Text('常数')),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    leaf.rightIsConst = v;
                    setState(() {});
              _emit();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: leaf.rightIsConst
                    ? TextField(
                        controller: _constCtrl(
                          '$prefix-$index',
                          leaf.rightConst,
                        ),
                        style: const TextStyle(fontSize: 13),
                        decoration: _dec('常数'),
                        keyboardType: const TextInputType.numberWithOptions(
                          decimal: true,
                        ),
                        inputFormatters: [
                          FilteringTextInputFormatter.allow(RegExp(r'[0-9.\-]')),
                        ],
                        onChanged: (t) {
                          final v = double.tryParse(t);
                          if (v == null) return;
                          leaf.rightConst = v;
                          _emit();
                        },
                      )
                    : _varPicker(
                        id: leaf.rightId,
                        kn: kn,
                        maxKn: maxKn,
                        label: '变量',
                        numericOnly: true,
                        onId: (id) {
                          leaf.rightId = id;
                          setState(() {});
                          _emit();
                        },
                      ),
              ),
            ],
          ),
          ],
        ],
      ),
    );
  }

  Widget _varPicker({
    required String id,
    required int kn,
    required int maxKn,
    required String label,
    required ValueChanged<String> onId,
    bool numericOnly = false,
  }) {
    var groups = groupedRegisteredVars(kn, maxKn);
    if (numericOnly) {
      groups = [
        for (final g in groups)
          if (g.fields.any((f) => isNumericComparableType(f.valueType)))
            TradeVarGroupSpec(
              key: g.key,
              label: g.label,
              panel: g.panel,
              fields: [
                for (final f in g.fields)
                  if (isNumericComparableType(f.valueType)) f,
              ],
            ),
      ];
    }
    if (groups.isEmpty) {
      return Text(label, style: const TextStyle(fontSize: 12));
    }
    final def = lookupTradeVariable(id, maxKn: maxKn);
    var groupKey = def?.groupKey ?? groups.first.key;
    if (!groups.any((g) => g.key == groupKey)) {
      groupKey = groups.first.key;
    }
    final group = groups.firstWhere((g) => g.key == groupKey);
    var fieldId = id;
    if (!group.fields.any((f) => f.variableId == fieldId)) {
      fieldId = group.fields.first.variableId;
    }
    return Row(
      children: [
        Expanded(
          flex: 4,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: groupKey,
            decoration: _dec(label),
            items: [
              for (final g in groups)
                DropdownMenuItem(value: g.key, child: Text(g.label)),
            ],
            onChanged: (v) {
              if (v == null) return;
              final g = groups.firstWhere((e) => e.key == v);
              onId(g.fields.first.variableId);
            },
          ),
        ),
        const SizedBox(width: 4),
        Expanded(
          flex: 5,
          child: DropdownButtonFormField<String>(
            isExpanded: true,
            value: fieldId,
            decoration: _dec('字段'),
            items: [
              for (final f in group.fields)
                DropdownMenuItem(
                  value: f.variableId,
                  child: Text(f.fieldLabel.isEmpty ? f.displayName : f.fieldLabel),
                ),
            ],
            onChanged: (v) {
              if (v != null) onId(v);
            },
          ),
        ),
      ],
    );
  }

  Widget _diagnoseCard() {
    final id = _diagId ??
        (_buy.leaves.isNotEmpty ? _buy.leaves.first.leftId : 'RAW.K0.CLOSE');
    final d = diagnoseTradeVariable(
      variableId: id,
      asOf: widget.asOf,
      bars: widget.bars,
      levels: widget.levels,
      mathFreeze: widget.mathFreeze,
      chanEvents: widget.chanEvents,
      zsObjects: widget.zsObjects,
      diverRelations: widget.diverRelations,
      lineSeries: widget.lineSeries,
      features: widget.features,
      chipPeaks: widget.chipPeaks,
      bucketStep: widget.bucketStep,
      maxKn: widget.maxKn < 0 ? 0 : widget.maxKn,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(8, 8, 8, 8),
      decoration: BoxDecoration(
        color: const Color(0xFF111827),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(color: const Color(0xFF334155)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            '变量诊断（只读：看图上已冻住的格子和计算钟，不会现场重算条件）',
            style: TextStyle(fontSize: 11, color: Color(0xFF94A3B8)),
          ),
          const SizedBox(height: 4),
          SelectableText(
            d.text,
            style: const TextStyle(
              fontSize: 11,
              height: 1.35,
              color: Color(0xFFE2E8F0),
              fontFamily: 'monospace',
            ),
          ),
        ],
      ),
    );
  }

  InputDecoration _dec(String label) {
    return InputDecoration(
      labelText: label,
      isDense: true,
      border: const OutlineInputBorder(),
      contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 8),
    );
  }

  Future<void> _showFillPriceHelp(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('成交价格怎么选'),
        content: const SingleChildScrollView(
          child: Text(
            '买点或卖点条件在第 N 根 K0 成立时，按下面规则撮合（买、卖共用同一选项）：\n\n'
            '· 本周期收盘价（默认）：在第 N 根按收盘价成交。'
            '信号当步已知、图上买1/卖1也在第 N 根，和交易明细的成交K一致。\n\n'
            '· 次周期开盘价：在第 N+1 根按开盘价成交。'
            '更保守；若后面没有下一根 K0，则该信号无法成交。\n\n'
            '滑点仍加在选定的原始价上；同一根既有买又有卖时仍先平后开。',
            style: TextStyle(fontSize: 13, height: 1.45),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('知道了'),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, TextEditingController c) {
    return TextField(
      controller: c,
      style: const TextStyle(fontSize: 13),
      decoration: InputDecoration(
        labelText: label,
        isDense: true,
        border: const OutlineInputBorder(),
      ),
      keyboardType: const TextInputType.numberWithOptions(decimal: true),
      inputFormatters: [
        FilteringTextInputFormatter.allow(RegExp(r'[0-9.]')),
      ],
      onSubmitted: (_) => _flushNums(),
    );
  }
}
