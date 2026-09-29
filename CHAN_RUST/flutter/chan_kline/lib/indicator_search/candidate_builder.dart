import 'dart:math' as math;

import 'package:chan_kline/backtest/condition_ast.dart';
import 'package:chan_kline/backtest/signal_data_catalog.dart';
import 'package:chan_kline/backtest/strategy_config.dart';
import 'package:chan_kline/backtest/trade_operand.dart';

import 'search_core.dart';
import 'variable_pool.dart';

enum CandidateBuildProfile { legacyFull, optimized }

class CandidateBuildOptions {
  final CandidateBuildProfile profile;
  /// 0 = 不截断（仅 legacyFull 推荐全量）。
  final int maxCandidates;

  const CandidateBuildOptions.legacyFull()
      : profile = CandidateBuildProfile.legacyFull,
        maxCandidates = 0;

  const CandidateBuildOptions.optimized({this.maxCandidates = 12000})
      : profile = CandidateBuildProfile.optimized;

  bool get capped => maxCandidates > 0;
}

List<ComboCand> buildCandidates(VariablePool pool, [CandidateBuildOptions? opt]) {
  final options = opt ?? const CandidateBuildOptions.optimized();
  if (options.profile == CandidateBuildProfile.legacyFull) {
    return _buildLegacyFull(pool);
  }
  return _buildOptimized(pool, options);
}

List<ComboCand> _buildLegacyFull(VariablePool pool) {
  final out = <ComboCand>[];
  _appendEventCross(pool, out);
  _appendNumericCross(pool, out, cap: null);
  _appendThresholds(pool, out, cap: null);
  return out;
}

List<ComboCand> _buildOptimized(VariablePool pool, CandidateBuildOptions opt) {
  final out = <ComboCand>[];
  _appendCompositeTemplates(pool, out);
  _appendEventCross(pool, out);
  final cap = opt.maxCandidates;
  if (!opt.capped) {
    _appendNumericCross(pool, out, cap: null);
    _appendThresholds(pool, out, cap: null);
    return out;
  }
  if (cap <= out.length) {
    return out;
  }
  final reserveThreshold =
      (cap * 0.12).round().clamp(0, math.min(1400, cap ~/ 3));
  final reserveUpperEntries =
      (cap * 0.28).round().clamp(0, math.min(4000, cap ~/ 2));
  final minUpperKPairs = reserveUpperEntries ~/ 2;
  final crossCap = (cap - reserveThreshold).clamp(0, cap).toInt();
  _appendNumericCrossLayered(
    pool,
    out,
    cap: crossCap,
    minUpperKPairs: minUpperKPairs,
  );
  final thresholdCap = (out.length + reserveThreshold).clamp(0, cap).toInt();
  if (out.length < cap) {
    _appendThresholds(pool, out, cap: thresholdCap);
  }
  if (out.length > cap) {
    return out.sublist(0, cap);
  }
  return out;
}

/// 按组合名称前缀统计本次枚举构成（供结果面板展示）。
class CandidateBuildSummary {
  final int templates;
  final int events;
  final int crosses;
  final int crossesK1Plus;
  final int thresholds;
  final int total;

  const CandidateBuildSummary({
    required this.templates,
    required this.events,
    required this.crosses,
    required this.crossesK1Plus,
    required this.thresholds,
    required this.total,
  });

  String toDisplayLine() =>
      '枚举构成：模板 $templates · 事件 $events · 穿越 $crosses（K1+ $crossesK1Plus）'
      ' · 阈值 $thresholds · 共 $total';
}

CandidateBuildSummary summarizeCandidates(List<ComboCand> cands) {
  var templates = 0, events = 0, crosses = 0, crossesK1Plus = 0, thresholds = 0;
  final k1Re = RegExp(r'K[1-9]');
  for (final c in cands) {
    if (c.name.startsWith('模板｜')) {
      templates++;
    } else if (c.name.startsWith('事件｜')) {
      events++;
    } else if (c.name.startsWith('穿越｜')) {
      crosses++;
      if (k1Re.hasMatch(c.name)) crossesK1Plus++;
    } else if (c.name.startsWith('阈值｜')) {
      thresholds++;
    }
  }
  return CandidateBuildSummary(
    templates: templates,
    events: events,
    crosses: crosses,
    crossesK1Plus: crossesK1Plus,
    thresholds: thresholds,
    total: cands.length,
  );
}

void _appendCompositeTemplates(VariablePool pool, List<ComboCand> out) {
  final maxKn = pool.maxKn;
  for (var kn = 0; kn <= maxKn; kn++) {
    final boll = StrategyConfig.bollLayers(buyKn: kn, sellKn: kn);
    out.add(ComboCand(
      '模板｜布林 K$kn',
      boll.buyAst,
      boll.sellAst,
    ));
    if (kn == 1) {
      out.add(ComboCand(
        '模板｜K1 综合布林',
        k1CompositeBuyAst(),
        k1CompositeSellAst(),
      ));
      out.add(ComboCand(
        '模板｜K1 MACD+RSI',
        k1MacdRsiBuyAst(),
        k1MacdRsiSellAst(),
      ));
    }
  }
}

void _appendEventCross(VariablePool pool, List<ComboCand> out) {
  for (final b in pool.buyEvents()) {
    for (final s in pool.sellEvents()) {
      out.add(ComboCand(
        '事件｜买${b.displayName} 卖${s.displayName}',
        TradeEventAst(b.variableId),
        TradeEventAst(s.variableId),
      ));
    }
  }
}

int _pairLayerKn((TradeVariableDef, TradeVariableDef) pair) {
  final a = pair.$1.displayKn ?? 0;
  final b = pair.$2.displayKn ?? 0;
  return a > b ? a : b;
}

void _appendNumericCrossLayered(
  VariablePool pool,
  List<ComboCand> out, {
  required int cap,
  required int minUpperKPairs,
}) {
  const baseSell = TradeEventAst('STRUCTURE.K0.SELL1');
  final sellPool = <TradeAst>{
    baseSell,
    ...pool.sellEvents().map((e) => TradeEventAst(e.variableId)),
  }.toList();

  final pairs = pool.sameClockNumericPairs();
  final upper = <(TradeVariableDef, TradeVariableDef)>[];
  final k0 = <(TradeVariableDef, TradeVariableDef)>[];
  for (final p in pairs) {
    if (_pairLayerKn(p) >= 1) {
      upper.add(p);
    } else {
      k0.add(p);
    }
  }

  var k = 0;
  var upperPairIdx = 0;
  var k0PairIdx = 0;
  var upperPairsUsed = 0;

  void emitPair((TradeVariableDef, TradeVariableDef) pair) {
    for (final op in const [TradeBinaryOp.crossAbove, TradeBinaryOp.crossBelow]) {
      if (out.length >= cap) return;
      final sell = sellPool[k % sellPool.length];
      k++;
      out.add(ComboCand(
        '穿越｜${pair.$1.displayName} ${tradeOpLabelCn(op)} ${pair.$2.displayName}',
        TradeCmpAst(
          left: TradeVarRef(pair.$1.variableId),
          right: TradeVarRef(pair.$2.variableId),
          op: op,
        ),
        sell,
      ));
    }
  }

  while (out.length < cap && upperPairIdx < upper.length) {
    if (upperPairsUsed >= minUpperKPairs) break;
    emitPair(upper[upperPairIdx++]);
    upperPairsUsed++;
  }
  while (out.length < cap && k0PairIdx < k0.length) {
    emitPair(k0[k0PairIdx++]);
  }
  while (out.length < cap && upperPairIdx < upper.length) {
    emitPair(upper[upperPairIdx++]);
  }
}

void _appendNumericCross(
  VariablePool pool,
  List<ComboCand> out, {
  int? cap,
}) {
  const baseSell = TradeEventAst('STRUCTURE.K0.SELL1');
  final sellPool = <TradeAst>{
    baseSell,
    ...pool.sellEvents().map((e) => TradeEventAst(e.variableId)),
  }.toList();

  final pairs = pool.sameClockNumericPairs();
  var k = 0;
  for (final (l, r) in pairs) {
    if (cap != null && out.length >= cap) return;
    for (final op in const [TradeBinaryOp.crossAbove, TradeBinaryOp.crossBelow]) {
      if (cap != null && out.length >= cap) return;
      final sell = sellPool[k % sellPool.length];
      k++;
      out.add(ComboCand(
        '穿越｜${l.displayName} ${tradeOpLabelCn(op)} ${r.displayName}',
        TradeCmpAst(
          left: TradeVarRef(l.variableId),
          right: TradeVarRef(r.variableId),
          op: op,
        ),
        sell,
      ));
    }
  }
}

void _appendThresholds(
  VariablePool pool,
  List<ComboCand> out, {
  int? cap,
}) {
  const baseSell = TradeEventAst('STRUCTURE.K0.SELL1');
  final sellPool = <TradeAst>{
    baseSell,
    ...pool.sellEvents().map((e) => TradeEventAst(e.variableId)),
  }.toList();
  var k = out.length;

  for (final d in pool.numeric) {
    if (cap != null && out.length >= cap) return;
    final consts = VariablePool.constantsFor(d);
    if (consts.isEmpty) continue;
    for (final c in consts) {
      for (final op in const [TradeBinaryOp.gt, TradeBinaryOp.lt]) {
        if (cap != null && out.length >= cap) return;
        final sell = sellPool[k % sellPool.length];
        k++;
        out.add(ComboCand(
          '阈值｜${d.displayName} ${tradeOpLabelCn(op)} $c',
          TradeCmpAst(
            left: TradeVarRef(d.variableId),
            right: TradeConstRef(c),
            op: op,
          ),
          sell,
        ));
      }
    }
  }
}
