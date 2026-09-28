import 'package:chan_kline/backtest/condition_ast.dart';
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
  final cap = opt.capped ? opt.maxCandidates : null;
  _appendNumericCross(pool, out, cap: cap);
  if (cap == null || out.length < cap) {
    _appendThresholds(pool, out, cap: cap);
  }
  if (cap != null && out.length > cap) {
    return out.sublist(0, cap);
  }
  return out;
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
