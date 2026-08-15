import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'condition_ast.dart';
import 'strategy_compile.dart';
import 'strategy_config.dart';
import 'trade_operand.dart';

/// 通用条件构建器：比较 / 穿越 / AND / OR / 变量 vs 常数。只搭 AST，不算真假。
class StrategyConfigForm extends StatefulWidget {
  final StrategyConfig config;
  final int maxKn;
  final ValueChanged<StrategyConfig> onChanged;
  final ValueChanged<StrategyConfig>? onRun;
  final bool running;

  const StrategyConfigForm({
    super.key,
    required this.config,
    required this.maxKn,
    required this.onChanged,
    this.onRun,
    this.running = false,
  });

  @override
  State<StrategyConfigForm> createState() => _StrategyConfigFormState();
}

class _LeafDraft {
  int kn;
  String leftKey;
  TradeBinaryOp op;
  bool rightIsConst;
  String rightKey;
  double rightConst;

  _LeafDraft({
    required this.kn,
    required this.leftKey,
    required this.op,
    required this.rightIsConst,
    required this.rightKey,
    required this.rightConst,
  });

  factory _LeafDraft.fromCmp(TradeCmpAst cmp, {int fallbackKn = 0}) {
    final leftParsed = cmp.left is TradeVarRef
        ? parseFirstBatchId((cmp.left as TradeVarRef).variableId)
        : null;
    final kn = leftParsed?.kn ??
        (cmp.right is TradeVarRef
            ? parseFirstBatchId((cmp.right as TradeVarRef).variableId)?.kn
            : null) ??
        fallbackKn;
    final leftKey = leftParsed?.key ?? 'CLOSE';
    final rightIsConst = cmp.right is TradeConstRef;
    final rightParsed = cmp.right is TradeVarRef
        ? parseFirstBatchId((cmp.right as TradeVarRef).variableId)
        : null;
    return _LeafDraft(
      kn: kn,
      leftKey: leftKey,
      op: cmp.op,
      rightIsConst: rightIsConst,
      rightKey: rightParsed?.key ?? 'BOLL.DOWN',
      rightConst: cmp.right is TradeConstRef
          ? (cmp.right as TradeConstRef).value
          : 0,
    );
  }

  TradeCmpAst toCmp() {
    final leftSpec = specByKey(leftKey) ?? kStrategyFirstBatch.first;
    final left = TradeVarRef(leftSpec.idOf(kn));
    final TradeValueRef right;
    if (rightIsConst) {
      right = TradeConstRef(rightConst);
    } else {
      final rs = specByKey(rightKey) ?? kStrategyFirstBatch.last;
      right = TradeVarRef(rs.idOf(kn));
    }
    return TradeCmpAst(left: left, right: right, op: op);
  }
}

class _SideDraft {
  List<_LeafDraft> leaves;
  List<CondJoin> joins;

  _SideDraft({required this.leaves, required this.joins});

  factory _SideDraft.fromAst(TradeAst ast, {int fallbackKn = 0}) {
    final flat = flattenAstChain(ast);
    final leaves = [
      for (final c in flat.leaves) _LeafDraft.fromCmp(c, fallbackKn: fallbackKn),
    ];
    if (leaves.isEmpty) {
      leaves.add(_LeafDraft.fromCmp(kDefaultBollBuyAst, fallbackKn: fallbackKn));
    }
    return _SideDraft(leaves: leaves, joins: [...flat.joins]);
  }

  TradeAst toAst() {
    final cmps = [for (final l in leaves) l.toCmp()];
    return foldAstChain(cmps, joins);
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
                leftKey: 'CLOSE',
                op: TradeBinaryOp.lt,
                rightIsConst: false,
                rightKey: 'BOLL.MID',
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
    const ops = <TradeBinaryOp>[
      TradeBinaryOp.gt,
      TradeBinaryOp.lt,
      TradeBinaryOp.ge,
      TradeBinaryOp.le,
      TradeBinaryOp.crossAbove,
      TradeBinaryOp.crossBelow,
    ];
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
                    setState(() {});
              _emit();
                  },
                ),
              ),
              const SizedBox(width: 6),
              Expanded(
                child: DropdownButtonFormField<String>(
                  isExpanded: true,
                  value: specByKey(leaf.leftKey) == null
                      ? kStrategyFirstBatch.first.key
                      : leaf.leftKey,
                  decoration: _dec('左'),
                  items: [
                    for (final s in kStrategyFirstBatch)
                      DropdownMenuItem(value: s.key, child: Text(s.label)),
                  ],
                  onChanged: (v) {
                    if (v == null) return;
                    leaf.leftKey = v;
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
                  value: ops.contains(leaf.op) ? leaf.op : TradeBinaryOp.gt,
                  decoration: _dec('关系'),
                  items: [
                    for (final o in ops)
                      DropdownMenuItem(
                        value: o,
                        child: Text(tradeOpLabelCn(o)),
                      ),
                  ],
                  onChanged: (v) {
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
            ],
          ),
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
                    : DropdownButtonFormField<String>(
                        isExpanded: true,
                        value: specByKey(leaf.rightKey) == null
                            ? kStrategyFirstBatch.last.key
                            : leaf.rightKey,
                        decoration: _dec('变量'),
                        items: [
                          for (final s in kStrategyFirstBatch)
                            DropdownMenuItem(
                              value: s.key,
                              child: Text(s.label),
                            ),
                        ],
                        onChanged: (v) {
                          if (v == null) return;
                          leaf.rightKey = v;
                          setState(() {});
              _emit();
                        },
                      ),
              ),
            ],
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
