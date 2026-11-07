import '../models/chart_indicator.dart';
import '../models/divergence_algo.dart';
import 'buy_n_var.dart';
import 'condition_ast.dart';
import 'strategy_config.dart';

/// 把策略买/卖条件里引用的变量，推导成「应在主图/副图显示」的指标集合。
///
/// 用途：运行回测（及寻优「在 K 线图查看」）后，主/副图显示集按
/// [strategyDisplayIndicators] 重算（完全替换，不保留上一次或手工勾选）。
/// 映射只认变量 ID 的面板/字段前缀，不重新计算任何值。
///
/// - RAW 开高低收是 K 线本体（常显），只有成交量/笔数进副图；
/// - RAW/MAIN/SUB 的数值与对象投影按前缀落到对应主/副图指标；
/// - STRUCTURE 买卖点（买+卖同槽）→ 副图 buy1/buy2/buyN；背驰默认取面积算法副图；
///   确认/未确认中枢数值投影 → 主图中枢；
/// - CHIP.PEAK / TICK.PEAK 走筹码配置，不是标准副图指标，忽略。
({Set<MainChartIndicator> main, Set<SubChartIndicator> sub})
    indicatorsFromStrategyConfig(StrategyConfig cfg) {
  final rawIds = <String>[];
  collectAstVarIds(cfg.buyAst, rawIds);
  collectAstVarIds(cfg.sellAst, rawIds);

  final main = <MainChartIndicator>{};
  final sub = <SubChartIndicator>{};

  for (final id in rawIds) {
    final parts = canonicalizeTradeVarId(id).split('.');
    if (parts.length < 3 || !parts[1].startsWith('K')) continue;
    final kn = int.tryParse(parts[1].substring(1));
    if (kn == null || kn < 0) continue;

    switch (parts[0]) {
      case 'RAW':
        // 开高低收是 K 线本体（常显）；成交量/笔数才进副图
        if (parts.length == 3) {
          if (parts[2] == 'VOLUME') {
            sub.add(SubChartIndicator.volume(kn));
          } else if (parts[2] == 'TICK_COUNT') {
            sub.add(SubChartIndicator.tickCount(kn));
          }
        }
      case 'MAIN':
        if (parts.length < 4) break;
        switch (parts[2]) {
          case 'BOLL':
            main.add(MainChartIndicator.boll(kn));
          case 'DONCHIAN':
            main.add(MainChartIndicator.donchian(kn));
          case 'MA':
            main.add(MainChartIndicator.meanLine(kn));
          case 'REGRESS':
            main.add(MainChartIndicator.regressionChannel(kn));
          case 'DEMARK':
            main.add(MainChartIndicator.demark(kn));
          case 'FX_TRIPLE':
            main.add(MainChartIndicator.fxTripleParallel(kn));
          case 'FX_QUAD':
            main.add(MainChartIndicator.fxQuadPair(kn));
          case 'FX_CHORD_TRANSLATED':
            main.add(MainChartIndicator.fxChordTranslated(kn));
          case 'FX_BOTTOM_SNUG':
            main.add(MainChartIndicator.fxBottomSnug(kn));
          case 'FX_TOP_SNUG':
            main.add(MainChartIndicator.fxTopSnug(kn));
          case 'TREND_LINE':
            main.add(MainChartIndicator.trendLine(kn));
          case 'STEP_RHYTHM':
            main.add(MainChartIndicator.stepRhythm(kn));
        }
      case 'SUB':
        switch (parts[2]) {
          case 'MACD':
            sub.add(SubChartIndicator.macd(kn));
          case 'RSI':
            sub.add(SubChartIndicator.rsi(kn));
          case 'KDJ':
            sub.add(SubChartIndicator.kdj(kn));
          case 'FRACTAL_CONFIRM':
            sub.add(SubChartIndicator.fractalConfirm(kn));
          case 'FRACTAL_JUDGMENT':
            sub.add(SubChartIndicator.fractalJudgment(kn));
          case 'ZS_CONFIRM':
            sub.add(SubChartIndicator.zsConfirm(kn));
          case 'ZS_JUDGMENT':
            sub.add(SubChartIndicator.zsJudgment(kn));
          case 'LINE_SLOPE':
            sub.add(SubChartIndicator.lineSlope(kn));
          case 'ADJACENT_RATIO':
            sub.add(SubChartIndicator.adjacentRatio(kn));
          case 'VOLUME':
            sub.add(SubChartIndicator.volume(kn));
          case 'TICK_COUNT':
            sub.add(SubChartIndicator.tickCount(kn));
          // CHIP.PEAK / TICK.PEAK：走筹码配置，不是标准副图指标，忽略
        }
      case 'STRUCTURE':
        if (parts.length == 3) {
          // 一类/二类买卖点（买+卖同槽）
          if (parts[2] == 'BUY1' || parts[2] == 'SELL1') {
            sub.add(SubChartIndicator.buy1(kn));
          } else if (parts[2] == 'BUY2' || parts[2] == 'SELL2') {
            sub.add(SubChartIndicator.buy2(kn));
          }
        } else if (parts.length == 4 && parts[2] == 'BUY_N') {
          final cls = int.tryParse(parts[3]);
          if (cls != null) {
            // 全部类号(0/-1)或无类号：落到最小的可见 N 类槽（三类）
            final c = cls < 3 ? 3 : cls;
            sub.add(SubChartIndicator.buyN(kn, c));
          }
        } else if (parts.length == 4 && parts[2] == 'SELL_N') {
          final cls = int.tryParse(parts[3]);
          if (cls != null) {
            final c = cls < 3 ? 3 : cls;
            sub.add(SubChartIndicator.buyN(kn, c));
          }
        } else if (parts.length >= 4 && parts[2] == 'DIVERGENCE') {
          // 背驰默认取面积算法副图（ensureMacdForDivergenceArea 会顺带并入同号 MACD）
          sub.add(SubChartIndicator.divergence(kn, DivergenceAlgo.area));
        } else if (parts.length == 5 &&
            parts[2] == 'ZS' &&
            (parts[3] == 'CURRENT' || parts[3] == 'ACTIVE')) {
          // 确认/未确认中枢数值投影 → 主图中枢
          main.add(MainChartIndicator.zs(kn));
        }
    }
  }

  return (main: main, sub: sub);
}

/// 回测/寻优投图后的主/副图显示集：**完全替换**（不保留上次点击，也不保留手工勾选）。
///
/// 三步口径（策略回测入口与寻优「在 K 线图查看」共用，保证两处一致）：
/// 1. **不再显示默认显示的指标**：本函数只产出条件引用 + 固定上级，默认那批（主图
///    K{n}/K{n}合并/K{n}中枢/K{n}连线 与副图分型确认/分型判断/截断/中枢确认/中枢判断，
///    见 [isDefaultDrawnMain] / [isDefaultDrawnSub]）除非条件引用到，否则一律不出现。
/// 2. **只叠加本策略条件引用**：[indicatorsFromStrategyConfig] 的映射。
/// 3. **固定显示上级指标**：产出的每个 K{n} 层，强制并入 K{n} 与 K{n}连线作为读图骨架
///    （该层中枢不强制）；主图一层都没有时兜底挂 K0 + K0连线，否则蜡烛不画。
///    副图无上级概念，不加。
///
/// 最后按当前 maxKn 走一次 [pruneIndicators] 裁剪，背驰项顺手走一次
/// [ensureMacdForDivergenceArea] 并入同号 MACD。返回裁剪后的新集合。
///
/// 只影响主/副图「显示集」，不参与任何缠论计算（步进管道与回测引擎仍算全量）。
({Set<MainChartIndicator> main, Set<SubChartIndicator> sub})
    strategyDisplayIndicators({
  required StrategyConfig cfg,
  required int maxKn,
  required bool truncationCheck,
  required int maxBsClass,
}) {
  final cond = indicatorsFromStrategyConfig(cfg);

  final mergedMain = <MainChartIndicator>{...cond.main};
  final levels = <int>{for (final e in mergedMain) e.kn};
  // 兜底：条件只用副图指标时主图会空掉（连蜡烛都不画），固定挂 K0 + K0连线作根骨架。
  if (levels.isEmpty) levels.add(0);
  for (final n in levels) {
    mergedMain
      ..add(MainChartIndicator.kn(n))
      ..add(MainChartIndicator.line(n));
  }

  final nextMain = pruneIndicators(
    mergedMain,
    buildMainIndicatorCatalog(maxKn),
  );
  final nextSub = ensureMacdForDivergenceArea(pruneIndicators(
    cond.sub,
    buildSubIndicatorCatalog(
      maxKn,
      truncationCheck: truncationCheck,
      maxBsClass: maxBsClass,
    ),
  ));
  return (main: nextMain, sub: nextSub);
}
