import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'strategy_config.dart';

/// 第一版条件搭建：每边只选一层，CLOSE/布林轨跟着那一层走。
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

class _StrategyConfigFormState extends State<StrategyConfigForm> {
  late final TextEditingController _qty;
  late final TextEditingController _cap;
  late final TextEditingController _fee;
  late final TextEditingController _slip;

  @override
  void initState() {
    super.initState();
    _qty = TextEditingController(text: '${widget.config.quantity}');
    _cap = TextEditingController(
      text: widget.config.initialCapital.toStringAsFixed(0),
    );
    _fee = TextEditingController(text: '${widget.config.commissionRate}');
    _slip = TextEditingController(text: '${widget.config.slippageAmount}');
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
    super.dispose();
  }

  StrategyConfig _readConfig() {
    final q = int.tryParse(_qty.text);
    final c = double.tryParse(_cap.text);
    final f = double.tryParse(_fee.text);
    final s = double.tryParse(_slip.text);
    var next = widget.config;
    if (q != null && q > 0) next = next.copyWith(quantity: q);
    if (c != null && c > 0) next = next.copyWith(initialCapital: c);
    if (f != null && f >= 0) next = next.copyWith(commissionRate: f);
    if (s != null && s >= 0) next = next.copyWith(slippageAmount: s);
    return next;
  }

  void _flushNums() {
    widget.onChanged(_readConfig());
  }

  @override
  Widget build(BuildContext context) {
    final maxKn = widget.maxKn < 0 ? 0 : widget.maxKn;
    final kns = [for (var i = 0; i <= maxKn; i++) i];
    final cfg = widget.config;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        const Text(
          '买入（同层同钟，不能混层）',
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 4),
        _knRow(
          value: cfg.buyKn.clamp(0, maxKn),
          kns: kns,
          onPick: (k) {
            widget.onChanged(_readConfig().copyWith(buyKn: k));
          },
          rest: '收盘  下穿  布林下轨',
        ),
        const SizedBox(height: 8),
        const Text(
          '卖出（同层同钟，不能混层）',
          style: TextStyle(fontSize: 12, color: Color(0xFF94A3B8)),
        ),
        const SizedBox(height: 4),
        _knRow(
          value: cfg.sellKn.clamp(0, maxKn),
          kns: kns,
          onPick: (k) {
            widget.onChanged(_readConfig().copyWith(sellKn: k));
          },
          rest: '收盘  上穿  布林上轨',
        ),
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
                  final next = _readConfig();
                  widget.onChanged(next);
                  widget.onRun?.call(next);
                },
          icon: const Icon(Icons.play_arrow, size: 18),
          label: Text(widget.running ? '正在回测…' : '运行回测'),
        ),
      ],
    );
  }

  Widget _knRow({
    required int value,
    required List<int> kns,
    required ValueChanged<int> onPick,
    required String rest,
  }) {
    return Row(
      children: [
        SizedBox(
          width: 88,
          child: DropdownButtonFormField<int>(
            isExpanded: true,
            value: kns.contains(value) ? value : kns.first,
            decoration: const InputDecoration(
              labelText: '层',
              isDense: true,
              border: OutlineInputBorder(),
              contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
            ),
            items: [
              for (final k in kns)
                DropdownMenuItem(value: k, child: Text('K$k')),
            ],
            onChanged: (v) {
              if (v != null) onPick(v);
            },
          ),
        ),
        const SizedBox(width: 8),
        Expanded(
          child: Text(
            rest,
            style: const TextStyle(fontSize: 13, color: Color(0xFFE2E8F0)),
          ),
        ),
      ],
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
